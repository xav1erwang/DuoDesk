// Copyright 2026 DUO你电脑 contributors. SPDX-License-Identifier: Apache-2.0
// Check the offline phase comparison without capture or display changes.
import Foundation

func signature(_ value: Int) -> [UInt8] { [UInt8](repeating: UInt8((value * 5) % 240), count: 128 * 90) }
func source(fps: Int) -> [PhaseSelection.Sample] {
    (0..<(fps * 3)).map { i in
        let pts = Double(i) / Double(fps)
        return .init(pts: pts, arrived: pts + 0.001, signature: signature(i))
    }
}
var checks = 0, failures = 0
func check(_ label: String, _ value: Bool) {
    checks += 1; if !value { failures += 1 }
    print("\(value ? "PASS" : "FAIL") \(label)")
}
check("identical signatures do not count as change", !PhaseSelection.changed(signature(1), signature(1)))
check("sampled meaningful differences count as change", PhaseSelection.changed(signature(1), signature(2)))
let fast = source(fps: 170)
for phase in [0.0, 0.002, 0.004, 0.006] {
    let result = PhaseSelection.candidate(fast, start: 1, end: 2, fps: 120, phase: phase)
    check("170-to-120 phase \(phase) uses distinct source samples", result.slots == 120 && result.comparisons == 120
          && result.changed == 120 && result.reusedSource == 0 && result.missing == 0)
}
let slow = PhaseSelection.candidate(source(fps: 60), start: 1, end: 2, fps: 120, phase: 0)
check("60 Hz source cannot be counted as 120 distinct samples", slow.slots == 120 && slow.reusedSource > 0 && slow.changed <= 61)
let actual = PhaseSelection.actual(fast, outputs: [
    .init(pts: fast[10].pts, delivered: 0.90),
    .init(pts: fast[12].pts, delivered: 1.00),
    .init(pts: fast[14].pts, delivered: 1.01),
    .init(pts: fast[14].pts, delivered: 1.02),
    .init(pts: -1, delivered: 1.03)
], start: 1, end: 2)
check("actual outputs match source PTS and reject duplicates or missing", actual.slots == 4 && actual.comparisons == 2
      && actual.changed == 2 && actual.reusedSource == 1 && actual.missing == 1)
let impossible = PhaseSelection.actual(fast, outputs: [.init(pts: fast[10].pts, delivered: 0.01)], start: 0, end: 1)
check("output before its source callback is rejected", impossible.slots == 1 && impossible.missing == 1)
check("empty source produces no hypothetical result", PhaseSelection.candidate([], start: 1, end: 2, fps: 120, phase: 0).slots == 0)
print("PHASE SELECTION: \(checks) checks, \(failures) failures; synthetic timestamps only")
exit(failures == 0 ? 0 : 1)
