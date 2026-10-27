// Copyright 2026 DUO你电脑 contributors. SPDX-License-Identifier: Apache-2.0
// Clock arithmetic only; no capture, display configuration, or synthetic FPS acceptance.
import CoreMedia
import Foundation

func emits(_ pacer: inout CaptureFramePacer, _ timestamp: CMTime) -> Bool {
    if case .emit = pacer.consider(timestamp) { return true }
    return false
}

func samples(sourceFPS: Int, targetFPS: Int, seconds: Int) -> Int {
    var pacer = CaptureFramePacer(fps: targetFPS)
    return (0..<(sourceFPS * seconds)).reduce(into: 0) { count, index in
        if emits(&pacer, CMTime(value: Int64(index), timescale: CMTimeScale(sourceFPS))) { count += 1 }
    }
}
guard samples(sourceFPS: 170, targetFPS: 120, seconds: 30) == 3600,
      samples(sourceFPS: 120, targetFPS: 120, seconds: 30) == 3600,
      samples(sourceFPS: 60, targetFPS: 120, seconds: 30) == 1800 else {
    fputs("FAIL: source-to-target clock selection\n", stderr); exit(1)
}
var pacer = CaptureFramePacer(fps: 120)
guard emits(&pacer, CMTime(value: 1, timescale: 1)),
      !emits(&pacer, CMTime(value: 1, timescale: 1)),
      !emits(&pacer, .invalid),
      !emits(&pacer, CMTime(value: 1, timescale: 2)),
      emits(&pacer, CMTime(value: 10, timescale: 1)),
      !emits(&pacer, CMTime(value: 10001, timescale: 1000)),
      !emits(&pacer, CMTime(value: 1, timescale: 1)),
      !emits(&pacer, CMTime(value: 1001, timescale: 1000)),
      emits(&pacer, CMTime(value: 1002, timescale: 1000)),
      !emits(&pacer, CMTime(value: 1003, timescale: 1000)) else {
    fputs("FAIL: duplicate, invalid, backwards, or long-gap handling\n", stderr); exit(1)
}
var tail = CaptureFramePacer(fps: 10)
guard emits(&tail, .zero),
      case .hold(let wait) = tail.consider(CMTime(value: 4, timescale: 100)),
      abs(wait - 0.06) < 0.000_001 else {
    fputs("FAIL: early changed frame was not held until its target deadline\n", stderr); exit(1)
}
tail.deliveredHeldFrame()
guard case .hold(let nextWait) = tail.consider(CMTime(value: 11, timescale: 100)),
      abs(nextWait - 0.09) < 0.000_001 else {
    fputs("FAIL: held-frame delivery did not advance the stable target clock\n", stderr); exit(1)
}

// Model timer and source arrivals independently: output values must remain distinct original
// samples, follow the requested clock under load, and include the last sample after motion stops.
var continuous = CaptureFramePacer(fps: 120)
var input = 0, pending: CMTime?, deadline: CMTime?, output: [CMTime] = []
let limit = CMTime(value: 2, timescale: 1)
while input < 340 || deadline != nil {
    let source = input < 340 ? CMTime(value: Int64(input), timescale: 170) : nil
    if let due = deadline, source == nil || CMTimeCompare(due, source!) <= 0 {
        guard let held = pending else { fputs("FAIL: timer without a held frame\n", stderr); exit(1) }
        output.append(held); continuous.deliveredHeldFrame(); pending = nil; deadline = nil
    } else if let source {
        input += 1
        switch continuous.consider(source) {
        case .discard: fputs("FAIL: ordered source sample was discarded as invalid\n", stderr); exit(1)
        case .emit: pending = nil; deadline = nil; output.append(source)
        case .hold(let wait):
            pending = source
            if deadline == nil {
                deadline = CMTimeAdd(source, CMTimeMakeWithSeconds(wait, preferredTimescale: 1_000_000_000))
            }
        }
    }
}
let inInterval = output.filter { CMTimeCompare($0, limit) < 0 }.count
guard (240...241).contains(inInterval),
      output.last.map({ CMTimeCompare($0, CMTime(value: 339, timescale: 170)) == 0 }) == true,
      zip(output, output.dropFirst()).allSatisfy({ CMTimeCompare($0, $1) < 0 }),
      output.allSatisfy({ CMTimeConvertScale($0, timescale: 170, method: .default).value >= 0
                         && CMTimeCompare($0, CMTimeConvertScale($0, timescale: 170, method: .default)) == 0 }) else {
    fputs("FAIL: paced continuous source lost its tail, duplicated frames, or missed its target clock\n", stderr); exit(1)
}
print("CAPTURE FRAME PACER PASS: rate selection, tail deadlines, duplicate/invalid/backwards timestamps, and clock reset rebase")
