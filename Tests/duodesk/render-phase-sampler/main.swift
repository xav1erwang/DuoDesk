// Copyright 2026 DUO你电脑 contributors. SPDX-License-Identifier: Apache-2.0
// In-memory checks for the test-only marker decoder; no window or capture is opened.
import AppKit
import CoreVideo
import Foundation

@main
@MainActor
struct Check {
    static func main() {
        let rect = CGRect(x: 32, y: 12, width: 128, height: 12)
        let sampler = RenderPhaseSampler(markerRect: rect, windowHeight: 714, scale: 2)
        var buffer: CVPixelBuffer?
        guard CVPixelBufferCreate(nil, 2008, 1428, kCVPixelFormatType_420YpCbCr8BiPlanarFullRange, nil, &buffer) == kCVReturnSuccess,
              let buffer else { exit(1) }
        func paint(_ sequence: Int, badSentinel: Bool = false, ambiguous: Bool = false) {
            CVPixelBufferLockBaseAddress(buffer, [])
            defer { CVPixelBufferUnlockBaseAddress(buffer, []) }
            guard let bytes = CVPixelBufferGetBaseAddressOfPlane(buffer, 0)?.assumingMemoryBound(to: UInt8.self) else { exit(1) }
            let row = CVPixelBufferGetBytesPerRowOfPlane(buffer, 0)
            let bits = [true, false] + (0..<12).map { (sequence & (1 << $0)) != 0 } + [true, false]
            for (index, white) in bits.enumerated() {
                let x = Int((rect.minX + (CGFloat(index) + 0.5) * 8) * 2)
                let y = Int((714 - rect.midY) * 2)
                bytes[y * row + x] = badSentinel && index == 0 ? 0 : ambiguous && index == 4 ? 120 : white ? 235 : 16
            }
        }
        for value in [0, 1, 245, 2048, 4095] {
            paint(value)
            guard sampler.inspect(buffer).sequence == value else { print("FAIL: sequence \(value)"); exit(1) }
        }
        paint(10, badSentinel: true)
        guard sampler.inspect(buffer).sequence == nil else { print("FAIL: wrong sentinel"); exit(1) }
        paint(10, ambiguous: true)
        guard sampler.inspect(buffer).sequence == nil else { print("FAIL: ambiguous luma"); exit(1) }
        let outside = RenderPhaseSampler(markerRect: CGRect(x: 10000, y: 12, width: 128, height: 12), windowHeight: 714, scale: 2)
        guard outside.inspect(buffer).sequence == nil else { print("FAIL: out-of-bounds marker"); exit(1) }
        print("RENDER PHASE SAMPLER PASS: five codes, sentinels, ambiguous luma and bounds; no capture")
    }
}
