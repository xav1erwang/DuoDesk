// Copyright 2026 DUO你电脑 contributors. SPDX-License-Identifier: Apache-2.0
// Drives production callback entry points without starting ScreenCaptureKit or a listener.
// Test-only access control is disabled by run.sh; no production test hooks are added.
import CoreMedia
import CoreVideo
import Foundation
import ScreenCaptureKit

final class Audit: @unchecked Sendable {
    private let lock = NSLock()
    private var frames = 0
    private var stops: [WindowCapture.Stop] = []
    private var queueEntered = false
    private var stopFinished = false
    func frame() { lock.withLock { frames += 1 } }
    func stop(_ event: WindowCapture.Stop) { lock.withLock { stops.append(event) } }
    func enterQueue() { lock.withLock { queueEntered = true } }
    func finishStop() { lock.withLock { stopFinished = true } }
    var snapshot: (frames: Int, stops: [WindowCapture.Stop], entered: Bool, finished: Bool) {
        lock.withLock { (frames, stops, queueEntered, stopFinished) }
    }
}

struct CheckFailure: Error { let message: String }

@main
@MainActor
struct Checks {
    static var passed = 0
    static func expect(_ condition: @autoclosure () -> Bool, _ message: String) throws {
        guard condition() else { throw CheckFailure(message: message) }
        passed += 1
    }

    static func waitFor(_ condition: () -> Bool) async throws {
        let deadline = ContinuousClock.now + .seconds(2)
        while !condition() {
            guard ContinuousClock.now < deadline else { throw CheckFailure(message: "Callback deadline exceeded") }
            try await Task.sleep(for: .milliseconds(5))
        }
    }

    static func sample(_ timestamp: CMTime = CMTime(value: 1, timescale: 120)) throws -> CMSampleBuffer {
        var pixels: CVPixelBuffer?
        guard CVPixelBufferCreate(kCFAllocatorDefault, 16, 16, kCVPixelFormatType_420YpCbCr8BiPlanarFullRange,
                                  nil, &pixels) == kCVReturnSuccess, let pixels else {
            throw CheckFailure(message: "Could not create callback fixture")
        }
        var format: CMVideoFormatDescription?
        guard CMVideoFormatDescriptionCreateForImageBuffer(allocator: kCFAllocatorDefault, imageBuffer: pixels,
                                                           formatDescriptionOut: &format) == noErr, let format else {
            throw CheckFailure(message: "Could not describe callback fixture")
        }
        var timing = CMSampleTimingInfo(duration: .invalid, presentationTimeStamp: timestamp,
                                        decodeTimeStamp: .invalid)
        var sample: CMSampleBuffer?
        guard CMSampleBufferCreateReadyWithImageBuffer(allocator: kCFAllocatorDefault, imageBuffer: pixels,
                                                       formatDescription: format, sampleTiming: &timing,
                                                       sampleBufferOut: &sample) == noErr, let sample,
              let attachments = CMSampleBufferGetSampleAttachmentsArray(sample, createIfNecessary: true) else {
            throw CheckFailure(message: "Could not create sample fixture")
        }
        let attachment = unsafeBitCast(CFArrayGetValueAtIndex(attachments, 0), to: NSMutableDictionary.self)
        attachment[SCStreamFrameInfo.status.rawValue] = SCFrameStatus.complete.rawValue
        return sample
    }

