// Copyright 2026 DUO你电脑 contributors. SPDX-License-Identifier: Apache-2.0
// Exercises the production retry policy with WindowCapture's inert, injected SCK entry points.
// No screen capture, listener, device input, or display configuration is performed.
import Foundation
import ScreenCaptureKit

final class Audit: @unchecked Sendable {
    private let lock = NSLock()
    private var attemptsValue = 0, stopsValue = 0, waitsValue = 0
    func attempt() -> Int { lock.withLock { attemptsValue += 1; return attemptsValue } }
    func stop() { lock.withLock { stopsValue += 1 } }
    func waited() { lock.withLock { waitsValue += 1 } }
    var counts: (Int, Int, Int) { lock.withLock { (attemptsValue, stopsValue, waitsValue) } }
}

@main struct CaptureStartupRetryChecks {
    @MainActor static func main() async {
        var checks: [(String, Bool)] = []
        func check(_ label: String, _ passed: Bool) { checks.append((label, passed)) }
        func failure(_ code: Int = 1003) -> NSError { NSError(domain: "CoreGraphicsErrorDomain", code: code) }
        func start(_ capture: WindowCapture) async throws {
            try await capture.start(filter: SCContentFilter(), width: 16, height: 16, fps: 60, showsCursor: false)
        }

        let recovered = WindowCapture(), recoveredAudit = Audit()
        recovered.testStartCapture = { _ in if recoveredAudit.attempt() == 1 { throw failure() } }
        recovered.testStopCapture = { _ in recoveredAudit.stop() }
        var recoveredOK = true
        do {
            try await CaptureStartupRetry.run(enabled: true, isCurrent: { true }, canRetry: { true },
                                              wait: { recoveredAudit.waited() }) { try await start(recovered) }
        } catch { recoveredOK = false }
        check("one 1003 failure can recover on the second start", recoveredOK && recoveredAudit.counts.0 == 2)
        check("the failed start is not stopped and one delay is used", recoveredAudit.counts.1 == 0 && recoveredAudit.counts.2 == 1)
        await recovered.stop()
        check("the successfully started stream is stopped normally", recoveredAudit.counts.1 == 1)

        let persistent = WindowCapture(), persistentAudit = Audit()
        persistent.testStartCapture = { _ in _ = persistentAudit.attempt(); throw failure() }
        persistent.testStopCapture = { _ in persistentAudit.stop() }
        var persistentError: NSError?
        do {
            try await CaptureStartupRetry.run(enabled: true, isCurrent: { true }, canRetry: { true },
                                              wait: { persistentAudit.waited() }) { try await start(persistent) }
        } catch { persistentError = error as NSError }
        check("a repeated 1003 stops after two attempts", persistentAudit.counts.0 == 2 && persistentAudit.counts.2 == 1)
        check("the final CoreGraphics error is retained", persistentError?.domain == "CoreGraphicsErrorDomain"
              && persistentError?.code == 1003 && persistentAudit.counts.1 == 0)

        let unrelated = WindowCapture(), unrelatedAudit = Audit()
        unrelated.testStartCapture = { _ in _ = unrelatedAudit.attempt(); throw failure(1002) }
        unrelated.testStopCapture = { _ in unrelatedAudit.stop() }
        var unrelatedError: NSError?
        do {
            try await CaptureStartupRetry.run(enabled: true, isCurrent: { true }, canRetry: { true },
                                              wait: { unrelatedAudit.waited() }) { try await start(unrelated) }
        } catch { unrelatedError = error as NSError }
        check("other capture errors are not retried", unrelatedAudit.counts.0 == 1 && unrelatedAudit.counts.2 == 0
              && unrelatedError?.code == 1002)

        let disabled = WindowCapture(), disabledAudit = Audit()
        disabled.testStartCapture = { _ in _ = disabledAudit.attempt(); throw failure() }
        disabled.testStopCapture = { _ in disabledAudit.stop() }
        do {
            try await CaptureStartupRetry.run(enabled: false, isCurrent: { true }, canRetry: { true },
                                              wait: { disabledAudit.waited() }) { try await start(disabled) }
        } catch { }
        check("a non-native capture does not use the retry", disabledAudit.counts.0 == 1 && disabledAudit.counts.2 == 0)

        let staleBefore = WindowCapture(), staleBeforeAudit = Audit()
        staleBefore.testStartCapture = { _ in _ = staleBeforeAudit.attempt() }
        var cancelledBefore = false
        do {
            try await CaptureStartupRetry.run(enabled: true, isCurrent: { false }, canRetry: { true },
                                              wait: { staleBeforeAudit.waited() }) { try await start(staleBefore) }
        } catch is CancellationError { cancelledBefore = true } catch { }
        check("an already stale request starts nothing", cancelledBefore && staleBeforeAudit.counts.0 == 0)

        let staleWait = WindowCapture(), staleWaitAudit = Audit()
        staleWait.testStartCapture = { _ in _ = staleWaitAudit.attempt(); throw failure() }
        var current = true
        do {
            try await CaptureStartupRetry.run(enabled: true, isCurrent: { current }, canRetry: { true },
                                              wait: { current = false; staleWaitAudit.waited() }) { try await start(staleWait) }
        } catch { }
        check("a newer request during the delay prevents the retry", staleWaitAudit.counts.0 == 1 && staleWaitAudit.counts.2 == 1)

        let changedDisplay = WindowCapture(), changedDisplayAudit = Audit()
        changedDisplay.testStartCapture = { _ in _ = changedDisplayAudit.attempt(); throw failure() }
        var displayValid = true
        do {
            try await CaptureStartupRetry.run(enabled: true, isCurrent: { true }, canRetry: { displayValid },
                                              wait: { displayValid = false; changedDisplayAudit.waited() }) { try await start(changedDisplay) }
        } catch { }
        check("a display that changes during the delay prevents the retry", changedDisplayAudit.counts.0 == 1)

        let invalidDisplay = WindowCapture(), invalidDisplayAudit = Audit()
        invalidDisplay.testStartCapture = { _ in _ = invalidDisplayAudit.attempt(); throw failure() }
        do {
            try await CaptureStartupRetry.run(enabled: true, isCurrent: { true }, canRetry: { false },
                                              wait: { invalidDisplayAudit.waited() }) { try await start(invalidDisplay) }
        } catch { }
        check("a display already unavailable prevents the retry", invalidDisplayAudit.counts.0 == 1
              && invalidDisplayAudit.counts.2 == 0)

        let wrongPixels = WindowCapture(), wrongPixelsAudit = Audit()
        wrongPixels.testStartCapture = { [weak wrongPixels] _ in
            _ = wrongPixelsAudit.attempt()
            wrongPixels?.failNativePadding()
        }
        wrongPixels.testStopCapture = { _ in wrongPixelsAudit.stop() }
        do {
            try await CaptureStartupRetry.run(enabled: true, isCurrent: { true }, canRetry: { true },
                                              wait: { wrongPixelsAudit.waited() }) { try await start(wrongPixels) }
        } catch { }
        check("a native-pixel validation failure is stopped and never retried", wrongPixelsAudit.counts.0 == 1
              && wrongPixelsAudit.counts.1 == 1 && wrongPixelsAudit.counts.2 == 0)

        let staleSuccess = WindowCapture(), staleSuccessAudit = Audit()
        var stillCurrent = true
        staleSuccess.testStartCapture = { _ in _ = staleSuccessAudit.attempt(); stillCurrent = false }
        staleSuccess.testStopCapture = { _ in staleSuccessAudit.stop() }
        var cancelledAfterStart = false
        do {
            try await CaptureStartupRetry.run(enabled: true, isCurrent: { stillCurrent }, canRetry: { true },
                                              wait: { staleSuccessAudit.waited() }) { try await start(staleSuccess) }
        } catch is CancellationError {
            cancelledAfterStart = true
            await staleSuccess.stop() // Same cleanup as StreamCoordinator's error path.
        } catch { }
        check("a request superseded during a successful start is cancelled", cancelledAfterStart && staleSuccessAudit.counts.0 == 1)
        check("the superseded successful stream is stopped", staleSuccessAudit.counts.1 == 1)

        let staleRetry = WindowCapture(), staleRetryAudit = Audit()
        var retryCurrent = true
        staleRetry.testStartCapture = { _ in
            if staleRetryAudit.attempt() == 1 { throw failure() }
            retryCurrent = false
        }
        staleRetry.testStopCapture = { _ in staleRetryAudit.stop() }
        var retryCancelled = false
        do {
            try await CaptureStartupRetry.run(enabled: true, isCurrent: { retryCurrent }, canRetry: { true },
                                              wait: { staleRetryAudit.waited() }) { try await start(staleRetry) }
        } catch is CancellationError {
            retryCancelled = true
            await staleRetry.stop() // Same cleanup as StreamCoordinator's error path.
        } catch { }
        check("a request superseded during retry is cancelled", retryCancelled && staleRetryAudit.counts.0 == 2)
        check("the superseded retried stream is stopped", staleRetryAudit.counts.1 == 1)

        let cancelledWait = WindowCapture(), cancelledWaitAudit = Audit()
        cancelledWait.testStartCapture = { _ in _ = cancelledWaitAudit.attempt(); throw failure() }
        var waitCancelled = false
        do {
            try await CaptureStartupRetry.run(enabled: true, isCurrent: { true }, canRetry: { true },
                                              wait: { throw CancellationError() }) { try await start(cancelledWait) }
        } catch is CancellationError { waitCancelled = true } catch { }
        check("cancellation of the delay does not retry", waitCancelled && cancelledWaitAudit.counts.0 == 1)

        for (label, passed) in checks { print("\(passed ? "PASS" : "FAIL"): \(label)") }
        print("SCOPE: injected SCK startup outcomes; no real capture, device, or display changes")
        exit(checks.allSatisfy(\.1) ? 0 : 1)
    }
}
