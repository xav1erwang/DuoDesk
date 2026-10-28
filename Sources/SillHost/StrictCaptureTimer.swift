// Copyright 2026 DUO你电脑 contributors. SPDX-License-Identifier: Apache-2.0
#if DUO_CAPTURE_DIAGNOSTICS
import Foundation
import Dispatch

/// Diagnostic candidate for the capture queue only. Calls and event handling must be serialized
/// on that queue. The strict flag is a best-effort hint, not a deadline guarantee.
/// A queued wakeup from an old arm may run after a new arm; it must never deliver the new token
/// before the new deadline. WindowCapture independently checks its stream and pending token.
final class StrictCaptureTimer {
    private struct Arm {
        let token: UUID
        let deadline: DispatchTime
    }
    private let source: DispatchSourceTimer
    private let deliver: (UUID) -> Void
    private var current: Arm?

    init(queue: DispatchQueue, deliver: @escaping (UUID) -> Void) {
        source = DispatchSource.makeTimerSource(flags: .strict, queue: queue)
        self.deliver = deliver
        source.setEventHandler { [weak self] in self?.handleWakeup() }
        source.schedule(deadline: .distantFuture)
        source.resume()
    }

    func arm(deadline: DispatchTime, token: UUID) {
        current = Arm(token: token, deadline: deadline)
        schedule(deadline)
    }

    func cancelPending() {
        current = nil
        schedule(.distantFuture)
    }

    // Internal so a deterministic test can inject an obsolete/early wakeup, without relying on
    // the OS to actually produce one. The production handler uses the real monotonic clock.
    func handleWakeup(now: DispatchTime = .now()) {
        guard let arm = current else { return }
        guard now.uptimeNanoseconds >= arm.deadline.uptimeNanoseconds else {
            schedule(arm.deadline)
            return
        }
        current = nil
        deliver(arm.token)
    }

    private func schedule(_ deadline: DispatchTime) {
        source.schedule(deadline: deadline, repeating: .never, leeway: .nanoseconds(0))
    }

    deinit { source.cancel() }
}
#endif
