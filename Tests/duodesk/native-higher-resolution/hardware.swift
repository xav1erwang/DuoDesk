// Copyright 2026 DUO你电脑 contributors. SPDX-License-Identifier: Apache-2.0
// One larger synthetic frame through the production hardware encoder and decoder router.
import Foundation
import CoreMedia
import CoreVideo
import StreamProtocol

struct Failure: Error { let text: String }
final class Result: @unchecked Sendable {
    private let lock = NSLock()
    private var image: (Int, Int, Int)?
    private var error: String?
    let done = DispatchSemaphore(value: 0)
    func fail(_ reason: String) { lock.withLock { error = reason }; done.signal() }
    func sample(_ sample: CMSampleBuffer, _ permit: VideoOutputPermit) {
        guard permit.isValid, let pixel = CMSampleBufferGetImageBuffer(sample),
              CVPixelBufferLockBaseAddress(pixel, .readOnly) == kCVReturnSuccess else { fail("sample"); return }
        defer { CVPixelBufferUnlockBaseAddress(pixel, .readOnly) }
        let w = CVPixelBufferGetWidth(pixel), h = CVPixelBufferGetHeight(pixel)
        guard CVPixelBufferGetPlaneCount(pixel) > 0,
              let base = CVPixelBufferGetBaseAddressOfPlane(pixel, 0)?.assumingMemoryBound(to: UInt8.self) else {
            fail("luma plane"); return
        }
        let luma = Int(base[(h / 2) * CVPixelBufferGetBytesPerRowOfPlane(pixel, 0) + w / 2])
        lock.withLock { image = (w, h, luma) }; done.signal()
    }
    var state: ((Int, Int, Int)?, String?) { lock.withLock { (image, error) } }
}

@main struct Check {
    static func main() {
        do { try run() } catch { print("HIGHER HARDWARE PIPELINE FAIL: \(error)"); exit(1) }
    }
    static func run() throws {
        let native = DuoDesktopResolution(width: 2007, height: 1427)
        let width = 4014, height = 2854
        guard native.accepts(width: width, height: height) else { throw Failure(text: "resolution gate") }
        var buffer: CVPixelBuffer?
        guard CVPixelBufferCreate(nil, width, height, kCVPixelFormatType_420YpCbCr8BiPlanarFullRange,
                                  [kCVPixelBufferIOSurfacePropertiesKey: [:]] as CFDictionary, &buffer) == kCVReturnSuccess,
              let buffer, CVPixelBufferLockBaseAddress(buffer, []) == kCVReturnSuccess else { throw Failure(text: "buffer") }
        for plane in 0..<CVPixelBufferGetPlaneCount(buffer) {
            guard let base = CVPixelBufferGetBaseAddressOfPlane(buffer, plane) else { throw Failure(text: "plane") }
            memset(base, plane == 0 ? 96 : 128,
                   CVPixelBufferGetBytesPerRowOfPlane(buffer, plane) * CVPixelBufferGetHeightOfPlane(buffer, plane))
        }
        CVPixelBufferUnlockBaseAddress(buffer, [])
        let result = Result()
        let decoder = HardwareDecoderRouter(onFormat: { _, _ in }, onSample: { sample, _, permit in result.sample(sample, permit) },
                                            onFailure: { message, _ in result.fail(message) })
        _ = decoder.require(native)
        let encoder = try HEVCEncoder(width: width, height: height, fps: 30, bitrate: 16_000_000,
                                      prioritizeSpeed: true, software: false, quiet: true)
        defer { _ = decoder.clear(); _ = encoder.abandon() }
        encoder.onEncoded = { bytes, keyframe, parameters in
            guard keyframe, let parameters else { return }
            decoder.apply(parameters); decoder.enqueue(bytes, isKeyframe: true)
        }
        encoder.encode(buffer, pts: CMTime(value: 1, timescale: 30))
        guard result.done.wait(timeout: .now() + 10) == .success else { throw Failure(text: "timeout") }
        let (image, error) = result.state
        guard error == nil, let image, image.0 == width, image.1 == height, (75...115).contains(image.2) else {
            throw Failure(text: "wrong output \(String(describing: error)) \(String(describing: image))")
        }
        print("HIGHER HARDWARE PIPELINE PASS: synthetic \(width)×\(height), native aspect, hardware HEVC encode/decode, luma=\(image.2)")
        print("SCOPE: one synthetic frame, no physical display mode, desktop capture, real Duo, network or FPS acceptance")
    }
}
