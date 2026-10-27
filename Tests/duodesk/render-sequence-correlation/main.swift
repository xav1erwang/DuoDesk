// Copyright 2026 DUO你电脑 contributors. SPDX-License-Identifier: Apache-2.0
// Pure correlation checks: no capture, display changes or user content.
import Foundation

typealias Audit = RenderSequenceCorrelation
func sample(_ marker: Int?, _ time: UInt64?, arrival: UInt64? = nil) -> Audit.Sample {
    Audit.Sample(displayTime: time, arrival: arrival ?? ((time ?? 0) + 20), marker: marker)
}
let draws: [(Int, UInt64)] = [(1, 80), (2, 180), (3, 280), (4, 380), (5, 480)]
let primary = [sample(1, 100), sample(2, 200), sample(2, 208), sample(4, 400), sample(5, 500)]
let secondary = [sample(1, 105), sample(3, 305), sample(4, 410), sample(5, 505)]
func compare(_ a: [Audit.Sample], _ b: [Audit.Sample], drawings: [(Int, UInt64)] = draws,
             lower: UInt64 = 50, upper: UInt64 = 550) -> Audit.Summary {
    Audit.compare(draws: drawings, primary: a, secondary: b, lower: lower, upper: upper, nanosecondsPerTick: 1_000_000)
}
var checks = 0, failures = 0
func check(_ name: String, _ passed: Bool) {
    checks += 1
    if !passed { failures += 1 }
    print("\(passed ? "PASS" : "FAIL") \(name)")
}
let basic = compare(primary, secondary)
check("same drawn marker matched without timestamp equality", basic.valid && basic.common == 3)
check("interior markers present on one side counted once", basic.primaryOnly == 1 && basic.secondaryOnly == 1)
check("repeated sample uses its first observation", basic.primaryUnique == 4 && basic.displayDeltaP50 == 5 && basic.displayDeltaP95 == 10)
check("callback differences preserve their own timing", basic.arrivalDeltaP50 == 5 && basic.arrivalDeltaP95 == 10)
let duplicate = compare(primary, secondary, drawings: draws + [(4, 381)])
check("ambiguous source draw is excluded", duplicate.valid && duplicate.ambiguousDraws == 1 && duplicate.common == 2)
check("missing marker invalidates overlap", !compare([sample(nil, 100)], secondary).valid)
check("missing display timestamp invalidates rather than silently disappearing", !compare([sample(1, nil)], secondary).valid)
check("backward display time is rejected", !compare([sample(1, 200), sample(2, 100)], secondary).valid)
check("backward marker is rejected", !compare([sample(2, 200), sample(1, 300)], secondary).valid)
check("unknown marker is rejected", !compare([sample(77, 200)], secondary).valid)
check("callback earlier than source draw is rejected", !compare([sample(1, 100, arrival: 79)], secondary).valid)
check("unmatched captures are not compared", !compare([sample(2, 200)], [sample(3, 300)]).valid)
check("invalid time window is rejected", !compare(primary, secondary, lower: 550, upper: 50).valid)
let boundaries = compare([sample(1, 100), sample(2, 200), sample(4, 400)],
                         [sample(3, 300), sample(4, 410), sample(5, 500)])
check("unmatched boundary codes are not claimed", boundaries.valid && boundaries.primaryOnly == 1 && boundaries.secondaryOnly == 0)
print("\(checks) checks; \(failures) failures; no capture")
exit(failures == 0 ? 0 : 1)
