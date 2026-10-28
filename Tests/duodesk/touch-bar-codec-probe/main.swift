// Copyright 2026 DUO你电脑 contributors. SPDX-License-Identifier: Apache-2.0
// One synthetic Touch Bar-shaped frame through hardware HEVC; no screen or system input.
import Foundation
import CoreMedia
import CoreVideo
import VideoToolbox
import StreamProtocol

struct Failure: Error, CustomStringConvertible {
    let description: String
    init(_ value: String) { description = value }
}

final class Encoded: @unchecked Sendable {
    private let lock = NSLock()
    private var packet: (Data, Bool, ParameterSets?)?
    let done = DispatchSemaphore(value: 0)
    func put(_ data: Data, _ key: Bool, _ sets: ParameterSets?) {
        lock.withLock { packet = (data, key, sets) }
        done.signal()
    }
    var value: (Data, Bool, ParameterSets?)? { lock.withLock { packet } }
}

final class Decoded: @unchecked Sendable {
    private let lock = NSLock()
    private var result: (OSStatus, Int, Int, Int)?
    let done = DispatchSemaphore(value: 0)
    func put(_ status: OSStatus, _ image: CVImageBuffer?) {
        var width = 0, height = 0, luma = -1
        if let image {
            width = CVPixelBufferGetWidth(image); height = CVPixelBufferGetHeight(image)
            if CVPixelBufferGetPlaneCount(image) > 0,
               CVPixelBufferLockBaseAddress(image, .readOnly) == kCVReturnSuccess {
                if let p = CVPixelBufferGetBaseAddressOfPlane(image, 0)?.assumingMemoryBound(to: UInt8.self) {
                    luma = Int(p[(height / 2) * CVPixelBufferGetBytesPerRowOfPlane(image, 0) + width / 2])
                }
                CVPixelBufferUnlockBaseAddress(image, .readOnly)
            }
        }
        lock.withLock { result = (status, width, height, luma) }
        done.signal()
    }
    var value: (OSStatus, Int, Int, Int)? { lock.withLock { result } }
}

