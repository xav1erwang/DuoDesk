// Copyright 2026 DUO你电脑 contributors. SPDX-License-Identifier: Apache-2.0
// Invalid-success outputs are injected into the real encoder scheduler; no codec session starts.
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
func waitUntil(_ condition: () -> Bool, timeout: Double = 0.7) -> Bool {
    let deadline = CACurrentMediaTime() + timeout
    while CACurrentMediaTime() < deadline {
        if condition() { return true }
        Thread.sleep(forTimeInterval: 0.002)
    }
    return condition()
}
func checkTail(_ name: String, kind: Malformation) -> Bool {
    FakeVT.reset(plan: { _, call, _, _ in call == 2 ? .malformedAfter(0.002, kind) : .returnAfter(0.002) })
    guard let encoder = try? HEVCEncoder(width: 16, height: 16, fps: 120, bitrate: 1_000_000,
                                         prioritizeSpeed: false, software: false) else { return false }
    let session = FakeVT.lastSession, delivered = Delivered()
    encoder.onEncoded = { data, _, _ in delivered.add(data) }
    encoder.encode(makeFrame(seq: 1), pts: CMTime(value: 1, timescale: 120))
    guard waitUntil({ delivered.calls == [1] }) else { _ = encoder.abandon(); return false }
    encoder.encode(makeFrame(seq: 2), pts: CMTime(value: 2, timescale: 120))
    let recovered = waitUntil { delivered.calls.contains(3) }
    let calls = FakeVT.callsOf(session), outputs = delivered.calls
    let pass = recovered && calls.map(\.seq) == [1, 2, 2]
        && calls.map(\.forced) == [false, false, true] && outputs == [1, 3]
    print("\(pass ? "PASS" : "FAIL") \(name): content=\(calls.map(\.seq)), forced=\(calls.map(\.forced)), outputs=\(outputs)")
    _ = encoder.abandon()
    return pass
}

func checkNewer() -> Bool {
    FakeVT.reset(plan: { _, call, _, _ in call == 2 ? .malformedAfter(0.08, .copyFailure) : .returnAfter(0.002) })
    guard let encoder = try? HEVCEncoder(width: 16, height: 16, fps: 120, bitrate: 1_000_000,
                                         prioritizeSpeed: false, software: false) else { return false }
    let session = FakeVT.lastSession, delivered = Delivered()
    encoder.onEncoded = { data, _, _ in delivered.add(data) }
    encoder.encode(makeFrame(seq: 1), pts: CMTime(value: 1, timescale: 120))
    guard waitUntil({ delivered.calls == [1] }) else { _ = encoder.abandon(); return false }
    encoder.encode(makeFrame(seq: 2), pts: CMTime(value: 2, timescale: 120))
    guard waitUntil({ FakeVT.callsOf(session).count >= 2 }) else { _ = encoder.abandon(); return false }
    encoder.encode(makeFrame(seq: 3), pts: CMTime(value: 3, timescale: 120))
    let recovered = waitUntil { delivered.calls.contains(3) }
    let calls = FakeVT.callsOf(session)
    let pass = recovered && calls.map(\.seq) == [1, 2, 3]
        && calls.map(\.forced) == [false, false, true] && delivered.calls == [1, 3]
    print("\(pass ? "PASS" : "FAIL") newer waiting frame carries recovery: content=\(calls.map(\.seq)), forced=\(calls.map(\.forced))")
    _ = encoder.abandon()
    return pass
}

func checkBounded() -> Bool {
    FakeVT.reset(plan: { _, call, _, _ in (2...5).contains(call) ? .malformedAfter(0.002, .emptyBlock) : .returnAfter(0.002) })
    guard let encoder = try? HEVCEncoder(width: 16, height: 16, fps: 120, bitrate: 1_000_000,
                                         prioritizeSpeed: false, software: false) else { return false }
    let session = FakeVT.lastSession, delivered = Delivered()
    encoder.onEncoded = { data, _, _ in delivered.add(data) }
    encoder.encode(makeFrame(seq: 1), pts: CMTime(value: 1, timescale: 120))
    guard waitUntil({ delivered.calls == [1] }) else { _ = encoder.abandon(); return false }
    encoder.encode(makeFrame(seq: 2), pts: CMTime(value: 2, timescale: 120))
    _ = waitUntil { FakeVT.callsOf(session).count >= 5 }
    Thread.sleep(forTimeInterval: 0.12)
    let before = FakeVT.callsOf(session)
    let bounded = before.map(\.seq) == [1, 2, 2, 2, 2] && delivered.calls == [1]
    encoder.encode(makeFrame(seq: 3), pts: CMTime(value: 3, timescale: 120))
    let recovered = waitUntil { delivered.calls.contains(6) }
    let calls = FakeVT.callsOf(session)
    let pass = bounded && recovered && calls.map(\.seq) == [1, 2, 2, 2, 2, 3] && calls.last?.forced == true
    print("\(pass ? "PASS" : "FAIL") malformed keyframe retries stay bounded; next new image is forced: calls=\(calls.count)")
    _ = encoder.abandon()
    return pass
}

