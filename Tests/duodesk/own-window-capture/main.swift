// Copyright 2026 DUO你电脑 contributors. SPDX-License-Identifier: Apache-2.0
// Captures only this process's own AppKit window, using the system's current-process inventory.
// This is not a full-desktop, network, or real-device performance test.
import AppKit
import CoreMedia
import CoreVideo
import ScreenCaptureKit
import StreamProtocol

setbuf(stdout, nil)
let app = NSApplication.shared
app.setActivationPolicy(.regular)
let activity = ProcessInfo.processInfo.beginActivity(options: [.userInitiatedAllowingIdleSystemSleep, .latencyCritical],
                                                     reason: "Native document capture measurement")
let workload = MainActor.assumeIsolated { DocumentWorkload(frameSize: NSSize(width: 1004, height: 714), usesStdin: false) }

final class Frames: @unchecked Sendable {
    let audit: DesktopContentAudit
    private let lock = NSLock()
    private var start = Double.infinity, end = Double.infinity
    private var count = 0, wrongSize = 0
    private var failure: String?
    init() throws { audit = try DesktopContentAudit(activeOffsetSeconds: 2) }
    func begin(seconds: Int) -> Double {
        lock.withLock {
            start = ProcessInfo.processInfo.systemUptime; end = start + Double(seconds)
            return start
        }
    }
    func receive(_ image: CVPixelBuffer) {
        let time = ProcessInfo.processInfo.systemUptime
        let accepted = lock.withLock {
            guard time >= start, time < end else { return false }
            guard CVPixelBufferGetWidth(image) == 2008, CVPixelBufferGetHeight(image) == 1428 else {
                wrongSize += 1; return false
            }
            count += 1; return true
        }
        if accepted { audit.inspect(image, at: time, onResult: nil) }
    }
    func fail(_ message: String) { lock.withLock { failure = message } }
    func check() throws {
        if let failure = lock.withLock({ failure }) {
            throw NSError(domain: "DuoOwnWindowCapture", code: 1, userInfo: [NSLocalizedDescriptionKey: failure])
        }
    }
    var summary: (Int, Int) { lock.withLock { (count, wrongSize) } }
}

func currentProcessContent() async -> SCShareableContent? {
    final class Once: @unchecked Sendable {
        private let lock = NSLock(); private var done = false
        func first() -> Bool { lock.withLock { if done { return false }; done = true; return true } }
    }
    let once = Once()
    return await withCheckedContinuation { (continuation: CheckedContinuation<SCShareableContent?, Never>) in
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
    var encoder: HEVCEncoder?
    var decoder: HardwareHEVCDecoder?
    var passed = false
    let initialGrant = CGPreflightScreenCaptureAccess()
    print("OWN WINDOW START: globalRecording=\(initialGrant); completeDesktop=false; no display mode changes")
    do {
        guard !initialGrant, let window = workload.window else { throw PixelMotionAudit.Failure.unavailable }
        try await Task.sleep(for: .milliseconds(400))
        guard let content = await currentProcessContent(),
              let owned = content.windows.first(where: {
                  $0.windowID == UInt32(window.windowNumber) && $0.owningApplication?.processID == getpid()
              }) else { throw PixelMotionAudit.Failure.unavailable }
        let filter = SCContentFilter(desktopIndependentWindow: owned)
        let width = Int((filter.contentRect.width * CGFloat(filter.pointPixelScale)).rounded())
        let height = Int((filter.contentRect.height * CGFloat(filter.pointPixelScale)).rounded())
        print("OWN WINDOW FILTER: owner=\(owned.owningApplication?.processID ?? 0), ownPID=\(getpid()), frame=\(filter.contentRect), scale=\(filter.pointPixelScale), nativePixels=\(width)×\(height)")
        guard width == 2008, height == 1428 else { throw PixelMotionAudit.Failure.invalidFrames }
        let captured = try Frames(), decoded = try Frames()
        let received = HardwareHEVCDecoder(onFormat: { size, _ in
            if size != CGSize(width: 2008, height: 1428) { decoded.fail("unexpected hardware-decoder dimensions") }
        }, onSample: { sample, _ in
            if let image = CMSampleBufferGetImageBuffer(sample) { decoded.receive(image) }
        }, onFailure: { message, _ in decoded.fail(message) })
        received.require(DuoDesktopResolution(width: 2007, height: 1427))
        let compressor = try HEVCEncoder(width: 2008, height: 1428, fps: 120, bitrate: 80_000_000,
                                         prioritizeSpeed: true, software: false)
        compressor.onEncoded = { bytes, keyframe, parameters in
            if let parameters { received.apply(parameters) }
            received.enqueue(bytes, isKeyframe: keyframe)
        }
        compressor.onHung = { decoded.fail("hardware encoder stalled") }
        capture.onFrame = { image, pts in captured.receive(image); compressor.encode(image, pts: pts) }
        capture.onStopped = { stop in captured.fail(stop.error.localizedDescription) }
        encoder = compressor; decoder = received
        let resampled = CommandLine.arguments.contains("--resampled")
        try await capture.start(filter: filter, width: 2008, height: 1428, fps: 120, showsCursor: false,
                                resampleCadence: resampled)
        try await Task.sleep(for: .seconds(2))
        let diagnostic = CommandLine.arguments.contains("--diagnose")
        // One second stationary, one second scrolling warmup, then a fixed active interval.
        let duration = diagnostic ? 12 : 32
        let capturedStart = captured.begin(seconds: duration), decodedStart = decoded.begin(seconds: duration)
        for step in 0..<(duration * 2) {
            try await Task.sleep(for: .milliseconds(500))
            if step == 1 { workload.startScrolling() }
            try captured.check(); try decoded.check()
        }
        await capture.stop(); capture.onFrame = nil
        try await Task.sleep(for: .milliseconds(250))
        let (samples, wrong) = captured.summary
        let (outputs, badOutputs) = decoded.summary
        print("OWN WINDOW CAPTURE: samples=\(samples), wrongDimensions=\(wrong)")
        print(await captured.audit.report(from: capturedStart, seconds: duration))
        print("OWN WINDOW HARDWARE DECODE: outputs=\(outputs), wrongDimensions=\(badOutputs)")
        print(await decoded.audit.report(from: decodedStart, seconds: duration))
        try captured.audit.validate(); try decoded.audit.validate()
        passed = !diagnostic && wrong == 0 && badOutputs == 0 && (captured.audit.changedFramesPerSecond ?? 0) >= 120
            && (decoded.audit.changedFramesPerSecond ?? 0) >= 120
        print("OWN WINDOW RESULT: target120=\(passed); diagnosticOnly=\(diagnostic); resampled=\(resampled); completeDesktop=false; network=false; realDuo=false")
    } catch {
        print("OWN WINDOW CHECK FAILED: \(error)")
    }
    await capture.stop(); capture.onFrame = nil
    _ = encoder?.abandon(); decoder?.clear()
    workload.window?.close()
    ProcessInfo.processInfo.endActivity(activity)
    print("OWN WINDOW END: globalRecording=\(CGPreflightScreenCaptureAccess()); no screen capture or permission prompt was requested for another process")
    exit(passed ? 0 : 1)
}

MainActor.assumeIsolated { workload.onReady = { Task { @MainActor in await run() } } }
app.delegate = workload
app.run()
