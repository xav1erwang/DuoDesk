// Copyright 2026 DUO你电脑 contributors. SPDX-License-Identifier: Apache-2.0
// Exercises the production pacing callback with real SCK timestamps from this app's window.
// One callback is intentionally delayed, then later callbacks are gated: this is a latency
// mechanism check, not a full-desktop, real-device, 120 FPS or end-to-end performance test.
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

struct DisplayState: Equatable {
    let id: CGDirectDisplayID, mode: Int32, x: CGFloat, y: CGFloat, mirror: CGDirectDisplayID, main: Bool
    let width: Int, height: Int, pixelsWide: Int, pixelsHigh: Int
    let refresh: Double
}
func displayInventory() -> [DisplayState]? {
    func read() -> [DisplayState]? {
        let main = CGMainDisplayID()
        var count: UInt32 = 0
        guard CGGetOnlineDisplayList(0, nil, &count) == .success, count > 0 else { return nil }
        let expected = count
        var ids = [CGDirectDisplayID](repeating: 0, count: Int(count))
        guard CGGetOnlineDisplayList(count, &ids, &count) == .success, count == expected,
              Set(ids).count == ids.count, !ids.contains(kCGNullDirectDisplay) else { return nil }
        var result: [DisplayState] = []
        for id in ids.sorted() {
            guard CGDisplayIsOnline(id) > 0, let mode = CGDisplayCopyDisplayMode(id) else { return nil }
            let origin = CGDisplayBounds(id).origin
            result.append(DisplayState(id: id, mode: mode.ioDisplayModeID, x: origin.x, y: origin.y,
                mirror: CGDisplayMirrorsDisplay(id), main: main == id,
                width: mode.width, height: mode.height, pixelsWide: mode.pixelWidth, pixelsHigh: mode.pixelHeight,
                refresh: mode.refreshRate))
        }
        return main == CGMainDisplayID() ? result : nil
    }
    guard let first = read(), let second = read(), first == second else { return nil }
    return second
}

final class Audit: NSObject, SCStreamOutput, @unchecked Sendable {
    struct Target { let pts: CMTime, deadline: CMTime, oldDeadline: CMTime, beforeDelay: CMTime, afterDelay: CMTime }
    struct Result { let target: Target, deliveredAt: CMTime, ordered: Bool, count: Int }
    private let capture: WindowCapture
    private let lock = NSLock()
    private var watching = false, gated = false
    private var target: Target?, deliveredAt: CMTime?, timestamps: [CMTime] = []
    private(set) var gatedCallbacks = 0
    init(capture: WindowCapture) { self.capture = capture }
    func begin() { lock.withLock { watching = true } }

    func onFrame(_ pts: CMTime, stream: SCStream) {
        let now = stream.synchronizationClock.map { CMClockGetTime($0) }
        lock.withLock {
            timestamps.append(pts)
            if let target, CMTimeCompare(pts, target.pts) == 0 { deliveredAt = now }
        }
    }

    func stream(_ stream: SCStream, didOutputSampleBuffer sample: CMSampleBuffer, of type: SCStreamOutputType) {
        guard type == .screen,
              let attachments = CMSampleBufferGetSampleAttachmentsArray(sample, createIfNecessary: false) as? [[SCStreamFrameInfo: Any]],
              let status = attachments.first?[.status] as? Int, status == SCFrameStatus.complete.rawValue,
              CMSampleBufferGetImageBuffer(sample) != nil else { return }
        if lock.withLock({ gated }) { lock.withLock { gatedCallbacks += 1 }; return }
        let pts = CMSampleBufferGetPresentationTimeStamp(sample)
        var remaining: TimeInterval?
        if lock.withLock({ watching }) {
            remaining = capture.stateLock.withLock {
                guard var copy = capture.framePacer, case .hold(let wait) = copy.consider(pts), wait >= 0.05 else { return nil }
                return wait
            }
        }
        if let wait = remaining, let clock = stream.synchronizationClock {
            let before = CMClockGetTime(clock)
            let age = CMTimeGetSeconds(CMTimeSubtract(before, pts))
            if before.epoch == pts.epoch, age.isFinite, (0...0.02).contains(age) {
                // Delay an actual sample on the actual output queue, then suppress future frames.
                // No pixels are inspected or saved, and no other app enters the filter.
                usleep(30_000)
                let after = CMClockGetTime(clock)
                let delta = CMTimeMakeWithSeconds(wait, preferredTimescale: 1_000_000_000)
                let chosen = Target(pts: pts, deadline: CMTimeAdd(pts, delta), oldDeadline: CMTimeAdd(after, delta),
                                    beforeDelay: before, afterDelay: after)
                lock.withLock { target = chosen; gated = true }
            }
        }
        capture.stream(stream, didOutputSampleBuffer: sample, of: type)
    }

