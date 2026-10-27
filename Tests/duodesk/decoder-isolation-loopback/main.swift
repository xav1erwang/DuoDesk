// Copyright 2026 DUO你电脑 contributors. SPDX-License-Identifier: Apache-2.0
// A held old decoder queue is artificial. Video, requests and local QUIC use production paths.
import CoreMedia
import CoreVideo
import Foundation
import StreamProtocol

extension HardwareDecoderRouter: LoopbackVideoDecoder { }

final class Results: @unchecked Sendable {
    private let lock = NSLock()
    private var luminances: [UInt8] = [], failures: [String] = [], requests = 0
    private var encoded = 0, channel: LoopbackVideo?
    func attach(_ value: LoopbackVideo?) { lock.withLock { channel = value } }
    func request() { let target = lock.withLock { requests += 1; return channel }; target?.requestKeyframe() }
    func fail(_ value: String) { lock.withLock { failures.append(value) } }
    func encodedFrame() { lock.withLock { encoded += 1 } }
    func sample(_ sample: CMSampleBuffer) {
        guard let pixel = CMSampleBufferGetImageBuffer(sample), CVPixelBufferGetPlaneCount(pixel) >= 1,
              CVPixelBufferGetWidthOfPlane(pixel, 0) == 2008, CVPixelBufferGetHeightOfPlane(pixel, 0) == 1428,
              CVPixelBufferLockBaseAddress(pixel, .readOnly) == kCVReturnSuccess else { fail("decoded buffer"); return }
        defer { CVPixelBufferUnlockBaseAddress(pixel, .readOnly) }
        guard let base = CVPixelBufferGetBaseAddressOfPlane(pixel, 0)?.assumingMemoryBound(to: UInt8.self) else {
            fail("decoded luma"); return
        }
        let value = base[714 * CVPixelBufferGetBytesPerRowOfPlane(pixel, 0) + 1004]
        lock.withLock { luminances.append(value) }
    }
    var state: (luma: [UInt8], failures: [String], requests: Int, encoded: Int) {
        lock.withLock { (luminances, failures, requests, encoded) }
    }
}
final class Flag: @unchecked Sendable {
    private let lock = NSLock(); private var set = false
    func mark() { lock.withLock { set = true } }
    var value: Bool { lock.withLock { set } }
}
enum Failure: Error { case timeout(String), invalid(String) }
func wait(_ label: String, timeout: Duration = .seconds(6), _ condition: () -> Bool) async throws {
    let end = ContinuousClock.now + timeout
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
        let router = HardwareDecoderRouter(onFormat: { _, _ in }, onSample: { sample, _ in results.sample(sample) },
            onFailure: { message, _ in results.fail(message) }, onNeedsKeyframe: { _ in results.request() })
        router.require(DuoDesktopResolution(width: 2007, height: 1427))
        let encoder = try HEVCEncoder(width: 2008, height: 1428, fps: 120, bitrate: 20_000_000,
                                      prioritizeSpeed: true, software: false, quiet: true)
        let loop = try await LoopbackVideo.connect(decoder: router, encoder: encoder)
        results.attach(loop)
        defer { results.attach(nil); loop.close(); _ = router.clear(); _ = encoder.abandon() }
        try await wait("initial video reset") { loop.counters.resets > 0 }
        encoder.onEncoded = { bytes, keyframe, parameters in
            results.encodedFrame(); loop.sendEncoded(bytes, keyframe: keyframe, parameters: parameters)
        }
        encoder.encode(try frame(48), pts: CMTime(value: 1, timescale: 120))
        try await wait("initial decoded image") { !results.state.luma.isEmpty || !results.state.failures.isEmpty }
        guard results.state.failures.isEmpty, results.state.luma.first.map({ $0 < 100 }) == true else {
            throw Failure.invalid("initial image")
        }
        try await wait("initial decoder retirement") { router.lock.withLock { router.retiring.isEmpty } }
        let old = router.lock.withLock { router.decoder! }
        let gate = DispatchSemaphore(value: 0), entered = Flag()
        defer { gate.signal() }
        old.queue.async { entered.mark(); gate.wait() }
        try await wait("old queue blocked") { entered.value }
        encoder.encode(try frame(192), pts: CMTime(value: 2, timescale: 120))
        try await wait("new frame received over QUIC") { loop.counters.frames >= 2 || !results.state.failures.isEmpty }
        guard results.state.failures.isEmpty else { throw Failure.invalid("frame before stall") }
        let now = ProcessInfo.processInfo.systemUptime
        old.lock.withLock { old.inFlight = 1; old.inFlightBytes = 1; old.callbackProgressAt = now - 4; old.lastWatchdogCheck = now }
        old.checkWatchdog()
        try await wait("updated image after automatic recovery") {
            results.state.luma.contains { $0 > 150 } || !results.state.failures.isEmpty
        }
        try loop.check()
        let state = results.state
        guard state.failures.isEmpty, state.luma.first.map({ $0 < 100 }) == true,
              state.luma.last.map({ $0 > 150 }) == true, state.requests >= 1, state.encoded >= 3,
              loop.counters.keyframes >= 2, router.lock.withLock({ router.retiring.count == 1 && router.decoder !== old }) else {
            throw Failure.invalid("recovery outcome: \(state)")
        }
        print("DECODER ISOLATION LOOPBACK PASS: native hardware HEVC, QUIC on 127.0.0.1, old queue blocked, new keyframe and updated image; luma=\(state.luma), requests=\(state.requests), encoded=\(state.encoded)")
        print("SCOPE: synthetic frames, injected queue stall, temporary in-memory TLS; not an actual VT failure, desktop, public network or Duo")
    }
    static func main() async {
        do { try await run() }
        catch { print("DECODER ISOLATION LOOPBACK FAIL: \(error)"); exit(1) }
    }
}
