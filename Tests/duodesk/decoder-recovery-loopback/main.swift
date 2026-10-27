// Copyright 2026 DUO你电脑 contributors. SPDX-License-Identifier: Apache-2.0
// Synthetic native-size frames exercise production hardware HEVC and QUIC loopback. A decoder
// output loss or an oversized incoming frame is injected for the last delta; no screenshot or input.
import Foundation
import CoreMedia
import CoreVideo
import StreamProtocol
import VideoToolbox

final class Results: @unchecked Sendable {
    private let lock = NSLock()
    private var encodedCount = 0, recoveryCount = 0
    private var luma: [UInt8] = [], errors: [String] = []
    private var channel: LoopbackVideo?
    func attach(_ channel: LoopbackVideo?) { lock.withLock { self.channel = channel } }
    func encoded() -> Int { lock.withLock { encodedCount += 1; return encodedCount } }
    func request() { let channel = lock.withLock { recoveryCount += 1; return self.channel }; channel?.requestKeyframe() }
    func fail(_ message: String) { lock.withLock { errors.append(message) } }
    func receive(_ sample: CMSampleBuffer) {
        guard let pixel = CMSampleBufferGetImageBuffer(sample), CVPixelBufferGetPlaneCount(pixel) >= 1,
              CVPixelBufferLockBaseAddress(pixel, .readOnly) == kCVReturnSuccess else { fail("decoded buffer unavailable"); return }
        defer { CVPixelBufferUnlockBaseAddress(pixel, .readOnly) }
        guard CVPixelBufferGetWidthOfPlane(pixel, 0) == 2008, CVPixelBufferGetHeightOfPlane(pixel, 0) == 1428,
              let base = CVPixelBufferGetBaseAddressOfPlane(pixel, 0)?.assumingMemoryBound(to: UInt8.self) else {
            fail("decoded dimensions"); return
        }
        let row = CVPixelBufferGetBytesPerRowOfPlane(pixel, 0)
        let value = base[714 * row + 1004]
        lock.withLock { luma.append(value) }
    }
    var snapshot: (encoded: Int, requests: Int, luma: [UInt8], errors: [String]) {
        lock.withLock { (encodedCount, recoveryCount, luma, errors) }
    }
}

enum Failure: Error { case timeout(String), invalid(String) }
func waitFor(_ label: String, _ condition: () -> Bool) async throws {
    let deadline = ContinuousClock.now + .seconds(5)
    while !condition() {
        guard ContinuousClock.now < deadline else { throw Failure.timeout(label) }
        try await Task.sleep(for: .milliseconds(10))
    }
}
func makeFrame(_ luminance: UInt8) throws -> CVPixelBuffer {
    var result: CVPixelBuffer?
    let attrs = [kCVPixelBufferIOSurfacePropertiesKey: [:]] as CFDictionary
    guard CVPixelBufferCreate(nil, 2008, 1428, kCVPixelFormatType_420YpCbCr8BiPlanarFullRange, attrs, &result) == kCVReturnSuccess,
          let result, CVPixelBufferLockBaseAddress(result, []) == kCVReturnSuccess else { throw Failure.invalid("pixel buffer") }
    defer { CVPixelBufferUnlockBaseAddress(result, []) }
    for plane in 0..<CVPixelBufferGetPlaneCount(result) {
        guard let base = CVPixelBufferGetBaseAddressOfPlane(result, plane) else { throw Failure.invalid("pixel plane") }
        memset(base, plane == 0 ? Int32(luminance) : 128,
               CVPixelBufferGetBytesPerRowOfPlane(result, plane) * CVPixelBufferGetHeightOfPlane(result, plane))
    }
    return result
}

@main
struct Check {
    static func run() async throws {
            let results = Results()
            let decoder = HardwareHEVCDecoder(onFormat: { _, _ in }, onSample: { sample, _, _ in results.receive(sample) },
                onFailure: { message, _ in results.fail(message) }, onNeedsKeyframe: { _ in results.request() })
            decoder.require(DuoDesktopResolution(width: 2007, height: 1427))
            let encoder = try HEVCEncoder(width: 2008, height: 1428, fps: 120, bitrate: 20_000_000,
                                          prioritizeSpeed: true, software: false, quiet: true)
            let loop = try await LoopbackVideo.connect(decoder: decoder, encoder: encoder)
            results.attach(loop)
            defer { results.attach(nil); loop.close(); decoder.clear(); decoder.queue.sync { }; _ = encoder.abandon() }
            try await waitFor("video reset") { loop.counters.resets > 0 }
            encoder.onEncoded = { bytes, keyframe, parameters in
                let count = results.encoded()
                if count == 2 {
                    guard !keyframe else { results.fail("last input unexpectedly encoded as a keyframe"); return }
                    if CommandLine.arguments.contains("--invalid-frame") {
                        // Inject at the decoder boundary; recovery still travels over real QUIC.
                        decoder.enqueue(Data(count: 16 * 1024 * 1024 + 1), isKeyframe: false)
                    } else {
                        let flight: HardwareHEVCDecoder.Flight? = decoder.lock.withLock {
                            guard let ticket = decoder.backlog.admit(bytes: 1, keyframe: false) else { return nil }
                            decoder.backlog.complete(ticket)
                            decoder.inFlight += 1
                            return HardwareHEVCDecoder.Flight(generation: decoder.generation, ticket: ticket,
                                sequence: decoder.latestOutputSequence + 1, started: ProcessInfo.processInfo.systemUptime,
                                outputPermit: decoder.outputPermit!)
                        }
                        guard let flight else { results.fail("could not inject decoder output loss"); return }
                        // Simulate loss of the output and do not forward the real delta.
                        decoder.decoded(nil, status: noErr, flags: [.frameDropped], flight: flight, pts: .invalid)
                    }
                } else {
                    loop.sendEncoded(bytes, keyframe: keyframe, parameters: parameters)
                }
            }
            encoder.encode(try makeFrame(48), pts: CMTime(value: 1, timescale: 120))
            try await waitFor("first hardware image") { !results.snapshot.luma.isEmpty || !results.snapshot.errors.isEmpty }
            guard let first = results.snapshot.luma.first, first < 100, results.snapshot.errors.isEmpty else {
                throw Failure.invalid("initial decoded image")
            }
            encoder.encode(try makeFrame(192), pts: CMTime(value: 2, timescale: 120))
            try await waitFor("recovered hardware image") { results.snapshot.luma.contains { $0 > 150 } || !results.snapshot.errors.isEmpty }
            try loop.check()
            let final = results.snapshot
            guard final.errors.isEmpty, final.requests >= 1, final.encoded >= 3,
                  final.luma.first == first, final.luma.last.map({ $0 > 150 }) == true,
                  loop.counters.keyframes >= 2 else { throw Failure.invalid("recovery outcome") }
            let injection = CommandLine.arguments.contains("--invalid-frame") ? "oversized decoder input" : "last-delta output loss"
            print("DECODER RECOVERY LOOPBACK PASS: hardware encoder/decoder, real QUIC on 127.0.0.1, injected \(injection), request and newer keyframe; luma=\(final.luma), requests=\(final.requests), encoded=\(final.encoded)")
            print("SCOPE: native-size synthetic buffers and simulated decoder fault; not desktop, FPS, external network or Duo acceptance")
    }
    static func main() async {
        do { try await run(); exit(0) }
        catch { print("DECODER RECOVERY LOOPBACK FAIL: \(error)"); exit(1) }
    }
}
