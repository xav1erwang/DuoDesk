// Copyright 2026 DUO你电脑 contributors. SPDX-License-Identifier: Apache-2.0
// Production encoder scheduling with a fake VideoToolbox: no real encoder, capture, or input.
import Foundation
import CoreMedia
import QuartzCore

final class Delivered {
    private let lock = UnfairLock()
    private var values: [Int] = []
    func add(_ data: Data) { if let origin = FakeVT.origin(data) { lock.run { values.append(origin.call) } } }
    var calls: [Int] { lock.run { values } }
}

@discardableResult
func waitUntil(_ condition: () -> Bool, timeout: Double = 0.5) -> Bool {
    let deadline = CACurrentMediaTime() + timeout
    while CACurrentMediaTime() < deadline {
        if condition() { return true }
        Thread.sleep(forTimeInterval: 0.002)
    }
    return condition()
}

func checkTail(_ name: String, failure: Behavior) -> Bool {
    FakeVT.reset(plan: { _, call, _, _ in call == 2 ? failure : .returnAfter(0.002) })
    _ = Stats.shared.take()
    guard let encoder = try? HEVCEncoder(width: 16, height: 16, fps: 120, bitrate: 1_000_000,
                                          prioritizeSpeed: false, software: false) else { return false }
    let session = FakeVT.lastSession, delivered = Delivered()
    encoder.onEncoded = { data, _, _ in delivered.add(data) }
    encoder.encode(makeFrame(seq: 1), pts: CMTime(value: 1, timescale: 120))
    guard waitUntil({ delivered.calls == [1] }) else { _ = encoder.abandon(); return false }
    encoder.encode(makeFrame(seq: 2), pts: CMTime(value: 2, timescale: 120))
    let recovered = waitUntil { delivered.calls.contains(3) }
    Thread.sleep(forTimeInterval: 0.12) // a deliberately late duplicate callback must not emit again
    let calls = FakeVT.callsOf(session), outputs = delivered.calls
    let pass = recovered && calls.map(\.seq) == [1, 2, 2]
        && calls.map(\.forced) == [false, false, true] && outputs == [1, 3]
    print("\(pass ? "PASS" : "FAIL") \(name): content=\(calls.map(\.seq)), forced=\(calls.map(\.forced)), outputs=\(outputs)")
    _ = encoder.abandon()
    return pass
}

func checkNewerWaiting() -> Bool {
    FakeVT.reset(plan: { _, call, _, _ in call == 2 ? .errorAfter(0.08) : .returnAfter(0.002) })
    guard let encoder = try? HEVCEncoder(width: 16, height: 16, fps: 120, bitrate: 1_000_000,
                                          prioritizeSpeed: false, software: false) else { return false }
    let session = FakeVT.lastSession, delivered = Delivered()
    encoder.onEncoded = { data, _, _ in delivered.add(data) }
    encoder.encode(makeFrame(seq: 1), pts: CMTime(value: 1, timescale: 120))
    guard waitUntil({ delivered.calls == [1] }) else { _ = encoder.abandon(); return false }
    encoder.encode(makeFrame(seq: 2), pts: CMTime(value: 2, timescale: 120))
    guard waitUntil({ FakeVT.callsOf(session).count >= 2 }) else { _ = encoder.abandon(); return false }
    encoder.encode(makeFrame(seq: 3), pts: CMTime(value: 3, timescale: 120))
    let deliveredNewer = waitUntil { delivered.calls.contains(3) }
    Thread.sleep(forTimeInterval: 0.12)
    let calls = FakeVT.callsOf(session), outputs = delivered.calls
    let pass = deliveredNewer && calls.map(\.seq) == [1, 2, 3]
        && calls.map(\.forced) == [false, false, true] && outputs == [1, 3]
    print("\(pass ? "PASS" : "FAIL") newer waiting image wins: content=\(calls.map(\.seq)), forced=\(calls.map(\.forced)), outputs=\(outputs)")
    _ = encoder.abandon()
    return pass
}

