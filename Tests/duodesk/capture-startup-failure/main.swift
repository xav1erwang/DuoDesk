// Copyright 2026 DUO你电脑 contributors. SPDX-License-Identifier: Apache-2.0
// Exercises WindowCapture's production startup state with inert SCK objects and injected results.
// The fixture does not start capture, access a window, connect a device, or change a display.
import Foundation
import ScreenCaptureKit

enum FixtureError: Error { case startFailed, systemStopped }

final class Audit: @unchecked Sendable {
    private let lock = NSLock()
    private var stopsValue = 0
    private var finishedValue = false
    private var queueEnteredValue = false
    func stopped() { lock.withLock { stopsValue += 1 } }
    func finished() { lock.withLock { finishedValue = true } }
    func queueEntered() { lock.withLock { queueEnteredValue = true } }
    var stops: Int { lock.withLock { stopsValue } }
    var isFinished: Bool { lock.withLock { finishedValue } }
    var queueHasEntered: Bool { lock.withLock { queueEnteredValue } }
}

@main struct CaptureStartupFailureChecks {
    @MainActor static func main() async {
        var checks: [(String, Bool)] = []
        func check(_ label: String, _ passed: Bool) { checks.append((label, passed)) }
        func start(_ capture: WindowCapture) async -> Bool {
            do {
                try await capture.start(filter: SCContentFilter(), width: 16, height: 16, fps: 60,
                                        showsCursor: false)
                return true
            } catch { return false }
        }

        let failed = WindowCapture(), failedAudit = Audit()
        failed.testStartCapture = { _ in throw NSError(domain: "CoreGraphicsErrorDomain", code: 1003) }
        failed.testStopCapture = { _ in failedAudit.stopped() }
        var reportedError: NSError?
        do {
            try await failed.start(filter: SCContentFilter(), width: 16, height: 16, fps: 60, showsCursor: false)
        } catch { reportedError = error as NSError }
        check("the CoreGraphics start error is preserved", reportedError?.domain == "CoreGraphicsErrorDomain"
              && reportedError?.code == 1003)
        check("a stream that failed to start is not stopped again", failedAudit.stops == 0)
        check("failed startup clears the active stream", failed.stateLock.withLock { failed.stream == nil })

        let cancelled = WindowCapture(), cancelledAudit = Audit()
        cancelled.testStartCapture = { _ in throw CancellationError() }
        cancelled.testStopCapture = { _ in cancelledAudit.stopped() }
        let cancelledStarted = await start(cancelled)
        check("a cancelled start is reported", !cancelledStarted)
        check("an unconfirmed cancellation still stops the stream", cancelledAudit.stops == 1)

        let alreadyStopped = WindowCapture(), stoppedAudit = Audit()
        alreadyStopped.testStartCapture = { [weak alreadyStopped] stream in
            alreadyStopped?.stream(stream, didStopWithError: FixtureError.systemStopped)
        }
        alreadyStopped.testStopCapture = { _ in stoppedAudit.stopped() }
        let stoppedStarted = await start(alreadyStopped)
        check("a system stop during startup is reported", !stoppedStarted)
        check("a system-confirmed stop during startup is not stopped again", stoppedAudit.stops == 0)

        let rejectedStopped = WindowCapture(), rejectedStoppedAudit = Audit()
        rejectedStopped.testStartCapture = { [weak rejectedStopped] stream in
            rejectedStopped?.failNativePadding()
            rejectedStopped?.stream(stream, didStopWithError: FixtureError.systemStopped)
        }
        rejectedStopped.testStopCapture = { _ in rejectedStoppedAudit.stopped() }
        let rejectedStoppedStarted = await start(rejectedStopped)
        check("invalid native pixels remain rejected after a system stop", !rejectedStoppedStarted)
        check("a system-confirmed stop after pixel rejection is not repeated", rejectedStoppedAudit.stops == 0)

        let ambiguous = WindowCapture(), ambiguousAudit = Audit()
        ambiguous.testStartCapture = { [weak ambiguous] stream in
            ambiguous?.stream(stream, didStopWithError: FixtureError.systemStopped)
            await ambiguous?.stop()
        }
        ambiguous.testStopCapture = { _ in ambiguousAudit.stopped() }
        let ambiguousStarted = await start(ambiguous)
        check("an interrupted system-stopped startup remains failed", !ambiguousStarted)
        check("changed startup generation retains conservative cleanup", ambiguousAudit.stops == 1)

        let rejected = WindowCapture(), rejectedAudit = Audit()
        rejected.testStartCapture = { [weak rejected] _ in rejected?.failNativePadding() }
        rejected.testStopCapture = { _ in rejectedAudit.stopped() }
        let rejectedStarted = await start(rejected)
        check("a started stream with invalid native pixels is rejected", !rejectedStarted)
        check("a started stream with invalid pixels is stopped", rejectedAudit.stops == 1)

        let running = WindowCapture(), runningAudit = Audit()
        running.testStartCapture = { _ in }
        running.testStopCapture = { _ in runningAudit.stopped() }
        let runningStarted = await start(running)
        await running.stop()
        check("an ordinary successful start succeeds", runningStarted)
        check("an ordinary successful stream stops once", runningAudit.stops == 1)

        let interrupted = WindowCapture(), interruptedAudit = Audit()
        interrupted.testStartCapture = { [weak interrupted] _ in await interrupted?.stop() }
        interrupted.testStopCapture = { _ in interruptedAudit.stopped() }
        let interruptedStarted = await start(interrupted)
        check("an explicit stop during startup cancels the attempt", !interruptedStarted)
        check("a late successful start after explicit stop receives a final stop", interruptedAudit.stops == 2)

        let interruptedFailure = WindowCapture(), interruptedFailureAudit = Audit()
        interruptedFailure.testStartCapture = { [weak interruptedFailure] _ in
            await interruptedFailure?.stop()
            throw FixtureError.startFailed
        }
        interruptedFailure.testStopCapture = { _ in interruptedFailureAudit.stopped() }
        let interruptedFailureStarted = await start(interruptedFailure)
        check("an explicitly stopped failed start remains failed", !interruptedFailureStarted)
        check("a failed late start does not cause another stop", interruptedFailureAudit.stops == 1)

        let draining = WindowCapture(), drainingAudit = Audit()
        let releaseQueue = DispatchSemaphore(value: 0)
        draining.testStartCapture = { _ in throw FixtureError.startFailed }
        draining.testStopCapture = { _ in drainingAudit.stopped() }
        draining.queue.async { drainingAudit.queueEntered(); releaseQueue.wait() }
        let task = Task { _ = await start(draining); drainingAudit.finished() }
        let deadline = ContinuousClock.now + .seconds(2)
        while !drainingAudit.queueHasEntered && ContinuousClock.now < deadline {
            try? await Task.sleep(for: .milliseconds(5))
        }
        try? await Task.sleep(for: .milliseconds(50))
        check("failed-start cleanup waits for the output queue", drainingAudit.queueHasEntered && !drainingAudit.isFinished)
        releaseQueue.signal()
        await task.value
        check("failed-start cleanup finishes after the queue drains", drainingAudit.isFinished)

        for (label, passed) in checks { print("\(passed ? "PASS" : "FAIL"): \(label)") }
        print("SCOPE: injected startup and stop results; no screen capture, device, or display change")
        exit(checks.allSatisfy(\.1) ? 0 : 1)
    }
}
