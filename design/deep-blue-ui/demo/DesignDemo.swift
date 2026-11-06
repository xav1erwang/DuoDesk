import SwiftUI
import CoreText
import UIKit

// MARK: - Tokens
//
// The same values as design/deep-blue-ui/board.css. Two themes, picked by the
// system appearance only — there is no manual switch, by design.

struct Theme {
    let bgTop: Color, bgMid: Color, bgBottom: Color
    let panelTop: Color, panelBottom: Color
    let chip: Color, chipOpen: Color
    let stroke: Color, strokeSoft: Color
    let ink: Color, muted: Color, tertiary: Color, barLabel: Color
    let accent: Color, cyan: Color, neutral: Color, mark: Color
    let glow: Bool

    static let dark = Theme(
        bgTop: Color(hex: 0x061323), bgMid: Color(hex: 0x030811), bgBottom: Color(hex: 0x02060D),
        panelTop: Color(hex: 0x0E2E52).opacity(0.52),
        panelBottom: Color(hex: 0x020A16).opacity(0.38),
        chip: Color(hex: 0x0C2440), chipOpen: Color(hex: 0x12395C),
        stroke: Color(hex: 0x69B4FF).opacity(0.24),
        strokeSoft: Color(hex: 0x69B4FF).opacity(0.14),
        ink: Color(hex: 0xF2F7FF), muted: Color(hex: 0x8FA7C2),
        tertiary: Color(hex: 0x7C93AD), barLabel: Color(hex: 0xC4C9D1),
        accent: Color(hex: 0x23A7FF), cyan: Color(hex: 0x2BD6FF),
        neutral: Color(hex: 0x85A4C5), mark: Color(hex: 0x7C93AD), glow: true)

    static let light = Theme(
        bgTop: Color(hex: 0xF3F8FE), bgMid: Color(hex: 0xEEF3F9), bgBottom: Color(hex: 0xE7EEF7),
        panelTop: Color.white.opacity(0.72),
        panelBottom: Color(hex: 0xF5F9FD).opacity(0.58),
        chip: .white, chipOpen: Color(hex: 0xD8E8FB),
        stroke: Color(hex: 0x0B63C6).opacity(0.16),
        strokeSoft: Color(hex: 0x0B63C6).opacity(0.10),
        ink: Color(hex: 0x0C1A2A), muted: Color(hex: 0x4C6076),
        tertiary: Color(hex: 0x435A70), barLabel: Color(hex: 0x4C6076),
        accent: Color(hex: 0x0B63C6), cyan: Color(hex: 0x0A6488),
        neutral: Color(hex: 0x4B6D8F), mark: Color(hex: 0x435A70), glow: false)

    static func of(_ scheme: ColorScheme) -> Theme { scheme == .dark ? .dark : .light }
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

// MARK: - VisionTec wordmark
//
// Spec: VISIONTEC, Montserrat Black 900, 0.18em tracking, one line, optical
// left edge (the trailing tracking is pulled back).

enum WordmarkFont {
    static let name = "Montserrat-Black"

    static let available: Bool = {
        guard let url = Bundle.main.url(forResource: "Montserrat-900", withExtension: "ttf")
        else { return false }
        var error: Unmanaged<CFError>?
        CTFontManagerRegisterFontsForURL(url as CFURL, .process, &error)
        return UIFont(name: name, size: 12) != nil
    }()
}

struct Wordmark: View {
    var size: CGFloat = 9
    var color: Color

    var body: some View {
        Text("VISIONTEC")
            .font(WordmarkFont.available
                  ? .custom(WordmarkFont.name, size: size)
                  : .system(size: size, weight: .black))
            .tracking(size * 0.18)
            .foregroundStyle(color)
            .padding(.trailing, -size * 0.18)
            .lineLimit(1)
            .fixedSize()
            .accessibilityLabel("VisionTec")
    }
}

// MARK: - Surfaces

struct PageBackground: View {
    let t: Theme

    var body: some View {
        ZStack {
            LinearGradient(colors: [t.bgTop, t.bgMid, t.bgBottom],
                           startPoint: .top, endPoint: .bottom)
            if t.glow {
                RadialGradient(colors: [Color(hex: 0x1C70BA).opacity(0.28), .clear],
                               center: UnitPoint(x: 0.5, y: 0.0),
                               startRadius: 0, endRadius: 420)
                RadialGradient(colors: [Color(hex: 0x105496).opacity(0.16), .clear],
                               center: UnitPoint(x: 0.10, y: 0.80),
                               startRadius: 0, endRadius: 420)
            } else {
                RadialGradient(colors: [Color(hex: 0x0B63C6).opacity(0.10), .clear],
                               center: UnitPoint(x: 0.5, y: 0.0),
                               startRadius: 0, endRadius: 420)
            }
        }
        .ignoresSafeArea()
    }
}

struct Glass: ViewModifier {
    let t: Theme
    var radius: CGFloat = 24

