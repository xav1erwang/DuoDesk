// Copyright 2026 DUO你电脑 contributors. SPDX-License-Identifier: Apache-2.0
// Production hardware HEVC and QUIC over loopback; the network queue is deliberately held briefly.
import Foundation
import CoreMedia
import CoreVideo
import StreamProtocol

final class Results: @unchecked Sendable {
    private let lock = NSLock()
    private var encoded = 0, luminances: [UInt8] = [], failures: [String] = []
    func sent() { lock.withLock { encoded += 1 } }
    func fail(_ message: String) { lock.withLock { failures.append(message) } }
    func receive(_ sample: CMSampleBuffer) {
        guard let image = CMSampleBufferGetImageBuffer(sample), CVPixelBufferGetPlaneCount(image) >= 1,
              CVPixelBufferLockBaseAddress(image, .readOnly) == kCVReturnSuccess else { fail("invalid decoded image"); return }
        defer { CVPixelBufferUnlockBaseAddress(image, .readOnly) }
        guard CVPixelBufferGetWidthOfPlane(image, 0) == 2008, CVPixelBufferGetHeightOfPlane(image, 0) == 1428,
              let base = CVPixelBufferGetBaseAddressOfPlane(image, 0)?.assumingMemoryBound(to: UInt8.self) else {
            fail("wrong decoded dimensions"); return
        }
        let y = base[714 * CVPixelBufferGetBytesPerRowOfPlane(image, 0) + 1004]
        lock.withLock { luminances.append(y) }
    }
    var state: (encoded: Int, luma: [UInt8], failures: [String]) { lock.withLock { (encoded, luminances, failures) } }
}

enum Failure: Error { case timeout(String), invalid(String) }
func waitFor(_ label: String, _ condition: () -> Bool) async throws {
    let until = ContinuousClock.now + .seconds(5)
    while !condition() {
        guard ContinuousClock.now < until else { throw Failure.timeout(label) }
        try await Task.sleep(for: .milliseconds(10))
    }
}
func frame(_ luminance: UInt8) throws -> CVPixelBuffer {
    var image: CVPixelBuffer?
    let attrs = [kCVPixelBufferIOSurfacePropertiesKey: [:]] as CFDictionary
    guard CVPixelBufferCreate(nil, 2008, 1428, kCVPixelFormatType_420YpCbCr8BiPlanarFullRange, attrs, &image) == kCVReturnSuccess,
          let image, CVPixelBufferLockBaseAddress(image, []) == kCVReturnSuccess else { throw Failure.invalid("pixel buffer") }
    defer { CVPixelBufferUnlockBaseAddress(image, []) }
    for plane in 0..<2 {
        guard let base = CVPixelBufferGetBaseAddressOfPlane(image, plane) else { throw Failure.invalid("plane") }
        memset(base, plane == 0 ? Int32(luminance) : 128,
               CVPixelBufferGetBytesPerRowOfPlane(image, plane) * CVPixelBufferGetHeightOfPlane(image, plane))
    }
    return image
}

