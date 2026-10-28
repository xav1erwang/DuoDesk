// Copyright 2026 DUO你电脑 contributors. SPDX-License-Identifier: Apache-2.0
// Synthetic narrow frame through the production hardware encoder and decoder router.
import Foundation
import CoreMedia
import CoreVideo
import StreamProtocol

struct Failure: Error, CustomStringConvertible {
    let description: String
    init(_ text: String) { description = text }
}

final class Results: @unchecked Sendable {
    private let lock = NSLock()
    private var image: (Int, Int, Int)?
    private var packet: (Data, ParameterSets)?
    private var errors: [String] = []
    let done = DispatchSemaphore(value: 0)
    func encoded(_ data: Data, _ ps: ParameterSets) { lock.withLock { packet = (data, ps) } }
    func fail(_ message: String) { lock.withLock { errors.append(message) }; done.signal() }
    func sample(_ sample: CMSampleBuffer, _ permit: VideoOutputPermit) {
        guard permit.isValid, let pixel = CMSampleBufferGetImageBuffer(sample),
              CVPixelBufferGetPlaneCount(pixel) > 0,
              CVPixelBufferLockBaseAddress(pixel, .readOnly) == kCVReturnSuccess else { fail("sample buffer"); return }
        defer { CVPixelBufferUnlockBaseAddress(pixel, .readOnly) }
        let width = CVPixelBufferGetWidth(pixel), height = CVPixelBufferGetHeight(pixel)
        guard let p = CVPixelBufferGetBaseAddressOfPlane(pixel, 0)?.assumingMemoryBound(to: UInt8.self) else {
            fail("sample plane"); return
        }
        let luma = Int(p[(height / 2) * CVPixelBufferGetBytesPerRowOfPlane(pixel, 0) + width / 2])
        lock.withLock { image = (width, height, luma) }; done.signal()
    }
    var state: ((Int, Int, Int)?, (Data, ParameterSets)?, [String]) {
        lock.withLock { (image, packet, errors) }
    }
}

func run() throws {
    let width = 2008, height = 60
    let sourceID = UUID()
    let required = HardwareVideoRequirement.touchBar(id: sourceID, width: width, height: height)
    guard required.accepts(width: width, height: height), !required.accepts(width: width, height: 62),
          !HardwareVideoRequirement.touchBar(id: sourceID, width: 8192, height: 2048).accepts(width: 8192, height: 2048),
          !HardwareVideoRequirement.touchBar(id: sourceID, width: width, height: 59).accepts(width: width, height: 59),
          HardwareVideoRequirement.desktop(DuoDesktopResolution(width: 2007, height: 1427))
            .accepts(width: 2008, height: 1428),
          !HardwareVideoRequirement.desktop(DuoDesktopResolution(width: 2007, height: 1427))
            .accepts(width: 2008, height: 60) else { throw Failure("size acceptance") }
    var input: CVPixelBuffer?
    guard CVPixelBufferCreate(nil, width, height, kCVPixelFormatType_420YpCbCr8BiPlanarFullRange,
                              [kCVPixelBufferIOSurfacePropertiesKey: [:]] as CFDictionary, &input) == kCVReturnSuccess,
          let input, CVPixelBufferLockBaseAddress(input, []) == kCVReturnSuccess else { throw Failure("input") }
    for plane in 0..<2 {
        guard let base = CVPixelBufferGetBaseAddressOfPlane(input, plane) else { throw Failure("input plane") }
        memset(base, plane == 0 ? 96 : 128,
               CVPixelBufferGetBytesPerRowOfPlane(input, plane) * CVPixelBufferGetHeightOfPlane(input, plane))
    }
    CVPixelBufferUnlockBaseAddress(input, [])
    let results = Results()
    let router = HardwareDecoderRouter(onFormat: { _, _ in }, onSample: { sample, _, permit in
        results.sample(sample, permit)
    }, onFailure: { message, _ in results.fail(message) })
    _ = router.requireVideo(required)
    let encoder = try HEVCEncoder(width: width, height: height, fps: 30, bitrate: 3_000_000,
                                  prioritizeSpeed: true, software: false, quiet: true)
    defer { _ = router.clear(); _ = encoder.abandon() }
    encoder.onEncoded = { data, key, parameters in
        guard key, let parameters else { return }
        results.encoded(data, parameters)
        router.apply(parameters); router.enqueue(data, isKeyframe: true)
    }
    encoder.encode(input, pts: CMTime(value: 1, timescale: 30))
    guard results.done.wait(timeout: .now() + 5) == .success else { throw Failure("hardware pipeline timeout") }
    let (image, packet, errors) = results.state
    guard errors.isEmpty, let image, image.0 == width, image.1 == height, (75...115).contains(image.2),
          let packet else { throw Failure("hardware pipeline output: \(errors), \(String(describing: image))") }

    // A real production decoder must reject the same HEVC parameters before creating a
    // session when they don't match the surface that was advertised.
    let mismatch = HardwareHEVCDecoder(onFormat: { _, _ in }, onSample: { _, _, _ in }, onFailure: { _, _ in })
    _ = mismatch.requireVideo(.touchBar(id: sourceID, width: width, height: 62))
    mismatch.apply(packet.1)
    mismatch.queue.sync { }
    guard mismatch.session == nil else { throw Failure("mismatched dimensions opened a decoder") }
    _ = mismatch.clear()
    let generations = HardwareHEVCDecoder(onFormat: { _, _ in }, onSample: { _, _, _ in }, onFailure: { _, _ in })
    let old = generations.requireVideo(required)
    guard generations.requireVideo(required) == old else { throw Failure("unchanged surface restarted") }
    let next = generations.requireVideo(.touchBar(id: UUID(), width: width, height: height))
    guard next != old, !generations.canOutput(old) else { throw Failure("same-sized source retained old output") }
    _ = generations.clear()
    print("TOUCH BAR HARDWARE PIPELINE PASS: synthetic \(width)×\(height), production hardware encoder/router/decoder, size rejection and source fencing, luma=\(image.2)")
    print("SCOPE: one synthetic frame, no screen capture, no input, no network, no real Touch Bar or FPS acceptance")
}

do { try run() } catch { print("TOUCH BAR HARDWARE PIPELINE FAIL: \(error)"); exit(1) }
