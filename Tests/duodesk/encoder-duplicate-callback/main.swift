// Copyright 2026 DUO你电脑 contributors. SPDX-License-Identifier: Apache-2.0
// Real HEVCEncoder glue with the existing fake VideoToolbox; no encoder, capture or input is opened.
import Foundation
import CoreMedia
import QuartzCore

final class Delivered {
    private let lock = UnfairLock()
    private var calls: [Int] = []
    func add(_ data: Data) { if let origin = FakeVT.origin(data) { lock.run { calls.append(origin.call) } } }
    var all: [Int] { lock.run { calls } }
}

func run(_ name: String, failureCount: Int, beforeReturn: Bool, success: Bool) -> Bool {
    FakeVT.reset(plan: { _, call, _, _ in
        call <= failureCount ? .refuseWithCallback(delay: 0.040, beforeReturn: beforeReturn, success: success)
                             : .returnAfter(0.002)
    })
    _ = Stats.shared.take()
    guard let encoder = try? HEVCEncoder(width: 16, height: 16, fps: 120, bitrate: 1_000_000,
                                          prioritizeSpeed: false, software: false) else { return false }
    let session = FakeVT.lastSession
    let delivered = Delivered()
    encoder.onEncoded = { data, _, _ in delivered.add(data) }
    encoder.requestKeyframe()
    for i in 1...12 {
        encoder.encode(makeFrame(seq: i), pts: CMTime(value: CMTimeValue(i), timescale: 120))
        Thread.sleep(forTimeInterval: 0.010)
    }
    Thread.sleep(forTimeInterval: 0.100)
    let calls = FakeVT.callsOf(session)
    let forced = calls.filter(\.forced).map(\.n)
    let outputs = delivered.all
    let counters = Stats.shared.take()
    let expected = Array(1...(failureCount + 1))
    let valid = forced == expected && !outputs.contains(where: { $0 <= failureCount })
        && outputs.contains(where: { $0 > failureCount })
        && counters["enc.refused", default: 0] == failureCount
        && counters["enc.error", default: 0] == (beforeReturn && !success ? failureCount : 0)
    print("\(valid ? "PASS" : "FAIL") \(name): forced=\(forced), outputs=\(outputs), refused=\(counters["enc.refused", default: 0]), callbackErrors=\(counters["enc.error", default: 0])")
    _ = encoder.abandon()
    return valid
}

func queuedFrameAfterFailure(_ name: String, refusal: Bool) -> Bool {
    FakeVT.reset(plan: { _, call, _, _ in
        call == 1 ? (refusal ? .refuse(after: 0.050) : .errorAfter(0.050)) : .returnAfter(0.002)
    })
    _ = Stats.shared.take()
    guard let encoder = try? HEVCEncoder(width: 16, height: 16, fps: 120, bitrate: 1_000_000,
                                          prioritizeSpeed: false, software: false) else { return false }
    let session = FakeVT.lastSession
    encoder.requestKeyframe()
    for i in 1...12 {
        encoder.encode(makeFrame(seq: i), pts: CMTime(value: CMTimeValue(i), timescale: 120))
        Thread.sleep(forTimeInterval: 0.010)
    }
    Thread.sleep(forTimeInterval: 0.100)
    let calls = FakeVT.callsOf(session)
    let counters = Stats.shared.take()
    let forced = calls.filter(\.forced).map(\.n)
    let valid = forced == [1, 2] && counters["enc.mailboxDrop", default: 0] > 0
        && counters[refusal ? "enc.refused" : "enc.error", default: 0] == 1
    print("\(valid ? "PASS" : "FAIL") \(name): forced=\(forced), mailboxDrops=\(counters["enc.mailboxDrop", default: 0])")
    _ = encoder.abandon()
    return valid
}

let checks = [
    run("late failure is ignored after refusal", failureCount: 1, beforeReturn: false, success: false),
    run("late success is ignored after refusal", failureCount: 1, beforeReturn: false, success: true),
    run("callback before refusal consumes one retry per failed frame", failureCount: 3, beforeReturn: true, success: false),
    queuedFrameAfterFailure("waiting frame takes the retry after refusal", refusal: true),
    queuedFrameAfterFailure("waiting frame takes the retry after callback failure", refusal: false)
]
exit(checks.allSatisfy { $0 } ? 0 : 1)
