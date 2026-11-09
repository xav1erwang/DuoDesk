// Copyright 2026 DUO你电脑 contributors. SPDX-License-Identifier: Apache-2.0
import SwiftUI
import UIKit
import StreamProtocol

/// The aluminum lower half. The video view is a sibling and is never rebuilt by a mode change.
struct DuoControlDeck: View {
    @Environment(\.colorScheme) private var colorScheme
    @Environment(\.colorSchemeContrast) private var contrast
    @ObservedObject var client: StreamClient
    @Binding var latched: KeyModifiers
    let showSettings: () -> Void
    let showSystemKeyboard: () -> Void
    let showCleanImage: () -> Void
    @AppStorage("duodesk.controlMode") private var mode: DuoControlMode = .combined
    @AppStorage(DuoStreamPolicy.preferredFPSKey) private var preferredFPS = DuoStreamPolicy.defaultFPS
    @State private var capsLock = false
    @State private var keyboardTouches = DuoKeyboardTouches()

    private var appearance: DuoDeckAppearance {
        DuoDeckAppearance(dark: colorScheme == .dark, highContrast: contrast == .increased)
    }

    var body: some View {
        GeometryReader { geometry in
            // The compact toolbar and safe bottom inset leave the rest to the controls.
            let room = max(0, geometry.size.height - 66 - (mode == .combined ? 6 : 0))
            let combinedHeight = min(min(240, max(200, room * 0.62)), max(0, room - min(70, room * 0.3)))
            let keyHeight = mode == .combined ? combinedHeight : room
            VStack(spacing: 0) {
                toolbar
                    // Center the 34-point controls in their 44-point header, with 5 points
                    // above and below. The keyboard and trackpad keep their existing frames.
                    .frame(height: 44)
                VStack(spacing: 6) {
                    if mode.hasKeyboard {
                        DuoKeyboardView(capsLock: $capsLock, keyboardTouches: $keyboardTouches,
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
            }
            .padding(.horizontal, 12)
            .padding(.bottom, 22)
        }
        .clipped()
        .background {
            LinearGradient(colors: appearance.chassis,
                           startPoint: .topLeading, endPoint: .bottomTrailing)
                .overlay(alignment: .top) { Rectangle().fill(appearance.rim).frame(height: 1) }
        }
        .onChange(of: mode) { _, _ in
            latched = []
            releaseKeyboard()
            UISelectionFeedbackGenerator().selectionChanged()
        }
        .onChange(of: client.hasNativeDesktopVideo, initial: true) { _, _ in
            latched = []
            releaseKeyboard()
        }
        .onDisappear { releaseKeyboard() }
    }

    private func releaseKeyboard() {
        keyboardTouches.reset(capsLock: capsLock).forEach(client.sendFromKeyRow)
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
                        .frame(maxWidth: .infinity, minHeight: 30)
                        .foregroundStyle(mode == item ? appearance.selectedInk : appearance.ink)
                        .background(mode == item ? appearance.selection : Color.clear,
                                    in: RoundedRectangle(cornerRadius: 8))
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel(Text(title(item)))
                    .accessibilityAddTraits(mode == item ? [.isSelected] : [])
                    .accessibilityIdentifier("duo.mode.\(item.rawValue)")
                }
            }
            .padding(2)
            .background(appearance.segmentWell, in: RoundedRectangle(cornerRadius: 10))
            .overlay(RoundedRectangle(cornerRadius: 10).strokeBorder(appearance.rim))
            .frame(maxWidth: 300)
            Spacer(minLength: 0)
            rateMenu
            deckButton("纯净图像", symbol: "arrow.up.left.and.arrow.down.right", action: showCleanImage)
            deckButton("系统键盘", symbol: "keyboard.badge.ellipsis", action: showSystemKeyboard)
            deckButton("设置", symbol: "gearshape", action: showSettings)
        }
        .frame(height: 34)
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
            VStack(spacing: 0) {
                Text("目标帧率")
                    .font(.system(size: 8, weight: .medium))
                    .lineLimit(1)
                Text("\(DuoStreamPolicy.normalizedFPS(preferredFPS)) FPS")
                    .font(.system(size: 11, weight: .semibold).monospacedDigit())
                    .lineLimit(1)
                    .minimumScaleFactor(0.8)
            }
            .foregroundStyle(appearance.ink)
            .frame(width: 48, height: 34)
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
                .font(.system(size: 16, weight: .medium))
                .foregroundStyle(appearance.ink)
                .frame(width: 40, height: 34)
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
                     latched: [], onModifiersConsumed: {},
                     verticalSpan: nil,
                     pointerFrameSize: client.videoSize,
                     sendGesture: { client.sendGesture($0, fingers: $1) })
            .background {
                RoundedRectangle(cornerRadius: 13)
                    .fill(LinearGradient(colors: appearance.trackpad,
                                         startPoint: .top, endPoint: .bottom))
                    .shadow(color: .black.opacity(appearance.dark ? 0.65 : 0.2), radius: 1, y: -1)
                    .shadow(color: appearance.rim, radius: 1, y: 1)
            }
            .clipShape(RoundedRectangle(cornerRadius: 13))
            .overlay(RoundedRectangle(cornerRadius: 13).strokeBorder(appearance.trackpadEdge,
                                                                 lineWidth: appearance.highContrast ? 1.25 : 0.75))
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

private struct DuoKeyboardView: View {
    @Environment(\.colorScheme) private var colorScheme
    @Environment(\.colorSchemeContrast) private var contrast
    @Binding var capsLock: Bool
    @Binding var keyboardTouches: DuoKeyboardTouches
    let inputReady: Bool
    let send: (InputEvent) -> Void

