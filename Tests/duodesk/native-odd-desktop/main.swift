// Copyright 2026 DUO你电脑 contributors. SPDX-License-Identifier: Apache-2.0
// Synthetic odd BGRA pixels, production padding/input/protocol and one hardware codec frame.
// No actual screen, display configuration, system input, Duo, public network or FPS claim.
import CoreGraphics
import CoreMedia
import CoreVideo
import Foundation
import StreamProtocol

private struct Failure: Error { let text: String }
private func check(_ condition: @autoclosure () -> Bool, _ label: String) throws {
    guard condition() else { throw Failure(text: label) }
    print("PASS: \(label)")
}

private func buffer(_ canvas: DuoDesktopCanvas, uniform: Bool = false) throws -> CVPixelBuffer {
    var made: CVPixelBuffer?
    let attrs: [CFString: Any] = [kCVPixelBufferIOSurfacePropertiesKey: [:], kCVPixelBufferMetalCompatibilityKey: true]
    guard CVPixelBufferCreate(nil, canvas.width, canvas.height, kCVPixelFormatType_32BGRA,
                              attrs as CFDictionary, &made) == kCVReturnSuccess,
          let made, CVPixelBufferLockBaseAddress(made, []) == kCVReturnSuccess else { throw Failure(text: "create source") }
    defer { CVPixelBufferUnlockBaseAddress(made, []) }
    guard let base = CVPixelBufferGetBaseAddress(made)?.assumingMemoryBound(to: UInt8.self) else { throw Failure(text: "source plane") }
    let stride = CVPixelBufferGetBytesPerRow(made)
    guard stride >= canvas.width * 4 else { throw Failure(text: "source stride") }
    for y in 0..<canvas.height { for x in 0..<canvas.width { for channel in 0..<4 {
        base[y * stride + x * 4 + channel] = channel == 3 ? 255 : uniform ? 96 : UInt8((x * 3 + y * 7 + channel * 53) & 255)
    } } }
    CVBufferSetAttachment(made, kCVImageBufferCGColorSpaceKey, CGColorSpace(name: CGColorSpace.sRGB)!, .shouldPropagate)
    let aperture: [CFString: Any] = [kCVImageBufferCleanApertureWidthKey: canvas.width,
                                      kCVImageBufferCleanApertureHeightKey: canvas.height,
                                      kCVImageBufferCleanApertureHorizontalOffsetKey: 0,
                                      kCVImageBufferCleanApertureVerticalOffsetKey: 0]
    CVBufferSetAttachment(made, kCVImageBufferCleanApertureKey, aperture as CFDictionary, .shouldPropagate)
    CVBufferSetAttachment(made, kCVImageBufferPreferredCleanApertureKey, aperture as CFDictionary, .shouldPropagate)
    return made
}

private func verifyPixels(_ source: CVPixelBuffer, _ output: CVPixelBuffer, _ canvas: DuoDesktopCanvas) throws {
    guard CVPixelBufferLockBaseAddress(source, .readOnly) == kCVReturnSuccess else { throw Failure(text: "source lock") }
    defer { CVPixelBufferUnlockBaseAddress(source, .readOnly) }
    guard CVPixelBufferLockBaseAddress(output, .readOnly) == kCVReturnSuccess else { throw Failure(text: "output lock") }
    defer { CVPixelBufferUnlockBaseAddress(output, .readOnly) }
    guard CVPixelBufferGetWidth(output) == canvas.encodedWidth, CVPixelBufferGetHeight(output) == canvas.encodedHeight else { throw Failure(text: "padded size") }
    guard let a = CVPixelBufferGetBaseAddress(source)?.assumingMemoryBound(to: UInt8.self),
          let b = CVPixelBufferGetBaseAddress(output)?.assumingMemoryBound(to: UInt8.self) else { throw Failure(text: "output pixels") }
    let asize = CVPixelBufferGetBytesPerRow(source), bsize = CVPixelBufferGetBytesPerRow(output)
    for y in 0..<canvas.height { for byte in 0..<(canvas.width * 4) {
        guard a[y * asize + byte] == b[y * bsize + byte] else { throw Failure(text: "content changed at byte \(byte), row \(y)") }
    } }
    if canvas.width != canvas.encodedWidth {
        for y in 0..<canvas.height { for channel in 0..<4 where b[y * bsize + canvas.width * 4 + channel] != b[y * bsize + (canvas.width - 1) * 4 + channel] {
            throw Failure(text: "right edge")
        } }
    }
    if canvas.height != canvas.encodedHeight {
        for byte in 0..<(canvas.encodedWidth * 4) where b[canvas.height * bsize + byte] != b[(canvas.height - 1) * bsize + byte] {
            throw Failure(text: "bottom edge")
        }
    }
    let color = CVBufferCopyAttachment(output, kCVImageBufferCGColorSpaceKey, nil)
    guard let color, CFEqual(color, CGColorSpace(name: CGColorSpace.sRGB)!) else { throw Failure(text: "color metadata") }
    guard CVBufferCopyAttachment(output, kCVImageBufferCleanApertureKey, nil) == nil,
          CVBufferCopyAttachment(output, kCVImageBufferPreferredCleanApertureKey, nil) == nil,
          CVBufferCopyAttachment(source, kCVImageBufferCleanApertureKey, nil) != nil else { throw Failure(text: "padded aperture") }
}