    func body(content: Content) -> some View {
        content
            .background {
                ZStack {
                    // The blur every floating panel sits on: the Mac behind it must
                    // read as frosted, not as a flat fill.
                    RoundedRectangle(cornerRadius: radius, style: .continuous)
                        .fill(.ultraThinMaterial)

                    RoundedRectangle(cornerRadius: radius, style: .continuous)
                        .fill(LinearGradient(colors: [t.panelTop, t.panelBottom],
                                             startPoint: .topLeading, endPoint: .bottomTrailing))

                    RoundedRectangle(cornerRadius: radius, style: .continuous)
                        .fill(Color(hex: 0x1E7CD6).opacity(t.glow ? 0.06 : 0))

                    // A faint sheen across the pane: the thing that makes glass read
                    // as glass rather than as a translucent rectangle.
                    RoundedRectangle(cornerRadius: radius, style: .continuous)
                        .fill(LinearGradient(
                            colors: [Color.white.opacity(t.glow ? 0.10 : 0.55),
                                     Color.white.opacity(0.01),
                                     Color.white.opacity(t.glow ? 0.04 : 0.18)],
                            startPoint: .topLeading, endPoint: .bottomTrailing))

                    // The lit edge stays inside the border: a stroke that fades out
                    // rather than a 1 pt bar laid across the top.
                    RoundedRectangle(cornerRadius: radius, style: .continuous)
                        .strokeBorder(LinearGradient(
                            colors: [Color.white.opacity(t.glow ? 0.18 : 0.85),
                                     Color.white.opacity(0.02)],
                            startPoint: .top, endPoint: .bottom), lineWidth: 1)

                    RoundedRectangle(cornerRadius: radius, style: .continuous)
                        .strokeBorder(t.stroke, lineWidth: 1)
                }
                .shadow(color: Color.black.opacity(t.glow ? 0.46 : 0.09),
                        radius: t.glow ? 22 : 13,
                        y: t.glow ? 16 : 8)
            }
    }
}

extension View {
    func glass(_ t: Theme, radius: CGFloat = 24) -> some View {
        modifier(Glass(t: t, radius: radius))
    }
}

// MARK: - Pieces

struct Kicker: View {
    let t: Theme
    let text: String

    var body: some View {
        Text(text.uppercased())
            .font(.system(size: 10, weight: .bold))
            .tracking(2.6)
            .foregroundStyle(t.cyan)
    }
}

struct Pill: View {
    let t: Theme
    let text: String
    var current = false

    var body: some View {
        Text(text)
            .font(.system(size: 11, weight: .semibold))
            .foregroundStyle(current ? t.cyan : t.muted)
            .padding(.horizontal, 9)
            .padding(.vertical, 4.5)
            .background {
                Capsule().fill(current
                    ? (t.glow ? Color(hex: 0x082748).opacity(0.82) : Color(hex: 0xE3F0FD))
                    : (t.glow ? Color(hex: 0x061628).opacity(0.70) : Color(hex: 0xEEF4FB)))
            }
            .overlay {
                Capsule().strokeBorder(current ? t.cyan.opacity(0.48) : t.stroke, lineWidth: 1)
            }
    }
}

struct IconTile: View {
    let t: Theme
    let symbol: String
    var size: CGFloat = 34

    var body: some View {
        Image(systemName: symbol)
            .font(.system(size: size * 0.49, weight: .regular))
            .foregroundStyle(t.ink)
            .frame(width: size, height: size)
            .background {
                RoundedRectangle(cornerRadius: size * 0.30, style: .continuous)
                    .fill(LinearGradient(colors: t.glow
                        ? [Color(hex: 0x173A5C), Color(hex: 0x0A2138)]
                        : [Color(hex: 0xE2EEFB), Color(hex: 0xCADFF4)],
                        startPoint: .topLeading, endPoint: .bottomTrailing))
            }
            .overlay {
                RoundedRectangle(cornerRadius: size * 0.30, style: .continuous)
                    .strokeBorder(Color(hex: t.glow ? 0x69B4FF : 0x0B63C6).opacity(0.20),
                                  lineWidth: 1)
            }
            .shadow(color: Color.black.opacity(t.glow ? 0 : 0.06), radius: 1, y: 1)
    }
}

struct BarChip: View {
    let t: Theme
    let symbol: String
    let label: String
    var open = false
    /// The Aa control draws letters rather than a symbol: SF Symbols localizes
    /// "textformat.size" into 大小 on a Chinese device.
    var letters: String? = nil

