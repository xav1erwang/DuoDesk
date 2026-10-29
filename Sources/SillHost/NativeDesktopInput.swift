// Copyright 2026 DUO你电脑 contributors. SPDX-License-Identifier: Apache-2.0
import Foundation
import StreamProtocol

/// Convert encoded-video fractions into fractions of the actual source desktop. Padding is at
/// the right and bottom; interaction in that edge is clamped to the nearest real desktop pixel.
enum NativeDesktopInput {
    static func map(_ raw: InputEvent, canvas: DuoDesktopCanvas) -> InputEvent? {
        guard canvas.isValid, let event = raw.boundedCoordinates else { return nil }
        let sx = Double(canvas.encodedWidth) / Double(canvas.width)
        let sy = Double(canvas.encodedHeight) / Double(canvas.height)
        func x(_ value: Double) -> Double { min(1, value * sx) }
        func y(_ value: Double) -> Double { min(1, value * sy) }
        switch event {
        case .pointer(let action, let px, let py): return .pointer(action, x: x(px), y: y(py))
        case .scroll(let px, let py, let dx, let dy):
            let mx = dx * sx, my = dy * sy
            guard mx.isFinite, my.isFinite else { return nil }
            return .scroll(x: x(px), y: y(py), dx: mx, dy: my)
        case .scrollGesture(let phase, let px, let py): return .scrollGesture(phase, x: x(px), y: y(py))
        case .key, .text: return event
        }
    }
}
