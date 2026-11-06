// Copyright 2026 DUO你电脑 contributors. SPDX-License-Identifier: Apache-2.0
import SwiftUI
import SillHostCore

/// The status item's panel: the same entries the menu builder makes, drawn as the app's
/// own glass card instead of AppKit's menu. The NSMenu it replaces could carry our words
/// but not our type, spacing or colour — and the card at its top was already ours, so the
/// two never quite matched.
///
/// Behaviour is the builder's, unchanged: every row is one `MenuEntry`, and tapping it
/// hands the entry's action back to the controller, which performs it exactly as the menu
/// item did.
struct StatusPanel: View {
    let presentation: StatusPresentation
    let entries: [MenuEntry]
    let action: (MenuEntry.Action) -> Void
    let dismiss: () -> Void

    @Environment(\.colorScheme) private var scheme

    private var theme: MacTheme { MacTheme(scheme) }

    /// The card entry is drawn as this panel's header; the rest follow it.
    private var rows: [MenuEntry] {
        entries.filter { $0.kind != .card }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header

            ForEach(Array(rows.enumerated()), id: \.offset) { _, entry in
                switch entry.kind {
                case .separator:
                    Rectangle()
                        .fill(theme.strokeSoft)
                        .frame(height: 1)
                        .padding(.horizontal, 12)
                        .padding(.vertical, 6)
                case .card:
                    EmptyView()
                case .item:
                    row(entry)
                }
            }
        }
        .padding(10)
        .frame(width: 320)
        .background {
            ZStack {
                RoundedRectangle(cornerRadius: 18, style: .continuous).fill(.ultraThinMaterial)
                RoundedRectangle(cornerRadius: 18, style: .continuous)
                    .fill(LinearGradient(colors: [theme.panelTop, theme.panelBottom],
                                         startPoint: .topLeading, endPoint: .bottomTrailing))
                RoundedRectangle(cornerRadius: 18, style: .continuous)
                    .strokeBorder(theme.stroke, lineWidth: 1)
            }
        }
        .clipShape(RoundedRectangle(cornerRadius: 18, style: .continuous))
    }

    // MARK: Header

    private var header: some View {
        HStack(alignment: .top, spacing: 10) {
            Circle()
                .fill(glyphColor)
                .frame(width: 8, height: 8)
                .padding(.top, 6)
                .shadow(color: presentation.glyph == .streaming ? glyphColor.opacity(0.7) : .clear,
                        radius: 6)

            VStack(alignment: .leading, spacing: 2) {
                Text(presentation.header)
                    .font(.system(size: 14, weight: .semibold))
                    .foregroundStyle(theme.ink)
                if let subtitle = presentation.subtitle {
                    Text(subtitle)
                        .font(.system(size: 11.5))
                        .foregroundStyle(theme.muted)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 8)
        .padding(.top, 6)
        .padding(.bottom, 10)
    }

    private var glyphColor: Color {
        switch presentation.glyph {
        case .streaming: return theme.current
        case .attention: return .orange
        case .connected: return theme.accent
        default: return theme.muted.opacity(0.6)
        }
    }

    // MARK: Rows

    @ViewBuilder private func row(_ e: MenuEntry) -> some View {
        PanelRow(
            title: e.title,
            subtitle: e.subtitle,
            symbol: e.symbol,
            key: e.key,
            checked: e.checked,
            attention: e.attention,
            enabled: e.enabled,
            theme: theme,
            perform: {
                guard case .none = e.action else {
                    dismiss()
                    action(e.action)
                    return
                }
            }
        )
    }
}

/// One row: symbol, title, and a key or check at the trailing edge. Hover lifts it.
private struct PanelRow: View {
    let title: String
    let subtitle: String?
    let symbol: String?
    let key: String
    let checked: Bool
    let attention: Bool
    let enabled: Bool
    let theme: MacTheme
    let perform: () -> Void

    @State private var hovering = false

    var body: some View {
        Button(action: perform) {
            HStack(spacing: 10) {
                if attention {
                    Image(systemName: "exclamationmark.triangle.fill")
                        .foregroundStyle(.orange)
                        .frame(width: 18)
                } else if let symbol {
                    Image(systemName: symbol)
                        .foregroundStyle(theme.muted)
                        .frame(width: 18)
                }
                VStack(alignment: .leading, spacing: 1) {
                    Text(title)
                        .font(.system(size: 13))
                        .foregroundStyle(enabled ? theme.ink : theme.muted.opacity(0.55))
                    if let subtitle {
                        Text(subtitle)
                            .font(.system(size: 11))
                            .foregroundStyle(theme.muted)
                            .lineLimit(2)
                    }
                }
                Spacer(minLength: 0)
                if checked {
                    Image(systemName: "checkmark")
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundStyle(theme.ink)
                } else if !key.isEmpty {
                    Text("⌘\(key.uppercased())")
                        .font(.system(size: 11))
                        .foregroundStyle(theme.muted.opacity(0.8))
                }
            }
            .padding(.horizontal, 8)
            .padding(.vertical, 7)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background {
                RoundedRectangle(cornerRadius: 9, style: .continuous)
                    .fill(hovering && enabled ? theme.ink.opacity(theme.dark ? 0.08 : 0.05) : .clear)
            }
            .contentShape(RoundedRectangle(cornerRadius: 9, style: .continuous))
        }
        .buttonStyle(.plain)
        .disabled(!enabled)
        .onHover { hovering = $0 }
    }
}
