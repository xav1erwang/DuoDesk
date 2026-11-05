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
        let initialPhysical: [(Int, Double, Int)] = [(120, 60, 60), (120, 59.94, 60), (120, 120, 120),
                                                       (60, 170, 60), (120, 0, 120)]
        for (requested, clock, expected) in initialPhysical {
            guard DuoDesktopDisplay.initialPhysicalSamplingFPS(requested: requested, refreshHz: clock) == expected else {
                fatalError("physical sampling target mismatch")
            }
        }
        let virtualPlans: [(Bool, Double, Int, Double, Int)] = [
            (true, 170, 120, 170, 120), (true, 170, 60, 170, 60),
            (true, 59.94, 120, 59.94, 60), (true, 120, 120, 120, 120),
            (false, 60, 120, 120, 120)
        ]
        for (mirrored, physical, requested, expectedClock, expectedSampling) in virtualPlans {
            guard let plan = DuoDesktopDisplay.candidateVirtualClock(mirrored: mirrored, physicalHz: physical,
                                                                      requestedFPS: requested),
                  plan.refreshHz == expectedClock, plan.samplingFPS == expectedSampling else {
                fatalError("candidate virtual clock or sampling target mismatch")
            }
        }
        for invalid in [0.0, -1.0, Double.nan, Double.infinity, 1001.0] {
            guard DuoDesktopDisplay.candidateVirtualClock(mirrored: true, physicalHz: invalid, requestedFPS: 120) == nil else {
                fatalError("unknown physical clock must not choose mirror timing")
            }
        }
        guard DuoDesktopDisplay.candidateVirtualClock(mirrored: true, physicalHz: 170, requestedFPS: 241) == nil else {
            fatalError("invalid sampling request must not choose mirror timing")
        }
        for fps in [60, 120] {
            guard let plan = DuoDesktopDisplay.extendedVirtualClock(physicalHz: 170, requestedFPS: fps),
                  plan.refreshHz == Double(fps), plan.samplingFPS == fps else {
                fatalError("an independent extension uses its own requested clock")
            }
        }
        guard DuoDesktopDisplay.extendedVirtualClock(physicalHz: .nan, requestedFPS: 120) == nil else {
            fatalError("an extension needs a known original physical clock")
        }
        print("PASS: candidate mirror clock follows physical timing while sampling remains independent")
        guard DuoDesktopDisplay.permitsPhysicalMode(currentHz: 60, candidateHz: 60, fps: 60),
              !DuoDesktopDisplay.permitsPhysicalMode(currentHz: 60, candidateHz: 120, fps: 60) else {
            fatalError("physical mode must keep its original clock")
        }
        print("PASS: initial sampling caps to the physical clock without selecting a new refresh")
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
        guard let safety = await DuoDesktopDisplay.inspectRefreshSafetyForTesting(), safety.count == 4 else {
            fatalError("read-only refresh-safety fixture could not inspect the current main display")
        }
        let safetyLabels = ["mirror writes intercepted and independent-primary path remains disabled",
                            "independent physical display detected", "physical mirror master detected",
                            "physical mirror follower detected"]
        for (passed, label) in zip(safety, safetyLabels) {
            guard passed else { fatalError(label) }
            print("PASS: \(label)")
        }
        guard let mirror = DuoDesktopDisplay.inspectPinnedMirrorForTesting(), mirror.count == 5 else {
            fatalError("read-only pinned-mirror fixture could not inspect the current mode")
        }
        let mirrorLabels = ["mirror accepts a uniform rebase and rejects changed topology", "mirror restores source and unrelated origins without writing unrelated modes",
                            "candidate stops staging at the first failure", "invalid mirror identifiers cause no operations",
                            "only an exact virtual insertion permits temporary adjacent-screen movement"]
        for (passed, label) in zip(mirror, mirrorLabels) {
            guard passed else { fatalError(label) }
            print("PASS: \(label)")
        }
        let preview = CGRect(x: 15, y: 195, width: 146, height: 141)
        let actual = CGRect(x: 15, y: 30, width: 1493, height: 820)
        guard DesktopWindowHandoff.isScaledPreview(preview, accessibilityFrame: actual),
              !DesktopWindowHandoff.isScaledPreview(actual, accessibilityFrame: actual),
              !DesktopWindowHandoff.isScaledPreview(CGRect(x: 200, y: 300, width: 1493, height: 820), accessibilityFrame: actual),
              !DesktopWindowHandoff.isScaledPreview(.zero, accessibilityFrame: actual) else {
            fatalError("scaled Stage Manager previews must not be treated as movable windows")
        }
        print("PASS: scaled Stage Manager previews are excluded while normal or moved windows remain eligible")
        guard let extensionWrites = DuoDesktopDisplay.inspectExtendedModeWritesForTesting(), extensionWrites.count == 4 else {
            fatalError("read-only extended display fixture could not inspect the current mode")
        }
        let extensionLabels = ["extension mode operation targets the new display only",
                               "extension mode operation rejects an original display",
                               "extension mode operation rejects a null display",
                               "extension mode operation propagates failure"]
        for (passed, label) in zip(extensionWrites, extensionLabels) {
            guard passed else { fatalError(label) }
            print("PASS: \(label)")
        }
        guard DuoDesktopDisplay.inspectExtendedRestoreForTesting() else {
            fatalError("extension cleanup must not configure a physical display")
        }
        print("PASS: extension cleanup makes no physical display configuration")
        print("DESKTOP SAMPLING SWITCH PASS; source clock and virtual topology were simulated; no display configuration or capture")
    }
}
