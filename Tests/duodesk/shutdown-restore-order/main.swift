// Copyright 2026 DUO你电脑 contributors. SPDX-License-Identifier: Apache-2.0
// Simulate a blocked Accessibility restore; no real display or input is changed.
import Foundation

final class Record: @unchecked Sendable {
    private let lock = NSLock()
    private var events: [String] = []
    func append(_ event: String) { lock.withLock { events.append(event) } }
    var snapshot: [String] { lock.withLock { events } }
}
let record = Record(), entered = DispatchSemaphore(value: 0), release = DispatchSemaphore(value: 0)
let complete = DispatchSemaphore(value: 0)
DispatchQueue.global().async {
    ShutdownRestoreOrder.run(display: { record.append("display") },
                             windows: { record.append("windows"); entered.signal(); release.wait() },
                             stage: { record.append("stage") })
    complete.signal()
}
guard entered.wait(timeout: .now() + 2) == .success, record.snapshot == ["display", "windows"] else {
    release.signal(); fputs("FAIL: display was not restored before blocked window cleanup\n", stderr); exit(1)
}
release.signal()
guard complete.wait(timeout: .now() + 2) == .success, record.snapshot == ["display", "windows", "stage"] else {
    fputs("FAIL: cleanup did not resume in order\n", stderr); exit(1)
}
print("PASS: display restoration precedes a blocked window cleanup and the remaining work resumes")
