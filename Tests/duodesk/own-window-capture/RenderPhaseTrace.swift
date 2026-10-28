// Copyright 2026 DUO你电脑 contributors. SPDX-License-Identifier: Apache-2.0
// Test-only source/render marker. It is outside the document center and is never used to claim FPS.
import AppKit
import CoreVideo
import Darwin

@MainActor
final class RenderPhaseMarker: NSView {
    nonisolated static let bits = 12
    nonisolated static let cellWidth: CGFloat = 8
    nonisolated static let cellHeight: CGFloat = 12
    private var value: Int = 0
    var onDraw: ((Int, UInt64) -> Void)?
    override var isOpaque: Bool { true }

    func setSequence(_ sequence: Int) {
        value = sequence & ((1 << Self.bits) - 1)
        needsDisplay = true
    }

    override func draw(_ dirtyRect: NSRect) {
        let current = value
        // Two fixed sentinels let the decoder reject wrong coordinates or a partially drawn view.
        let cells = [true, false] + (0..<Self.bits).map { (current & (1 << $0)) != 0 } + [true, false]
        for (index, white) in cells.enumerated() {
            (white ? NSColor.white : NSColor.black).setFill()
            NSRect(x: CGFloat(index) * Self.cellWidth, y: 0, width: Self.cellWidth, height: Self.cellHeight).fill()
        }
        onDraw?(current, mach_absolute_time())
    }

    static var size: CGSize { CGSize(width: CGFloat(bits + 4) * cellWidth, height: cellHeight) }
}

/// Only reads a few pixels belonging to this process's own marker; no pixels or codes are saved.
final class RenderPhaseSampler: @unchecked Sendable {
    struct Result { let sequence: Int?; let lockWaitTicks: UInt64 }
    private let points: [(Int, Int)]
    var pixelPoints: [(Int, Int)] { points }

    init(markerRect: CGRect, windowHeight: CGFloat, scale: CGFloat) {
        points = (0..<(RenderPhaseMarker.bits + 4)).map { index in
            let x = (markerRect.minX + (CGFloat(index) + 0.5) * RenderPhaseMarker.cellWidth) * scale
            let y = (windowHeight - markerRect.midY) * scale
            return (Int(x.rounded(.down)), Int(y.rounded(.down)))
        }
    }

    func inspect(_ image: CVPixelBuffer) -> Result {
        let before = mach_absolute_time()
        let status = CVPixelBufferLockBaseAddress(image, .readOnly)
        let wait = mach_absolute_time() - before
        guard status == kCVReturnSuccess else { return Result(sequence: nil, lockWaitTicks: wait) }
        defer { CVPixelBufferUnlockBaseAddress(image, .readOnly) }
        guard CVPixelBufferGetPlaneCount(image) >= 1,
              let bytes = CVPixelBufferGetBaseAddressOfPlane(image, 0)?.assumingMemoryBound(to: UInt8.self) else {
            return Result(sequence: nil, lockWaitTicks: wait)
        }
        let width = CVPixelBufferGetWidthOfPlane(image, 0), height = CVPixelBufferGetHeightOfPlane(image, 0)
        let row = CVPixelBufferGetBytesPerRowOfPlane(image, 0)
        var bits: [Bool] = []
        for (x, y) in points {
            guard x >= 0, x < width, y >= 0, y < height else { return Result(sequence: nil, lockWaitTicks: wait) }
            let value = bytes[y * row + x]
            guard value <= 80 || value >= 175 else { return Result(sequence: nil, lockWaitTicks: wait) }
            bits.append(value >= 175)
        }
        guard bits.count == RenderPhaseMarker.bits + 4, bits[0], !bits[1], bits[bits.count - 2], !bits[bits.count - 1] else {
            return Result(sequence: nil, lockWaitTicks: wait)
        }
        let value = (0..<RenderPhaseMarker.bits).reduce(0) { $0 | (bits[$1 + 2] ? 1 << $1 : 0) }
        return Result(sequence: value, lockWaitTicks: wait)
    }
}