    private var activeModifiers: KeyModifiers { keyboardTouches.held }

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
                                .buttonStyle(DuoKeycapStyle(selected: selected(key), pressed: isDown(key)))
                                .accessibilityLabel(Text(key.accessibilityName ?? legend(key)))
                                .accessibilityAddTraits(selected(key) ? [.isSelected] : [])
                                .accessibilityIdentifier("duo.key.\(key.id)")
                                .accessibilityHidden(key.heldUsage != nil)
                                .overlay {
                                    if let usage = key.heldUsage {
                                        DuoKeyTouchView(label: key.accessibilityName ?? legend(key),
                                            identifier: "duo.key.\(key.id)", selected: selected(key), enabled: inputReady,
                                            repeatable: isRepeatable(key),
                                            began: { keyBegan(usage) }, ended: { keyEnded(usage) },
                                            repeated: { keyRepeated(usage) })
                                    }
                                }
                            }
                        }
                    }
                }
                .padding(6)
            }
            .scrollIndicators(.hidden)
            .scrollBounceBehavior(.basedOnSize)
        }
        .background(Color(white: colorScheme == .dark ? 0.035 : 0.16), in: RoundedRectangle(cornerRadius: 11))
        .overlay(RoundedRectangle(cornerRadius: 11)
            .strokeBorder(.white.opacity(contrast == .increased ? 0.65 : colorScheme == .dark ? 0.14 : 0.45), lineWidth: 0.7))
        .disabled(!inputReady)
    }

    private func legend(_ key: DuoKey) -> String {
        DuoKeyboardLayout.legend(for: key, latched: activeModifiers, capsLock: capsLock)
    }
    private func selected(_ key: DuoKey) -> Bool {
        switch key.action {
        case .modifier(let usage): return keyboardTouches.isDown(usage)
        case .capsLock: return capsLock
        default: return false
        }
    }
    private func isRepeatable(_ key: DuoKey) -> Bool {
        if case .key(let usage) = key.action { return usage == 0x2A || (0x4F...0x52).contains(usage) }
        return false
    }
    private func isDown(_ key: DuoKey) -> Bool {
        key.heldUsage.map { keyboardTouches.isDown($0) } ?? false
    }
    private func keyBegan(_ usage: UInt16) {
        guard inputReady else { return }
        guard let event = keyboardTouches.began(usage, capsLock: capsLock) else { return }
        send(event)
        UIImpactFeedbackGenerator(style: .light).impactOccurred(intensity: 0.45)
    }
    private func keyEnded(_ usage: UInt16) {
        if let event = keyboardTouches.ended(usage, capsLock: capsLock) { send(event) }
    }
    private func keyRepeated(_ usage: UInt16) {
        guard inputReady, let event = keyboardTouches.repeated(usage, capsLock: capsLock) else { return }
        send(event)
    }
    private func press(_ key: DuoKey) {
        guard inputReady else { return }
        switch key.action {
        case .modifier, .key: return
        case .capsLock:
            capsLock.toggle()
            if let event = keyboardTouches.began(0x39, capsLock: capsLock) { send(event) }
            if let event = keyboardTouches.ended(0x39, capsLock: capsLock) { send(event) }
        case .inputSource:
            guard !keyboardTouches.isDown(0x2C) else { return }
            let needsControl = !activeModifiers.contains(.control)
            if needsControl, let event = keyboardTouches.began(0xE0, capsLock: capsLock) { send(event) }
            if let event = keyboardTouches.began(0x2C, capsLock: capsLock) { send(event) }
            if let event = keyboardTouches.ended(0x2C, capsLock: capsLock) { send(event) }
            if needsControl, let event = keyboardTouches.ended(0xE0, capsLock: capsLock) { send(event) }
        }
        UIImpactFeedbackGenerator(style: .light).impactOccurred(intensity: 0.45)
    }
}

private struct DuoKeyTouchView: UIViewRepresentable {
    let label: String
    let identifier: String
    let selected: Bool
    let enabled: Bool
    let repeatable: Bool
    let began: () -> Void
    let ended: () -> Void
    let repeated: () -> Void

    func makeUIView(context: Context) -> DuoKeyTouchControl { DuoKeyTouchControl() }

