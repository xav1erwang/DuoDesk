// Copyright 2026 DUO你电脑 contributors. SPDX-License-Identifier: Apache-2.0
import SwiftUI
import UIKit
import CoreText

// MARK: - Design tokens
//
// One palette, two appearances. Every colour here is a dynamic UIColor, so a view
// that asks for `Palette.text` gets the dark or the light value from the system
// appearance without a colour scheme threaded through the call sites. The values
// and the reasoning are in `design/deep-blue-ui/README.md`.

extension UIColor {
    convenience init(hex: UInt32, alpha: CGFloat = 1) {
        self.init(red: CGFloat((hex >> 16) & 0xFF) / 255,
                  green: CGFloat((hex >> 8) & 0xFF) / 255,
                  blue: CGFloat(hex & 0xFF) / 255,
                  alpha: alpha)
    }
}

extension Color {
    /// A colour that resolves per appearance.
    static func adaptive(dark: UInt32, light: UInt32) -> Color {
        Color(UIColor { traits in
            UIColor(hex: traits.userInterfaceStyle == .dark ? dark : light)
        })
    }

    /// A translucent colour that resolves per appearance.
    static func adaptive(dark: UInt32, darkAlpha: CGFloat,
                         light: UInt32, lightAlpha: CGFloat) -> Color {
        Color(UIColor { traits in
            traits.userInterfaceStyle == .dark
                ? UIColor(hex: dark, alpha: darkAlpha)
                : UIColor(hex: light, alpha: lightAlpha)
        })
    }
}

/// The app's palette. Names kept from the previous version so the views that
/// already ask for them follow the theme; the values are the design's.
enum Palette {
    // Chrome
    static let bar = Color.adaptive(dark: 0x071729, light: 0xF7FAFE)
    static let barTop = Color.adaptive(dark: 0x091A2D, light: 0xFFFFFF)
    static let barBottom = Color.adaptive(dark: 0x050F1C, light: 0xF2F7FD)
    static let panel = Color.adaptive(dark: 0x05101F, light: 0xEDF3FA)

    // Controls
    static let control = Color.adaptive(dark: 0x0C2440, light: 0xFFFFFF)
    static let controlOpen = Color.adaptive(dark: 0x12395C, light: 0xD8E8FB)
    static let group = Color.adaptive(dark: 0x0A2138, darkAlpha: 0.92,
                                      light: 0xFFFFFF, lightAlpha: 0.92)
    static let groupQuiet = Color.adaptive(dark: 0x081E34, darkAlpha: 0.45,
                                           light: 0xF5FAFE, lightAlpha: 1)

    // Ink
    static let text = Color.adaptive(dark: 0xF2F7FF, light: 0x0C1A2A)
    static let muted = Color.adaptive(dark: 0x8FA7C2, light: 0x4C6076)
    static let barLabel = Color.adaptive(dark: 0xC4C9D1, light: 0x4C6076)
    static let tertiary = Color.adaptive(dark: 0x7C93AD, light: 0x435A70)

    // Accents
    static let accent = Color.adaptive(dark: 0x23A7FF, light: 0x0B63C6)
    /// The one "current" colour: the selected row, the active thumbnail, the
    /// panel that is open. Never decoration.
    static let current = Color.adaptive(dark: 0x2BD6FF, light: 0x0A6488)
    static let neutral = Color.adaptive(dark: 0x85A4C5, light: 0x4B6D8F)
    /// Text on a filled accent button: dark ink on the bright dark-mode blue,
    /// white on the darker light-mode blue.
    static let onAccent = Color.adaptive(dark: 0x04263B, light: 0xFFFFFF)

    // Lines
    static let stroke = Color.adaptive(dark: 0x69B4FF, darkAlpha: 0.24,
                                       light: 0x0B63C6, lightAlpha: 0.16)
    static let strokeSoft = Color.adaptive(dark: 0x69B4FF, darkAlpha: 0.14,
                                           light: 0x0B63C6, lightAlpha: 0.10)
    static let divider = Color.adaptive(dark: 0x69B4FF, darkAlpha: 0.10,
                                        light: 0x0B63C6, lightAlpha: 0.10)

    // Thumbnails and badges (the mock Mac's chrome, not ours)
    static let thumbBody = Color.adaptive(dark: 0x22384F, light: 0xDFE9F4)
    static let thumbTitleBar = Color.adaptive(dark: 0x2E3C4C, light: 0xCBDCEC)
    static let iconFallback = Color.adaptive(dark: 0x173A5C, light: 0xDCE9F7)
    static let iconTile = Color.adaptive(dark: 0x173A5C, light: 0xE2EEFB)

    /// The portrait trackpad's well belongs to the aluminium control deck, which
    /// keeps its own light finish in both appearances.
    static let trackpad = Color(hex: 0x101215)
}

extension Color {
    init(hex: UInt32, opacity: Double = 1) {
        self.init(.sRGB,
                  red: Double((hex >> 16) & 0xFF) / 255,
                  green: Double((hex >> 8) & 0xFF) / 255,
                  blue: Double(hex & 0xFF) / 255,
                  opacity: opacity)
    }
}

/// Whether the glow treatment applies: it belongs to the dark appearance only.
/// Light drops glow for hairlines and shadows.
struct GlowKey: EnvironmentKey {
    static let defaultValue = true
}

extension EnvironmentValues {
    var duoGlow: Bool {
        get { self[GlowKey.self] }
        set { self[GlowKey.self] = newValue }
    }
}

/// Put on a screen's root so its subtree knows which treatment it is drawing.
struct AppearanceReader: ViewModifier {
    @Environment(\.colorScheme) private var scheme

