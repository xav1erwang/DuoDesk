// Copyright 2026 DUO你电脑 contributors. SPDX-License-Identifier: Apache-2.0
import SwiftUI
import UIKit
import StreamProtocol

/// The aluminum lower half. The video view is a sibling and is never rebuilt by a mode change.
struct DuoControlDeck: View {
    @ObservedObject var client: StreamClient
    @Binding var latched: KeyModifiers
    let showSettings: () -> Void
    let showSystemKeyboard: () -> Void
    @AppStorage("duodesk.controlMode") private var mode: DuoControlMode = .combined
    @AppStorage(DuoStreamPolicy.preferredFPSKey) private var preferredFPS = DuoStreamPolicy.defaultFPS
    @State private var capsLock = false

    var body: some View {
        GeometryReader { geometry in
            let room = max(0, geometry.size.height - 138)
            let keyHeight = mode == .combined ? min(220, max(200, room * 0.61)) : max(200, room)
            VStack(spacing: 6) {
                toolbar
                if mode.hasKeyboard {
                    DuoTouchBarStrip(touchBar: client.touchBar, canBegin: { !client.inputPaused },
                                     showsMockPreview: showsMockTouchBar)
                        .frame(height: 44)
                        .layoutPriority(1)
                    DuoKeyboardView(latched: $latched, capsLock: $capsLock,
                                    inputReady: client.hasNativeDesktopVideo, send: client.sendFromKeyRow)
                        .frame(height: keyHeight)
                        .accessibilityIdentifier("duo.keyboard")
                }
                if mode.hasTrackpad {
                    glassTrackpad
                        .frame(maxWidth: mode == .combined ? min(geometry.size.width * 0.75, 540) : .infinity)
                        .frame(maxHeight: .infinity)
                        .accessibilityIdentifier("duo.trackpad")
                }
            }
            .padding(.horizontal, 12)
            .padding(.top, 6)
            .padding(.bottom, 22)
        }
        .clipped()
        .background {
            LinearGradient(colors: [Color(white: 0.76), Color(white: 0.9), Color(white: 0.75)],
                           startPoint: .topLeading, endPoint: .bottomTrailing)
                .overlay(alignment: .top) { Rectangle().fill(.white.opacity(0.65)).frame(height: 1) }
        }
        .onChange(of: mode) { _, _ in
            // No modifier may linger when the surface that shows it disappears.
            latched = []
            UISelectionFeedbackGenerator().selectionChanged()
        }
        .onChange(of: client.hasNativeDesktopVideo, initial: true) { _, _ in
            // A surface mounted during a reset must not inherit a pre-reset one-shot latch.
            latched = []
        }
    }

    private var toolbar: some View {
        HStack(spacing: 6) {
            deckButton("断开连接", symbol: "rectangle.portrait.and.arrow.right", action: client.disconnect)
            Spacer(minLength: 0)
            HStack(spacing: 3) {
                ForEach(DuoControlMode.allCases) { item in
                    Button { mode = item } label: {
                        ViewThatFits(in: .horizontal) {
                            Label(item == .combined ? "组合" : title(item), systemImage: symbol(item))
                                .labelStyle(.titleAndIcon)
                            Image(systemName: symbol(item))
                        }
                        .font(.system(size: 12, weight: .semibold))
                        .frame(maxWidth: .infinity, minHeight: 44)
                        .foregroundStyle(mode == item ? Color.white : Color(white: 0.22))
                        .background(mode == item ? Color(white: 0.20) : Color.clear,
                                    in: RoundedRectangle(cornerRadius: 8))
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel(Text(title(item)))
                    .accessibilityAddTraits(mode == item ? [.isSelected] : [])
                    .accessibilityIdentifier("duo.mode.\(item.rawValue)")
                }
            }
            .padding(3)
            .background(Color.black.opacity(0.08), in: RoundedRectangle(cornerRadius: 10))
            .overlay(RoundedRectangle(cornerRadius: 10).strokeBorder(.white.opacity(0.5)))
            .frame(maxWidth: 300)
            Spacer(minLength: 0)
            rateMenu
            deckButton("系统键盘", symbol: "keyboard.badge.ellipsis", action: showSystemKeyboard)
            deckButton("设置", symbol: "gearshape", action: showSettings)
        }
        .frame(height: 44)
    }

    private var showsMockTouchBar: Bool {
        #if DEBUG
        client.mockDiscovery
        #else
        false
        #endif
    }

    private var rateMenu: some View {
        Menu {
            Picker("目标帧率", selection: Binding(
                get: { DuoStreamPolicy.normalizedFPS(preferredFPS) },
                set: { preferredFPS = DuoStreamPolicy.normalizedFPS($0) }
            )) {
                Text("60 FPS").tag(60)
                Text("120 FPS").tag(120)
            }
        } label: {
            VStack(spacing: 1) {
                Text("\(DuoStreamPolicy.normalizedFPS(preferredFPS))")
                    .font(.system(size: 15, weight: .semibold).monospacedDigit())
                Text("FPS")
                    .font(.system(size: 9, weight: .semibold))
            }
            .foregroundStyle(Color(white: 0.22))
            .frame(width: 44, height: 44)
            .contentShape(Rectangle())
        }
        .accessibilityLabel("目标帧率")
        .accessibilityValue("\(DuoStreamPolicy.normalizedFPS(preferredFPS)) FPS")
        .accessibilityHint("选择本机目标帧率，受连接和 Mac 当前桌面时钟限制；更高目标可能需要重新连接")
        .accessibilityIdentifier("duo.rate")
    }

    private func deckButton(_ title: String, symbol: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: symbol)
                .font(.system(size: 17, weight: .medium))
                .foregroundStyle(Color(white: 0.25))
                .frame(width: 44, height: 44)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel(Text(title))
    }