private final class CodecResult: @unchecked Sendable {
    private let lock = NSLock()
    private var image: (Int, Int, Int, Int)?
    private var failure: String?
    let done = DispatchSemaphore(value: 0)
    func fail(_ text: String) { lock.withLock { failure = text }; done.signal() }
    func sample(_ sample: CMSampleBuffer, _ permit: VideoOutputPermit) {
        guard permit.isValid, let pixel = CMSampleBufferGetImageBuffer(sample),
              CVPixelBufferLockBaseAddress(pixel, .readOnly) == kCVReturnSuccess else { fail("decode sample"); return }
        defer { CVPixelBufferUnlockBaseAddress(pixel, .readOnly) }
        guard let base = CVPixelBufferGetBaseAddressOfPlane(pixel, 0)?.assumingMemoryBound(to: UInt8.self) else { fail("decode luma"); return }
        let w = CVPixelBufferGetWidth(pixel), h = CVPixelBufferGetHeight(pixel), stride = CVPixelBufferGetBytesPerRowOfPlane(pixel, 0)
        lock.withLock { image = (w, h, Int(base[(h / 2) * stride + w / 2]), Int(base[(h - 1) * stride + w - 1])) }
        done.signal()
    }
    var state: ((Int, Int, Int, Int)?, String?) { lock.withLock { (image, failure) } }
}

