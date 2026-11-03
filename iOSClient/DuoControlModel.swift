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
    // The first release starts at 60; 120 is an explicit opt-in and remains bounded by the
    // screen and Low Power Mode. This is a request, not a claim about delivered distinct frames.
    static let preferredFPSKey = "duodesk.preferredFPS"
    static let legacyUpperDisplayKey = "duodesk.nativeUpperDisplay"
    static let renderedUpperDisplayKey = "duodesk.nativeUpperDisplay.renderPixelsV1"
    static let defaultFPS = 60
    static func normalizedFPS(_ value: Int) -> Int { value == 120 ? 120 : defaultFPS }
    static func requestedFPS(panelMaximum: Int, lowPower: Bool, preferredFPS: Int = defaultFPS) -> Int {
        let ceiling = min(normalizedFPS(preferredFPS), min(120, max(30, panelMaximum)))
        return lowPower ? min(60, ceiling) : ceiling
    }

    static func nativeUpperDisplay(width: Double, height: Double) -> DuoDesktopResolution? {
        guard width.isFinite, height.isFinite, width > 0, height > 0,
              width <= 8192, height <= 16384 else { return nil }
        let resolution = DuoDesktopResolution(width: Int(min(width, height).rounded(.up)),
                                               height: Int((max(width, height) / 2).rounded(.up)))
        return resolution.isValid ? resolution : nil
    }

    /// Keep the same native desktop while entering or leaving clean-image mode. Older installed
    /// hosts may be unable to detach and restore a virtual display after an in-session resize.
    /// The renderer preserves the whole frame; a differently shaped screen can show black bars.
    static func stableDesktopRequest(width: Double, height: Double, cleanImage: Bool) -> DuoDesktopResolution? {
        nativeUpperDisplay(width: width, height: height)
    }

    /// UIKit can render more pixels than the physical panel has. Accept one complete canvas only
    /// when it covers the other and their aspects agree within one pixel of quantization per side.
    /// Combining unrelated widths and heights would silently change the desktop's aspect.
    static func requiredDisplayPixels(physical: CGSize, rendered: CGSize) -> CGSize? {
        let physicalSides = [physical.width, physical.height].sorted()
        let renderedSides = [rendered.width, rendered.height].sorted()
        guard (physicalSides + renderedSides).allSatisfy({ $0.isFinite && $0 > 0 && $0 <= 16384 }) else { return nil }
        let cross = abs(physicalSides[0] * renderedSides[1] - renderedSides[0] * physicalSides[1])
        guard cross <= physicalSides[1] + renderedSides[1] else { return nil }
        if renderedSides[0] >= physicalSides[0], renderedSides[1] >= physicalSides[1] {
            return CGSize(width: renderedSides[0], height: renderedSides[1])
        }
        if physicalSides[0] >= renderedSides[0], physicalSides[1] >= renderedSides[1] {
            return CGSize(width: physicalSides[0], height: physicalSides[1])
        }
        return nil
    }

    static func upperDisplay(metrics: DuoNativeDisplayMetrics, renderedRequired: Bool) -> DuoDesktopResolution? {
        let pixels: CGSize
        if renderedRequired {
            guard let rendered = metrics.renderPixels,
                  let required = requiredDisplayPixels(physical: metrics.pixels, rendered: rendered) else { return nil }
            pixels = required
        } else { pixels = metrics.pixels }
        return nativeUpperDisplay(width: pixels.width, height: pixels.height)
    }

    static func cachedUpperDisplay(in defaults: UserDefaults, rendered: Bool) -> DuoDesktopResolution? {
        let key = rendered ? renderedUpperDisplayKey : legacyUpperDisplayKey
        guard let data = defaults.data(forKey: key),
              let resolution = try? JSONDecoder().decode(DuoDesktopResolution.self, from: data),
              resolution.isValid else { return nil }
        return resolution
    }

    /// Immersive mode uses the whole inner screen. Match its current orientation so the host can
    /// provide every desktop pixel without cropping or distorting an upper-half picture.
    static func nativeFullDisplay(width: Double, height: Double, landscape: Bool) -> DuoDesktopResolution? {
        guard width.isFinite, height.isFinite, width > 0, height > 0,
              width <= 8192, height <= 8192 else { return nil }
        let short = Int(min(width, height).rounded(.up))
        let long = Int(max(width, height).rounded(.up))
        let resolution = DuoDesktopResolution(width: landscape ? long : short, height: landscape ? short : long)
        return resolution.isValid ? resolution : nil
    }

    /// The orientation is chosen once when the extension is created and kept for its life.
    /// An unknown or inconsistent render canvas must not silently become a smaller extension.
    static func extendedDisplay(metrics: DuoNativeDisplayMetrics) -> DuoDesktopResolution? {
        guard let rendered = metrics.renderPixels,
              let required = requiredDisplayPixels(physical: metrics.pixels, rendered: rendered) else { return nil }
        guard metrics.windowSize.width.isFinite, metrics.windowSize.height.isFinite,
              metrics.windowSize.width > 0, metrics.windowSize.height > 0 else { return nil }
        return nativeFullDisplay(width: Double(required.width), height: Double(required.height),
                                 landscape: metrics.windowSize.width > metrics.windowSize.height)
    }

    /// In the normal landscape UI the toolbar and padding sit outside the picture. Match the
    /// measured picture in render pixels, so keeping the controls visible does not add letterbox.
    static func landscapePanel(metrics: DuoNativeDisplayMetrics, frame: CGRect, panel: CGSize) -> DuoDesktopResolution? {
        guard frame.width > frame.height, metrics.windowSize.width > metrics.windowSize.height,
              let full = extendedDisplay(metrics: metrics),
              panel.width.isFinite, panel.height.isFinite, panel.width > 0, panel.height > 0,
              abs(panel.width - (frame.width - 16)) <= 2,
              panel.height <= frame.height + 2 else { return nil }
        let sx = Double(full.width) / metrics.windowSize.width
        let sy = Double(full.height) / metrics.windowSize.height
        guard abs(sx - sy) < 0.01 else { return nil }
        let resolution = DuoDesktopResolution(width: Int((panel.width * sx).rounded(.up)),
                                             height: Int((panel.height * sy).rounded(.up)))
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

/// Fits the existing native desktop into the whole screen without requesting a Mac resize.
/// A quarter turn is useful when a landscape desktop is shown on the unfolded Duo upright.
enum DuoCleanImageLayout {
    static func shouldRotate(panel: CGSize, video: CGSize, nativeDesktop: Bool) -> Bool {
        guard nativeDesktop,
              panel.width.isFinite, panel.height.isFinite,
              video.width.isFinite, video.height.isFinite,
              panel.width > 0, panel.height > 0, video.width > 0, video.height > 0 else { return false }
        let upright = min(panel.width / video.width, panel.height / video.height)
        let rotated = min(panel.width / video.height, panel.height / video.width)
        // Avoid rotating nearly square content for an imperceptible gain. The comparison is in
        // linear scale; 1.05 is a little over 10% more area, with no cropping or distortion.
        return rotated.isFinite && upright.isFinite && rotated > upright * 1.05
    }
}

enum DuoExtendedDesktopPolicy {
    /// A fallback must preserve the entire physical display at no fewer pixels than the requested
    /// Duo picture. Its different aspect is intentional and shown to the user.
    static func physicalFallback(_ issue: DuoDesktopIssue?, expected: DuoDesktopResolution?,
                                 extending: Bool, active: StreamSource) -> DuoDesktopResolution? {
        guard !extending, active == .none, let issue, issue.resolution == expected,
              let physical = issue.physicalFallback, physical.isValid,
              physical.width >= issue.resolution.width, physical.height >= issue.resolution.height else { return nil }
        return physical
    }

    static func request(hostAdvertised: Bool, connected: Bool, alreadyExtended: Bool,
                        pathMoving: Bool = false, connectionDead: Bool = false,
                        upper: DuoDesktopResolution?, metrics: DuoNativeDisplayMetrics?) -> DuoDesktopResolution? {
        guard hostAdvertised, connected, !alreadyExtended, !pathMoving, !connectionDead,
              upper?.isValid == true, let metrics else { return nil }
        return DuoStreamPolicy.extendedDisplay(metrics: metrics)
    }

    static func applies(_ response: DuoExtendedDesktopStatus, currentRequest: UUID?) -> Bool {
        currentRequest != nil && response.requestID == currentRequest
    }

    /// A mirror error belongs only to the matching idle mirror request. A delayed catalog cannot
    /// hide an extension, replace a live desktop, or describe a different requested canvas.
    static func mirrorIssue(_ issue: DuoDesktopIssue?, expected: DuoDesktopResolution?,
                            extending: Bool, active: StreamSource) -> String? {
        guard !extending, active == .none, let issue, issue.resolution.isValid,
              issue.resolution == expected else { return nil }
        let safe = SafeText.label(issue.message, limit: 200)
        return safe.isEmpty ? nil : safe
    }

    static func mirrorViewport(_ old: Viewport?, upper: DuoDesktopResolution?) -> Viewport? {
        guard var result = old else { return nil }
        result.desktopResolution = upper
        result.extendedDesktop = nil
        result.extendedRequestID = nil
        result.preservePhysicalMode = nil
        return result
    }
}

struct DuoNativeDisplayMetrics: Equatable {
    var pixels: CGSize
    var windowSize: CGSize
    var renderPixels: CGSize? = nil
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
        [DuoKey(id: "input-source", legend: "globe", action: .inputSource, accessibilityName: "切换 Mac 输入法"),
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