    func updateUIView(_ view: DuoKeyTouchControl, context: Context) {
        view.accessibilityLabel = label
        view.accessibilityIdentifier = identifier
        view.accessibilityTraits = selected ? [.button, .selected] : .button
        view.setKeyEnabled(enabled)
        view.repeatable = repeatable
        view.began = began
        view.ended = ended
        view.repeated = repeated
    }
}

private final class DuoKeyTouchControl: UIControl {
    var began: () -> Void = {}
    var ended: () -> Void = {}
    var repeated: () -> Void = {}
    var repeatable = false
    private var active = false
    private var repeatTimer: Timer?

    override init(frame: CGRect) {
        super.init(frame: frame)
        isAccessibilityElement = true
        addTarget(self, action: #selector(touchBegan), for: .touchDown)
        addTarget(self, action: #selector(touchEnded), for: .touchUpInside)
        addTarget(self, action: #selector(touchCancelled), for: [.touchUpOutside, .touchCancel])
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    func setKeyEnabled(_ enabled: Bool) {
        if !enabled {
            active = false
            stopRepeating()
        }
        isEnabled = enabled
    }

    override func didMoveToWindow() {
        super.didMoveToWindow()
        if window == nil {
            active = false
            stopRepeating()
        }
        var ancestor = superview
        while let view = ancestor {
            if let scroll = view as? UIScrollView {
                // Deliver key touches immediately while retaining scroll cancellation.
                scroll.delaysContentTouches = false
                break
            }
            ancestor = view.superview
        }
    }

    @objc private func touchBegan() {
        guard !active else { return }
        active = true
        began()
        guard repeatable else { return }
        let timer = Timer(timeInterval: 0.45, repeats: false) { [weak self] _ in
            guard let self, self.active else { return }
            self.repeated()
            let repeating = Timer(timeInterval: 0.07, repeats: true) { [weak self] _ in self?.repeated() }
            self.repeatTimer = repeating
            RunLoop.main.add(repeating, forMode: .common)
        }
        repeatTimer = timer
        RunLoop.main.add(timer, forMode: .common)
    }
    @objc private func touchEnded() { finishTouch() }
    @objc private func touchCancelled() { finishTouch() }

    private func stopRepeating() {
        repeatTimer?.invalidate()
        repeatTimer = nil
    }

    private func finishTouch() {
        guard active else { return }
        active = false
        stopRepeating()
        ended()
    }

    override func accessibilityActivate() -> Bool {
        guard isEnabled else { return false }
        began()
        ended()
        return true
    }
}

private struct DuoKeycapStyle: ButtonStyle {
    @Environment(\.colorScheme) private var colorScheme
    @Environment(\.colorSchemeContrast) private var contrast
    let selected: Bool
    let pressed: Bool
    func makeBody(configuration: Configuration) -> some View {
        let pressed = pressed || configuration.isPressed
        let dark = colorScheme == .dark
        let ink = selected ? Color(red: 0.64, green: 0.98, blue: 0.77) : Color(white: dark ? 1 : 0.96)
        configuration.label
            .foregroundStyle(ink)
            // The backlight belongs to the legends; the key face stays dark.
            .shadow(color: dark ? ink.opacity(pressed ? 0.65 : 0.35) : .clear, radius: pressed ? 3 : 1.5)
            .background {
                RoundedRectangle(cornerRadius: 5)
                    .fill(LinearGradient(colors: [Color(white: pressed ? 0.07 : dark ? 0.16 : 0.24),
                                                   Color(white: dark ? 0.065 : 0.09)], startPoint: .top, endPoint: .bottom))
                    .shadow(color: .black.opacity(0.9), radius: 0.5, y: pressed ? 0 : 2)
            }
            .overlay(RoundedRectangle(cornerRadius: 5)
                .strokeBorder(.white.opacity(contrast == .increased ? 0.65 : pressed ? 0.28 : 0.18), lineWidth: 0.5))
            .overlay(alignment: .topLeading) {
                if selected {
                    Circle().fill(ink).frame(width: 3, height: 3).padding(4)
                        .accessibilityHidden(true)
                }
            }
            .offset(y: pressed ? 1 : 0)
    }
}

/// A single material palette keeps every deck mode in the same system appearance.
private struct DuoDeckAppearance {
    let dark: Bool
    let highContrast: Bool
    var chassis: [Color] { dark ? [Color(white: 0.13), Color(white: 0.19), Color(white: 0.105)]
                                : [Color(white: 0.76), Color(white: 0.9), Color(white: 0.75)] }
    var trackpad: [Color] { dark ? [Color(white: 0.17), Color(white: 0.205)]
                                 : [Color(white: 0.69), Color(white: 0.78)] }
    var ink: Color { Color(white: dark ? 0.94 : 0.22) }
    var selectedInk: Color { .white }
    var selection: Color { Color(white: dark ? 0.36 : 0.20) }
    var segmentWell: Color { .black.opacity(dark ? 0.28 : 0.08) }
    var rim: Color { .white.opacity(highContrast ? 0.65 : dark ? 0.16 : 0.5) }
    var trackpadEdge: Color { dark ? .white.opacity(highContrast ? 0.65 : 0.22) : .black.opacity(0.2) }
}
