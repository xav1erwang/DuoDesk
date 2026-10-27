// Copyright 2026 DUO你电脑 contributors. SPDX-License-Identifier: Apache-2.0
// The production encoder scheduler runs with test-only VideoToolbox and format-description faults.
import Foundation
import CoreMedia
import QuartzCore

final class Delivered {
    private let lock = UnfairLock()
    private var items: [(Int, Bool, Bool)] = []
    func add(_ data: Data, key: Bool, parameters: ParameterSets?) {
        guard let origin = FakeVT.origin(data) else { return }
        let valid = parameters.map { $0.nalUnitHeaderLength == 4 && $0.sets.count == 3
            && $0.sets.allSatisfy { !$0.isEmpty && $0.count <= 65_535 } } ?? false
        lock.run { items.append((origin.call, key, valid)) }
    }
    var snapshot: [(Int, Bool, Bool)] { lock.run { items } }
}

@discardableResult
func waitUntil(_ condition: () -> Bool, timeout: Double = 0.8) -> Bool {
    let deadline = CACurrentMediaTime() + timeout
    while CACurrentMediaTime() < deadline {
        if condition() { return true }
        Thread.sleep(forTimeInterval: 0.002)
    }
    return condition()
}

func checkTail(_ label: String, fault: Malformation) -> Bool {
    FakeVT.reset(plan: { _, call, _, _ in call == 2 ? .malformedAfter(0.002, fault) : .returnAfter(0.002) })
    guard let encoder = try? HEVCEncoder(width: 16, height: 16, fps: 120, bitrate: 1_000_000,
                                         prioritizeSpeed: false, software: false) else { return false }
    let session = FakeVT.lastSession, delivered = Delivered()
    encoder.onEncoded = { data, key, ps in delivered.add(data, key: key, parameters: ps) }
    encoder.encode(makeFrame(seq: 1), pts: CMTime(value: 1, timescale: 120))
    guard waitUntil({ delivered.snapshot.count == 1 }) else { _ = encoder.abandon(); return false }
    encoder.requestKeyframe()
    encoder.encode(makeFrame(seq: 2), pts: CMTime(value: 2, timescale: 120))
    _ = waitUntil { delivered.snapshot.contains { $0.0 == 3 } }
    let calls = FakeVT.callsOf(session), output = delivered.snapshot
    let pass = calls.map(\.seq) == [1, 2, 2] && calls.map(\.forced) == [false, true, true]
        && output.map(\.0) == [1, 3] && output.last?.1 == true && output.last?.2 == true
    print("\(pass ? "PASS" : "FAIL") \(label): submitted=\(calls.map(\.seq)), forced=\(calls.map(\.forced)), delivered=\(output.map(\.0)), validFinalParameters=\(output.last?.2 ?? false)")
    _ = encoder.abandon()
    return pass
}

func checkNewer() -> Bool {
    FakeVT.reset(plan: { _, call, _, _ in call == 2 ? .malformedAfter(0.08, .badNALLength) : .returnAfter(0.002) })
    guard let encoder = try? HEVCEncoder(width: 16, height: 16, fps: 120, bitrate: 1_000_000,
                                         prioritizeSpeed: false, software: false) else { return false }
    let session = FakeVT.lastSession, delivered = Delivered()
    encoder.onEncoded = { data, key, ps in delivered.add(data, key: key, parameters: ps) }
    encoder.encode(makeFrame(seq: 1), pts: CMTime(value: 1, timescale: 120))
    guard waitUntil({ delivered.snapshot.count == 1 }) else { _ = encoder.abandon(); return false }
    encoder.requestKeyframe()
    encoder.encode(makeFrame(seq: 2), pts: CMTime(value: 2, timescale: 120))
    guard waitUntil({ FakeVT.callsOf(session).count >= 2 }) else { _ = encoder.abandon(); return false }
    encoder.encode(makeFrame(seq: 3), pts: CMTime(value: 3, timescale: 120))
    let recovered = waitUntil { delivered.snapshot.contains { $0.0 == 3 } }
    let calls = FakeVT.callsOf(session), output = delivered.snapshot
    let pass = recovered && calls.map(\.seq) == [1, 2, 3] && calls.map(\.forced) == [false, true, true]
        && output.map(\.0) == [1, 3] && output.last?.2 == true
    print("\(pass ? "PASS" : "FAIL") newer pending image carries recovery: submitted=\(calls.map(\.seq)), delivered=\(output.map(\.0))")
    _ = encoder.abandon(); return pass
}

func checkBounded() -> Bool {
    FakeVT.reset(plan: { _, call, _, _ in (2...5).contains(call) ? .malformedAfter(0.002, .missingFormat) : .returnAfter(0.002) })
    guard let encoder = try? HEVCEncoder(width: 16, height: 16, fps: 120, bitrate: 1_000_000,
                                         prioritizeSpeed: false, software: false) else { return false }
    let session = FakeVT.lastSession, delivered = Delivered()
    encoder.onEncoded = { data, key, ps in delivered.add(data, key: key, parameters: ps) }
    encoder.encode(makeFrame(seq: 1), pts: CMTime(value: 1, timescale: 120))
    guard waitUntil({ delivered.snapshot.count == 1 }) else { _ = encoder.abandon(); return false }
    encoder.requestKeyframe()
    encoder.encode(makeFrame(seq: 2), pts: CMTime(value: 2, timescale: 120))
    _ = waitUntil { FakeVT.callsOf(session).count >= 5 }
    Thread.sleep(forTimeInterval: 0.12)
    let bounded = FakeVT.callsOf(session).map(\.seq) == [1, 2, 2, 2, 2] && delivered.snapshot.map(\.0) == [1]
    encoder.encode(makeFrame(seq: 3), pts: CMTime(value: 3, timescale: 120))
    let recovered = waitUntil { delivered.snapshot.contains { $0.0 == 6 } }
    let calls = FakeVT.callsOf(session), output = delivered.snapshot
    let pass = bounded && recovered && calls.map(\.seq) == [1, 2, 2, 2, 2, 3]
        && calls.last?.forced == true && output.last?.2 == true
    print("\(pass ? "PASS" : "FAIL") parameter failure retries bounded, later new frame forced: calls=\(calls.count)")
    _ = encoder.abandon(); return pass
}

let results = [checkTail("missing keyframe format", fault: .missingFormat),
               checkTail("parameter set count over wire limit", fault: .badParameterCount),
               checkTail("unsupported NAL prefix length", fault: .badNALLength),
               checkTail("empty parameter set", fault: .emptyParameter),
               checkTail("oversized parameter set", fault: .oversizedParameter),
               checkTail("failed parameter set read", fault: .parameterReadFailure),
               checkNewer(), checkBounded()]
print("\(results.filter { $0 }.count)/\(results.count) passed; fake codec only")
exit(results.allSatisfy { $0 } ? 0 : 1)
