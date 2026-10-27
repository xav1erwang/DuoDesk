// Copyright 2026 DUO你电脑 contributors. SPDX-License-Identifier: Apache-2.0
// Exercises the production physical-mode decision without configuring a display.
import Foundation

let cases: [(String, Double, Double, Int, Bool)] = [
    ("keep a 170 Hz panel while sampling at 120", 170, 170, 120, true),
    ("keep a 120 Hz panel", 120, 120, 120, true),
    ("do not lower a physical panel to 120", 170, 120, 120, false),
    ("do not raise a physical panel to 170", 120, 170, 120, false),
    ("do not choose a slightly different physical clock", 120, 119.88, 120, false),
    ("unknown physical refresh falls back", 0, 0, 120, false),
    ("insufficient physical clock falls back", 60, 60, 120, false),
    ("invalid negotiated rate falls back", 170, 170, 0, false)
]
for (label, current, candidate, fps, expected) in cases {
    let actual = DuoDesktopDisplay.permitsPhysicalMode(currentHz: current, candidateHz: candidate, fps: fps)
    guard actual == expected else { fputs("FAIL: \(label)\n", stderr); exit(1) }
    print("PASS: \(label)")
}
print("PHYSICAL MODE POLICY PASS; no display configuration was applied")