    private var glassTrackpad: some View {
        TrackpadView(send: client.sendInput,
                     setPointer: { client.setOwnPointer($0, from: .trackpad) },
                     feed: { let state = client.pointerFeedState; return (state.anchor, state.reseeds) },
                     onFingers: client.trackpadFingers,
                     latched: latched, onModifiersConsumed: { latched = [] },
                     verticalSpan: nil,
                     sendGesture: { client.sendGesture($0, fingers: $1) })
            .background {
                RoundedRectangle(cornerRadius: 13)
                    .fill(LinearGradient(colors: [Color(white: 0.69), Color(white: 0.78)],
                                         startPoint: .top, endPoint: .bottom))
                    .shadow(color: .black.opacity(0.2), radius: 1, y: -1)
                    .shadow(color: .white.opacity(0.9), radius: 1, y: 1)
            }
            .clipShape(RoundedRectangle(cornerRadius: 13))
            .overlay(RoundedRectangle(cornerRadius: 13).strokeBorder(Color.black.opacity(0.2), lineWidth: 0.75))
            .accessibilityLabel("Mac 触控板")
            .accessibilityHint("单指移动，轻点单击，双指滚动或右键，双击后拖动")
    }

    private func title(_ mode: DuoControlMode) -> String {
        switch mode {
        case .keyboard: return "键盘"
        case .trackpad: return "触控板"
        case .combined: return "键盘＋触控板"
        }
    }
    private func symbol(_ mode: DuoControlMode) -> String {
        switch mode {
        case .keyboard: return "keyboard"
        case .trackpad: return "hand.draw"
        case .combined: return "laptopcomputer"
        }
    }
}

/// Displays only the real side-stream. Older Macs and hosts without a source show a clear status.
private struct DuoTouchBarStrip: View {
    @ObservedObject var touchBar: DuoTouchBarClient
    let canBegin: () -> Bool
    let showsMockPreview: Bool

