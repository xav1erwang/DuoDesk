// Copyright 2026 DUO你电脑 contributors. SPDX-License-Identifier: Apache-2.0
// Targeted held-sample lifetime check. This owns the window and uses only the current-process
// inventory. Its 60 fps pacing is a diagnostic input, not a 120 fps or desktop acceptance test.
import AppKit
import CoreMedia
import CoreVideo
import Darwin
import ScreenCaptureKit

setbuf(stdout, nil)
setenv("DUODESK_WORKLOAD_OWN_TEXT", "1", 1)
setenv("DUODESK_WORKLOAD_CLOCK", "timer", 1)
let app = NSApplication.shared
app.setActivationPolicy(.regular)
let workload = MainActor.assumeIsolated { DocumentWorkload(frameSize: NSSize(width: 1004, height: 714), usesStdin: false) }

/// An in-memory sample of the fixture's own luma plane. No pixel data or hashes are saved.
func fingerprint(_ pixel: CVPixelBuffer) -> UInt64? {
    guard CVPixelBufferGetPlaneCount(pixel) >= 1,
          CVPixelBufferLockBaseAddress(pixel, .readOnly) == kCVReturnSuccess else { return nil }
    defer { CVPixelBufferUnlockBaseAddress(pixel, .readOnly) }
    guard let bytes = CVPixelBufferGetBaseAddressOfPlane(pixel, 0)?.assumingMemoryBound(to: UInt8.self) else { return nil }
    let width = CVPixelBufferGetWidthOfPlane(pixel, 0), height = CVPixelBufferGetHeightOfPlane(pixel, 0)
    let row = CVPixelBufferGetBytesPerRowOfPlane(pixel, 0)
    guard width == 2008, height == 1428 else { return nil }
    var hash: UInt64 = 14_695_981_039_346_656_037
    for y in stride(from: 0, to: height, by: 47) {
        for x in stride(from: 0, to: width, by: 53) { hash = (hash ^ UInt64(bytes[y * row + x])) &* 1_099_511_628_211 }
    }
    return hash
}

final class Audit: NSObject, SCStreamOutput, @unchecked Sendable {
    struct Entry { let pts: CMTime; let hash: UInt64? }
    private let lock = NSLock()
    private let capture: WindowCapture
    private var raw: [Entry] = [], delivered: [Entry] = [], held: [CMTime] = []
    private var watching = false, stoppedWorkload = false, suppressed = 0
    private var lastRawAt = 0.0
    var onHeld: (() -> Void)?

    init(capture: WindowCapture) { self.capture = capture }
    func begin() { lock.withLock { watching = true } }
    func receive(_ image: CVPixelBuffer, _ pts: CMTime) {
        let entry = Entry(pts: pts, hash: fingerprint(image))
        lock.withLock { delivered.append(entry) }
    }
    func stream(_ stream: SCStream, didOutputSampleBuffer sample: CMSampleBuffer, of type: SCStreamOutputType) {
        // Once the first real sample is held, stop forwarding further callbacks. This creates the
        // exact end-of-burst condition without asserting that WindowServer itself became idle.
        let gated = lock.withLock { () -> Bool in
            if stoppedWorkload { suppressed += 1; return true }
            return false
        }
        guard !gated else { return }
        guard type == .screen,
              let attachments = CMSampleBufferGetSampleAttachmentsArray(sample, createIfNecessary: false) as? [[SCStreamFrameInfo: Any]],
              let status = attachments.first?[.status] as? Int, status == SCFrameStatus.complete.rawValue,
              let pixel = CMSampleBufferGetImageBuffer(sample) else { return }
        let pts = CMSampleBufferGetPresentationTimeStamp(sample)
        let entry = Entry(pts: pts, hash: fingerprint(pixel))
        lock.withLock { raw.append(entry); lastRawAt = ProcessInfo.processInfo.systemUptime }
        capture.stream(stream, didOutputSampleBuffer: sample, of: type)
        let isHeld: Bool = capture.stateLock.withLock {
            guard let pending = capture.pendingSample else { return false }
            return CMTimeCompare(CMSampleBufferGetPresentationTimeStamp(pending), pts) == 0
        }
        let notify = lock.withLock { () -> Bool in
            guard watching, isHeld else { return false }
            held.append(pts)
            if stoppedWorkload { return false }
            stoppedWorkload = true
            return true
        }
        if notify { onHeld?() }
    }
    func snapshot() -> (raw: [Entry], delivered: [Entry], held: [CMTime], stopped: Bool, suppressed: Int, lastRawAt: Double) {
        lock.withLock { (raw, delivered, held, stoppedWorkload, suppressed, lastRawAt) }
    }
}

