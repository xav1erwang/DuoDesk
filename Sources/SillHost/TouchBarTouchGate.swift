// Copyright 2026 DUO你电脑 contributors. SPDX-License-Identifier: Apache-2.0
import Foundation
import StreamProtocol

/// Serially owned by the host's coordinator. One paired device can hold a Touch Bar contact at
/// a time. Disconnecting, hiding the bar or replacing its surface returns the release the caller
/// must deliver (or invalidate the backend if input authorization has disappeared).
struct TouchBarTouchGate<Peer: Hashable> {
    private var owner: Peer?
    private var last: TouchBarTouch?

    mutating func accept(_ touch: TouchBarTouch, from peer: Peer, surface: TouchBarSurface,
                         subscribed: Bool, paired: Bool, inputAllowed: Bool) -> TouchBarTouch? {
        guard paired, subscribed, inputAllowed, surface.isValid, surface.acceptsInput,
              touch.isValid, touch.surfaceID == surface.id else { return nil }
        switch touch.phase {
        case .began:
            guard owner == nil else { return nil }
            owner = peer; last = touch
        case .moved:
            guard owner == peer, last?.surfaceID == surface.id else { return nil }
            last = touch
        case .ended, .cancelled:
            guard owner == peer, last?.surfaceID == surface.id else { return nil }
            owner = nil; last = nil
        }
        return touch
    }

    mutating func release(for peer: Peer) -> TouchBarTouch? {
        guard owner == peer else { return nil }
        return release()
    }

    mutating func release() -> TouchBarTouch? {
        defer { owner = nil; last = nil }
        guard let last else { return nil }
        return TouchBarTouch(surfaceID: last.surfaceID, phase: .cancelled, x: last.x, y: last.y)
    }
}
