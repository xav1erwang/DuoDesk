// Copyright 2026 DUO你电脑 contributors. SPDX-License-Identifier: Apache-2.0
// Clock arithmetic only; no capture, display configuration, or synthetic FPS acceptance.
import CoreMedia
import Foundation

func samples(sourceFPS: Int, targetFPS: Int, seconds: Int) -> Int {
    var pacer = CaptureFramePacer(fps: targetFPS)
    return (0..<(sourceFPS * seconds)).reduce(into: 0) { count, index in
        if pacer.admit(CMTime(value: Int64(index), timescale: CMTimeScale(sourceFPS))) { count += 1 }
    }
}
guard samples(sourceFPS: 170, targetFPS: 120, seconds: 30) == 3600,
      samples(sourceFPS: 120, targetFPS: 120, seconds: 30) == 3600,
      samples(sourceFPS: 60, targetFPS: 120, seconds: 30) == 1800 else {
    fputs("FAIL: source-to-target clock selection\n", stderr); exit(1)
}
var pacer = CaptureFramePacer(fps: 120)
guard pacer.admit(CMTime(value: 1, timescale: 1)),
      !pacer.admit(CMTime(value: 1, timescale: 1)),
      !pacer.admit(.invalid),
      !pacer.admit(CMTime(value: 1, timescale: 2)),
      pacer.admit(CMTime(value: 10, timescale: 1)),
      !pacer.admit(CMTime(value: 10001, timescale: 1000)),
      !pacer.admit(CMTime(value: 1, timescale: 1)),
      !pacer.admit(CMTime(value: 1001, timescale: 1000)),
      pacer.admit(CMTime(value: 1002, timescale: 1000)),
      !pacer.admit(CMTime(value: 1003, timescale: 1000)) else {
    fputs("FAIL: duplicate, invalid, backwards, or long-gap handling\n", stderr); exit(1)
}
print("CAPTURE FRAME PACER PASS: rate selection, duplicate/invalid/backwards timestamps, and clock reset rebase")