    func result() -> Result? {
        lock.withLock {
            guard let target, let deliveredAt else { return nil }
            return Result(target: target, deliveredAt: deliveredAt,
                ordered: zip(timestamps, timestamps.dropFirst()).allSatisfy { CMTimeCompare($0, $1) < 0 }, count: timestamps.count)
        }
    }
}

func ownContent() async -> SCShareableContent? {
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
    let before = displayInventory()
    let capture = WindowCapture()
    var passed = false
    do {
        guard let before, !before.isEmpty, let window = workload.window else { throw Failure.displayOrWindow }
        // The current-process inventory is populated asynchronously after AppKit orders a window.
        try await Task.sleep(for: .milliseconds(400))
        guard let content = await ownContent() else { throw Failure.inventory }
        guard let own = content.windows.first(where: { $0.windowID == UInt32(window.windowNumber)
                  && $0.owningApplication?.processID == getpid() }) else { throw Failure.ownWindowMissing }
        let filter = SCContentFilter(desktopIndependentWindow: own)
        let width = Int((filter.contentRect.width * CGFloat(filter.pointPixelScale)).rounded())
        let height = Int((filter.contentRect.height * CGFloat(filter.pointPixelScale)).rounded())
        guard width == 2008, height == 1428 else {
            print("CLOCK PACER unexpected owned-window size: \(width)x\(height)")
            throw Failure.windowSize
        }
        let config = SCStreamConfiguration()
        config.width = width; config.height = height; config.pixelFormat = kCVPixelFormatType_420YpCbCr8BiPlanarFullRange
        config.minimumFrameInterval = .zero; config.queueDepth = 5; config.showsCursor = false
        let stream = SCStream(filter: filter, configuration: config, delegate: nil)
        let audit = Audit(capture: capture)
        capture.onFrame = { _, pts in audit.onFrame(pts, stream: stream) }
        capture.stateLock.withLock { capture.stream = stream; capture.framePacer = CaptureFramePacer(fps: 10) }
        try stream.addStreamOutput(audit, type: .screen, sampleHandlerQueue: capture.queue)
        try await stream.startCapture()
        try await Task.sleep(for: .milliseconds(300))
        capture.stateLock.withLock {
            capture.framePacer = CaptureFramePacer(fps: 10); capture.pendingSample = nil; capture.pendingSampleToken = nil
        }
        audit.begin(); workload.startScrolling()
        let timeout = ContinuousClock.now + .seconds(4)
        while audit.result() == nil && ContinuousClock.now < timeout { try await Task.sleep(for: .milliseconds(20)) }
        guard let result = audit.result() else { throw Failure.deadline }
        let added = CMTimeGetSeconds(CMTimeSubtract(result.target.afterDelay, result.target.beforeDelay)) * 1000
        let deliveredFromDeadline = CMTimeGetSeconds(CMTimeSubtract(result.deliveredAt, result.target.deadline)) * 1000
        let soonerThanOld = CMTimeGetSeconds(CMTimeSubtract(result.target.oldDeadline, result.deliveredAt)) * 1000
        let deliveryAge = CMTimeGetSeconds(CMTimeSubtract(result.target.afterDelay, result.target.pts)) * 1000
        passed = added >= 28 && deliveryAge >= added && deliveredFromDeadline >= -2 && deliveredFromDeadline < 15
            && soonerThanOld >= 15 && result.ordered && result.count >= 2
        print(String(format: "CLOCK PACER: intentionalDelayMs=%.3f, deliveryAgeMs=%.3f, actualVsTargetMs=%.3f, earlierThanOldDeadlineMs=%.3f, ordered=%@, frames=%d, passed=%@",
                     added, deliveryAge, deliveredFromDeadline, soonerThanOld, String(result.ordered), result.count, String(passed)))
        print("SCOPE: own AppKit document 2008x1428; 10 FPS diagnostic target, one 30ms injected callback delay, later callbacks gated; no full-desktop, device or FPS acceptance")
    } catch { print("CLOCK PACER ERROR: \(error)") }
    workload.stopScrolling()
    await capture.stop()
    capture.onFrame = nil
    workload.window?.close()
    let after = displayInventory()
    let unchanged = before != nil && before == after
    passed = passed && unchanged
    print("CLOCK PACER DISPLAY: physical and online display state unchanged=\(unchanged)")
    print("CLOCK PACER RESULT: \(passed ? "PASS" : "FAIL")")
    exit(passed ? 0 : 1)
}

enum Failure: Error { case displayOrWindow, inventory, ownWindowMissing, windowSize, deadline }
MainActor.assumeIsolated {
    workload.onReady = { Task { @MainActor in await run() } }
    app.delegate = workload
}
app.run()