    func body(content: Content) -> some View {
        content.environment(\.duoGlow, scheme == .dark)
    }
}

extension View {
    func readsAppearance() -> some View { modifier(AppearanceReader()) }
}

// MARK: - Glass

/// The floating panels' material: a blurred base, a 145° gradient, a lit top edge
/// that fades down the sides, and a diagonal sheen. The blur is the point — a flat
/// translucent fill reads as a painted card, not glass.
struct GlassBackground: ViewModifier {
    var radius: CGFloat = 24
    @Environment(\.colorScheme) private var scheme

    func body(content: Content) -> some View {
        let dark = scheme == .dark
        content
            .background {
                ZStack {
                    RoundedRectangle(cornerRadius: radius, style: .continuous)
                        .fill(.ultraThinMaterial)

                    RoundedRectangle(cornerRadius: radius, style: .continuous)
                        .fill(LinearGradient(colors: dark
                            ? [Color(hex: 0x0E2E52, opacity: 0.78),
                               Color(hex: 0x020A16, opacity: 0.66)]
                            : [Color.white.opacity(0.72),
                               Color(hex: 0xF5F9FD, opacity: 0.58)],
                            startPoint: .topLeading, endPoint: .bottomTrailing))

                    RoundedRectangle(cornerRadius: radius, style: .continuous)
                        .fill(LinearGradient(colors: dark
                            ? [Color.white.opacity(0.05), .clear, Color.white.opacity(0.02)]
                            : [Color.white.opacity(0.55), .clear, Color.white.opacity(0.18)],
                            startPoint: .topLeading, endPoint: .bottomTrailing))

                    RoundedRectangle(cornerRadius: radius, style: .continuous)
                        .strokeBorder(LinearGradient(
                            colors: [Color.white.opacity(dark ? 0.18 : 0.85), .clear],
                            startPoint: .top, endPoint: .bottom), lineWidth: 1)

                    RoundedRectangle(cornerRadius: radius, style: .continuous)
                        .strokeBorder(Palette.stroke, lineWidth: 1)
                }
                .shadow(color: .black.opacity(dark ? 0.46 : 0.09),
                        radius: dark ? 22 : 13, y: dark ? 16 : 8)
            }
    }
}

extension View {
    /// A floating panel: the app drawer, the settings sheet, a pairing card.
    func glassPanel(_ radius: CGFloat = 24) -> some View {
        modifier(GlassBackground(radius: radius))
    }
}

/// The surface behind the app's own screens: the template's deep blue with one
/// cold light from the top, or its paper-white light counterpart.
struct PageBackground: View {
    @Environment(\.colorScheme) private var scheme

    var body: some View {
        let dark = scheme == .dark
        ZStack {
            (dark ? Color(hex: 0x030811) : Color(hex: 0xEEF3F9))
            LinearGradient(colors: dark
                ? [Color(hex: 0x061323), Color(hex: 0x030811), Color(hex: 0x02060D)]
                : [Color(hex: 0xF3F8FE), Color(hex: 0xEEF3F9), Color(hex: 0xE7EEF7)],
                startPoint: .top, endPoint: .bottom)
            RadialGradient(colors: [(dark ? Color(hex: 0x1B6FC8) : Color(hex: 0x9CC4EE)).opacity(dark ? 0.22 : 0.30),
                                    .clear],
                           center: UnitPoint(x: 0.5, y: -0.05),
                           startRadius: 0, endRadius: 420)
        }
        .ignoresSafeArea()
    }
}

// MARK: - Small shared parts

/// The close button a floating panel wears in its corner.
struct PanelCloseButton: View {
    let label: String
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Image(systemName: "xmark")
                .font(.system(size: 11, weight: .bold))
                .foregroundStyle(Palette.muted)
                .frame(width: 28, height: 28)
                .background(Circle().fill(Palette.control))
                .overlay(Circle().strokeBorder(Palette.stroke, lineWidth: 1))
                .contentShape(Circle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel(Text(label))
    }
}

// MARK: - VisionTec wordmark
//
// Per `VisionTec 品牌资源/VisionTec 文字 Logo 设计规范.md`: VISIONTEC, Montserrat
// Black (900), 0.18em tracking, line height 1, one line. The font ships in the
// bundle and is registered once; if it is missing the view falls back to the
// system's heaviest weight, keeping the tracking.

enum WordmarkFont {
    static let postScriptName = "Montserrat-Black"

    static let isAvailable: Bool = {
        guard let url = Bundle.main.url(forResource: "Montserrat-900", withExtension: "ttf") else {
            return false
        }
        var error: Unmanaged<CFError>?
        CTFontManagerRegisterFontsForURL(url as CFURL, .process, &error)
        return UIFont(name: postScriptName, size: 12) != nil
    }()
}

struct VisionTecWordmark: View {
    var size: CGFloat = 9
    var color: Color = Palette.tertiary

    private static let trackingRatio: CGFloat = 0.18

    var body: some View {
        Text("VISIONTEC")
            .font(WordmarkFont.isAvailable
                  ? .custom(WordmarkFont.postScriptName, size: size)
                  : .system(size: size, weight: .black))
            .tracking(size * Self.trackingRatio)
            .foregroundStyle(color)
            // Tracking adds a gap after the last glyph; pull it back so the glyph
            // edge, not the box, is what centres.
            .padding(.trailing, -size * Self.trackingRatio)
            .lineLimit(1)
            .fixedSize()
            .accessibilityLabel("VisionTec")
    }
}