    var body: some View {
        VStack(spacing: 5) {
            if let letters {
                Text(letters).font(.system(size: 20, weight: .regular))
            } else {
                Image(systemName: symbol).font(.system(size: 21, weight: .regular))
            }
            Text(label).font(.system(size: 11, weight: .medium))
        }
        .foregroundStyle(open ? t.cyan : t.ink)
        .frame(width: 66, height: 66)
        .background {
            RoundedRectangle(cornerRadius: 16, style: .continuous)
                .fill(open ? t.chipOpen : t.chip)
        }
        .overlay {
            RoundedRectangle(cornerRadius: 16, style: .continuous)
                .strokeBorder(open ? t.cyan.opacity(0.55) : t.stroke, lineWidth: 1)
        }
        .shadow(color: t.glow && open ? t.cyan.opacity(0.20) : .clear, radius: 10)
        .shadow(color: Color.black.opacity(t.glow ? 0 : 0.05), radius: 1, y: 1)
    }
}

struct Thumb: View {
    let t: Theme
    var active = false

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 2) {
                ForEach(0..<3, id: \.self) { _ in
                    Circle().fill(t.muted.opacity(0.42)).frame(width: 3, height: 3)
                }
                Spacer(minLength: 0)
            }
            .padding(.leading, 4)
            .frame(height: 9)
            .background(t.ink.opacity(0.10))

            VStack(alignment: .leading, spacing: 4) {
                Capsule().fill(t.muted.opacity(0.30)).frame(width: 88, height: 4)
                Capsule().fill(t.muted.opacity(0.30)).frame(width: 67, height: 4)
                Capsule().fill(t.muted.opacity(0.30)).frame(width: 51, height: 4)
                Spacer(minLength: 0)
            }
            .padding(8)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .frame(width: 104, height: 66)
        .background {
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .fill(LinearGradient(colors: t.glow
                    ? [Color(hex: 0x22384F), Color(hex: 0x0E2236)]
                    : [Color(hex: 0xDFE9F4), Color(hex: 0xCBDCEC)],
                    startPoint: .topLeading, endPoint: .bottomTrailing))
        }
        .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .strokeBorder(active ? t.cyan.opacity(0.85) : t.muted.opacity(0.28), lineWidth: 1)
        }
        .shadow(color: t.glow && active ? t.cyan.opacity(0.28) : .clear, radius: 11)
    }
}

// MARK: - Connect screen

struct ConnectView: View {
    let t: Theme
    var title = "连接 Mac"

    private struct Row { let symbol: String; let name: String; let word: String }

    private var rows: [Row] {
        [Row(symbol: "laptopcomputer", name: "MacBook Pro", word: "Wi‑Fi"),
         Row(symbol: "macmini", name: "Mac mini", word: "有线"),
         Row(symbol: "laptopcomputer", name: "Noah 的 MacBook Air", word: "远程")]
    }

    var body: some View {
        VStack(spacing: 0) {
            Spacer(minLength: 0)

            HStack(spacing: 12) {
                IconTile(t: t, symbol: "laptopcomputer", size: 34)
                VStack(alignment: .leading, spacing: 3) {
                    Kicker(t: t, text: "DUO 你电脑")
                    Text(title)
                        .font(.system(size: 21, weight: .semibold))
                        .foregroundStyle(t.ink)
                }
                Spacer(minLength: 0)
            }
            .padding(.bottom, 12)

            HStack(spacing: 8) {
                Circle().fill(t.glow ? t.cyan : t.accent).frame(width: 6, height: 6)
                Text("正在搜索局域网中的 Mac…")
                    .font(.system(size: 12.5))
                    .foregroundStyle(t.muted)
                Spacer(minLength: 0)
            }
            .padding(.bottom, 10)

            VStack(spacing: 2) {
                ForEach(Array(rows.enumerated()), id: \.offset) { index, row in
                    HStack(spacing: 11) {
                        IconTile(t: t, symbol: row.symbol, size: 32)
                        Text(row.name)
                            .font(.system(size: 14.5))
                            .foregroundStyle(t.ink)
                            .lineLimit(1)
                        Spacer(minLength: 8)
                        Pill(t: t, text: row.word, current: index == 0)
                    }
                    .padding(.horizontal, 11)
                    .frame(height: 54)
                    .background {
                        if index == 0 {
                            RoundedRectangle(cornerRadius: 14, style: .continuous)
                                .fill(LinearGradient(colors: t.glow
                                    ? [Color(hex: 0x12395C).opacity(0.92), Color(hex: 0x0A2138).opacity(0.35)]
                                    : [Color(hex: 0xDBEAFA), Color(hex: 0xEEF6FD)],
                                    startPoint: .leading, endPoint: .trailing))
                                .overlay(alignment: .leading) {
                                    Capsule().fill(t.cyan)
                                        .frame(width: 3, height: 32)
                                        .shadow(color: t.glow ? t.cyan.opacity(0.6) : .clear, radius: 6)
                                        .padding(.leading, 0)
                                }
                                .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
                        }
                    }
                }
            }
            .padding(6)
            .glass(t, radius: 22)

            HStack(spacing: 10) {
                Image(systemName: "plus").font(.system(size: 15, weight: .semibold))
                Text("添加 Mac").font(.system(size: 14.5, weight: .semibold))
                Spacer(minLength: 0)
            }
            .foregroundStyle(t.accent)
            .padding(.horizontal, 14)
            .frame(height: 46)
            .background {
                RoundedRectangle(cornerRadius: 14, style: .continuous)
                    .fill(t.glow ? Color(hex: 0x081E34).opacity(0.45) : Color(hex: 0xF5FAFE))
            }
            .overlay {
                RoundedRectangle(cornerRadius: 14, style: .continuous)
                    .strokeBorder(t.accent.opacity(0.30),
                                  style: StrokeStyle(lineWidth: 1, dash: [4, 4]))
            }
            .padding(.top, 10)

            Spacer(minLength: 0)
            Spacer(minLength: 0)

            Wordmark(size: 9, color: t.mark)
                .opacity(t.glow ? 0.62 : 0.50)
                .padding(.bottom, 18)
        }
        .padding(.horizontal, 26)
        .padding(.top, 10)
    }
}

