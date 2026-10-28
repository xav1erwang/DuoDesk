// Copyright 2026 DUO你电脑 contributors. SPDX-License-Identifier: Apache-2.0
import CoreMedia
import CoreVideo
import Foundation
import IOSurface
import StreamProtocol

/// Copies one borrowed BGRA IOSurface synchronously while the producer's callback owns it.
/// VideoToolbox receives an independent, even-sized buffer, so the producer can immediately
/// reuse the original. Other source formats fail closed until a real backend validates them.
enum TouchBarSurfaceCopier {
    static func copy(_ source: IOSurfaceRef, pts: CMTime) -> TouchBarCapturedFrame? {
        let width = IOSurfaceGetWidth(source), height = IOSurfaceGetHeight(source)
        guard width > 0, height > 0, width <= 8191, height <= 2047,
              IOSurfaceGetPixelFormat(source) == kCVPixelFormatType_32BGRA,
              IOSurfaceGetBytesPerElement(source) == 4 else { return nil }
        let encodedWidth = (width + 1) & ~1, encodedHeight = (height + 1) & ~1
        let geometry = TouchBarSurface(id: UUID(), pixelWidth: width, pixelHeight: height,
                                       encodedWidth: encodedWidth, encodedHeight: encodedHeight, acceptsInput: false)
        guard geometry.isValid else { return nil }
        let sourceStride = IOSurfaceGetBytesPerRow(source)
        let contentBytes = width * 4
        guard sourceStride >= contentBytes,
              sourceStride <= Int.max / height,
              IOSurfaceGetAllocSize(source) >= (height - 1) * sourceStride + contentBytes else { return nil }
        var output: CVPixelBuffer?
        let attributes: [CFString: Any] = [kCVPixelBufferIOSurfacePropertiesKey: [:],
                                           kCVPixelBufferMetalCompatibilityKey: true]
        guard CVPixelBufferCreate(nil, encodedWidth, encodedHeight, kCVPixelFormatType_32BGRA,
                                  attributes as CFDictionary, &output) == kCVReturnSuccess,
              let output, IOSurfaceLock(source, .readOnly, nil) == kIOReturnSuccess else { return nil }
        defer { IOSurfaceUnlock(source, .readOnly, nil) }
        guard CVPixelBufferLockBaseAddress(output, []) == kCVReturnSuccess else { return nil }
        defer { CVPixelBufferUnlockBaseAddress(output, []) }
        let from = IOSurfaceGetBaseAddress(source)
        guard let to = CVPixelBufferGetBaseAddress(output) else { return nil }
        let targetStride = CVPixelBufferGetBytesPerRow(output)
        guard targetStride >= encodedWidth * 4, targetStride <= Int.max / encodedHeight else { return nil }
        memset(to, 0, targetStride * encodedHeight)
        for row in 0..<height {
            memcpy(to.advanced(by: row * targetStride), from.advanced(by: row * sourceStride), contentBytes)
        }
        return TouchBarCapturedFrame(pixels: output, contentWidth: width, contentHeight: height, pts: pts)
    }
}
