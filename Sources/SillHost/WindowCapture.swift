import Foundation
import ScreenCaptureKit
import CoreMedia
#if DUO_CAPTURE_DIAGNOSTICS
import IOSurface
#endif

/// Runs one ScreenCaptureKit stream (a window or a display) and hands out 420f pixel buffers.
/// The coordinator stops and restarts it whenever the client picks a different source.
final class WindowCapture: NSObject, SCStreamOutput, SCStreamDelegate {
    enum NativeGeometryFailure: LocalizedError {
        case filter, frame
        var errorDescription: String? {
            "系统采集的桌面尺寸或缩放比例与原生目标不一致。"
        }
    }

    /// The display mode's pixel canvas and SCK's source geometry must agree. Output dimensions
    /// alone cannot establish this: SCK can rescale the source to the requested surface size.
    struct NativeGeometry {
        let width: Int
        let height: Int
        private static let pixelTolerance = 0.01
        private static let scaleTolerance = 0.00001

        private static func near(_ a: Double, _ b: Double, tolerance: Double) -> Bool {
            a.isFinite && b.isFinite && abs(a - b) <= tolerance
        }
        func acceptsFilter(rect: CGRect, scale: Double) -> Bool {
            width > 0 && height > 0 && scale.isFinite && scale > 0
                && Self.near(Double(rect.width) * scale, Double(width), tolerance: Self.pixelTolerance)
                && Self.near(Double(rect.height) * scale, Double(height), tolerance: Self.pixelTolerance)
        }
        func acceptsFrame(width actualWidth: Int, height actualHeight: Int, rect: CGRect,
                          scale: Double, contentScale: Double, filterScale: Double) -> Bool {
            actualWidth == width && actualHeight == height
                && Self.near(scale, filterScale, tolerance: Self.scaleTolerance)
                && Self.near(contentScale, 1, tolerance: Self.scaleTolerance)
                && Self.near(Double(rect.minX) * scale, 0, tolerance: Self.pixelTolerance)
                && Self.near(Double(rect.minY) * scale, 0, tolerance: Self.pixelTolerance)
                && acceptsFilter(rect: rect, scale: scale)
        }
    }

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
    private var nativeGeometry: (geometry: NativeGeometry, scale: Double)?
    private var nativeGeometryRejected = false
    private let queue = DispatchQueue(label: "sill.capture", qos: .userInteractive)
    #if DUO_CAPTURE_GEOMETRY_TESTING
    /// An owned-window fixture can ask SCK to scale the content, to exercise the live frame gate.
    var testDestinationRect: CGRect?
    private var testNextContentScale: Double?
    func overrideNextContentScaleForTesting(_ scale: Double) {
        stateLock.withLock { testNextContentScale = scale }
    }
    #endif
    #if DUO_CAPTURE_DIAGNOSTICS
    // Set only before starting a test stream. Production builds never expose this switch.
    var diagnosticUseStrictTimer = false
    private var diagnosticStrictTimer: StrictCaptureTimer?
    #endif
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
    /// Test-only view of actual SCK inputs before cadence selection. No production build includes it.
    var onUnpacedSample: ((CVPixelBuffer, CMTime, CMTime) -> Void)?
    /// For diagnostics that must retain a particular raw CMSampleBuffer through a GPU operation.
    var onUnpacedSampleBuffer: ((CMSampleBuffer) -> Void)?
    /// A diagnostic may retain the sample itself until its asynchronous GPU read completes.
    /// This hook is absent from production and must not capture anything outside its own fixture.
    var onDeliveredSample: ((CMSampleBuffer) -> Void)?
    static func diagnosticRect(_ value: Any) -> CGRect? {
        captureRect(value)
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
               nativeCadence: Bool = false, resampleCadence: Bool = false,
               requireNativeGeometry: Bool = false) async throws {
        precondition(!nativeCadence || !resampleCadence)
        let geometry = requireNativeGeometry ? NativeGeometry(width: width, height: height) : nil
        let filterScale = Double(filter.pointPixelScale)
        if let geometry, !geometry.acceptsFilter(rect: filter.contentRect, scale: filterScale) {
            throw NativeGeometryFailure.filter
        }
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
        #if DUO_CAPTURE_GEOMETRY_TESTING
        if let testDestinationRect { config.destinationRect = testDestinationRect }
        #endif

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
            nativeGeometry = geometry.map { ($0, filterScale) }
            nativeGeometryRejected = false
            framesSeen = 0
        }
        do {
            try await stream.startCapture()
            // A delegate error may have arrived while startCapture was suspended.
            let failure: (any Error)? = stateLock.withLock {
                startupFailure ?? (self.stream === stream ? nil : CancellationError())
            }
            if let failure { throw failure }
        } catch {
            stateLock.withLock {
                if self.stream === stream {
                    self.stream = nil
                    framePacer = nil
                    pendingSample = nil
                    pendingSampleToken = nil
                    nativeGeometry = nil
                    nativeGeometryRejected = false
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
            nativeGeometry = nil
            nativeGeometryRejected = false
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
        guard let image = CMSampleBufferGetImageBuffer(sampleBuffer) else { Stats.shared.bump("cap.noPixels"); return }
        let geometry = stateLock.withLock { self.stream === stream && !nativeGeometryRejected ? nativeGeometry : nil }
        if let geometry {
            let info = attachments.first!
            let scale = (info[.scaleFactor] as? NSNumber)?.doubleValue
            var contentScale = (info[.contentScale] as? NSNumber)?.doubleValue
            #if DUO_CAPTURE_GEOMETRY_TESTING
            if let injected = stateLock.withLock({ () -> Double? in
                defer { testNextContentScale = nil }
                return testNextContentScale
            }) { contentScale = injected }
            #endif
            let rect = info[.contentRect].flatMap(Self.captureRect)
            guard let scale, let contentScale, let rect,
                  geometry.geometry.acceptsFrame(width: CVPixelBufferGetWidth(image), height: CVPixelBufferGetHeight(image),
                                                 rect: rect, scale: scale, contentScale: contentScale,
                                                 filterScale: geometry.scale) else {
                rejectNativeGeometry(stream)
                return
            }
        }
        let pts = CMSampleBufferGetPresentationTimeStamp(sampleBuffer)
        #if DUO_CAPTURE_DIAGNOSTICS
        if let onUnpacedSample, let image = CMSampleBufferGetImageBuffer(sampleBuffer),
           stateLock.withLock({ self.stream === stream }) {
            let arrival = CMClockGetTime(CMClockGetHostTimeClock())
            onUnpacedSample(image, pts, arrival)
        }
        if let onUnpacedSampleBuffer, stateLock.withLock({ self.stream === stream }) {
            onUnpacedSampleBuffer(sampleBuffer)
        }
        #endif
        let selection = stateLock.withLock { () -> Selection in
            guard self.stream === stream, !nativeGeometryRejected else { return .ignored }
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
                let deadline = DispatchTime.now() + delay
                #if DUO_CAPTURE_DIAGNOSTICS
                if diagnosticUseStrictTimer {
                    if diagnosticStrictTimer == nil {
                        diagnosticStrictTimer = StrictCaptureTimer(queue: queue) { [weak self] token in
                            self?.deliverPendingSample(token)
                        }
                    }
                    diagnosticStrictTimer?.arm(deadline: deadline, token: token)
                } else {
                    queue.asyncAfter(deadline: deadline) { [weak self] in self?.deliverPendingSample(token) }
                }
                #else
                queue.asyncAfter(deadline: deadline) { [weak self] in self?.deliverPendingSample(token) }
                #endif
            }
        case .emit(let first, let replaced):
            #if DUO_CAPTURE_DIAGNOSTICS
            if diagnosticUseStrictTimer { diagnosticStrictTimer?.cancelPending() }
            #endif
            if replaced { Stats.shared.bump("cap.cadenceDrop") }
            deliver(sampleBuffer, first: first)
        }
    }

    private enum Selection {
        case ignored, discarded
        case held(replaced: Bool, timer: (TimeInterval, UUID)?)
        case emit(first: Bool, replaced: Bool)
    }

    /// Capture attachments encode rectangles as dictionaries; accept NSValue as well for the
    /// platform variants already exercised by the diagnostics. Invalid or missing data fails closed.
    static func captureRect(_ value: Any) -> CGRect? {
        if let rect = value as? CGRect { return rect }
        if let wrapped = value as? NSValue,
           String(cString: wrapped.objCType) == String(cString: NSValue(rect: .zero).objCType) {
            return wrapped.rectValue
        }
        if let dictionary = value as? [String: Any] {
            var rect = CGRect.zero
            if CGRectMakeWithDictionaryRepresentation(dictionary as CFDictionary, &rect) { return rect }
        }
        return nil
    }

    /// Keep the live stream for stop(): it still needs a real SCK stop and output-queue drain.
    /// At most one report escapes, and a held older sample is discarded before the callback.
    private func rejectNativeGeometry(_ stream: SCStream) {
        let stopped: Stop? = stateLock.withLock {
            guard self.stream === stream, !nativeGeometryRejected else { return nil }
            nativeGeometryRejected = true
            startupFailure = NativeGeometryFailure.frame
            framePacer = nil
            pendingSample = nil
            pendingSampleToken = nil
            return Stop(error: NativeGeometryFailure.frame, generation: generation)
        }
        if let stopped {
            print("Capture stopped: native desktop content was scaled or incomplete")
            onStopped?(stopped)
        }
    }

    /// Runs on the same serial queue as SCK output. This delivers an actual changed sample even
    /// if the desktop becomes static before the next eligible capture callback.
    private func deliverPendingSample(_ token: UUID) {
        let pending = stateLock.withLock { () -> (CMSampleBuffer, Bool)? in
            guard stream != nil, !nativeGeometryRejected, pendingSampleToken == token, let sample = pendingSample,
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
        onDeliveredSample?(sampleBuffer)
        #endif
        onFrame?(pixelBuffer, pts)
    }

    func stream(_ stream: SCStream, didStopWithError error: Error) {
        let stopped: Stop? = stateLock.withLock {
            guard stream === self.stream else { return nil }
            self.stream = nil
            framePacer = nil
            pendingSample = nil
            pendingSampleToken = nil
            nativeGeometry = nil
            // A geometry rejection has already notified the owner. A subsequent system stop
            // must not replace its failure or report the same stream a second time.
            guard !nativeGeometryRejected else { return nil }
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