// MARK: - The streamed Mac (neutral, never tinted)

struct MacDesktop: View {
    var body: some View {
        GeometryReader { geo in
            ZStack(alignment: .topLeading) {
                wallpaper

                VStack(spacing: 0) {
                    HStack(spacing: 14) {
                        Circle().fill(Color.white.opacity(0.85)).frame(width: 10, height: 10)
                        ForEach(["访达", "文件", "编辑", "显示", "前往", "窗口", "帮助"], id: \.self) {
                            Text($0).font(.system(size: 10))
                                .foregroundStyle(Color.white.opacity(0.82))
                        }
                        Spacer(minLength: 0)
                    }
                    .padding(.horizontal, 12)
                    .frame(height: 22)
                    .background(Color.black.opacity(0.28))

                    ZStack(alignment: .topLeading) {
                        // a second window, peeking from behind
                        notesWindow
                            .offset(x: geo.size.width * 0.30, y: 26)

                        finderWindow
                            .padding(.leading, max(16, geo.size.width * 0.04))
                            .padding(.top, max(14, geo.size.height * 0.07))
                    }

                    Spacer(minLength: 0)
                }
            }
        }
        .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .strokeBorder(Color.white.opacity(0.09), lineWidth: 1)
        }
    }

    /// The Mac's own wallpaper: deliberately colourful, so a panel over it has
    /// something to frost.
    private var wallpaper: some View {
        ZStack {
            LinearGradient(colors: [Color(hex: 0x1B3A5B), Color(hex: 0x0B1B2C)],
                           startPoint: .topLeading, endPoint: .bottomTrailing)
            RadialGradient(colors: [Color(hex: 0x3E7EA8), .clear],
                           center: UnitPoint(x: 0.22, y: 0.28),
                           startRadius: 0, endRadius: 340)
            RadialGradient(colors: [Color(hex: 0xC98A4B).opacity(0.75), .clear],
                           center: UnitPoint(x: 0.86, y: 0.78),
                           startRadius: 0, endRadius: 300)
            RadialGradient(colors: [Color(hex: 0x7A5C9E).opacity(0.55), .clear],
                           center: UnitPoint(x: 0.62, y: 0.12),
                           startRadius: 0, endRadius: 260)
        }
    }

    private var finderWindow: some View {
        VStack(spacing: 0) {
            HStack(spacing: 8) {
                ForEach([0xFF5F57, 0xFEBC2E, 0x28C840], id: \.self) {
                    Circle().fill(Color(hex: UInt32($0))).frame(width: 9, height: 9)
                }
                Text("项目资料")
                    .font(.system(size: 11))
                    .foregroundStyle(Color.white.opacity(0.78))
                Spacer(minLength: 0)
            }
            .padding(.horizontal, 12)
            .frame(height: 30)
            .background(Color(hex: 0x2E3C4C).opacity(0.92))

            HStack(spacing: 0) {
                VStack(alignment: .leading, spacing: 8) {
                    ForEach(0..<6, id: \.self) { i in
                        HStack(spacing: 6) {
                            RoundedRectangle(cornerRadius: 2)
                                .fill(i == 0 ? Color(hex: 0x2BD6FF).opacity(0.55)
                                             : Color.white.opacity(0.34))
                                .frame(width: 9, height: 9)
                            Capsule()
                                .fill(i == 0 ? Color(hex: 0x2BD6FF).opacity(0.35)
                                             : Color.white.opacity(0.28))
                                .frame(width: i == 0 ? 58 : 48, height: 5)
                        }
                    }
                    Spacer(minLength: 0)
                }
                .padding(10)
                .frame(width: 118)
                .frame(maxHeight: .infinity, alignment: .top)
                .background(Color.white.opacity(0.06))

                LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 8), count: 4),
                          spacing: 8) {
                    ForEach(0..<8, id: \.self) { i in
                        RoundedRectangle(cornerRadius: 6)
                            .fill(i == 4 ? Color(hex: 0x2BD6FF).opacity(0.22)
                                         : Color.white.opacity(0.10))
                            .overlay {
                                RoundedRectangle(cornerRadius: 6)
                                    .strokeBorder(i == 4 ? Color(hex: 0x2BD6FF).opacity(0.5)
                                                         : Color.white.opacity(0.12),
                                                  lineWidth: 1)
                            }
                            .frame(height: 42)
                    }
                }
                .padding(12)
            }
            .frame(maxHeight: .infinity)
        }
        .frame(width: 330, height: 240)
        .background(Color(hex: 0x16232F).opacity(0.94))
        .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .strokeBorder(Color.white.opacity(0.16), lineWidth: 1)
        }
        .shadow(color: .black.opacity(0.45), radius: 20, y: 12)
    }

    private var notesWindow: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 6) {
                ForEach([0xFF5F57, 0xFEBC2E, 0x28C840], id: \.self) {
                    Circle().fill(Color(hex: UInt32($0))).frame(width: 7, height: 7)
                }
                Spacer(minLength: 0)
            }
            .padding(.bottom, 2)

            ForEach(0..<5, id: \.self) { i in
                Capsule()
                    .fill(Color(hex: 0x2A3542))
                    .frame(width: i % 3 == 0 ? 120 : 150, height: 5)
            }
            Spacer(minLength: 0)
        }
        .padding(12)
        .frame(width: 190, height: 150, alignment: .topLeading)
        .background(Color(hex: 0xF2EAD8).opacity(0.92))
        .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .strokeBorder(Color.white.opacity(0.35), lineWidth: 1)
        }
        .shadow(color: .black.opacity(0.35), radius: 16, y: 10)
    }
}