@main
struct Check {
    static func run() async throws {
        let results = Results()
        let decoder = HardwareHEVCDecoder(onFormat: { _, _ in }, onSample: { sample, _, _ in results.receive(sample) },
                                          onFailure: { message, _ in results.fail(message) })
        decoder.require(DuoDesktopResolution(width: 2007, height: 1427))
        let encoder = try HEVCEncoder(width: 2008, height: 1428, fps: 120, bitrate: 20_000_000,
                                      prioritizeSpeed: true, software: false, quiet: true)
        let loop = try await LoopbackVideo.connect(decoder: decoder, encoder: encoder)
        let gate = DispatchSemaphore(value: 0), entered = DispatchSemaphore(value: 0)
        var holding = false
        defer {
            if holding { gate.signal() }
            loop.close(); decoder.clear(); decoder.queue.sync { }; _ = encoder.abandon()
        }
        try await waitFor("video reset") { loop.counters.resets > 0 }
        encoder.onEncoded = { bytes, key, sets in
            loop.sendEncoded(bytes, keyframe: key, parameters: sets)
            results.sent()
        }
        if CommandLine.arguments.contains("--healthy") {
            let images = try [frame(48), frame(128), frame(192)]
            for index in 0..<240 {
                encoder.encode(images[index % images.count], pts: CMTime(value: Int64(index + 1), timescale: 120))
                try await Task.sleep(for: .nanoseconds(8_333_333))
            }
            // Let the final encoder callback and the loopback connection drain.
            try await Task.sleep(for: .milliseconds(500))
            try loop.check()
            let current = results.state
            let ingressDrops = Stats.shared.lock.withLock { Stats.shared.counts["net.ingressDrop", default: 0] }
            let received = loop.counters.frames
            guard current.failures.isEmpty, current.encoded >= 150, received == current.encoded,
                  current.luma.count >= current.encoded - 2, ingressDrops == 0 else {
                throw Failure.invalid("healthy feed encoded=\(current.encoded), received=\(received), decoded=\(current.luma.count), ingressDrops=\(ingressDrops), errors=\(current.failures)")
            }
            print("VIDEO INGRESS HEALTHY PASS: 240 paced synthetic inputs; encoded=\(current.encoded), received=\(received), decoded=\(current.luma.count), ingressDrops=\(ingressDrops)")
            print("SCOPE: native-size synthetic frames, hardware HEVC and loopback QUIC; no FPS or desktop acceptance")
            return
        }
        encoder.encode(try frame(48), pts: CMTime(value: 1, timescale: 120))
        try await waitFor("initial image") { !results.state.luma.isEmpty || !results.state.failures.isEmpty }
        guard results.state.failures.isEmpty, results.state.luma.first.map({ $0 < 100 }) == true else {
            throw Failure.invalid("initial image")
        }
        holding = true
        loop.server.queue.async { entered.signal(); gate.wait() }
        let enteredQueue = await withCheckedContinuation { continuation in
            DispatchQueue.global(qos: .userInitiated).async {
                continuation.resume(returning: entered.wait(timeout: .now() + 2) == .success)
            }
        }
        guard enteredQueue else { throw Failure.timeout("queue gate") }
        encoder.encode(try frame(128), pts: CMTime(value: 2, timescale: 120))
        try await waitFor("second encoded frame") { results.state.encoded >= 2 || !results.state.failures.isEmpty }
        let tail = CommandLine.arguments.contains("--tail")
        if tail {
            // Replace the waiting delta with a keyframe of the same picture. Then drop the
            // following delta so the queue must send the keyframe and request a newer one.
            encoder.requestKeyframe()
            try await waitFor("pending keyframe") { results.state.encoded >= 3 || !results.state.failures.isEmpty }
        }
        encoder.encode(try frame(192), pts: CMTime(value: 3, timescale: 120))
        let expectedEncoded = tail ? 4 : 3
        try await waitFor("last encoded frame") { results.state.encoded >= expectedEncoded || !results.state.failures.isEmpty }
        let pending = loop.server.videoIngressLock.withLock { loop.server.videoIngress.pending }
        guard let pending, tail ? (pending.isKeyframe && pending.lostAfter) : (!pending.isKeyframe && pending.lostBefore) else {
            throw Failure.invalid("delta loss was not detected")
        }
        gate.signal(); holding = false
        try await waitFor("recovered image") { results.state.luma.contains { $0 > 150 } || !results.state.failures.isEmpty }
        try loop.check()
        let final = results.state
        guard final.failures.isEmpty, final.luma.first.map({ $0 < 100 }) == true,
              final.luma.last.map({ $0 > 150 }) == true, final.encoded >= expectedEncoded + 1,
              loop.counters.keyframes >= (tail ? 3 : 2) else {
            throw Failure.invalid("recovered output")
        }
        print("VIDEO INGRESS LOOPBACK PASS: blocked network queue, \(tail ? "keyframe followed by dropped delta" : "discarded dependent delta"), requested keyframe and decoded latest image; luma=\(final.luma), encoded=\(final.encoded), keyframes=\(loop.counters.keyframes)")
        print("SCOPE: native-size synthetic frames, hardware HEVC and loopback QUIC; not full desktop, real Duo, WAN or FPS acceptance")
    }
    static func main() async {
        do { try await run(); exit(0) }
        catch { print("VIDEO INGRESS LOOPBACK FAIL: \(error)"); exit(1) }
    }
}
