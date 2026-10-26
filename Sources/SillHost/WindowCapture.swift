import Foundation
import ScreenCaptureKit
import CoreMedia

/// Runs one ScreenCaptureKit stream (a window or a display) and hands out 420f pixel buffers.
/// The coordinator stops and restarts it whenever the client picks a different source.
final class WindowCapture: NSObject, SCStreamOutput, SCStreamDelegate {
    struct Stop: Sendable {
        let error: any Error
        fileprivate let generation: UUID
    }

    // SCK's delegate and output queues may race an awaited start/stop on the coordinator.
    private let stateLock = NSLock()
    private var stream: SCStream?
    private var generation = UUID()
    private var startupFailure: (any Error)?
    private let queue = DispatchQueue(label: "sill.capture", qos: .userInteractive)
    var onFrame: ((CVPixelBuffer, CMTime) -> Void)?
    /// The stream ended on its own (window closed, permission revoked). Called on an SCK thread.
    var onStopped: ((Stop) -> Void)?

    /// Recheck after an executor hop: a failure from the previous stream cannot stop its successor.
    func isCurrent(_ stop: Stop) -> Bool {
        stateLock.withLock { generation == stop.generation }
    }

    /// `showsCursor`: draw the Mac cursor into the frames. The host passes false: the client draws
    /// the pointer itself (with the Mac's current shape, sent separately), so the video never
    /// carries a round-trip-late cursor. Never change this on a running stream:
    /// `SCStream.updateConfiguration` wedged the stream on macOS 27 (frames stopped, the next
    /// `stopCapture` never returned, and the coordinator's switch flag stayed set for good).
    ///
    /// `sourceRect`: `--virtual-display` only. The part of a display filter to encode, in points in
    /// the display's own coordinate system (origin at its top-left, SCStream.h), i.e. exactly the
    /// staged window's rectangle, so the device gets the window and nothing else. Nil (the default,
    /// and the whole default path) leaves the configuration exactly as it was.
    /// `nativeCadence`: only for a display whose actual clock equals the negotiated FPS. A second
    /// 1/fps throttle can miss a compositor deadline; zero follows that display's native clock.
    func start(filter: SCContentFilter, width: Int, height: Int, fps: Int, showsCursor: Bool, sourceRect: CGRect? = nil,
               nativeCadence: Bool = false) async throws {
        let config = SCStreamConfiguration()
        config.width = width
        config.height = height
        config.pixelFormat = kCVPixelFormatType_420YpCbCr8BiPlanarFullRange
        config.minimumFrameInterval = nativeCadence ? .zero : CMTime(value: 1, timescale: CMTimeScale(fps))
        config.queueDepth = 5   // headroom: a wedged encoder may keep one buffer forever
        config.showsCursor = showsCursor
        config.colorSpaceName = CGColorSpace.sRGB
        if let sourceRect {
            config.sourceRect = sourceRect
            config.ignoreShadowsDisplay = true                 // the crop is the window's frame; its shadow would be clipped anyway
            config.backgroundColor = Self.black                  // deterministic black behind the rounded corners
        }

        let stream = SCStream(filter: filter, configuration: config, delegate: self)
        try stream.addStreamOutput(self, type: .screen, sampleHandlerQueue: queue)
        // Register before starting: a stop error that arrives during start must not be swallowed
        // by the identity check in didStopWithError.
        stateLock.withLock {
            self.stream = stream
            generation = UUID()
            startupFailure = nil
            framesSeen = 0
        }
        do {
            try await stream.startCapture()
            // A delegate error may have arrived while startCapture was suspended.
            let failure: (any Error)? = stateLock.withLock {
                self.stream === stream ? nil : (startupFailure ?? CancellationError())
            }
            if let failure { throw failure }
        } catch {
            stateLock.withLock {
                if self.stream === stream { self.stream = nil }
            }
            try? await stream.stopCapture()
            await drainOutputQueue()
            throw error
        }
        let crop = sourceRect.map { String(format: " sourceRect (%.0f,%.0f,%.0f,%.0f)", $0.minX, $0.minY, $0.width, $0.height) } ?? ""
        print("Capture started: \(width)×\(height) @\(fps) fps, cadence \(nativeCadence ? "native display" : "limited"), cursor \(showsCursor ? "in" : "out"), filter \(filter.contentRect.size) scale \(filter.pointPixelScale)" + crop)
    }

    private var framesSeen = 0
    /// Held by the type: `SCStreamConfiguration.backgroundColor` is unowned(unsafe) and would not keep
    /// a temporary alive.
    private static let black = CGColor(gray: 0, alpha: 1)

    func stop() async {
        let previous = stateLock.withLock {
            let previous = stream
            stream = nil
            generation = UUID()
            startupFailure = nil
            return previous
        }
        if let previous { try? await previous.stopCapture() }
        // stopCapture returning does not mean the sample-handler queue has drained. Wait for it,
        // even when didStopWithError already cleared the stream.
        await drainOutputQueue()
    }

    private func drainOutputQueue() async {
        await withCheckedContinuation { (c: CheckedContinuation<Void, Never>) in queue.async { c.resume() } }
    }

    func stream(_ stream: SCStream, didOutputSampleBuffer sampleBuffer: CMSampleBuffer, of type: SCStreamOutputType) {
        guard type == .screen else { return }
        guard let attachments = CMSampleBufferGetSampleAttachmentsArray(sampleBuffer, createIfNecessary: false) as? [[SCStreamFrameInfo: Any]],
              let statusRaw = attachments.first?[.status] as? Int,
              let status = SCFrameStatus(rawValue: statusRaw)
        else { Stats.shared.bump("cap.noStatus"); return }
        // .idle frames (nothing changed) are skipped, which is what we want.
        guard status == .complete else { Stats.shared.bump(status == .idle ? "cap.idle" : "cap.status\(statusRaw)"); return }
        guard let pixelBuffer = CMSampleBufferGetImageBuffer(sampleBuffer) else { Stats.shared.bump("cap.noPixels"); return }
        let delivery = stateLock.withLock { () -> (current: Bool, first: Bool) in
            guard self.stream === stream else { return (false, false) }
            framesSeen += 1
            return (true, framesSeen == 1)
        }
        guard delivery.current else { return }
        Stats.shared.bump("cap.complete")
        if delivery.first { print("Capture: first frame \(CVPixelBufferGetWidth(pixelBuffer))×\(CVPixelBufferGetHeight(pixelBuffer))") }
        onFrame?(pixelBuffer, CMSampleBufferGetPresentationTimeStamp(sampleBuffer))
    }

    func stream(_ stream: SCStream, didStopWithError error: Error) {
        let stopped: Stop? = stateLock.withLock {
            guard stream === self.stream else { return nil }
            self.stream = nil
            startupFailure = error
            return Stop(error: error, generation: generation)
        }
        print("Capture stream stopped (\(stopped == nil ? "replaced" : "current")): \(error) — \((error as NSError).userInfo)")
        guard let stopped else { return }
        onStopped?(stopped)
    }
}

/// HEVC wants even dimensions.
func evenPixels(_ v: CGFloat) -> Int { Int(v.rounded(.down)) & ~1 }