// MARK: - Drawer

struct DrawerView: View {
    let t: Theme

    private struct App { let mark: String; let name: String; let count: String? }

    private var open: [App] {
        [App(mark: "项", name: "项目资料", count: "3 个窗口"),
         App(mark: "迅", name: "迅雷", count: "1 个窗口"),
         App(mark: "微", name: "微信", count: "2 个窗口")]
    }

    private var all: [App] {
        [App(mark: "备", name: "备忘录", count: nil),
         App(mark: "日", name: "日历", count: nil),
         App(mark: "浏", name: "Safari 浏览器", count: nil)]
    }

    var body: some View {
        VStack(spacing: 8) {
            HStack(spacing: 10) {
                Image(systemName: "magnifyingglass")
                    .font(.system(size: 18))
                    .foregroundStyle(t.muted)
                Text("搜索 MacBook Pro 上的应用")
                    .font(.system(size: 15))
                    .foregroundStyle(t.tertiary)
                Spacer(minLength: 0)
            }
            .padding(.horizontal, 14)
            .frame(height: 48)
            .background { RoundedRectangle(cornerRadius: 12, style: .continuous).fill(t.chip) }
            .overlay {
                RoundedRectangle(cornerRadius: 12, style: .continuous)
                    .strokeBorder(t.strokeSoft, lineWidth: 1)
            }

            VStack(spacing: 2) {
                label("OPEN NOW")
                ForEach(Array(open.enumerated()), id: \.offset) { i, app in
                    row(app, selected: i == 0)
                }
                label("ALL APPS").padding(.top, 12)
                ForEach(Array(all.enumerated()), id: \.offset) { _, app in
                    row(app, selected: false)
                }
                Spacer(minLength: 0)
            }
        }
        .padding(14)
        .frame(maxHeight: .infinity, alignment: .top)
        .glass(t, radius: 24)
    }

    private func label(_ text: String) -> some View {
        Text(text)
            .font(.system(size: 11, weight: .bold))
            .tracking(1.5)
            .foregroundStyle(t.muted)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, 10)
            .padding(.bottom, 2)
    }

    private func row(_ app: App, selected: Bool) -> some View {
        HStack(spacing: 12) {
            Text(app.mark)
                .font(.system(size: 12, weight: .bold))
                .foregroundStyle(t.ink)
                .frame(width: 32, height: 32)
                .background {
                    RoundedRectangle(cornerRadius: 9, style: .continuous)
                        .fill(LinearGradient(colors: t.glow
                            ? [Color(hex: 0x2F6B96), Color(hex: 0x14324C)]
                            : [Color(hex: 0xDCEBF9), Color(hex: 0xC4DAF0)],
                            startPoint: .topLeading, endPoint: .bottomTrailing))
                }
                .overlay {
                    RoundedRectangle(cornerRadius: 9, style: .continuous)
                        .strokeBorder(Color(hex: t.glow ? 0x69B4FF : 0x0B63C6).opacity(0.22),
                                      lineWidth: 1)
                }
            Text(app.name).font(.system(size: 15)).foregroundStyle(t.ink)
            Spacer(minLength: 8)
            if let count = app.count {
                Text(count).font(.system(size: 12)).foregroundStyle(t.tertiary)
            }
        }
        .padding(.horizontal, 10)
        .frame(height: 50)
        .background {
            if selected {
                RoundedRectangle(cornerRadius: 10, style: .continuous)
                    .fill(LinearGradient(colors: t.glow
                        ? [Color(hex: 0x12395C).opacity(0.90), Color(hex: 0x0A2138).opacity(0.30)]
                        : [Color(hex: 0xDBEAFA), Color(hex: 0xEDF5FD)],
                        startPoint: .leading, endPoint: .trailing))
                    .overlay(alignment: .leading) {
                        Capsule().fill(t.cyan)
                            .frame(width: 3, height: 30)
                            .shadow(color: t.glow ? t.cyan.opacity(0.6) : .clear, radius: 6)
                    }
                    .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
            }
        }
    }
}

