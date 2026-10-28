// Copyright 2026 DUO你电脑 contributors. SPDX-License-Identifier: Apache-2.0
// Read-only live display metadata plus a simulated virtual topology; no capture or display writes.
import Foundation

@main struct DesktopSamplingSwitchCheck {
    @MainActor static func main() async {
        let clocks: [(Double, Int?)] = [(60, 60), (59.94, 60), (119.88, 120), (120, 120),
                                        (170, 170), (0, nil), (.nan, nil), (.infinity, nil)]
        for (clock, expected) in clocks {
            guard DuoDesktopDisplay.samplingCeiling(refreshHz: clock) == expected else {
                fatalError("sampling ceiling mismatch for \(clock)")
            }
        }
        let targets: [(String, Int, Int?, Bool, Int?, Int)] = [
            ("new 120 session", 120, 120, false, nil, 120),
            ("120 clock sampled at 60", 120, 60, false, 120, 60),
            ("120 clock sampled at 120", 120, 120, false, 120, 120),
            ("60 clock keeps the target at 60", 120, 120, false, 60, 60),
            ("faster physical clock", 120, 120, false, 170, 120),
            ("host limit", 60, 120, false, 120, 60),
            ("legacy default", 120, nil, false, nil, 60),
            ("legacy software limit", 120, 120, true, 120, 60)
        ]
        for (label, maximum, highest, software, ceiling, expected) in targets {
            let actual = StreamSamplingPolicy.target(maximum: maximum, highestRequested: highest,
                                                      softwareEncoder: software, sourceClockCeiling: ceiling)
            guard actual == expected else { fatalError("\(label): \(actual), expected \(expected)") }
            print("PASS: \(label)")
        }
        guard let checks = await DuoDesktopDisplay.inspectSamplingSwitchForTesting(), checks.count == 5 else {
            fatalError("read-only sampling fixture could not use the current main mode")
        }
        let labels = ["virtual topology stand-in is valid", "120 to 60 reuses the desktop",
                      "60 to 120 reuses the desktop", "above-source request is rejected without a write",
                      "physical mode changes sampling without a new snapshot"]
        for (passed, label) in zip(checks, labels) {
            guard passed else { fatalError(label) }
            print("PASS: \(label)")
        }
        print("DESKTOP SAMPLING SWITCH PASS; source clock and virtual topology were simulated; no display configuration or capture")
    }
}