func run() throws {
    let width = 2008, height = 60
    var input: CVPixelBuffer?
    guard CVPixelBufferCreate(nil, width, height, kCVPixelFormatType_420YpCbCr8BiPlanarFullRange,
                              [kCVPixelBufferIOSurfacePropertiesKey: [:]] as CFDictionary, &input) == kCVReturnSuccess,
          let input, CVPixelBufferLockBaseAddress(input, []) == kCVReturnSuccess else { throw Failure("input allocation") }
    for plane in 0..<2 {
        guard let base = CVPixelBufferGetBaseAddressOfPlane(input, plane) else { throw Failure("input plane") }
        memset(base, plane == 0 ? 96 : 128,
               CVPixelBufferGetBytesPerRowOfPlane(input, plane) * CVPixelBufferGetHeightOfPlane(input, plane))
    }
    CVPixelBufferUnlockBaseAddress(input, [])

    // The production encoder requires hardware and checks VideoToolbox's actual hardware property.
    let encoder = try HEVCEncoder(width: width, height: height, fps: 30, bitrate: 3_000_000,
                                  prioritizeSpeed: true, software: false, quiet: true)
    defer { _ = encoder.abandon() }
    let encoded = Encoded()
    encoder.onEncoded = { data, key, sets in encoded.put(data, key, sets) }
    encoder.encode(input, pts: CMTime(value: 1, timescale: 30))
    guard encoded.done.wait(timeout: .now() + 5) == .success,
          let (data, key, sets) = encoded.value, key, let sets, sets.sets.count == 3 else {
        throw Failure("hardware encoder did not produce a usable keyframe")
    }
    let buffers = sets.sets.map { data -> UnsafeMutablePointer<UInt8> in
        let p = UnsafeMutablePointer<UInt8>.allocate(capacity: data.count)
        data.copyBytes(to: p, count: data.count); return p
    }
    defer { buffers.forEach { $0.deallocate() } }
    let pointers = buffers.map { UnsafePointer($0) }, lengths = sets.sets.map(\.count)
    var format: CMVideoFormatDescription?
    let description = CMVideoFormatDescriptionCreateFromHEVCParameterSets(allocator: nil, parameterSetCount: 3,
        parameterSetPointers: pointers, parameterSetSizes: lengths, nalUnitHeaderLength: 4,
        extensions: nil, formatDescriptionOut: &format)
    guard description == noErr, let format else { throw Failure("format: \(description)") }
    let dimensions = CMVideoFormatDescriptionGetDimensions(format)
    guard Int(dimensions.width) == width, Int(dimensions.height) == height else { throw Failure("encoded dimensions") }
    var decoder: VTDecompressionSession?
    let spec = [kVTVideoDecoderSpecification_RequireHardwareAcceleratedVideoDecoder: true] as CFDictionary
    let attributes: [CFString: Any] = [kCVPixelBufferPixelFormatTypeKey: kCVPixelFormatType_420YpCbCr8BiPlanarFullRange,
        kCVPixelBufferIOSurfacePropertiesKey: [:]]
    let created = VTDecompressionSessionCreate(allocator: nil, formatDescription: format, decoderSpecification: spec,
        imageBufferAttributes: attributes as CFDictionary, outputCallback: nil, decompressionSessionOut: &decoder)
    guard created == noErr, let decoder else { throw Failure("hardware decoder creation: \(created)") }
    defer { VTDecompressionSessionInvalidate(decoder) }
    var actual: Unmanaged<CFTypeRef>?
    let queried = VTSessionCopyProperty(decoder, key: kVTDecompressionPropertyKey_UsingHardwareAcceleratedVideoDecoder,
                                       allocator: nil, valueOut: &actual)
    guard queried == noErr, (actual?.takeRetainedValue() as? NSNumber)?.boolValue == true else {
        throw Failure("hardware decoder not verified: \(queried)")
    }
    var block: CMBlockBuffer?
    guard CMBlockBufferCreateWithMemoryBlock(allocator: nil, memoryBlock: nil, blockLength: data.count,
        blockAllocator: nil, customBlockSource: nil, offsetToData: 0, dataLength: data.count,
        flags: 0, blockBufferOut: &block) == noErr, let block,
        CMBlockBufferAssureBlockMemory(block) == noErr else { throw Failure("compressed buffer") }
    let copied = data.withUnsafeBytes { CMBlockBufferReplaceDataBytes(with: $0.baseAddress!, blockBuffer: block,
                                                                       offsetIntoDestination: 0, dataLength: data.count) }
    guard copied == noErr else { throw Failure("compressed copy: \(copied)") }
    var timing = CMSampleTimingInfo(duration: CMTime(value: 1, timescale: 30),
                                     presentationTimeStamp: CMTime(value: 1, timescale: 30), decodeTimeStamp: .invalid)
    var length = data.count, sample: CMSampleBuffer?
    let ready = CMSampleBufferCreateReady(allocator: nil, dataBuffer: block, formatDescription: format,
        sampleCount: 1, sampleTimingEntryCount: 1, sampleTimingArray: &timing, sampleSizeEntryCount: 1,
        sampleSizeArray: &length, sampleBufferOut: &sample)
    guard ready == noErr, let sample else { throw Failure("sample: \(ready)") }
    let decoded = Decoded()
    var flags: VTDecodeInfoFlags = []
    let submitted = VTDecompressionSessionDecodeFrame(decoder, sampleBuffer: sample,
        flags: [._EnableAsynchronousDecompression], infoFlagsOut: &flags) { status, _, image, _, _ in
            decoded.put(status, image)
        }
    guard submitted == noErr, decoded.done.wait(timeout: .now() + 5) == .success,
          let (status, outputWidth, outputHeight, luma) = decoded.value,
          status == noErr, outputWidth == width, outputHeight == height, (75...115).contains(luma) else {
        throw Failure("hardware decode output: submitted=\(submitted), result=\(String(describing: decoded.value))")
    }
    print("TOUCH BAR CODEC PROBE PASS: synthetic \(width)×\(height), production hardware encoder and verified hardware decoder; luma=\(luma)")
    print("SCOPE: one synthetic image, no screen capture, no input, no network, no physical Touch Bar, no FPS acceptance")
}

do { try run() } catch { print("TOUCH BAR CODEC PROBE FAIL: \(error)"); exit(1) }