func checkSessionSwap() -> Bool {
    FakeVT.reset(plan: { _, _, _, _ in .returnAfter(0.002) })
    guard let encoder = try? HEVCEncoder(width: 16, height: 16, fps: 120, bitrate: 1_000_000,
                                         prioritizeSpeed: false, software: false) else { return false }
    let oldSession = FakeVT.lastSession, gate = DispatchSemaphore(value: 0), entered = DispatchSemaphore(value: 0)
    let lock = UnfairLock()
    var outputs: [Int] = []
    encoder.onEncoded = { data, _, _ in
        guard let origin = FakeVT.origin(data) else { return }
        if origin.session == oldSession { entered.signal(); gate.wait() }
        lock.run { outputs.append(origin.session) }
    }
    encoder.encode(makeFrame(seq: 1), pts: CMTime(value: 1, timescale: 120))
    guard entered.wait(timeout: .now() + 1) == .success else { gate.signal(); _ = encoder.abandon(); return false }
    let replacement = VTCompressionSession(software: false), newSession = replacement.index
    encoder.lock.withLock { encoder.replacement = replacement }
    encoder.encode(makeFrame(seq: 2), pts: CMTime(value: 2, timescale: 120))
    Thread.sleep(forTimeInterval: 0.04)
    let waited = FakeVT.callsOf(newSession).isEmpty
    gate.signal()
    let finished = waitUntil { lock.run { outputs.count == 2 } }
    let result = lock.run { outputs }
    let pass = waited && finished && result == [oldSession, newSession]
    print("\(pass ? "PASS" : "FAIL") replacement waits for old encoded output: waited=\(waited), order=\(result)")
    _ = encoder.abandon()
    return pass
}

func checkHardwareTimingScope() -> Bool {
    FakeVT.reset(plan: { _, call, _, _ in call == 2 ? .malformedAfter(0.002, .slowCopy) : .returnAfter(0.002) })
    guard let encoder = try? HEVCEncoder(width: 16, height: 16, fps: 120, bitrate: 1_000_000,
                                         prioritizeSpeed: false, software: false) else { return false }
    let lock = UnfairLock(), delivered = Delivered()
    var latencies: [Double] = []
    encoder.onEncoded = { data, _, _ in delivered.add(data) }
    encoder.onEncodeLatency = { value in lock.run { latencies.append(value) } }
    encoder.encode(makeFrame(seq: 1), pts: CMTime(value: 1, timescale: 120))
    guard waitUntil({ delivered.calls == [1] }) else { _ = encoder.abandon(); return false }
    let start = CACurrentMediaTime()
    encoder.encode(makeFrame(seq: 2), pts: CMTime(value: 2, timescale: 120))
    let finished = waitUntil { delivered.calls == [1, 2] }
    let wallMs = (CACurrentMediaTime() - start) * 1000
    let reported = lock.run { latencies.last ?? .infinity }
    let pass = finished && wallMs >= 75 && reported < 50
    print(String(format: "%@ delayed output copy stays outside VT timing: elapsed=%.1fms, reported=%.1fms", pass ? "PASS" : "FAIL", wallMs, reported))
    _ = encoder.abandon()
    return pass
}

let args = Set(CommandLine.arguments.dropFirst())
var checks = [checkTail("missing compressed block restores the last frame", kind: .missingBlock),
              checkTail("failed compressed-data copy restores the last frame", kind: .copyFailure)]
if !args.contains("--before-fix") {
    let missingFixture = VTCompressionSession.emptySample(withBlock: false)
    let emptyFixture = VTCompressionSession.emptySample(withBlock: true)
    let oversizedFixture = VTCompressionSession.oversizedSample()
    let fixturesValid = missingFixture != nil && missingFixture.flatMap { CMSampleBufferGetDataBuffer($0) } == nil
        && missingFixture.flatMap { CMSampleBufferGetFormatDescription($0) } != nil
        && emptyFixture.flatMap { CMSampleBufferGetDataBuffer($0) }.map { CMBlockBufferGetDataLength($0) } == 0
        && oversizedFixture.flatMap { CMSampleBufferGetDataBuffer($0) }.map { CMBlockBufferGetDataLength($0) } == StreamMessage.maxFramePayload + 1
    print("\(fixturesValid ? "PASS" : "FAIL") malformed samples contain the intended block and format conditions")
    checks.append(fixturesValid)
    checks.append(checkTail("empty compressed block restores the last frame", kind: .emptyBlock))
    checks.append(checkTail("oversized compressed block restores the last frame", kind: .oversizedBlock))
    checks.append(checkNewer())
    checks.append(checkBounded())
    checks.append(checkSessionSwap())
    checks.append(checkHardwareTimingScope())
}
exit(checks.allSatisfy { $0 } ? 0 : 1)
