// Copyright 2026 DUO你电脑 contributors. SPDX-License-Identifier: Apache-2.0
import AppKit
import Foundation
import StreamProtocol

/// The simulated display's input extent comes from its own runtime. It is not inferred from a
/// physical-bar screenshot, an even-aligned video canvas, or a guessed scale. The native private
/// API's units and orientation are still unverified and this mapping is not enabled in the app.
struct TouchBarVirtualInputMapping: Equatable, Sendable {
    let imageWidth: Int
    let imageHeight: Int
    let pointWidth: Double
    let pointHeight: Double

    var isValid: Bool {
        imageWidth > 0 && imageWidth <= 8192 && imageHeight > 0 && imageHeight <= 2048
            && pointWidth.isFinite && pointWidth > 0 && pointWidth <= 8192
            && pointHeight.isFinite && pointHeight > 0 && pointHeight <= 2048
    }

    static func observed(imageWidth: Int, imageHeight: Int, extent: CGSize?) -> Self? {
        guard let extent else { return nil }
        let value = Self(imageWidth: imageWidth, imageHeight: imageHeight,
                         pointWidth: Double(extent.width), pointHeight: Double(extent.height))
        return value.isValid ? value : nil
    }

    func matches(extent: CGSize?) -> Bool {
        guard let extent else { return false }
        return isValid && Double(extent.width) == pointWidth && Double(extent.height) == pointHeight
    }

    /// Wire coordinates are top-left based; the historical simulator's view coordinates are
    /// bottom-left based. This remains a candidate until current-system orientation is verified.
    func event(_ touch: TouchBarTouch) -> TouchBarVirtualMouseEvent? {
        guard isValid, touch.isValid else { return nil }
        let type: NSEvent.EventType
        switch touch.phase {
        case .began: type = .leftMouseDown
        case .moved: type = .leftMouseDragged
        case .ended, .cancelled: type = .leftMouseUp
        }
        let x = min(pointWidth.nextDown, touch.x * pointWidth)
        let y = min(pointHeight.nextDown, (1 - touch.y) * pointHeight)
        return TouchBarVirtualMouseEvent(type: type, point: CGPoint(x: x, y: y), mapping: self, phase: touch.phase)
    }
}

struct TouchBarVirtualMouseEvent: Sendable {
    let type: NSEvent.EventType
    let point: CGPoint
    let mapping: TouchBarVirtualInputMapping
    let phase: TouchBarPhase
}

/// One native post may be in flight; at most a down, latest move and up can wait behind it.
/// A later contact cannot start until its preceding up has actually returned from the runtime.
final class TouchBarVirtualInputMailbox: @unchecked Sendable {
    private let lock = NSLock()
    private var token: UUID?
    private var pending: [TouchBarVirtualMouseEvent] = []
    private var scheduled = false
    private var contact = false
    private var awaitingRelease = false
    private var mapping: TouchBarVirtualInputMapping?

    func reset(to token: UUID?) {
        lock.withLock {
            self.token = token; pending.removeAll(); scheduled = false
            contact = false; awaitingRelease = false; mapping = nil
        }
    }

    /// The second result asks the caller to schedule one drain; false means no input was accepted.
    func offer(_ event: TouchBarVirtualMouseEvent, token: UUID) -> (accepted: Bool, schedule: Bool) {
        lock.withLock {
            guard self.token == token else { return (false, false) }
            switch event.phase {
            case .began:
                guard !contact, !awaitingRelease else { return (false, false) }
                contact = true; mapping = event.mapping; pending.append(event)
            case .moved:
                guard contact, mapping == event.mapping else { return (false, false) }
                if pending.last?.phase == .moved { pending[pending.count - 1] = event }
                else { pending.append(event) }
            case .ended, .cancelled:
                guard contact, mapping == event.mapping else { return (false, false) }
                contact = false; awaitingRelease = true; pending.append(event)
            }
            precondition(pending.count <= 3)
            let schedule = !scheduled
            scheduled = true
            return (true, schedule)
        }
    }

    func take(token: UUID) -> TouchBarVirtualMouseEvent? {
        lock.withLock {
            guard self.token == token, scheduled else { return nil }
            guard !pending.isEmpty else { scheduled = false; return nil }
            return pending.removeFirst()
        }
    }

    func completed(_ event: TouchBarVirtualMouseEvent, token: UUID) {
        lock.withLock {
            guard self.token == token else { return }
            if event.phase == .ended || event.phase == .cancelled {
                awaitingRelease = false; mapping = nil
            }
        }
    }
}
