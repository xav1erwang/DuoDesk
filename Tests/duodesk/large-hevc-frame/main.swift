// Copyright 2026 DUO你电脑 contributors. SPDX-License-Identifier: Apache-2.0
// Real hardware codec compatibility for one intentionally enlarged HEVC access unit.
// The added HEVC filler NAL carries no image data. Optional network uses local QUIC only.
import CoreMedia
import CoreVideo
import Foundation
import StreamProtocol

final class Results: @unchecked Sendable {
    private let lock = NSLock()
    private var outputs: [UInt8] = [], errors: [String] = []
    private var compressedSize = 0, requests = 0
    func receive(_ sample: CMSampleBuffer) {
        guard let image = CMSampleBufferGetImageBuffer(sample), CVPixelBufferGetPlaneCount(image) >= 1,
              CVPixelBufferGetWidthOfPlane(image, 0) == 2008, CVPixelBufferGetHeightOfPlane(image, 0) == 1428,
              CVPixelBufferLockBaseAddress(image, .readOnly) == kCVReturnSuccess else { fail("decoded buffer"); return }
        defer { CVPixelBufferUnlockBaseAddress(image, .readOnly) }
        guard let base = CVPixelBufferGetBaseAddressOfPlane(image, 0)?.assumingMemoryBound(to: UInt8.self) else {
            fail("decoded pixels"); return
        }
        let value = base[714 * CVPixelBufferGetBytesPerRowOfPlane(image, 0) + 1004]
        lock.withLock { outputs.append(value) }
    }
    func sent(_ count: Int) { lock.withLock { compressedSize = count } }
    func request() { lock.withLock { requests += 1 } }
    func fail(_ text: String) { lock.withLock { errors.append(text) } }
    var state: (outputs: [UInt8], errors: [String], bytes: Int, requests: Int) {
        lock.withLock { (outputs, errors, compressedSize, requests) }
    }
}

enum Failure: Error { case unavailable(String), timeout(String) }
func wait(_ label: String, _ condition: () -> Bool) async throws {
    let deadline = ContinuousClock.now + .seconds(3)
    while !condition() {
        guard ContinuousClock.now < deadline else { throw Failure.timeout(label) }
        try await Task.sleep(for: .milliseconds(10))
    }
}
func image(_ value: UInt8) throws -> CVPixelBuffer {
    var image: CVPixelBuffer?
    let attrs = [kCVPixelBufferIOSurfacePropertiesKey: [:]] as CFDictionary
    guard CVPixelBufferCreate(nil, 2008, 1428, kCVPixelFormatType_420YpCbCr8BiPlanarFullRange, attrs, &image) == kCVReturnSuccess,
          let image, CVPixelBufferLockBaseAddress(image, []) == kCVReturnSuccess else { throw Failure.unavailable("input buffer") }
    defer { CVPixelBufferUnlockBaseAddress(image, []) }
    for plane in 0..<2 {
        guard let base = CVPixelBufferGetBaseAddressOfPlane(image, plane) else { throw Failure.unavailable("input plane") }
        memset(base, plane == 0 ? Int32(value) : 128,
               CVPixelBufferGetBytesPerRowOfPlane(image, plane) * CVPixelBufferGetHeightOfPlane(image, plane))
    }
    return image
}

func withFiller(_ encoded: Data, target: Int) throws -> Data {
    let nalCount = target - encoded.count - 4
    guard nalCount >= 3, nalCount <= Int(UInt32.max) else { throw Failure.unavailable("filler size") }
    var result = encoded
    let length = UInt32(nalCount)
    result.append(contentsOf: [UInt8((length >> 24) & 0xff), UInt8((length >> 16) & 0xff),
                               UInt8((length >> 8) & 0xff), UInt8(length & 0xff), 0x4c, 0x01])
    result.append(Data(repeating: 0xff, count: nalCount - 3))
    result.append(0x80)
    return result
}

@main
struct Check {
    static func main() async {
        let results = Results()
        let decoder = HardwareHEVCDecoder(onFormat: { _, _ in }, onSample: { sample, _, _ in results.receive(sample) },
            onFailure: { message, _ in results.fail(message) }, onNeedsKeyframe: { _ in results.request() })
        decoder.require(DuoDesktopResolution(width: 2007, height: 1427))
        if CommandLine.arguments.contains("--wide-control") {
            // Explicit test-only control: lets the same real decoder receive the padded unit.
            decoder.lock.withLock { decoder.backlog = VideoDecodeBacklog(byteLimit: StreamMessage.maxFramePayload) }
        }
        do {
            let encoder = try HEVCEncoder(width: 2008, height: 1428, fps: 120, bitrate: 20_000_000,
                                          prioritizeSpeed: true, software: false, quiet: true)
            let loop = CommandLine.arguments.contains("--quic") ? try await LoopbackVideo.connect(decoder: decoder, encoder: encoder) : nil
            defer { loop?.close(); _ = encoder.abandon(); _ = decoder.clear(); decoder.queue.sync { } }
            if let loop { try await wait("video reset") { loop.counters.resets > 0 } }
            encoder.onEncoded = { bytes, key, parameters in
                if let parameters {
                    do {
                        let padded = try withFiller(bytes, target: 9 * 1024 * 1024)
                        results.sent(padded.count)
                        if let loop { loop.sendEncoded(padded, keyframe: key, parameters: parameters) }
                        else { decoder.apply(parameters); decoder.enqueue(padded, isKeyframe: key) }
                    } catch { results.fail("filler construction: \(error)") }
                } else if let loop { loop.sendEncoded(bytes, keyframe: key, parameters: nil) }
                else { decoder.enqueue(bytes, isKeyframe: key) }
            }
            encoder.encode(try image(48), pts: CMTime(value: 1, timescale: 120))
            try await wait("first image") { !results.state.outputs.isEmpty || !results.state.errors.isEmpty }
            guard results.state.errors.isEmpty, results.state.outputs.first.map({ $0 < 100 }) == true else {
                throw Failure.unavailable("first image")
            }
            encoder.encode(try image(192), pts: CMTime(value: 2, timescale: 120))
            try await wait("updated image") { results.state.outputs.contains { $0 > 150 } || !results.state.errors.isEmpty }
            let state = results.state
            guard state.errors.isEmpty, state.outputs.last.map({ $0 > 150 }) == true,
                  state.bytes == 9 * 1024 * 1024 else { throw Failure.unavailable("updated image") }
            if let loop { try loop.check(); guard loop.counters.frames >= 2 else { throw Failure.unavailable("QUIC frames") } }
            decoder.queue.sync { }
            let accounting = decoder.lock.withLock { (decoder.inFlight, decoder.inFlightBytes, decoder.backlog.bytes) }
            guard accounting.0 == 0, accounting.1 == 0, accounting.2 == 0 else { throw Failure.unavailable("compressed reservations") }
            print("LARGE HEVC FRAME PASS: native 2008×1428 hardware encode/decode; paddedBytes=\(state.bytes), luma=\(state.outputs), requests=\(state.requests), outstanding=\(accounting), testWideControl=\(CommandLine.arguments.contains("--wide-control")), localQUIC=\(loop != nil)")
            print("SCOPE: synthetic pixels and filler NAL; no desktop, public network, Duo or FPS acceptance")
        } catch {
            print("LARGE HEVC FRAME FAIL: \(error); state=\(results.state)")
            exit(1)
        }
    }
}