/// The close button a floating panel wears in its top-right corner.
struct CloseButton: View {
    let t: Theme

    var body: some View {
        Image(systemName: "xmark")
            .font(.system(size: 11, weight: .bold))
            .foregroundStyle(t.muted)
            .frame(width: 26, height: 26)
            .background { Circle().fill(t.chip) }
            .overlay { Circle().strokeBorder(t.stroke, lineWidth: 1) }
            .accessibilityLabel("关闭")
    }
}

// MARK: - Settings panel

struct SettingsView: View {
    let t: Theme

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 12) {
                Text("MacBook Pro")
                    .font(.system(size: 16, weight: .semibold))
                    .foregroundStyle(t.ink)
                Spacer(minLength: 4)
                CloseButton(t: t)
            }
            .padding(.horizontal, 2)
            .padding(.bottom, 14)

            VStack(spacing: 0) {
                row("画质") { Text("极致 · 150 Mbps ▾").font(.system(size: 12))
                    .foregroundStyle(t.muted) }
                divider
                row("分辨率") { segments(["Retina", "标准"], active: 1) }
                divider
                row("Mac 帧率上限") { segments(["60 fps", "120 fps"], active: 1) }
            }
            .glass(t, radius: 16)
            footnote("画质按 60 fps 计，120 fps 的串流量翻倍。画面卡顿时请降一档。")

            VStack(spacing: 0) { toggle("优先编码速度", on: true) }
                .glass(t, radius: 16)
            footnote("Mac 繁忙时降低延迟，画面可能略微变柔和。")

            VStack(spacing: 0) { toggle("虚拟显示器", on: true) }
                .glass(t, radius: 16)
            footnote("串流时，所选窗口会移到 Mac 的虚拟显示器，即使被遮挡也能继续更新。")

            Spacer(minLength: 0)

            HStack(spacing: 10) {
                Image(systemName: "xmark.circle").font(.system(size: 16))
                Text("断开 MacBook Pro").font(.system(size: 14, weight: .semibold))
                Spacer(minLength: 0)
            }
            .foregroundStyle(t.accent)
            .padding(.horizontal, 14)
            .frame(height: 44)
            .background { RoundedRectangle(cornerRadius: 12, style: .continuous).fill(t.chip) }
            .overlay {
                RoundedRectangle(cornerRadius: 12, style: .continuous)
                    .strokeBorder(t.strokeSoft, lineWidth: 1)
            }
        }
        .padding(14)
        .frame(maxHeight: .infinity, alignment: .top)
        .glass(t, radius: 24)
    }

    private func row<C: View>(_ title: String, @ViewBuilder control: () -> C) -> some View {
        HStack {
            Text(title).font(.system(size: 14)).foregroundStyle(t.ink)
            Spacer(minLength: 8)
            control()
        }
        .padding(.horizontal, 14)
        .frame(height: 44)
    }

    private func segments(_ items: [String], active: Int) -> some View {
        HStack(spacing: 2) {
            ForEach(Array(items.enumerated()), id: \.offset) { i, item in
                Text(item)
                    .font(.system(size: 11))
                    .foregroundStyle(i == active ? t.cyan : t.muted)
                    .padding(.horizontal, 9)
                    .padding(.vertical, 5)
                    .background {
                        if i == active {
                            RoundedRectangle(cornerRadius: 7, style: .continuous).fill(t.chipOpen)
                        }
                    }
            }
        }
        .padding(2)
        .background {
            RoundedRectangle(cornerRadius: 9, style: .continuous)
                .fill(t.glow ? Color(hex: 0x030C16).opacity(0.70) : Color(hex: 0xEEF4FB))
        }
        .overlay {
            RoundedRectangle(cornerRadius: 9, style: .continuous)
                .strokeBorder(t.strokeSoft, lineWidth: 1)
        }
    }

    private func toggle(_ title: String, on: Bool) -> some View {
        HStack {
            Text(title).font(.system(size: 14)).foregroundStyle(t.ink)
            Spacer(minLength: 8)
            ZStack(alignment: on ? .trailing : .leading) {
                Capsule()
                    .fill(on
                          ? (t.glow ? Color(hex: 0x1199F0) : Color(hex: 0x0B63C6))
                          : (t.glow ? Color(hex: 0x0A1E32) : Color(hex: 0xDDE8F4)))
                    .frame(width: 40, height: 24)
                    .overlay {
                        Capsule().strokeBorder(on ? t.cyan.opacity(0.50) : t.stroke, lineWidth: 1)
                    }
                    .shadow(color: t.glow && on ? t.cyan.opacity(0.30) : .clear, radius: 8)
                Circle()
                    .fill(t.glow ? (on ? Color(hex: 0x04263B) : Color(hex: 0xCFE3F7)) : Color.white)
                    .frame(width: 18, height: 18)
                    .padding(2)
                    .shadow(color: .black.opacity(0.15), radius: 1, y: 1)
            }
        }
        .padding(.horizontal, 14)
        .frame(height: 44)
    }

    private func divider2() -> some View { EmptyView() }

    private var divider: some View {
        Rectangle().fill(t.strokeSoft).frame(height: 1).padding(.leading, 14)
    }

    private func footnote(_ text: String) -> some View {
        Text(text)
            .font(.system(size: 11))
            .foregroundStyle(t.tertiary)
            .fixedSize(horizontal: false, vertical: true)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, 14)
            .padding(.top, 7)
            .padding(.bottom, 12)
    }
}

