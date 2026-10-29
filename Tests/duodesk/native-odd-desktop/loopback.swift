// Copyright 2026 DUO你电脑 contributors. SPDX-License-Identifier: Apache-2.0
// One synthetic odd frame through the production padder, hardware codec and localhost QUIC.
import CoreMedia
import CoreVideo
import Foundation
import StreamProtocol

private enum Failure: Error { case invalid(String), timeout(String) }
private final class Results: @unchecked Sendable {
    private let lock = NSLock()
    private var received: (Int, Int, Int)?
    private var failure: String?
    func fail(_ text: String) { lock.withLock { failure = text } }
    func image(_ sample: CMSampleBuffer) {
        guard let pixels = CMSampleBufferGetImageBuffer(sample),
              CVPixelBufferLockBaseAddress(pixels, .readOnly) == kCVReturnSuccess else { fail("decode sample"); return }
        defer { CVPixelBufferUnlockBaseAddress(pixels, .readOnly) }
        guard let base = CVPixelBufferGetBaseAddressOfPlane(pixels, 0)?.assumingMemoryBound(to: UInt8.self) else { fail("decode plane"); return }
        let w = CVPixelBufferGetWidth(pixels), h = CVPixelBufferGetHeight(pixels), row = CVPixelBufferGetBytesPerRowOfPlane(pixels, 0)
        lock.withLock { received = (w, h, Int(base[(h / 2) * row + w / 2])) }
    }
    var state: ((Int, Int, Int)?, String?) { lock.withLock { (received, failure) } }
}

private func waitFor(_ label: String, _ done: () -> Bool) async throws {
    let deadline = ContinuousClock.now + .seconds(8)
    while !done() {
        guard ContinuousClock.now < deadline else { throw Failure.timeout(label) }
        try await Task.sleep(for: .milliseconds(20))
    }
}

@main private struct Check {
    static func main() async {
        do { try await run(); print("NATIVE ODD QUIC PASS") }
        catch { print("NATIVE ODD QUIC FAIL: \(error)"); exit(1) }
    }
    static func run() async throws {
        let target = DuoDesktopResolution(width: 2007, height: 1427)
        let canvas = DuoDesktopCanvas(width: 2510, height: 1785)
        guard target.acceptsDisplayMode(width: canvas.width, height: canvas.height),
              !target.accepts(width: canvas.encodedWidth, height: canvas.encodedHeight),
              target.acceptsPaddedEncoded(width: canvas.encodedWidth, height: canvas.encodedHeight) else {
            throw Failure.invalid("fixture must require canvas metadata")
        }
        var source: CVPixelBuffer?
        let attrs: [CFString: Any] = [kCVPixelBufferIOSurfacePropertiesKey: [:], kCVPixelBufferMetalCompatibilityKey: true]
        guard CVPixelBufferCreate(nil, canvas.width, canvas.height, kCVPixelFormatType_32BGRA, attrs as CFDictionary, &source) == kCVReturnSuccess,
              let source, CVPixelBufferLockBaseAddress(source, []) == kCVReturnSuccess else { throw Failure.invalid("source") }
        guard let base = CVPixelBufferGetBaseAddress(source)?.assumingMemoryBound(to: UInt8.self) else {
            CVPixelBufferUnlockBaseAddress(source, []); throw Failure.invalid("pixels")
        }
        let stride = CVPixelBufferGetBytesPerRow(source)
        for y in 0..<canvas.height { for x in 0..<canvas.width {
            let p = y * stride + x * 4
            base[p] = 96; base[p + 1] = 96; base[p + 2] = 96; base[p + 3] = 255
        } }
        CVPixelBufferUnlockBaseAddress(source, [])
        guard let padder = NativeDesktopPadder(canvas: canvas), let padded = padder.pad(source) else { throw Failure.invalid("padding") }
        let results = Results()
        let decoder = HardwareHEVCDecoder(onFormat: { _, _ in }, onSample: { sample, _, _ in results.image(sample) },
                                          onFailure: { message, _ in results.fail(message) })
        _ = decoder.require(target)
        let encoder = try HEVCEncoder(width: canvas.encodedWidth, height: canvas.encodedHeight, fps: 30, bitrate: 16_000_000,
                                      prioritizeSpeed: true, software: false, quiet: true)
        let loop = try await LoopbackVideo.connect(decoder: decoder, encoder: encoder)
        defer { loop.close(); _ = decoder.clear(); _ = encoder.abandon() }
        try await waitFor("reset") { loop.counters.resets > 0 }
        encoder.onEncoded = { bytes, key, parameters in
            guard key, var parameters else { return }
            parameters.nativeDesktopCanvas = canvas
            loop.sendEncoded(bytes, keyframe: true, parameters: parameters)
        }
        encoder.encode(padded, pts: CMTime(value: 1, timescale: 30))
        try await waitFor("decoded frame") { results.state.0 != nil || results.state.1 != nil }
        try loop.check()
        let (image, error) = results.state
        guard error == nil, let image, image.0 == canvas.encodedWidth, image.1 == canvas.encodedHeight,
              (70...120).contains(image.2), loop.counters.parameters > 0, loop.counters.frames > 0 else {
            throw Failure.invalid("result \(String(describing: image)), \(String(describing: error))")
        }
        print("PASS: 2510×1785 source, 2510×1786 canvas, mandatory metadata, hardware HEVC and encrypted local QUIC")
        print("SCOPE: one synthetic frame; no actual desktop, real Duo, public WAN or FPS acceptance")
    }
}
