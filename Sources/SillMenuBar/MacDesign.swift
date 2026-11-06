// Copyright 2026 DUO你电脑 contributors. SPDX-License-Identifier: Apache-2.0
import SwiftUI

// The Mac's half of the design in `design/deep-blue-ui/`: the same tokens by
// appearance, the same frosted panel, the same wordmark. The menu bar app's own
// windows are drawn by us; the menu itself stays AppKit's.

extension Color {
    init(hex: UInt32, opacity: Double = 1) {
        self.init(.sRGB,
                  red: Double((hex >> 16) & 0xFF) / 255,
                  green: Double((hex >> 8) & 0xFF) / 255,
                  blue: Double(hex & 0xFF) / 255,
                  opacity: opacity)
    }
}

/// The tokens, resolved for one appearance.
struct MacTheme {
    let dark: Bool

    init(_ scheme: ColorScheme) { dark = scheme == .dark }

    var ink: Color { dark ? Color(hex: 0xF2F7FF) : Color(hex: 0x0C1A2A) }
    var muted: Color { dark ? Color(hex: 0x8FA7C2) : Color(hex: 0x4C6076) }
    var tertiary: Color { dark ? Color(hex: 0x7C93AD) : Color(hex: 0x435A70) }
    var accent: Color { dark ? Color(hex: 0x23A7FF) : Color(hex: 0x0B63C6) }
    /// The one "current" colour: the pairing code, the open control.
    var current: Color { dark ? Color(hex: 0x2BD6FF) : Color(hex: 0x0A6488) }
    var stroke: Color { dark ? Color(hex: 0x69B4FF, opacity: 0.24) : Color(hex: 0x0B63C6, opacity: 0.16) }
    var strokeSoft: Color { dark ? Color(hex: 0x69B4FF, opacity: 0.14) : Color(hex: 0x0B63C6, opacity: 0.10) }
    var panelTop: Color { dark ? Color(hex: 0x0E2E52, opacity: 0.52) : Color.white.opacity(0.72) }
    var panelBottom: Color { dark ? Color(hex: 0x020A16, opacity: 0.38) : Color(hex: 0xF5F9FD, opacity: 0.58) }
}

/// The deep-blue surface behind a Mac window, or its paper-white counterpart.
struct MacWindowBackground: View {
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
    }
}

/// A frosted panel: the blur, the 145° fill, a lit edge that fades down the
/// sides, and the diagonal sheen.
struct MacGlass: ViewModifier {
    var radius: CGFloat = 18
    @Environment(\.colorScheme) private var scheme

    func body(content: Content) -> some View {
        let theme = MacTheme(scheme)
        content
            .background {
                ZStack {
                    RoundedRectangle(cornerRadius: radius, style: .continuous).fill(.ultraThinMaterial)
                    RoundedRectangle(cornerRadius: radius, style: .continuous)
                        .fill(LinearGradient(colors: [theme.panelTop, theme.panelBottom],
                                             startPoint: .topLeading, endPoint: .bottomTrailing))
                    RoundedRectangle(cornerRadius: radius, style: .continuous)
                        .fill(LinearGradient(colors: theme.dark
                            ? [Color.white.opacity(0.10), .clear, Color.white.opacity(0.04)]
                            : [Color.white.opacity(0.55), .clear, Color.white.opacity(0.18)],
                            startPoint: .topLeading, endPoint: .bottomTrailing))
                    RoundedRectangle(cornerRadius: radius, style: .continuous)
                        .strokeBorder(LinearGradient(colors: [Color.white.opacity(theme.dark ? 0.18 : 0.85), .clear],
                                                     startPoint: .top, endPoint: .bottom), lineWidth: 1)
                    RoundedRectangle(cornerRadius: radius, style: .continuous)
                        .strokeBorder(theme.stroke, lineWidth: 1)
                }
                .shadow(color: .black.opacity(theme.dark ? 0.42 : 0.08),
                        radius: theme.dark ? 18 : 10, y: theme.dark ? 12 : 6)
            }
    }
}

extension View {
    func macGlass(_ radius: CGFloat = 18) -> some View { modifier(MacGlass(radius: radius)) }
}

/// The VisionTec mark: Montserrat Black where the font is bundled, the system's
/// black weight otherwise, 0.18em tracking either way.
struct VisionTecMark: View {
    var size: CGFloat = 9
    var color: Color = .secondary

    var body: some View {
        Text("VISIONTEC")
            .font(.custom("Montserrat-Black", size: size))
            .tracking(size * 0.18)
            .foregroundStyle(color)
            .padding(.trailing, -size * 0.18)
            .lineLimit(1)
            .fixedSize()
            .accessibilityLabel("VisionTec")
    }
}

/// Four cyan corner brackets around a scanning target.
struct MacScanCorners: View {
    var color: Color
    var inset: CGFloat = 10
    var length: CGFloat = 18

    var body: some View {
        GeometryReader { geo in
            let w = geo.size.width, h = geo.size.height
            Path { p in
                p.move(to: CGPoint(x: inset, y: inset + length)); p.addLine(to: CGPoint(x: inset, y: inset)); p.addLine(to: CGPoint(x: inset + length, y: inset))
                p.move(to: CGPoint(x: w - inset - length, y: inset)); p.addLine(to: CGPoint(x: w - inset, y: inset)); p.addLine(to: CGPoint(x: w - inset, y: inset + length))
                p.move(to: CGPoint(x: inset, y: h - inset - length)); p.addLine(to: CGPoint(x: inset, y: h - inset)); p.addLine(to: CGPoint(x: inset + length, y: h - inset))
                p.move(to: CGPoint(x: w - inset - length, y: h - inset)); p.addLine(to: CGPoint(x: w - inset, y: h - inset)); p.addLine(to: CGPoint(x: w - inset, y: h - inset - length))
            }
            .stroke(color, style: StrokeStyle(lineWidth: 2, lineCap: .round, lineJoin: .round))
        }
        .allowsHitTesting(false)
        .accessibilityHidden(true)
    }
}