    static func callbacks() async throws {
        let capture = WindowCapture()
        let audit = Audit()
        capture.onFrame = { _, _ in audit.frame() }
        capture.onStopped = { audit.stop($0) }
        // Allocate inert stream identities only. Never call startCapture or enumerate content.
        let first = SCStream(filter: SCContentFilter(), configuration: SCStreamConfiguration(), delegate: nil)
        let second = SCStream(filter: SCContentFilter(), configuration: SCStreamConfiguration(), delegate: nil)
        let frame = try sample()
        capture.stateLock.withLock { capture.stream = second; capture.generation = UUID() }
        capture.stream(first, didOutputSampleBuffer: frame, of: .screen)
        try expect(audit.snapshot.frames == 0, "Replaced stream delivered a frame")
        capture.stream(second, didOutputSampleBuffer: frame, of: .screen)
        try expect(audit.snapshot.frames == 1, "Current complete frame was lost")
        let error = NSError(domain: "DuoCallbackFixture", code: 73)
        capture.stream(first, didStopWithError: error)
        try expect(audit.snapshot.stops.isEmpty && capture.stream === second, "Old error stopped a successor")
        capture.stream(second, didStopWithError: error)
        try expect(audit.snapshot.stops.count == 1 && capture.stream == nil, "Current failure was not delivered")
        try expect((capture.startupFailure as NSError?)?.code == 73, "Startup failure was swallowed")
        let stop = audit.snapshot.stops[0]
        try expect(capture.isCurrent(stop), "Current stop token became stale too early")
        capture.stream(second, didOutputSampleBuffer: frame, of: .screen)
        try expect(audit.snapshot.frames == 1, "Stopped stream delivered a late frame")
        await capture.stop()
        try expect(!capture.isCurrent(stop), "Explicit stop did not invalidate a queued failure")

        // didStopWithError already cleared stream. stop must still wait for the output queue.
        let releaseQueue = DispatchSemaphore(value: 0)
        defer { releaseQueue.signal() }
        capture.queue.async { audit.enterQueue(); releaseQueue.wait() }
        try await waitFor { audit.snapshot.entered }
        let before = capture.generation
        let stopping = Task { @MainActor in await capture.stop(); audit.finishStop() }
        try await waitFor { capture.generation != before }
        try expect(!audit.snapshot.finished, "Stop returned before the output queue drained")
        releaseQueue.signal()
        await stopping.value
        try expect(audit.snapshot.finished, "Stop never finished after the queue drained")

        // Drive the production output callback with inert stream identities and real timestamps.
        // A stale stream cannot consume the new stream's pacing deadline.
        let paced = WindowCapture(), pacedAudit = Audit()
        paced.onFrame = { _, _ in pacedAudit.frame() }
        paced.stateLock.withLock { paced.stream = second; paced.framePacer = CaptureFramePacer(fps: 120) }
        paced.stream(second, didOutputSampleBuffer: try sample(.zero), of: .screen)
        paced.stream(first, didOutputSampleBuffer: try sample(CMTime(value: 100, timescale: 1)), of: .screen)
        paced.stream(second, didOutputSampleBuffer: try sample(CMTime(value: 1, timescale: 170)), of: .screen)
        try expect(pacedAudit.snapshot.frames == 1, "Pacer accepted an early frame or a replaced stream")
        let due = try sample(CMTime(value: 2, timescale: 170))
        paced.stream(second, didOutputSampleBuffer: due, of: .screen)
        paced.stream(second, didOutputSampleBuffer: due, of: .screen)
        try expect(pacedAudit.snapshot.frames == 2, "Pacer lost a due frame or delivered a duplicate timestamp")
        paced.stream(second, didStopWithError: error)
        try expect(paced.framePacer == nil, "Stopped capture retained its old pacing state")
    }

    static func deferredFailure() async throws {
        let coordinator = try StreamCoordinator(config: .standard, synthetic: true, appKitLoop: false)
        defer { coordinator.shutdownForExit() }
        let error = NSError(domain: "DuoCallbackFixture", code: 74)
        func event() -> WindowCapture.Stop {
            let id = UUID()
            coordinator.capture.generation = id
            return WindowCapture.Stop(error: error, generation: id)
        }
        let current = event()
        coordinator.switching = true
        await coordinator.captureStopped(current)
        try expect(coordinator.capture.isCurrent(current), "Busy pipeline stopped reentrantly")
        try expect(coordinator.captureStopWhileSwitching?.generation == current.generation, "Busy switch swallowed its failure")
        coordinator.switching = false
        await coordinator.resumeDeferredCaptureStop()?.value
        try expect(!coordinator.capture.isCurrent(current), "Settled failure left the failed generation current")
        try expect(coordinator.captureStopWhileSwitching == nil && coordinator.active == .none, "Settled failure was not stopped")

        let interrupted = event()
        coordinator.switching = true
        await coordinator.captureStopped(interrupted)
        // A different deferred request started another switch before this handler's hop ran.
        await coordinator.resumeDeferredCaptureStop()?.value
        try expect(coordinator.capture.isCurrent(interrupted), "Second busy switch stopped reentrantly")
        try expect(coordinator.captureStopWhileSwitching?.generation == interrupted.generation, "Second busy switch swallowed the failure")
        coordinator.switching = false
        await coordinator.resumeDeferredCaptureStop()?.value
        try expect(!coordinator.capture.isCurrent(interrupted), "Failure was lost across two busy switches")

        let replaced = event()
        coordinator.switching = true
        await coordinator.captureStopped(replaced)
        coordinator.switching = false
        let pending = coordinator.resumeDeferredCaptureStop()
        // Replace before the deferred MainActor hop executes.
        let successor = event()
        await pending?.value
        try expect(coordinator.capture.isCurrent(successor), "Deferred old error stopped a new generation")
        try expect(coordinator.captureStopWhileSwitching == nil, "Consumed old error remained queued")
        coordinator.switching = true
        await coordinator.captureStopped(replaced)
        try expect(coordinator.captureStopWhileSwitching == nil, "Stale error was queued during a later switch")
        coordinator.switching = false
        coordinator.shuttingDown = true
        await coordinator.captureStopped(successor)
        try expect(coordinator.capture.isCurrent(successor), "Shutdown accepted another pipeline transition")
    }

    static func main() async {
        do {
            try await callbacks()
            try await deferredFailure()
            print("Capture callback checks: \(passed) passed; no capture, input, keychain or listener started.")
            print("Scope: callback/generation/queue regression only; not real SCK startup or FPS acceptance.")
        } catch {
            print("Capture callback check failed: \(error)")
            exit(1)
        }
    }
}
