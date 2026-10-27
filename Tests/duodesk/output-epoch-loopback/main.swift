// Copyright 2026 DUO你电脑 contributors. SPDX-License-Identifier: Apache-2.0
// Real local QUIC and hardware HEVC; the held callback and input gap are injected deliberately.
import CoreMedia
import CoreVideo
import Foundation
import StreamProtocol

extension HardwareDecoderRouter: LoopbackVideoDecoder { }

final class Gate: @unchecked Sendable {
    private let lock = NSLock(); private var calls = 0, held = false
    let release = DispatchSemaphore(value: 0)
    func pauseSecond() {
        let pause = lock.withLock { calls += 1; if calls == 2 { held = true; return true }; return false }
        if pause { release.wait() }
    }
    var isHeld: Bool { lock.withLock { held } }
}
enum EpochFault {
    static let gate = Gate()
    static let before = CommandLine.arguments.contains("before-router")
    static func beforeRouter() { if before { gate.pauseSecond() } }
    static func afterRouter() { if !before { gate.pauseSecond() } }
}
final class Results: @unchecked Sendable {
    private let lock = NSLock()
    private var samples: [(UInt8, UInt64)] = [], failures: [String] = []
    private var requests = 0, encoded = 0, denied = 0, channel: LoopbackVideo?
    func attach(_ value: LoopbackVideo?) { lock.withLock { channel = value } }
    func request() { let target = lock.withLock { requests += 1; return channel }; target?.requestKeyframe() }
    func fail(_ value: String) { lock.withLock { failures.append(value) } }
    func sent() { lock.withLock { encoded += 1 } }
    func reject() { lock.withLock { denied += 1 } }
    func sample(_ sample: CMSampleBuffer, token: UInt64) {
        guard let pixel = CMSampleBufferGetImageBuffer(sample), CVPixelBufferGetPlaneCount(pixel) >= 1,
              CVPixelBufferGetWidthOfPlane(pixel, 0) == 2008, CVPixelBufferGetHeightOfPlane(pixel, 0) == 1428,
              CVPixelBufferLockBaseAddress(pixel, .readOnly) == kCVReturnSuccess else { fail("decoded buffer"); return }
        defer { CVPixelBufferUnlockBaseAddress(pixel, .readOnly) }
        guard let base = CVPixelBufferGetBaseAddressOfPlane(pixel, 0)?.assumingMemoryBound(to: UInt8.self) else {
            fail("decoded luma"); return
        }
        let value = base[714 * CVPixelBufferGetBytesPerRowOfPlane(pixel, 0) + 1004]
        lock.withLock { samples.append((value, token)) }
    }
    var state: (samples: [(UInt8, UInt64)], failures: [String], requests: Int, encoded: Int, denied: Int) {
        lock.withLock { (samples, failures, requests, encoded, denied) }
    }
}
enum Failure: Error { case timeout(String), invalid(String) }
func wait(_ label: String, _ condition: () -> Bool) async throws {
    let end = ContinuousClock.now + .seconds(6)
    while !condition() {
        guard ContinuousClock.now < end else { throw Failure.timeout(label) }
        try await Task.sleep(for: .milliseconds(10))
    }
}
func frame(_ luminance: UInt8) throws -> CVPixelBuffer {
    var result: CVPixelBuffer?
    guard CVPixelBufferCreate(nil, 2008, 1428, kCVPixelFormatType_420YpCbCr8BiPlanarFullRange,
                              [kCVPixelBufferIOSurfacePropertiesKey: [:]] as CFDictionary, &result) == kCVReturnSuccess,
          let result, CVPixelBufferLockBaseAddress(result, []) == kCVReturnSuccess else { throw Failure.invalid("input") }
    defer { CVPixelBufferUnlockBaseAddress(result, []) }
    for plane in 0..<2 {
        guard let base = CVPixelBufferGetBaseAddressOfPlane(result, plane) else { throw Failure.invalid("plane") }
        memset(base, plane == 0 ? Int32(luminance) : 128,
               CVPixelBufferGetBytesPerRowOfPlane(result, plane) * CVPixelBufferGetHeightOfPlane(result, plane))
    }
    return result
}

@main
struct Check {
    static func run() async throws {
        let results = Results()
        let router = HardwareDecoderRouter(onFormat: { _, _ in }, onSample: { sample, token, permit in
            EpochFault.afterRouter()
            if permit.admit({ }) { results.sample(sample, token: token) } else { results.reject() }
        }, onFailure: { message, _ in results.fail(message) }, onNeedsKeyframe: { _ in results.request() })
        router.require(DuoDesktopResolution(width: 2007, height: 1427))
        let encoder = try HEVCEncoder(width: 2008, height: 1428, fps: 120, bitrate: 20_000_000,
                                      prioritizeSpeed: true, software: false, quiet: true)
        let loop = try await LoopbackVideo.connect(decoder: router, encoder: encoder)
        results.attach(loop)
        defer { EpochFault.gate.release.signal(); results.attach(nil); loop.close(); _ = router.clear(); _ = encoder.abandon() }
        try await wait("initial video reset") { loop.counters.resets > 0 }
        encoder.onEncoded = { bytes, keyframe, parameters in
            results.sent(); loop.sendEncoded(bytes, keyframe: keyframe, parameters: parameters)
        }
        encoder.encode(try frame(48), pts: CMTime(value: 1, timescale: 120))
        try await wait("initial decoded image") { !results.state.samples.isEmpty || !results.state.failures.isEmpty }
        guard results.state.failures.isEmpty, let initial = results.state.samples.first, initial.0 < 100 else {
            throw Failure.invalid("initial image")
        }
        let decoder = router.lock.withLock { router.decoder! }
        guard let oldPermit = decoder.admissionPermit(for: initial.1) else { throw Failure.invalid("initial permit") }
        let oldEpoch = decoder.lock.withLock { decoder.backlog.epoch }
        encoder.encode(try frame(192), pts: CMTime(value: 2, timescale: 120))
        try await wait("second callback held") { EpochFault.gate.isHeld || !results.state.failures.isEmpty }
        guard results.state.failures.isEmpty else { throw Failure.invalid("callback") }
        router.enqueue(Data(), isKeyframe: false)
        guard !oldPermit.isValid, decoder.lock.withLock({ decoder.backlog.epoch != oldEpoch }) else {
            throw Failure.invalid("gap did not revoke old permit")
        }
        EpochFault.gate.release.signal()
        try await wait("denied old callback and recovery keyframe") {
            let state = results.state
            return (state.denied >= 1 && state.samples.contains { $0.0 > 150 }) || !state.failures.isEmpty
        }
        try loop.check()
        let state = results.state
        guard state.failures.isEmpty, state.denied == 1, state.samples.count >= 2,
              state.samples.last.map({ $0.0 > 150 && $0.1 == initial.1 }) == true,
              state.requests >= 1, state.encoded >= 3, loop.counters.keyframes >= 2 else {
            throw Failure.invalid("recovery outcome: \(state)")
        }
        let position = EpochFault.before ? "before router" : "after router"
        print("OUTPUT EPOCH LOOPBACK PASS: native hardware HEVC, QUIC on 127.0.0.1, held \(position), stale callback denied, same-generation recovery; luma=\(state.samples.map(\.0)), requests=\(state.requests), encoded=\(state.encoded)")
        print("SCOPE: synthetic frames and injected gap, temporary in-memory TLS; not desktop, FPS, public network or Duo")
    }
    static func main() async {
        do { try await run() }
        catch { print("OUTPUT EPOCH LOOPBACK FAIL: \(error)"); exit(1) }
    }
}
