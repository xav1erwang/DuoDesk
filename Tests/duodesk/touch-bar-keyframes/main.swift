// Copyright 2026 DUO你电脑 contributors. SPDX-License-Identifier: Apache-2.0
// A synthetic side stream: every hardware-encoded frame must decode independently.
import Foundation
import CoreMedia
import CoreVideo
import StreamProtocol

struct Failure: Error, CustomStringConvertible {
    let description: String
    init(_ text: String) { description = text }
}
final class Encoded: @unchecked Sendable {
    private let lock = NSLock()
    private var latest: (Data, Bool, ParameterSets?)?
    let available = DispatchSemaphore(value: 0)
    func put(_ data: Data, _ key: Bool, _ sets: ParameterSets?) {
        lock.withLock { latest = (data, key, sets) }; available.signal()
    }
    var value: (Data, Bool, ParameterSets?)? { lock.withLock { latest } }
}
final class Decoded: @unchecked Sendable {
    private let lock = NSLock()
    private var value: Int?
    private var failure: String?
    let available = DispatchSemaphore(value: 0)
    func put(_ sample: CMSampleBuffer, _ permit: VideoOutputPermit) {
        guard permit.isValid, let pixel = CMSampleBufferGetImageBuffer(sample),
              CVPixelBufferGetWidth(pixel) == 2008, CVPixelBufferGetHeight(pixel) == 60,
              CVPixelBufferGetPlaneCount(pixel) > 0, CVPixelBufferLockBaseAddress(pixel, .readOnly) == kCVReturnSuccess else {
            fail("invalid decoded image"); return
        }
        defer { CVPixelBufferUnlockBaseAddress(pixel, .readOnly) }
        guard let p = CVPixelBufferGetBaseAddressOfPlane(pixel, 0)?.assumingMemoryBound(to: UInt8.self) else {
            fail("missing luma plane"); return
        }
        let luma = Int(p[30 * CVPixelBufferGetBytesPerRowOfPlane(pixel, 0) + 1004])
        lock.withLock { value = luma }; available.signal()
    }
    func fail(_ message: String) { lock.withLock { failure = message }; available.signal() }
    var state: (Int?, String?) { lock.withLock { (value, failure) } }
}
func frame(_ luma: Int) throws -> CVPixelBuffer {
    var buffer: CVPixelBuffer?
    guard CVPixelBufferCreate(nil, 2008, 60, kCVPixelFormatType_420YpCbCr8BiPlanarFullRange,
        [kCVPixelBufferIOSurfacePropertiesKey: [:]] as CFDictionary, &buffer) == kCVReturnSuccess,
        let buffer, CVPixelBufferLockBaseAddress(buffer, []) == kCVReturnSuccess else { throw Failure("input buffer") }
    defer { CVPixelBufferUnlockBaseAddress(buffer, []) }
    for plane in 0..<2 {
        guard let p = CVPixelBufferGetBaseAddressOfPlane(buffer, plane) else { throw Failure("input plane") }
        memset(p, plane == 0 ? Int32(luma) : 128,
               CVPixelBufferGetBytesPerRowOfPlane(buffer, plane) * CVPixelBufferGetHeightOfPlane(buffer, plane))
    }
    return buffer
}
func run() throws {
    let id = UUID(), encoded = Encoded(), decoded = Decoded()
    let encoder = try HEVCEncoder(width: 2008, height: 60, fps: 30, bitrate: 3_000_000,
                                  prioritizeSpeed: true, software: false, quiet: true, independentFrames: true)
    let router = HardwareDecoderRouter(onFormat: { _, _ in }, onSample: { image, _, permit in decoded.put(image, permit) },
                                       onFailure: { message, _ in decoded.fail(message) })
    _ = router.requireVideo(.touchBar(id: id, width: 2008, height: 60))
    defer { _ = encoder.abandon(); _ = router.clear() }
    encoder.onEncoded = { bytes, key, parameters in encoded.put(bytes, key, parameters) }
    var decodedValues: [Int] = []
    for (index, brightness) in [48, 96, 144, 192].enumerated() {
        encoder.encode(try frame(brightness), pts: CMTime(value: Int64(index + 1), timescale: 30))
        guard encoded.available.wait(timeout: .now() + 5) == .success,
              let (bytes, key, parameters) = encoded.value, key, let parameters,
              let packet = TouchBarKeyframe(surfaceID: id, parameters: parameters, accessUnit: bytes),
              let received = TouchBarKeyframe(encoded: packet.encoded), received.surfaceID == id else {
            throw Failure("frame \(index + 1) was not an independently packaged keyframe")
        }
        // A slow client drops the second packet. The following keyframe must decode without it.
        if index == 1 { continue }
        router.apply(received.parameters); router.enqueue(received.accessUnit, isKeyframe: true)
        guard decoded.available.wait(timeout: .now() + 5) == .success else { throw Failure("decode timeout") }
        let (luma, error) = decoded.state
        guard error == nil, let luma, abs(luma - brightness) <= 20 else {
            throw Failure("decode after drop: luma=\(String(describing: luma)) error=\(String(describing: error))")
        }
        decodedValues.append(luma)
    }
    print("TOUCH BAR KEYFRAMES PASS: four synthetic hardware HEVC keyframes, dropped second packet, decoded luma \(decodedValues)")
    print("SCOPE: local synthetic frames only; no capture, network, touch input, real Touch Bar or FPS acceptance")
}
do { try run() } catch { print("TOUCH BAR KEYFRAMES FAIL: \(error)"); exit(1) }
