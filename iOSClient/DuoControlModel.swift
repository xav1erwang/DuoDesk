// Copyright 2026 DUO你电脑 contributors. SPDX-License-Identifier: Apache-2.0
import Foundation
import CoreGraphics
import StreamProtocol

/// Persisted independently of the posture. Changing input tools never changes the video session.
enum DuoControlMode: String, CaseIterable, Identifiable {
    case keyboard, trackpad, combined
    var id: String { rawValue }
    var hasKeyboard: Bool { self != .trackpad }
    var hasTrackpad: Bool { self != .keyboard }
}

enum DuoStreamPolicy {
    static func requestedFPS(panelMaximum: Int, lowPower: Bool) -> Int {
        let ceiling = min(120, max(30, panelMaximum))
        return lowPower ? min(60, ceiling) : ceiling
    }

    static func nativeUpperDisplay(width: Double, height: Double) -> DuoDesktopResolution? {
        guard width.isFinite, height.isFinite, width > 0, height > 0,
              width <= 8192, height <= 16384 else { return nil }
        let resolution = DuoDesktopResolution(width: Int(min(width, height).rounded(.up)),
                                               height: Int((max(width, height) / 2).rounded(.up)))
        return resolution.isValid ? resolution : nil
    }

    static func coherentInnerMetrics(_ metrics: DuoNativeDisplayMetrics, frame: CGRect, fold: CGRect?) -> Bool {
        guard let fold, !frame.isEmpty,
              frame.minX >= -2, frame.minY >= -2,
              frame.maxX <= metrics.windowSize.width + 2, frame.maxY <= metrics.windowSize.height + 2 else { return false }
        let horizontal = fold.width > fold.height
        let center = horizontal ? fold.midY + frame.minY : fold.midX + frame.minX
        let expected = (horizontal ? metrics.windowSize.height : metrics.windowSize.width) / 2
        return abs(center - expected) <= 2
    }
}

struct DuoNativeDisplayMetrics: Equatable {
    var pixels: CGSize
    var windowSize: CGSize
}

struct DuoKey: Identifiable, Equatable {
    enum Action: Equatable {
        case key(UInt16)
        case modifier(UInt64)
        case capsLock
        case inputSource
    }
    let id: String
    let legend: String
    var shifted: String? = nil
    let action: Action
    var units: Double = 1
    var accessibilityName: String? = nil
}

/// ANSI positions are sent as HID keys, so the Mac's selected input source handles composition.
/// Modifiers are one-shot latches; KeyChord releases every modifier after the key or pointer action.
enum DuoKeyboardLayout {
    /// Caps Lock is per-key metadata too: a green keycap alone cannot change what the Mac types.
    /// Keep HID input so the Mac's own layout/input source performs the character translation.
    static func keyEvents(_ usage: UInt16, latched: KeyModifiers, capsLock: Bool) -> [InputEvent] {
        var modifiers = latched
        if capsLock { modifiers.insert(.capsLock) } else { modifiers.remove(.capsLock) }
        return KeyChord.press(usage, with: modifiers)
    }

    static func legend(for key: DuoKey, latched: KeyModifiers, capsLock: Bool) -> String {
        if case .key(let usage) = key.action, (0x04...0x1D).contains(usage) {
            // The Mac's US layout keeps letters uppercase with both Caps Lock and Shift.
            return (latched.contains(.shift) || capsLock) ? key.legend.uppercased() : key.legend
        }
        return latched.contains(.shift) ? (key.shifted ?? key.legend) : key.legend
    }

    private static func key(_ label: String, _ usage: UInt16, _ units: Double = 1,
                            shifted: String? = nil, name: String? = nil) -> DuoKey {
        DuoKey(id: "hid-\(usage)", legend: label, shifted: shifted,
               action: .key(usage), units: units, accessibilityName: name)
    }
    private static func modifier(_ label: String, _ usage: UInt16, _ bit: Int,
                                 _ units: Double = 1, name: String) -> DuoKey {
        DuoKey(id: "modifier-\(usage)", legend: label, action: .modifier(1 << bit),
               units: units, accessibilityName: name)
    }
    private static func letters(_ text: String) -> [DuoKey] {
        text.utf8.map { key(String(UnicodeScalar($0)), 0x04 + UInt16($0 - 97)) }
    }