func currentProcessContent() async -> SCShareableContent? {
    final class Once: @unchecked Sendable {
        private let lock = NSLock(); private var done = false
        func first() -> Bool { lock.withLock { if done { return false }; done = true; return true } }
    }
    let once = Once()
    return await withCheckedContinuation { continuation in
        SCShareableContent.getCurrentProcessShareableContent { content, _ in
            if once.first() { continuation.resume(returning: content) }
        }
        DispatchQueue.global().asyncAfter(deadline: .now() + 3) {
            if once.first() { continuation.resume(returning: nil) }
        }
    }
}

@MainActor
func run() async {
    let capture = WindowCapture()
    var display: VirtualWindowDisplay?
    var passed = false
    do {
        print("PACER CHECK PRECHECK: globalRecording=\(CGPreflightScreenCaptureAccess()); ownWindowOnly=true")
        guard let window = workload.window else { throw Failure.unavailable }
        let virtual = try VirtualWindowDisplay()
        display = virtual
        try await virtual.prepare(window: window)
        guard let content = await currentProcessContent(),
              let owned = content.windows.first(where: { $0.windowID == UInt32(window.windowNumber) && $0.owningApplication?.processID == getpid() }) else {
            throw Failure.unavailable
        }
        let filter = SCContentFilter(desktopIndependentWindow: owned)
        guard Int((filter.contentRect.width * CGFloat(filter.pointPixelScale)).rounded()) == 2008,
              Int((filter.contentRect.height * CGFloat(filter.pointPixelScale)).rounded()) == 1428 else { throw Failure.unavailable }
        let configuration = SCStreamConfiguration()
        configuration.width = 2008; configuration.height = 1428
        configuration.pixelFormat = kCVPixelFormatType_420YpCbCr8BiPlanarFullRange
        configuration.minimumFrameInterval = .zero; configuration.queueDepth = 5; configuration.showsCursor = false
        let stream = SCStream(filter: filter, configuration: configuration, delegate: nil)
        let audit = Audit(capture: capture)
        capture.onFrame = { image, pts in audit.receive(image, pts) }
        audit.onHeld = { Task { @MainActor in workload.stopScrolling() } }
        capture.stateLock.withLock { capture.stream = stream; capture.framePacer = CaptureFramePacer(fps: 60) }
        try stream.addStreamOutput(audit, type: .screen, sampleHandlerQueue: capture.queue)
        try await stream.startCapture()
        try await Task.sleep(for: .milliseconds(300))
        audit.begin()
        workload.startScrolling()
        let deadline = ContinuousClock.now + .seconds(4)
        while ContinuousClock.now < deadline {
            let state = audit.snapshot()
            if state.stopped, let last = state.raw.last, let sent = state.delivered.last,
               CMTimeCompare(last.pts, sent.pts) == 0 { break }
            try await Task.sleep(for: .milliseconds(30))
        }
        workload.stopScrolling()
        try virtual.checkOwnedWindow(window)
        let state = audit.snapshot()
        let output = state.delivered
        let hashesMatch = output.allSatisfy { entry in
            guard let hash = entry.hash, let original = state.raw.last(where: { CMTimeCompare($0.pts, entry.pts) == 0 }) else { return false }
            return original.hash == hash
        }
        let ordered = zip(output, output.dropFirst()).allSatisfy { CMTimeCompare($0.pts, $1.pts) < 0 }
        let heldDelivered = output.contains { result in state.held.contains { CMTimeCompare($0, result.pts) == 0 } }
        let finalMatches: Bool
        let finalWasHeld: Bool
        if let rawLast = state.raw.last, let deliveredLast = output.last {
            finalMatches = CMTimeCompare(rawLast.pts, deliveredLast.pts) == 0
            finalWasHeld = state.held.contains { CMTimeCompare($0, deliveredLast.pts) == 0 }
        } else {
            finalMatches = false
            finalWasHeld = false
        }
        passed = state.stopped && !state.held.isEmpty && heldDelivered && finalMatches && finalWasHeld && hashesMatch && ordered
        print("PACER ACTUAL SCK: forwarded=\(state.raw.count), delivered=\(output.count), held=\(state.held.count), laterCallbacksSuppressed=\(state.suppressed), heldDelivered=\(heldDelivered), lastForwardedMatches=\(finalMatches), lastForwardedWasHeld=\(finalWasHeld), buffersMatch=\(hashesMatch), strictlyOrdered=\(ordered), passed=\(passed)")
        print("SCOPE: own AppKit document; 2008×1428; independent 120 Hz virtual display; 60 fps diagnostic sampling; later callbacks gated to model quiescence; no desktop/FPS/Duo acceptance")
    } catch { print("PACER ACTUAL SCK ERROR: \(error)") }
    workload.stopScrolling()
    await capture.stop()
    capture.onFrame = nil
    if let display { passed = await display.cleanup() && passed }
    print("PACER ACTUAL SCK RESULT: \(passed ? "PASS" : "FAIL")")
    exit(passed ? 0 : 1)
}

enum Failure: Error { case unavailable }
MainActor.assumeIsolated {
    workload.onReady = { Task { @MainActor in await run() } }
    app.delegate = workload
}
app.run()