// MARK: - Stream screen

struct StreamView: View {
    let t: Theme
    var settings = false

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 12) {
                BarChip(t: t, symbol: "magnifyingglass", label: "应用", open: !settings)
                HStack(spacing: 16) {
                    Thumb(t: t, active: true)
                    Thumb(t: t)
                    Thumb(t: t)
                    Spacer(minLength: 0)
                }
                .padding(.horizontal, 10)
                BarChip(t: t, symbol: "desktopcomputer", label: "桌面")
                BarChip(t: t, symbol: "keyboard", label: "键盘")
                BarChip(t: t, symbol: "textformat.size", label: "Aa", letters: "Aa")
                BarChip(t: t, symbol: "arrow.up.left.and.arrow.down.right", label: "纯净")
                BarChip(t: t, symbol: "gearshape", label: "设置", open: settings)
            }
            .frame(height: 86)
            .padding(.horizontal, 22)
            .background {
                LinearGradient(colors: t.glow
                    ? [Color(hex: 0x091A2D).opacity(0.96), Color(hex: 0x050F1C).opacity(0.96)]
                    : [Color.white, Color(hex: 0xF2F7FD)],
                    startPoint: .top, endPoint: .bottom)
                .overlay(alignment: .bottom) {
                    Rectangle()
                        .fill(t.glow ? t.strokeSoft : Color(hex: 0x0B63C6).opacity(0.14))
                        .frame(height: 1)
                }
            }

            ZStack(alignment: .topLeading) {
                MacDesktop()

                if settings {
                    SettingsView(t: t)
                        .frame(width: 330)
                        .padding(.vertical, 10)
                        .padding(.trailing, 14)
                        .frame(maxWidth: .infinity, alignment: .trailing)
                } else {
                    ZStack(alignment: .topLeading) {
                        (t.glow ? Color.black.opacity(0.24)
                                : Color(hex: 0xD6E2F0).opacity(0.14))
                        DrawerView(t: t)
                            .frame(width: 380)
                            .padding(.leading, 22)
                            .padding(.vertical, 8)
                    }
                }
            }
            .padding(8)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }
}


// MARK: - Pairing (Add a Mac)

struct PairingView: View {
    let t: Theme

    var body: some View {
        VStack(spacing: 0) {
            Spacer(minLength: 0)

            HStack(spacing: 12) {
                IconTile(t: t, symbol: "laptopcomputer", size: 34)
                VStack(alignment: .leading, spacing: 3) {
                    Kicker(t: t, text: "DUO 你电脑")
                    Text("添加 Mac")
                        .font(.system(size: 21, weight: .semibold))
                        .foregroundStyle(t.ink)
                }
                Spacer(minLength: 0)
            }
            .padding(.bottom, 12)

            VStack(spacing: 0) {
                ZStack {
                    RoundedRectangle(cornerRadius: 16, style: .continuous)
                        .fill(t.glow ? Color(hex: 0x04101D) : Color(hex: 0xF7FAFE))
                    QRArt(t: t, size: 130)
                    ScanCorners(t: t)
                }
                .frame(height: 196)

                Text("在 Mac 的 DUO 你电脑菜单中选择配对，然后扫描配对码。")
                    .font(.system(size: 13))
                    .foregroundStyle(t.ink)
                    .fixedSize(horizontal: false, vertical: true)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.top, 14)

                HStack(spacing: 16) {
                    Text("输入配对码").foregroundStyle(t.accent)
                    Text("取消").foregroundStyle(t.accent)
                    Spacer(minLength: 0)
                }
                .font(.system(size: 14.5, weight: .semibold))
                .padding(.top, 14)
            }
            .padding(16)
            .glass(t, radius: 22)

            Spacer(minLength: 0)
            Spacer(minLength: 0)

            Wordmark(size: 9, color: t.mark)
                .opacity(t.glow ? 0.62 : 0.50)
                .padding(.bottom, 18)
        }
        .padding(.horizontal, 26)
        .padding(.top, 10)
    }
}

/// Four corner brackets: the one control that keeps its glow in dark mode.
struct ScanCorners: View {
    let t: Theme

