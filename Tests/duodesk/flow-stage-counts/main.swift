// Copyright 2026 DUO你电脑 contributors. SPDX-License-Identifier: Apache-2.0
// Exercise only the diagnostic counter's time window and concurrent updates.
import Foundation

let counts = FlowStageCounts()
counts.record(.capture, at: 100)
guard counts.snapshot.seconds.isEmpty else { fatalError("unarmed counter recorded") }
counts.begin(at: 100, seconds: 2)
counts.record(.capture, at: 99.999)
counts.record(.capture, at: 100)
counts.record(.encode, at: 100.999)
counts.record(.receive, at: 101)
counts.record(.decode, at: 101.999)
counts.record(.decode, at: 102)
counts.record(.decode, at: .nan)
let measured = counts.snapshot
guard measured.totals == .init(capture: 1, encode: 1, receive: 1, decode: 1),
      measured.seconds == [.init(capture: 1, encode: 1), .init(receive: 1, decode: 1)] else {
    fatalError("window boundaries or stages are incorrect")
}
counts.begin(at: 200, seconds: 1)
let group = DispatchGroup()
for stage: FlowStageCounts.Stage in [.capture, .encode, .receive, .decode] {
    group.enter()
    DispatchQueue.global().async {
        for _ in 0..<2_000 { counts.record(stage, at: 200.5) }
        group.leave()
    }
}
guard group.wait(timeout: .now() + 3) == .success,
      counts.snapshot.totals == .init(capture: 2_000, encode: 2_000, receive: 2_000, decode: 2_000),
      counts.snapshot.seconds == [.init(capture: 2_000, encode: 2_000, receive: 2_000, decode: 2_000)] else {
    fatalError("concurrent stage counts or reset are incorrect")
}
print("FLOW STAGE COUNTS PASS: unarmed, reset, monotonic window boundaries, stage buckets and concurrent updates; no capture")