    var body: some View {
        Group {
            if showsMockPreview {
                mockPreview
            } else if let surface = touchBar.status.surface {
                DuoTouchBarRemoteView(video: touchBar.video, surface: surface,
                                      canBegin: canBegin, send: touchBar.send,
                                      onAttach: touchBar.requestRefresh)
            } else {
                HStack(spacing: 7) {
                    Image(systemName: "rectangle")
                        .font(.system(size: 11, weight: .medium))
                    Text("Touch Bar")
                        .font(.system(size: 11, weight: .semibold))
                    Spacer(minLength: 8)
                    Text(touchBar.status.availability == .starting ? "正在连接" : "暂不可用")
                        .font(.system(size: 11))
                }
                .foregroundStyle(Color.white.opacity(0.72))
                .padding(.horizontal, 12)
                .accessibilityElement(children: .combine)
                .accessibilityIdentifier("duo.touchbar.unavailable")
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background {
            RoundedRectangle(cornerRadius: 9)
                .fill(LinearGradient(colors: [Color(white: 0.18), Color(white: 0.08)],
                                     startPoint: .top, endPoint: .bottom))
        }
        .modifier(TouchBarPictureChrome(showingPicture: touchBar.status.surface != nil))
        .onAppear { touchBar.setVisible(true) }
        .onDisappear { touchBar.setVisible(false) }
    }

    @ViewBuilder private var mockPreview: some View {
        #if DEBUG
        HStack(spacing: 8) {
            Text("模拟")
                .font(.system(size: 10, weight: .semibold))
                .foregroundStyle(.white.opacity(0.7))
            Text("esc")
                .font(.system(size: 12, weight: .medium))
                .frame(minWidth: 28)
            Rectangle().fill(.white.opacity(0.2)).frame(width: 1, height: 20)
            Spacer(minLength: 0)
            ForEach(["sun.min", "sun.max", "speaker.slash", "speaker.wave.1", "speaker.wave.3", "backward.fill", "play.fill", "forward.fill"], id: \.self) { symbol in
                Image(systemName: symbol)
                    .font(.system(size: 13, weight: .medium))
                    .frame(maxWidth: .infinity)
            }
        }
        .foregroundStyle(.white.opacity(0.9))
        .padding(.horizontal, 12)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Touch Bar 模拟示意，未连接 Mac，不能操作")
        .accessibilityIdentifier("duo.touchbar.mock")
        .allowsHitTesting(false)
        #else
        EmptyView()
        #endif
    }
}

private struct DuoKeyboardView: View {
    @Binding var latched: KeyModifiers
    @Binding var capsLock: Bool
    let inputReady: Bool
    let send: (InputEvent) -> Void

    var body: some View {
        GeometryReader { geometry in
            // On the cover keep actual key targets usable, rather than squeezing fourteen into 380 pt.
            let boardWidth = max(548, geometry.size.width - 12)
            let gap: CGFloat = 4
            let rowHeight = max(28, (geometry.size.height - 12 - 5 * gap) / 6)
            ScrollView(.horizontal) {
                VStack(spacing: gap) {
                    ForEach(DuoKeyboardLayout.rows.indices, id: \.self) { rowIndex in
                        let row = DuoKeyboardLayout.rows[rowIndex]
                        let widths = DuoKeyboardLayout.widths(for: row, available: boardWidth, gap: gap)
                        HStack(spacing: gap) {
                            ForEach(Array(zip(row, widths)), id: \.0.id) { key, width in
                                Button { press(key) } label: {
                                    Group {
                                        if case .inputSource = key.action {
                                            Image(systemName: "globe")
                                                .font(.system(size: 15, weight: .medium))
                                        } else {
                                            Text(legend(key))
                                                .font(.system(size: key.legend.count > 2 ? 11 : 15, weight: .medium))
                                        }
                                    }
                                    .frame(width: width, height: rowHeight)
                                    .contentShape(Rectangle())
                                }
                                .buttonStyle(DuoKeycapStyle(selected: selected(key)))
                                .buttonRepeatBehavior(isRepeatable(key) ? .enabled : .disabled)
                                .accessibilityLabel(Text(key.accessibilityName ?? legend(key)))
                                .accessibilityAddTraits(selected(key) ? [.isSelected] : [])
                                .accessibilityIdentifier("duo.key.\(key.id)")
                            }
                        }
                    }
                }
                .padding(6)
            }
            .scrollIndicators(.hidden)
            .scrollBounceBehavior(.basedOnSize)
        }
        .background(Color(white: 0.16), in: RoundedRectangle(cornerRadius: 11))
        .overlay(RoundedRectangle(cornerRadius: 11).strokeBorder(.white.opacity(0.45), lineWidth: 0.7))
        .disabled(!inputReady)
    }

    private func legend(_ key: DuoKey) -> String {
        DuoKeyboardLayout.legend(for: key, latched: latched, capsLock: capsLock)
    }
    private func selected(_ key: DuoKey) -> Bool {
        switch key.action {
        case .modifier(let bits): return latched.contains(KeyModifiers(rawValue: bits))
        case .capsLock: return capsLock
        default: return false
        }
    }
    private func isRepeatable(_ key: DuoKey) -> Bool {
        if case .key(let usage) = key.action { return usage == 0x2A || (0x4F...0x52).contains(usage) }
        return false
    }
    private func press(_ key: DuoKey) {
        guard inputReady else { return }
        switch key.action {
        case .modifier(let bits):
            let flag = KeyModifiers(rawValue: bits)
            if latched.contains(flag) { latched.remove(flag) } else { latched.insert(flag) }
        case .capsLock:
            capsLock.toggle()
            DuoKeyboardLayout.keyEvents(0x39, latched: [], capsLock: capsLock).forEach(send)
        case .inputSource:
            KeyChord.press(0x2C, with: .control).forEach(send)
            latched = []
        case .key(let usage):
            DuoKeyboardLayout.keyEvents(usage, latched: latched, capsLock: capsLock).forEach(send)
            latched = []
        }
        UIImpactFeedbackGenerator(style: .light).impactOccurred(intensity: 0.45)
    }
}

private struct DuoKeycapStyle: ButtonStyle {
    let selected: Bool
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .foregroundStyle(selected ? Color(red: 0.64, green: 0.9, blue: 0.74) : Color(white: 0.96))
            .background {
                RoundedRectangle(cornerRadius: 5)
                    .fill(LinearGradient(colors: [Color(white: configuration.isPressed ? 0.09 : 0.24),
                                                   Color(white: 0.09)], startPoint: .top, endPoint: .bottom))
                    .shadow(color: .black.opacity(0.9), radius: 0.5, y: configuration.isPressed ? 0 : 2)
            }
            .overlay(RoundedRectangle(cornerRadius: 5).strokeBorder(.white.opacity(configuration.isPressed ? 0.05 : 0.18), lineWidth: 0.5))
            .offset(y: configuration.isPressed ? 1 : 0)
    }
}