    static let rows: [[DuoKey]] = [
        [key("esc", 0x29, 1.5, name: "Escape")]
            + (1...12).map { key("F\($0)", UInt16(0x39 + $0)) },
        [key("`", 0x35, shifted: "~")]
            + (1...9).map { key(String($0), UInt16(0x1D + $0), shifted: ["!", "@", "#", "$", "%", "^", "&", "*", "("][$0 - 1]) }
            + [key("0", 0x27, shifted: ")"), key("-", 0x2D, shifted: "_"),
               key("=", 0x2E, shifted: "+"), key("delete", 0x2A, 1.5, name: "删除")],
        [key("tab", 0x2B, 1.5, name: "Tab")] + letters("qwertyuiop")
            + [key("[", 0x2F, shifted: "{"), key("]", 0x30, shifted: "}"), key("\\", 0x31, shifted: "|")],
        [DuoKey(id: "caps-lock", legend: "caps lock", action: .capsLock, units: 1.75, accessibilityName: "大写锁定")]
            + letters("asdfghjkl") + [key(";", 0x33, shifted: ":"), key("'", 0x34, shifted: "\""),
                                       key("return", 0x28, 1.75, name: "回车")],
        [modifier("shift", 0xE1, 17, 2.25, name: "Shift")]
            + letters("zxcvbnm") + [key(",", 0x36, shifted: "<"), key(".", 0x37, shifted: ">"),
                                       key("/", 0x38, shifted: "?"), modifier("shift", 0xE5, 17, 2.25, name: "右 Shift")],
        [DuoKey(id: "input-source", legend: "🌐", action: .inputSource, accessibilityName: "切换 Mac 输入法"),
         modifier("⌃", 0xE0, 18, name: "Control"), modifier("⌥", 0xE2, 19, name: "Option"),
         modifier("⌘", 0xE3, 20, 1.25, name: "Command"), key("", 0x2C, 4, name: "空格"),
         modifier("⌘", 0xE7, 20, 1.25, name: "右 Command"), modifier("⌥", 0xE6, 19, name: "右 Option"),
         key("←", 0x50, name: "左箭头"), key("↑", 0x52, name: "上箭头"),
         key("↓", 0x51, name: "下箭头"), key("→", 0x4F, name: "右箭头")]
    ]

    static func widths(for row: [DuoKey], available: Double, gap: Double) -> [Double] {
        let unit = max(0, available - gap * Double(max(0, row.count - 1))) / row.reduce(0) { $0 + $1.units }
        return row.map { unit * $0.units }
    }
}

/// The upper panel and the controls occupy the two real sides of a horizontal hinge.
/// Open flat keeps the laptop arrangement; on the cover, a 16:10 desktop leaves room for input.
struct DuoConsoleGeometry: Equatable {
    let pictureHeight: Double
    let controlsTop: Double

    init(width: Double, height: Double, foldMinY: Double? = nil, foldMaxY: Double? = nil, cover: Bool = false) {
        let h = max(0, height)
        if let low = foldMinY, let high = foldMaxY, low >= 0, high >= low, high <= h {
            // Video reaches the center of the hinge: the complete physical upper half. Controls
            // still start below the reserved band, so no keyboard or trackpad sits on the fold.
            pictureHeight = (low + high) / 2
            controlsTop = high
        } else {
            pictureHeight = cover ? min(h * 0.45, max(0, width) / 1.6) : h / 2
            controlsTop = pictureHeight
        }
    }
}

/// AVFoundation's cumulative totals can reset after a flush. A reset starts a new sample window.
struct DuoFrameRateSampler {
    private var previous: (frames: Int, time: Double)?

    mutating func sample(total: Int, dropped: Int, time: Double) -> Int? {
        let displayed = max(0, total - dropped)
        defer { previous = (displayed, time) }
        guard let previous, displayed >= previous.frames, time > previous.time else { return nil }
        return Int((Double(displayed - previous.frames) / (time - previous.time)).rounded())
    }
}
