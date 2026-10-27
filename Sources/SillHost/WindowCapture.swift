import Foundation
import ScreenCaptureKit
import CoreMedia
#if DUO_CAPTURE_DIAGNOSTICS
import IOSurface
#endif

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
    private var framePacer: CaptureFramePacer?
    // At most one real sample waits for a pacing deadline. Replacing it keeps the newest image;
    // the token makes delayed work from a stopped or superseded stream harmless.
    private var pendingSample: CMSampleBuffer?
    private var pendingSampleToken: UUID?
    private let queue = DispatchQueue(label: "sill.capture", qos: .userInteractive)
    var onFrame: ((CVPixelBuffer, CMTime) -> Void)?
    #if DUO_CAPTURE_DIAGNOSTICS
    /// Test-only metadata from an admitted sample; never contains image pixels or window titles.
    struct SampleObservation {
        let displayTime: UInt64?
        let dirtyRectCount: Int?
        let dirtyCenter: Bool?
        let dirtyElementType: String?
        let surfaceID: UInt32?
    }
    var onSampleObservation: ((SampleObservation) -> Void)?
    static func diagnosticRect(_ value: Any) -> CGRect? {
        if let rect = value as? CGRect { return rect }
        if let wrapped = value as? NSValue { return wrapped.rectValue }
        if let dictionary = value as? [String: Any] {
            var rect = CGRect.zero
            if CGRectMakeWithDictionaryRepresentation(dictionary as CFDictionary, &rect) { return rect }
        }
        return nil
    }
    #endif
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
    /// `resampleCadence`: receive the faster source without SCK's extra limiter, then select real
    /// frames against a stable target clock. This never changes the source display's clock.
    func start(filter: SCContentFilter, width: Int, height: Int, fps: Int, showsCursor: Bool, sourceRect: CGRect? = nil,
               nativeCadence: Bool = false, resampleCadence: Bool = false) async throws {
        precondition(!nativeCadence || !resampleCadence)
        let config = SCStreamConfiguration()
        config.width = width
        config.height = height
        config.pixelFormat = kCVPixelFormatType_420YpCbCr8BiPlanarFullRange
        config.minimumFrameInterval = (nativeCadence || resampleCadence) ? .zero : CMTime(value: 1, timescale: CMTimeScale(fps))
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
            framePacer = resampleCadence ? CaptureFramePacer(fps: fps) : nil
            pendingSample = nil
            pendingSampleToken = nil
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
                if self.stream === stream {
                    self.stream = nil
                    framePacer = nil
                    pendingSample = nil
                    pendingSampleToken = nil
                }
            }
            try? await stream.stopCapture()
            await drainOutputQueue()
            throw error
        }
        let crop = sourceRect.map { String(format: " sourceRect (%.0f,%.0f,%.0f,%.0f)", $0.minX, $0.minY, $0.width, $0.height) } ?? ""
        let cadence = nativeCadence ? "native display" : resampleCadence ? "resampled" : "limited"
        print("Capture started: \(width)×\(height) @\(fps) fps, cadence \(cadence), cursor \(showsCursor ? "in" : "out"), filter \(filter.contentRect.size) scale \(filter.pointPixelScale)" + crop)
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
            framePacer = nil
            pendingSample = nil
            pendingSampleToken = nil
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
        guard CMSampleBufferGetImageBuffer(sampleBuffer) != nil else { Stats.shared.bump("cap.noPixels"); return }
        let pts = CMSampleBufferGetPresentationTimeStamp(sampleBuffer)
        let selection = stateLock.withLock { () -> Selection in
            guard self.stream === stream else { return .ignored }
            if var pacer = framePacer {
                let decision = pacer.consider(pts)
                framePacer = pacer
                switch decision {
                case .discard:
                    return .discarded
                case .hold(let wait):
                    let replaced = pendingSample != nil
                    pendingSample = sampleBuffer
                    if pendingSampleToken != nil { return .held(replaced: replaced, timer: nil) }
                    let token = UUID()
                    pendingSampleToken = token
                    return .held(replaced: replaced, timer: (wait, token))
                case .emit:
                    break
                }
            }
            let replaced = pendingSample != nil
            pendingSample = nil
            pendingSampleToken = nil
            framesSeen += 1
            return .emit(first: framesSeen == 1, replaced: replaced)
        }
        switch selection {
        case .ignored:
            return
        case .discarded:
            Stats.shared.bump("cap.cadenceDrop")
        case .held(let replaced, let timer):
            if replaced { Stats.shared.bump("cap.cadenceDrop") }
            if let (wait, token) = timer {
                // Sample PTS is on the stream's synchronization clock. `wait` starts at that
                // timestamp, so waiting the full interval again after callback delivery adds
                // avoidable latency. Fall back if the clock is unavailable or inconsistent.
                let now = stream.synchronizationClock.map { CMClockGetTime($0) }
                let delay = CaptureFramePacer.deliveryDelay(wait: wait, sampleTime: pts, clockTime: now)
                queue.asyncAfter(deadline: .now() + delay) { [weak self] in self?.deliverPendingSample(token) }
            }
        case .emit(let first, let replaced):
            if replaced { Stats.shared.bump("cap.cadenceDrop") }
            deliver(sampleBuffer, first: first)
        }
    }

    private enum Selection {
        case ignored, discarded
        case held(replaced: Bool, timer: (TimeInterval, UUID)?)
        case emit(first: Bool, replaced: Bool)
    }

    /// Runs on the same serial queue as SCK output. This delivers an actual changed sample even
    /// if the desktop becomes static before the next eligible capture callback.
    private func deliverPendingSample(_ token: UUID) {
        let pending = stateLock.withLock { () -> (CMSampleBuffer, Bool)? in
            guard stream != nil, pendingSampleToken == token, let sample = pendingSample,
                  var pacer = framePacer else { return nil }
            pendingSample = nil
            pendingSampleToken = nil
            pacer.deliveredHeldFrame()
            framePacer = pacer
            framesSeen += 1
            return (sample, framesSeen == 1)
        }
        if let (sample, first) = pending { deliver(sample, first: first) }
    }

    private func deliver(_ sampleBuffer: CMSampleBuffer, first: Bool) {
        guard let pixelBuffer = CMSampleBufferGetImageBuffer(sampleBuffer) else { return }
        let pts = CMSampleBufferGetPresentationTimeStamp(sampleBuffer)
        Stats.shared.bump("cap.complete")
        if first { print("Capture: first frame \(CVPixelBufferGetWidth(pixelBuffer))×\(CVPixelBufferGetHeight(pixelBuffer))") }
        #if DUO_CAPTURE_DIAGNOSTICS
        let attachments = CMSampleBufferGetSampleAttachmentsArray(sampleBuffer, createIfNecessary: false) as? [[SCStreamFrameInfo: Any]]
        let info = attachments?.first
        let displayTime = (info?[.displayTime] as? NSNumber)?.uint64Value
        let rectCount = (info?[.dirtyRects] as? [Any])?.count
        let rawRects = info?[.dirtyRects] as? [Any]
        let rects = rawRects?.compactMap(Self.diagnosticRect)
        let center = CGRect(x: CGFloat(CVPixelBufferGetWidth(pixelBuffer)) * 0.3,
                            y: CGFloat(CVPixelBufferGetHeight(pixelBuffer)) * 0.3,
                            width: CGFloat(CVPixelBufferGetWidth(pixelBuffer)) * 0.4,
                            height: CGFloat(CVPixelBufferGetHeight(pixelBuffer)) * 0.4)
        let dirtyCenter = rects.flatMap { rects -> Bool? in
            guard rects.count == rawRects?.count else { return nil }
            return rects.contains { $0.intersects(center) }
        }
        let dirtyElementType = rawRects?.first.map { String(reflecting: Swift.type(of: $0)) }
        let surfaceID = CVPixelBufferGetIOSurface(pixelBuffer).map { IOSurfaceGetID($0.takeUnretainedValue()) }
        onSampleObservation?(SampleObservation(displayTime: displayTime, dirtyRectCount: rectCount,
                                               dirtyCenter: dirtyCenter, dirtyElementType: dirtyElementType, surfaceID: surfaceID))
        #endif
        onFrame?(pixelBuffer, pts)
    }

    func stream(_ stream: SCStream, didStopWithError error: Error) {
        let stopped: Stop? = stateLock.withLock {
            guard stream === self.stream else { return nil }
            self.stream = nil
            startupFailure = error
            framePacer = nil
            pendingSample = nil
            pendingSampleToken = nil
            return Stop(error: error, generation: generation)
        }
        print("Capture stream stopped (\(stopped == nil ? "replaced" : "current")): \(error) — \((error as NSError).userInfo)")
        guard let stopped else { return }
        onStopped?(stopped)
    }
}

/// HEVC wants even dimensions.
func evenPixels(_ v: CGFloat) -> Int { Int(v.rounded(.down)) & ~1 }