    var body: some View {
        GeometryReader { geo in
            let inset: CGFloat = 18
            let len: CGFloat = 24
            let w = geo.size.width, h = geo.size.height
            Path { p in
                p.move(to: CGPoint(x: inset, y: inset + len)); p.addLine(to: CGPoint(x: inset, y: inset)); p.addLine(to: CGPoint(x: inset + len, y: inset))
                p.move(to: CGPoint(x: w - inset - len, y: inset)); p.addLine(to: CGPoint(x: w - inset, y: inset)); p.addLine(to: CGPoint(x: w - inset, y: inset + len))
                p.move(to: CGPoint(x: inset, y: h - inset - len)); p.addLine(to: CGPoint(x: inset, y: h - inset)); p.addLine(to: CGPoint(x: inset + len, y: h - inset))
                p.move(to: CGPoint(x: w - inset - len, y: h - inset)); p.addLine(to: CGPoint(x: w - inset, y: h - inset)); p.addLine(to: CGPoint(x: w - inset, y: h - inset - len))
            }
            .stroke(t.cyan, style: StrokeStyle(lineWidth: 2, lineCap: .round, lineJoin: .round))
            .shadow(color: t.glow ? t.cyan.opacity(0.6) : .clear, radius: 8)
        }
    }
}

/// A stand-in QR: three finder squares and a scatter of modules.
struct QRArt: View {
    let t: Theme
    var size: CGFloat = 120

    private var modules: [(CGFloat, CGFloat, CGFloat, CGFloat)] {
        [(0.36, 0.06, 0.14, 0.13), (0.58, 0.08, 0.09, 0.09), (0.74, 0.10, 0.13, 0.18),
         (0.08, 0.42, 0.16, 0.11), (0.38, 0.40, 0.20, 0.16), (0.66, 0.44, 0.12, 0.11),
         (0.26, 0.66, 0.13, 0.18), (0.48, 0.70, 0.10, 0.13), (0.66, 0.72, 0.15, 0.14)]
    }

    var body: some View {
        ZStack {
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .fill(t.glow ? Color(hex: 0x071A2C) : Color.white)
                .frame(width: size, height: size)
                .shadow(color: t.glow ? t.cyan.opacity(0.26) : .black.opacity(0.10), radius: 14)

            ForEach(0..<3, id: \.self) { i in
                let pos: [(CGFloat, CGFloat)] = [(0.05, 0.05), (0.68, 0.05), (0.05, 0.68)]
                RoundedRectangle(cornerRadius: 3)
                    .strokeBorder(t.glow ? Color(hex: 0xC9E7FF) : Color(hex: 0x12395C), lineWidth: 4)
                    .frame(width: size * 0.27, height: size * 0.27)
                    .overlay {
                        Rectangle()
                            .fill(t.glow ? Color(hex: 0xC9E7FF) : Color(hex: 0x12395C))
                            .frame(width: size * 0.11, height: size * 0.11)
                    }
                    .position(x: size * (pos[i].0 + 0.135), y: size * (pos[i].1 + 0.135))
            }

            ForEach(Array(modules.enumerated()), id: \.offset) { _, m in
                Rectangle()
                    .fill(t.glow ? Color(hex: 0xC9E7FF) : Color(hex: 0x12395C))
                    .frame(width: size * m.2, height: size * m.3)
                    .position(x: size * (m.0 + m.2 / 2), y: size * (m.1 + m.3 / 2))
            }
        }
        .frame(width: size, height: size)
        .clipped()
    }
}

// MARK: - Root
//
// The design canvas is 951 × 669 pt. The demo draws it at that size inside a
// container scaled to fit the screen, so text and hairlines keep their designed
// proportions on any simulator.

struct RootView: View {
    @Environment(\.colorScheme) private var scheme

    private var screen: String {
        UserDefaults.standard.string(forKey: "DemoScreen") ?? "stream"
    }

    private var theme: Theme { Theme.of(scheme) }

    private static let canvas = CGSize(width: 951, height: 669)
    private static let cover = CGSize(width: 382, height: 678)

    var body: some View {
        GeometryReader { geo in
            let portrait = screen == "connect" || screen == "pairing"
            let base = portrait ? Self.cover : Self.canvas
            let fit = min(geo.size.width / base.width, geo.size.height / base.height)

            ZStack {
                PageBackground(t: theme)

                Color.clear
                    .frame(width: base.width * fit, height: base.height * fit)
                    .overlay {
                        Group {
                            if screen == "pairing" {
                                PairingView(t: theme)
                            } else if portrait {
                                ConnectView(t: theme)
                            } else if screen == "settings" {
                                StreamView(t: theme, settings: true)
                            } else {
                                StreamView(t: theme)
                            }
                        }
                        .frame(width: base.width, height: base.height)
                        .clipShape(RoundedRectangle(cornerRadius: 24, style: .continuous))
                        .overlay {
                            RoundedRectangle(cornerRadius: 24, style: .continuous)
                                .strokeBorder(Color.white.opacity(theme.glow ? 0.07 : 0.55),
                                              lineWidth: 1 / max(fit, 0.01))
                        }
                        .scaleEffect(fit)
                    }
            }
            .frame(width: geo.size.width, height: geo.size.height)
        }
        .ignoresSafeArea()
        .statusBarHidden(true)
    }
}

@main
struct DesignDemoApp: App {
    var body: some Scene {
        WindowGroup { RootView() }
    }
}