@main private struct Check {
    static func main() {
        do { try run(); print("NATIVE ODD DESKTOP PASS") }
        catch { print("NATIVE ODD DESKTOP FAIL: \(error)"); exit(1) }
    }
    static func run() throws {
        let target = DuoDesktopResolution(width: 2007, height: 1427)
        let canvas = DuoDesktopCanvas(width: 2007, height: 1427)
        let large = DuoDesktopCanvas(width: 6021, height: 4281)
        try check(target.acceptsDisplayMode(width: canvas.width, height: canvas.height) && canvas.requiresPadding
                  && canvas.encodedWidth == 2008 && canvas.encodedHeight == 1428, "native odd source and upward alignment")
        try check(target.acceptsDisplayMode(width: large.width, height: large.height)
                  && !target.accepts(width: large.encodedWidth, height: large.encodedHeight)
                  && target.acceptsPaddedEncoded(width: large.encodedWidth, height: large.encodedHeight), "larger odd source preserves its exact aspect")
        let gate = HardwareVideoRequirement.desktop(target)
        try check(gate.accepts(width: large.encodedWidth, height: large.encodedHeight, canvas: large)
                  && !gate.accepts(width: large.encodedWidth, height: large.encodedHeight)
                  && !gate.accepts(width: large.encodedWidth, height: large.encodedHeight, canvas: canvas), "decoder requires matching content metadata")
        let sets = [Data([1, 2]), Data([3]), Data([4, 5])]
        let legacy = ParameterSets(nalUnitHeaderLength: 4, sets: sets).encoded()
        let wire = ParameterSets(nalUnitHeaderLength: 4, sets: sets, nativeDesktopCanvas: large).encoded()
        let decoded = ParameterSets(encoded: wire)
        try check(wire.starts(with: legacy) && decoded?.nativeDesktopCanvas == large
                  && ParameterSets(encoded: legacy)?.nativeDesktopCanvas == nil
                  && ParameterSets(encoded: Data(wire.dropLast())) == nil, "parameter extension round-trip and legacy prefix")

        for size in [(323, 241), (324, 241), (323, 242)] {
            let shape = DuoDesktopCanvas(width: size.0, height: size.1), input = try buffer(shape)
            guard let padder = NativeDesktopPadder(canvas: shape), let padded = padder.pad(input) else { throw Failure(text: "pad") }
            try verifyPixels(input, padded, shape)
            guard CVPixelBufferLockBaseAddress(input, []) == kCVReturnSuccess else { throw Failure(text: "source reuse lock") }
            guard let inputBase = CVPixelBufferGetBaseAddress(input)?.assumingMemoryBound(to: UInt8.self) else {
                CVPixelBufferUnlockBaseAddress(input, []); throw Failure(text: "source reuse")
            }
            let previous = inputBase[0]; inputBase[0] ^= 255
            CVPixelBufferUnlockBaseAddress(input, [])
            guard CVPixelBufferLockBaseAddress(padded, .readOnly) == kCVReturnSuccess else { throw Failure(text: "output reuse lock") }
            guard let outputBase = CVPixelBufferGetBaseAddress(padded)?.assumingMemoryBound(to: UInt8.self) else {
                CVPixelBufferUnlockBaseAddress(padded, .readOnly); throw Failure(text: "output reuse")
            }
            let independent = outputBase[0] == previous
            CVPixelBufferUnlockBaseAddress(padded, .readOnly)
            try check(independent, "padded output survives source buffer reuse")
            print("PASS: \(shape.width)×\(shape.height) BGRA pixels and odd edges copied without scaling")
        }
        let small = DuoDesktopCanvas(width: 323, height: 241), source = try buffer(small)
        guard let limited = NativeDesktopPadder(canvas: small) else { throw Failure(text: "pool") }
        var retained: [CVPixelBuffer] = []
        for _ in 0..<6 { guard let item = limited.pad(source) else { throw Failure(text: "pool before limit") }; retained.append(item) }
        try check(limited.pad(source) == nil, "padded buffer pool is bounded")
        retained.removeAll()
        try check(limited.pad(source) != nil, "padded buffer pool recovers after release")

        let halfX = 0.5 * Double(canvas.width) / Double(canvas.encodedWidth)
        let halfY = 0.5 * Double(canvas.height) / Double(canvas.encodedHeight)
        guard case .pointer(.leftDown, let x, let y)? = NativeDesktopInput.map(.pointer(.leftDown, x: halfX, y: halfY), canvas: canvas) else { throw Failure(text: "input mapping") }
        try check(abs(x - 0.5) < 1e-12 && abs(y - 0.5) < 1e-12, "touch maps encoded content to source")
        guard case .pointer(.move, let edgeX, let edgeY)? = NativeDesktopInput.map(.pointer(.move, x: 1, y: 1), canvas: canvas) else { throw Failure(text: "edge input") }
        try check(edgeX == 1 && edgeY == 1, "padding maps to real desktop edge")
        guard case .scroll(let scrollX, let scrollY, let dx, let dy)? = NativeDesktopInput.map(
            .scroll(x: halfX, y: halfY, dx: 0.1, dy: -0.2), canvas: canvas) else { throw Failure(text: "scroll mapping") }
        try check(abs(scrollX - 0.5) < 1e-12 && abs(scrollY - 0.5) < 1e-12
                  && abs(dx - 0.1 * Double(canvas.encodedWidth) / Double(canvas.width)) < 1e-12
                  && abs(dy + 0.2 * Double(canvas.encodedHeight) / Double(canvas.height)) < 1e-12,
                  "scroll position and delta use source coordinates")
        try check(NativeDesktopInput.map(.scroll(x: 0.5, y: 0.5, dx: .greatestFiniteMagnitude, dy: 0), canvas: canvas) == nil,
                  "overflowing mapped scroll is rejected")
        let watch = PointerWatch(synthetic: false, readLocation: { CGPoint(x: 1003.5, y: 713.5) }, clock: { 1 })
        watch.setGeometry(.paddedRect(CGRect(x: 0, y: 0, width: 2007, height: 1427), canvas), fps: 60)
        guard let pointer = watch.sample(devices: []) else { throw Failure(text: "pointer reading") }
        try check(pointer.inside && abs(pointer.x - MacPointer.rounded(halfX)) < 0.00011
                  && abs(pointer.y - MacPointer.rounded(halfY)) < 0.00011, "Mac pointer maps back to padded video")

        let original = try buffer(canvas, uniform: true)
        guard let padder = NativeDesktopPadder(canvas: canvas), let padded = padder.pad(original) else { throw Failure(text: "native pad") }
        try verifyPixels(original, padded, canvas)
        let result = CodecResult()
        let decoder = HardwareDecoderRouter(onFormat: { _, _ in }, onSample: { sample, _, permit in result.sample(sample, permit) },
                                            onFailure: { message, _ in result.fail(message) })
        _ = decoder.require(target)
        let encoder = try HEVCEncoder(width: canvas.encodedWidth, height: canvas.encodedHeight, fps: 30, bitrate: 16_000_000,
                                      prioritizeSpeed: true, software: false, quiet: true)
        defer { _ = decoder.clear(); _ = encoder.abandon() }
        encoder.onEncoded = { bytes, keyframe, parameters in
            guard keyframe, var parameters else { return }
            parameters.nativeDesktopCanvas = canvas
            guard let received = ParameterSets(encoded: parameters.encoded()) else { result.fail("wire"); return }
            decoder.apply(received); decoder.enqueue(bytes, isKeyframe: true)
        }
        encoder.encode(padded, pts: CMTime(value: 1, timescale: 30))
        guard result.done.wait(timeout: .now() + 10) == .success else { throw Failure(text: "hardware timeout") }
        let (image, error) = result.state
        guard error == nil, let image, image.0 == 2008, image.1 == 1428,
              (75...115).contains(image.2), (75...115).contains(image.3) else { throw Failure(text: "hardware output \(String(describing: error)) \(String(describing: image))") }
        print("PASS: 2007×1427 synthetic frame padded to 2008×1428, metadata round-trip, hardware HEVC encode and decode")
        print("SCOPE: synthetic pixels, no real screen or Duo, physical mode switch, network or FPS acceptance")
    }
}
