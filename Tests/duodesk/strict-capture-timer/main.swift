// Copyright 2026 DUO你电脑 contributors. SPDX-License-Identifier: Apache-2.0
// Exercise the diagnostic one-shot timer, including a simulated stale wakeup after rearming.
import Foundation
import Dispatch

final class Results: @unchecked Sendable {
    private let lock = NSLock()
    private var values: [(UUID, UInt64)] = []
    let delivered = DispatchSemaphore(value: 0)
    func append(_ token: UUID) {
        lock.withLock { values.append((token, DispatchTime.now().uptimeNanoseconds)) }
        delivered.signal()
    }
    var snapshot: [(UUID, UInt64)] { lock.withLock { values } }
}

struct Failure: Error, CustomStringConvertible {
    let description: String
}

func test() throws {
    let queue = DispatchQueue(label: "duodesk.strict-capture-timer-check", qos: .userInteractive)
    let results = Results(), old = UUID(), replacement = UUID(), canceled = UUID()
    let timer = StrictCaptureTimer(queue: queue) { results.append($0) }
    var replacementDue: DispatchTime = .now()
    queue.sync {
        timer.arm(deadline: .now() + .milliseconds(80), token: old)
        timer.handleWakeup() // Spurious early wakeup must leave the old arm pending.
        replacementDue = .now() + .milliseconds(180)
        timer.arm(deadline: replacementDue, token: replacement)
        timer.handleWakeup() // A stale old wakeup cannot deliver the new arm early.
    }
    guard results.delivered.wait(timeout: .now() + .milliseconds(120)) == .timedOut else {
        throw Failure(description: "A stale/early wakeup delivered the replacement")
    }
    guard results.delivered.wait(timeout: .now() + .seconds(2)) == .success else {
        throw Failure(description: "Replacement timer never delivered")
    }
    let first = results.snapshot
    guard first.count == 1, first[0].0 == replacement, first[0].1 >= replacementDue.uptimeNanoseconds else {
        throw Failure(description: "Wrong token, duplicate, or delivery before its own deadline")
    }
    queue.sync {
        timer.handleWakeup() // No current arm: a duplicate wakeup must be harmless.
        timer.arm(deadline: .now() + .milliseconds(80), token: canceled)
        timer.cancelPending()
        timer.handleWakeup()
    }
    guard results.delivered.wait(timeout: .now() + .milliseconds(150)) == .timedOut,
          results.snapshot.count == 1 else { throw Failure(description: "Canceled arm delivered") }
    queue.sync { _ = timer } // Keep destruction after queued operations.
    print("STRICT CAPTURE TIMER PASS: rearm, early/stale wakeup, deadline, single delivery and cancellation; no capture")
}

do { try test() } catch { fputs("ERROR: \(error)\n", stderr); exit(1) }
