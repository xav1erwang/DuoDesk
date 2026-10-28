// Copyright 2026 DUO你电脑 contributors. SPDX-License-Identifier: Apache-2.0
// Synthetic IOSurface ownership and narrow hardware codec check; no screen or input access.
import CoreMedia
import CoreVideo
import Foundation
import IOSurface
import StreamProtocol

struct Failure: Error, CustomStringConvertible {
    let description: String
    init(_ text: String) { description = text }
}
final class Result: @unchecked Sendable {
    private let lock = NSLock()
    private var image: (Int, Int, Int)?
    private var failure: String?
    let done = DispatchSemaphore(value: 0)
    func sample(_ sample: CMSampleBuffer, _ permit: VideoOutputPermit) {
        guard permit.isValid, let pixel = CMSampleBufferGetImageBuffer(sample), CVPixelBufferGetPlaneCount(pixel) > 0,
              CVPixelBufferLockBaseAddress(pixel, .readOnly) == kCVReturnSuccess else { fail("sample"); return }
        defer { CVPixelBufferUnlockBaseAddress(pixel, .readOnly) }
        let width = CVPixelBufferGetWidth(pixel), height = CVPixelBufferGetHeight(pixel)
        guard let p = CVPixelBufferGetBaseAddressOfPlane(pixel, 0)?.assumingMemoryBound(to: UInt8.self) else { fail("plane"); return }
        let value = Int(p[(height / 2) * CVPixelBufferGetBytesPerRowOfPlane(pixel, 0) + width / 2])
        lock.withLock { image = (width, height, value) }; done.signal()
    }
    func fail(_ value: String) { lock.withLock { failure = value }; done.signal() }
    var state: ((Int, Int, Int)?, String?) { lock.withLock { (image, failure) } }
}

func surface(width: Int, height: Int, format: OSType) throws -> IOSurfaceRef {
    let properties: [CFString: Any] = [kIOSurfaceWidth: width, kIOSurfaceHeight: height,
        kIOSurfaceBytesPerElement: 4, kIOSurfacePixelFormat: format]
    guard let surface = IOSurfaceCreate(properties as CFDictionary) else { throw Failure("create source") }
    return surface
}
func run() throws {
    let width = 2007, height = 59, source = try surface(width: width, height: height, format: kCVPixelFormatType_32BGRA)
    guard IOSurfaceLock(source, [], nil) == kIOReturnSuccess else { throw Failure("lock source") }
    let base = IOSurfaceGetBaseAddress(source)
    let row = IOSurfaceGetBytesPerRow(source)
    for y in 0..<height {
        let p = base.advanced(by: y * row).assumingMemoryBound(to: UInt8.self)
        for x in 0..<width { p[x * 4] = 96; p[x * 4 + 1] = 96; p[x * 4 + 2] = 96; p[x * 4 + 3] = 255 }
    }
    IOSurfaceUnlock(source, [], nil)
    guard let copied = TouchBarSurfaceCopier.copy(source, pts: CMTime(value: 1, timescale: 30)),
          copied.contentWidth == width, copied.contentHeight == height,
          CVPixelBufferGetWidth(copied.pixels) == 2008, CVPixelBufferGetHeight(copied.pixels) == 60 else {
        throw Failure("copy and even geometry")
    }
    // Reuse the producer's buffer immediately after the callback-equivalent copy.
    guard IOSurfaceLock(source, [], nil) == kIOReturnSuccess else { throw Failure("reuse source") }
    let reused = IOSurfaceGetBaseAddress(source)
    memset(reused, 240, IOSurfaceGetAllocSize(source))
    IOSurfaceUnlock(source, [], nil)
    guard CVPixelBufferLockBaseAddress(copied.pixels, .readOnly) == kCVReturnSuccess,
          let p = CVPixelBufferGetBaseAddress(copied.pixels)?.assumingMemoryBound(to: UInt8.self) else { throw Failure("lock copy") }
    let targetRow = CVPixelBufferGetBytesPerRow(copied.pixels)
    let independent = p[0] == 96 && p[(height - 1) * targetRow + (width - 1) * 4] == 96
        && p[width * 4] == 0 && p[height * targetRow] == 0
    CVPixelBufferUnlockBaseAddress(copied.pixels, .readOnly)
    guard independent else { throw Failure("buffer aliasing or padding") }
    let wrongFormat = try surface(width: 100, height: 20, format: kCVPixelFormatType_32ARGB)
    guard TouchBarSurfaceCopier.copy(wrongFormat, pts: .zero) == nil else { throw Failure("unsupported pixel format") }

    let result = Result(), router = HardwareDecoderRouter(onFormat: { _, _ in }, onSample: { sample, _, permit in
        result.sample(sample, permit)
    }, onFailure: { message, _ in result.fail(message) })
    _ = router.requireVideo(.touchBar(id: UUID(), width: 2008, height: 60))
    let encoder = try HEVCEncoder(width: 2008, height: 60, fps: 30, bitrate: 3_000_000,
                                  prioritizeSpeed: true, software: false, quiet: true, independentFrames: true)
    defer { _ = router.clear(); _ = encoder.abandon() }
    encoder.onEncoded = { data, key, parameters in
        guard key, let parameters else { return }
        router.apply(parameters); router.enqueue(data, isKeyframe: true)
    }
    encoder.encode(copied.pixels, pts: copied.pts)
    guard result.done.wait(timeout: .now() + 5) == .success else { throw Failure("hardware codec timeout") }
    let (image, error) = result.state
    guard error == nil, let image, image.0 == 2008, image.1 == 60, (70...120).contains(image.2) else {
        throw Failure("hardware result: \(String(describing: error)), \(String(describing: image))")
    }
    print("TOUCH BAR SURFACE COPY PASS: synthetic 2007×59 BGRA, independent 2008×60 buffer, padding and unsupported format; hardware HEVC decoded luma \(image.2)")
    print("SCOPE: in-memory synthetic IOSurface only; no system capture, input, physical Touch Bar, Duo, WAN or FPS acceptance")
}
do { try run() } catch { print("TOUCH BAR SURFACE COPY FAIL: \(error)"); exit(1) }
