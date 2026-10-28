// Copyright 2026 DUO你电脑 contributors. SPDX-License-Identifier: Apache-2.0
import Foundation

func expect(_ actual: Int, _ wanted: Int, _ caseName: String) {
    guard actual == wanted else { fatalError("\(caseName): got \(actual), wanted \(wanted)") }
}
expect(DuoStreamPolicy.requestedFPS(panelMaximum: 120, lowPower: false), 60, "default")
expect(DuoStreamPolicy.requestedFPS(panelMaximum: 120, lowPower: false, preferredFPS: 120), 120, "explicit 120")
expect(DuoStreamPolicy.requestedFPS(panelMaximum: 120, lowPower: true, preferredFPS: 120), 60, "low power")
expect(DuoStreamPolicy.requestedFPS(panelMaximum: 60, lowPower: false, preferredFPS: 120), 60, "60 Hz panel")
expect(DuoStreamPolicy.requestedFPS(panelMaximum: 30, lowPower: false, preferredFPS: 120), 30, "lower panel ceiling")
expect(DuoStreamPolicy.requestedFPS(panelMaximum: 240, lowPower: false, preferredFPS: 120), 120, "protocol ceiling")
expect(DuoStreamPolicy.requestedFPS(panelMaximum: 120, lowPower: false, preferredFPS: 0), 60, "unset preference")
expect(DuoStreamPolicy.requestedFPS(panelMaximum: 120, lowPower: false, preferredFPS: 999), 60, "invalid preference")
print("FRAME RATE POLICY PASS: default 60, explicit 120, power/panel caps, unset and invalid settings; requests only")