func checkNewerBeforeRetry() -> Bool {
    FakeVT.reset(plan: { _, call, _, _ in call == 2 ? .dropAfter(0.002) : .returnAfter(0.002) })
    guard let encoder = try? HEVCEncoder(width: 16, height: 16, fps: 120, bitrate: 1_000_000,
                                          prioritizeSpeed: false, software: false) else { return false }
    let session = FakeVT.lastSession, delivered = Delivered()
    encoder.onEncoded = { data, _, _ in delivered.add(data) }
    encoder.encode(makeFrame(seq: 1), pts: CMTime(value: 1, timescale: 120))
    guard waitUntil({ delivered.calls == [1] }) else { _ = encoder.abandon(); return false }
    encoder.encode(makeFrame(seq: 2), pts: CMTime(value: 2, timescale: 120))
    guard waitUntil({ FakeVT.callsOf(session).count >= 2 }) else { _ = encoder.abandon(); return false }
    Thread.sleep(forTimeInterval: 0.020)
    encoder.encode(makeFrame(seq: 3), pts: CMTime(value: 3, timescale: 120))
    let deliveredNewer = waitUntil { delivered.calls.contains(3) }
    Thread.sleep(forTimeInterval: 0.12)
    let calls = FakeVT.callsOf(session), outputs = delivered.calls
    let pass = deliveredNewer && calls.map(\.seq) == [1, 2, 3]
        && calls.map(\.forced) == [false, false, true] && outputs == [1, 3]
    print("\(pass ? "PASS" : "FAIL") newer image before timer wins: content=\(calls.map(\.seq)), forced=\(calls.map(\.forced)), outputs=\(outputs)")
    _ = encoder.abandon()
    return pass
}

func checkBoundedRetry() -> Bool {
    FakeVT.reset(plan: { _, call, seq, _ in call == 1 || seq == 3 ? .returnAfter(0.002) : .dropAfter(0.002) })
    guard let encoder = try? HEVCEncoder(width: 16, height: 16, fps: 120, bitrate: 1_000_000,
                                          prioritizeSpeed: false, software: false) else { return false }
    let session = FakeVT.lastSession, delivered = Delivered()
    encoder.onEncoded = { data, _, _ in delivered.add(data) }
    encoder.encode(makeFrame(seq: 1), pts: CMTime(value: 1, timescale: 120))
    guard waitUntil({ delivered.calls == [1] }) else { _ = encoder.abandon(); return false }
    encoder.encode(makeFrame(seq: 2), pts: CMTime(value: 2, timescale: 120))
    _ = waitUntil { FakeVT.callsOf(session).count >= 5 }
    Thread.sleep(forTimeInterval: 0.12)
    let beforeNewFrame = FakeVT.callsOf(session)
    let bounded = beforeNewFrame.map(\.seq) == [1, 2, 2, 2, 2]
        && beforeNewFrame.map(\.forced) == [false, false, true, true, true] && delivered.calls == [1]
    encoder.encode(makeFrame(seq: 3), pts: CMTime(value: 3, timescale: 120))
    let newerDelivered = waitUntil { delivered.calls.contains(6) }
    let calls = FakeVT.callsOf(session)
    let pass = bounded && newerDelivered && calls.map(\.seq) == [1, 2, 2, 2, 2, 3]
        && calls.last?.forced == true && delivered.calls == [1, 6]
    print("\(pass ? "PASS" : "FAIL") bounded retries and later keyframe: calls=\(calls.count), outputs=\(delivered.calls), laterForced=\(calls.last?.forced == true)")
    _ = encoder.abandon()
    return pass
}

let checks = [
    checkTail("last delta refused", failure: .refuse(after: 0)),
    checkTail("last delta dropped asynchronously", failure: .dropAfter(0.002)),
    checkTail("last delta dropped synchronously without callback", failure: .dropSync(callbackAfter: nil)),
    checkTail("synchronous drop with late duplicate callback", failure: .dropSync(callbackAfter: 0.10)),
    checkTail("synchronous drop callback before return", failure: .dropSyncCallbackBeforeReturn),
    checkNewerWaiting(), checkNewerBeforeRetry(), checkBoundedRetry()
]
exit(checks.allSatisfy { $0 } ? 0 : 1)
