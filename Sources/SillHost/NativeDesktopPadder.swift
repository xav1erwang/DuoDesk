// Copyright 2026 DUO你电脑 contributors. SPDX-License-Identifier: Apache-2.0
import CoreVideo
import Foundation
import StreamProtocol

/// Copies an odd BGRA desktop into an even IOSurface-backed encoder buffer without resampling.
/// The source remains held during this synchronous copy. Repeating its last row/column avoids
/// introducing a contrasting edge; every source pixel and its color attachments are retained.
/// BGRA is intentional: odd ScreenCaptureKit 420f surfaces can report rounded-down chroma planes,
/// which cannot represent the last source column/row's color without guessing.
/// The pool is bounded: if VideoToolbox retains too many buffers, the caller ends the stream
/// rather than silently losing a final static desktop update or growing memory without limit.
final class NativeDesktopPadder {
    private let canvas: DuoDesktopCanvas
    private let pool: CVPixelBufferPool
    private static let allocationLimit = 6

    init?(canvas: DuoDesktopCanvas) {
        guard canvas.isValid, canvas.requiresPadding else { return nil }
        self.canvas = canvas
        let attributes: [CFString: Any] = [
            kCVPixelBufferPixelFormatTypeKey: kCVPixelFormatType_32BGRA,
            kCVPixelBufferWidthKey: canvas.encodedWidth,
            kCVPixelBufferHeightKey: canvas.encodedHeight,
            kCVPixelBufferIOSurfacePropertiesKey: [:],
            kCVPixelBufferMetalCompatibilityKey: true
        ]
        var made: CVPixelBufferPool?
        guard CVPixelBufferPoolCreate(nil, nil, attributes as CFDictionary, &made) == kCVReturnSuccess,
              let made else { return nil }
        pool = made
    }

    func pad(_ source: CVPixelBuffer) -> CVPixelBuffer? {
        guard CVPixelBufferGetPixelFormatType(source) == kCVPixelFormatType_32BGRA,
              CVPixelBufferGetWidth(source) == canvas.width, CVPixelBufferGetHeight(source) == canvas.height,
              !CVPixelBufferIsPlanar(source) else { return nil }
        var made: CVPixelBuffer?
        let limit: [CFString: Any] = [kCVPixelBufferPoolAllocationThresholdKey: Self.allocationLimit]
        guard CVPixelBufferPoolCreatePixelBufferWithAuxAttributes(nil, pool, limit as CFDictionary, &made) == kCVReturnSuccess,
              let output = made,
              CVPixelBufferGetWidth(output) == canvas.encodedWidth, CVPixelBufferGetHeight(output) == canvas.encodedHeight,
              !CVPixelBufferIsPlanar(output),
              CVPixelBufferLockBaseAddress(source, .readOnly) == kCVReturnSuccess else { return nil }
        defer { CVPixelBufferUnlockBaseAddress(source, .readOnly) }
        guard CVPixelBufferLockBaseAddress(output, []) == kCVReturnSuccess else { return nil }
        defer { CVPixelBufferUnlockBaseAddress(output, []) }
        guard let from = CVPixelBufferGetBaseAddress(source), let to = CVPixelBufferGetBaseAddress(output) else { return nil }
        let sourceStride = CVPixelBufferGetBytesPerRow(source), outputStride = CVPixelBufferGetBytesPerRow(output)
        let sourceBytes = canvas.width * 4, outputBytes = canvas.encodedWidth * 4
        guard sourceStride >= sourceBytes, outputStride >= outputBytes else { return nil }
        for row in 0..<canvas.height {
            let src = from.advanced(by: row * sourceStride), dst = to.advanced(by: row * outputStride)
            memcpy(dst, src, sourceBytes)
            if canvas.width != canvas.encodedWidth {
                memcpy(dst.advanced(by: sourceBytes), src.advanced(by: sourceBytes - 4), 4)
            }
        }
        if canvas.height != canvas.encodedHeight {
            memcpy(to.advanced(by: canvas.height * outputStride),
                   to.advanced(by: (canvas.height - 1) * outputStride), outputBytes)
        }
        CVBufferRemoveAllAttachments(output)
        CVBufferPropagateAttachments(source, output)
        // The output is the whole encoded canvas, not a clean-aperture crop back to odd pixels.
        CVBufferRemoveAttachment(output, kCVImageBufferCleanApertureKey)
        CVBufferRemoveAttachment(output, kCVImageBufferPreferredCleanApertureKey)
        CVBufferRemoveAttachment(output, kCVImageBufferDisplayDimensionsKey)
        return output
    }
}
