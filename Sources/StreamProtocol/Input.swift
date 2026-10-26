import Foundation

/// Client → host input. Positions are fractions of the streamed video frame (0…1 across its width
/// and height), whatever size the client draws it at; the host maps them onto the source's screen
/// rectangle. That keeps the client ignorant of Mac geometry and survives window moves.
public enum PointerAction: String, Codable {
    case move       // cursor only (Pencil hover, finger position)
    case leftDown
    case leftUp
    case rightDown
    case rightUp
}

public enum InputEvent: Codable, Hashable {
    case pointer(PointerAction, x: Double, y: Double)

    /// Scroll with the cursor at (x, y). dx/dy are fractions of the frame the content should move,
    /// natural-scrolling sign: positive dy means the content moves down (finger dragged down).
    case scroll(x: Double, y: Double, dx: Double, dy: Double)

    /// Text from the software keyboard. "\n", "\t" and "\u{8}" (backspace) are delivered as the
    /// matching keys; everything else is typed as Unicode.
    case text(String)

    /// Scroll gesture boundaries, so the Mac sees a trackpad-like gesture (rubber-banding, and
    /// momentum after the fingers lift) rather than a bare wheel. Sent around `.scroll` deltas:
    /// began → deltas… → ended, then optionally momentumBegan → deltas… → momentumEnded, with the
    /// client generating the decaying momentum deltas itself.
    case scrollGesture(ScrollPhase, x: Double, y: Double)

    /// A key by USB HID usage (UIKeyboardHIDUsage.rawValue on iOS) with UIKeyModifierFlags bits,
    /// which are the same bit positions as CGEventFlags for shift/control/option/command.
    case key(hidUsage: UInt16, down: Bool, modifiers: UInt64)

    /// Key and pointer releases can finish an interaction while its video is restarting.
    public var isRelease: Bool {
        switch self {
        case .key(_, false, _), .pointer(.leftUp, _, _), .pointer(.rightUp, _, _): return true
        default: return false
        }
    }

    /// Bound untrusted unit coordinates before any screen-space multiplication or integer logging.
    /// A finite JSON number can overflow when multiplied by a desktop's width.
    public var boundedCoordinates: InputEvent? {
        func position(_ x: Double, _ y: Double) -> (Double, Double)? {
            guard x.isFinite, y.isFinite else { return nil }
            return (min(1, max(0, x)), min(1, max(0, y)))
        }
        switch self {
        case .pointer(let action, let x, let y):
            guard let (x, y) = position(x, y) else { return nil }
            return .pointer(action, x: x, y: y)
        case .scroll(let x, let y, let dx, let dy):
            guard let (x, y) = position(x, y), dx.isFinite, dy.isFinite else { return nil }
            return .scroll(x: x, y: y, dx: dx, dy: dy)
        case .scrollGesture(let phase, let x, let y):
            guard let (x, y) = position(x, y) else { return nil }
            return .scrollGesture(phase, x: x, y: y)
        case .key, .text: return self
        }
    }
}

public enum ScrollPhase: String, Codable {
    case began, ended, momentumBegan, momentumEnded
}
