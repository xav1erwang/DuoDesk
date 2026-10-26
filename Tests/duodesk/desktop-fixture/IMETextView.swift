// Copyright 2026 DUO你电脑 contributors. SPDX-License-Identifier: Apache-2.0
// Observe the native text system in this owned window; no global event taps or permission APIs.
import AppKit
import Carbon

/// A view overlay remains above both AppKit text and Metal content. It is decorative;
/// the parent fixture alone changes its state in response to an actual mouseDown.
final class IMEFixtureMarker: NSView {
    var clicked = false { didSet { needsDisplay = true } }
    override var isOpaque: Bool { false }
    override func hitTest(_ point: NSPoint) -> NSView? { nil }
    override func draw(_ dirtyRect: NSRect) {
        NSColor(calibratedRed: 0, green: 1, blue: 0, alpha: 1).setFill()
        NSRect(x: bounds.midX - 110, y: bounds.midY - 110, width: 220, height: 220).fill()
        NSColor(white: clicked ? 1 : 0.1, alpha: 1).setFill()
        NSRect(x: bounds.midX - 55, y: bounds.midY - 55, width: 110, height: 110).fill()
    }
}

final class IMETextView: NSTextView {
    static var owned: IMETextView?
    var onActualClick: (() -> Void)?
    private let reportURL: URL
    private let desiredSource: String
    private let originalSource: TISInputSource
    private let originalID: String
    private let startedAt = Date().timeIntervalSince1970
    private let contentStorage: NSTextContentStorage
    private var history: [[String: Any]] = []
    private var markedUpdates = 0
    private var restored = false
    private var selected = false
    private var timer: Timer?
    private var signals: [DispatchSourceSignal] = []
    private let writer = DispatchQueue(label: "duodesk.fixture.ime-report")

    static func sourceID(_ source: TISInputSource) -> String {
        guard let pointer = TISGetInputSourceProperty(source, kTISPropertyInputSourceID) else { return "unknown" }
        return Unmanaged<CFString>.fromOpaque(pointer).takeUnretainedValue() as String
    }

    static func makeIfRequested() -> IMETextView? {
        let env = ProcessInfo.processInfo.environment
        guard let path = env["DUODESK_FIXTURE_IME_REPORT"], let source = env["DUODESK_FIXTURE_INPUT_SOURCE_ID"] else { return nil }
        guard !FileManager.default.fileExists(atPath: path) else {
            fputs("IME fixture requires a fresh report path.\n", stderr); exit(2)
        }
        let view = IMETextView(path: path, source: source)
        owned = view
        atexit { IMETextView.owned?.restoreInputSource() }
        for sig in [SIGTERM, SIGINT, SIGHUP] {
            signal(sig, SIG_IGN)
            let signalSource = DispatchSource.makeSignalSource(signal: sig, queue: .main)
            signalSource.setEventHandler { view.restoreInputSource(); exit(128 + sig) }
            signalSource.resume(); view.signals.append(signalSource)
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 90) {
            view.restoreInputSource(); print("IME fixture watchdog completed cleanup"); exit(2)
        }
        return view
    }

    private init(path: String, source: String) {
        reportURL = URL(fileURLWithPath: path)
        desiredSource = source
        originalSource = TISCopyCurrentKeyboardInputSource().takeRetainedValue()
        originalID = Self.sourceID(originalSource)
        // The designated initializer does not construct a text system for a nil container.
        // Retain the TextKit 2 storage that owns this view's layout manager and container.
        // https://developer.apple.com/documentation/appkit/nstextview/init(frame:textcontainer:)
        let manager = NSTextLayoutManager()
        let container = NSTextContainer(size: NSSize(width: 1000, height: CGFloat.greatestFiniteMagnitude))
        container.widthTracksTextView = true
        manager.textContainer = container
        contentStorage = NSTextContentStorage()
        contentStorage.textStorage = NSTextStorage(string: "")
        contentStorage.addTextLayoutManager(manager)
        super.init(frame: .zero, textContainer: container)
        isRichText = false
        isEditable = true
        isSelectable = true
        isHorizontallyResizable = false
        isVerticallyResizable = false
        font = .monospacedSystemFont(ofSize: 22, weight: .regular)
        isAutomaticSpellingCorrectionEnabled = false
        isAutomaticQuoteSubstitutionEnabled = false
        isAutomaticTextReplacementEnabled = false
        backgroundColor = .textBackgroundColor
        textColor = .textColor
        record("created")
        let timer = Timer(timeInterval: 0.25, repeats: true) { [weak self] _ in
            self?.configureInputSource(); self?.record("state")
        }
        self.timer = timer
        RunLoop.main.add(timer, forMode: .common)
    }
    required init?(coder: NSCoder) { fatalError("not from a nib") }

    func focusForTest() {
        guard let window, window.makeFirstResponder(self) else {
            record("focus-failed"); return
        }
        configureInputSource()
    }
    override func becomeFirstResponder() -> Bool {
        let accepted = super.becomeFirstResponder()
        if accepted { DispatchQueue.main.async { [weak self] in self?.configureInputSource() } }
        return accepted
    }
    private func configureInputSource() {
        guard !selected, window?.firstResponder === self, window?.isKeyWindow == true,
              NSApp.isActive, let context = inputContext else { return }
        guard context.keyboardInputSources?.contains(desiredSource) == true else {
            record("source-not-enabled"); return
        }
        // Use only an already enabled input source in this text view's own input context.
        context.activate()
        context.selectedKeyboardInputSource = desiredSource
        selected = true
        record("focused")
    }
    func geometryChanged() { record("geometry") }
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    override func mouseDown(with event: NSEvent) {
        record("mouse-down-received")
        super.mouseDown(with: event)
        focusForTest()
        onActualClick?()
    }

    override func setMarkedText(_ string: Any, selectedRange: NSRange, replacementRange: NSRange) {
        super.setMarkedText(string, selectedRange: selectedRange, replacementRange: replacementRange)
        markedUpdates += 1
        record("marked")
    }
    override func insertText(_ insertString: Any, replacementRange: NSRange) {
        super.insertText(insertString, replacementRange: replacementRange)
        record("inserted")
    }
    override func unmarkText() { super.unmarkText(); record("unmarked") }
    override func keyDown(with event: NSEvent) { super.keyDown(with: event); record("key-down") }
    override func keyUp(with event: NSEvent) { super.keyUp(with: event); record("key-up") }

    private func record(_ kind: String, flush: Bool = false) {
        let markedRange = self.markedRange()
        let text = string as NSString
        let validMarked = hasMarkedText() && markedRange.location != NSNotFound
            && NSMaxRange(markedRange) <= text.length
        var clickX = -1.0, clickY = -1.0
        if let window, let screen = window.screen, !screen.frame.isEmpty {
            let point = window.convertPoint(toScreen: convert(NSPoint(x: bounds.midX, y: bounds.midY), to: nil))
            clickX = (point.x - screen.frame.minX) / screen.frame.width
            clickY = (screen.frame.maxY - point.y) / screen.frame.height
        }
        let state: [String: Any] = [
            "kind": kind, "unix": Date().timeIntervalSince1970, "text": string,
            "marked": validMarked ? text.substring(with: markedRange) : "",
            "committed": validMarked ? text.replacingCharacters(in: markedRange, with: "") : string,
            "hasMarkedText": validMarked, "markedUpdates": markedUpdates,
            "inputSource": Self.sourceID(TISCopyCurrentKeyboardInputSource().takeRetainedValue()),
            "clickX": clickX, "clickY": clickY,
            "onActiveSpace": window?.isOnActiveSpace ?? false,
            "nativeTextStorageAvailable": contentStorage.textStorage != nil,
            "windowVisible": window?.isVisible ?? false,
            "windowKey": window?.isKeyWindow ?? false,
            "applicationActive": NSApp.isActive,
            "focused": window?.isKeyWindow == true && window?.firstResponder === self && NSApp.isActive
        ]
        // Keep composition events when an idle fixture remains open: periodic focus/source
        // samples must not evict the marked-text evidence collected earlier in the run.
        if kind != "state" {
            history.append(state)
            if history.count > 200 { history.removeFirst(history.count - 200) }
        }
        let snapshot = kind == "state" ? history + [state] : history
        let report: [String: Any] = ["processID": getpid(), "startedAt": startedAt,
                                  "originalInputSource": originalID, "desiredInputSource": desiredSource,
                                  "restored": restored, "states": snapshot]
        guard let data = try? JSONSerialization.data(withJSONObject: report, options: [.prettyPrinted, .sortedKeys]) else { return }
        let url = reportURL
        let write = { try? data.write(to: url, options: .atomic) }
        if flush { writer.sync { write() } } else { writer.async { write() } }
    }

    private func restoreInputSource() {
        timer?.invalidate(); timer = nil
        let current = Self.sourceID(TISCopyCurrentKeyboardInputSource().takeRetainedValue())
        if selected, current == desiredSource {
            inputContext?.discardMarkedText()
            inputContext?.selectedKeyboardInputSource = originalID
            _ = TISSelectInputSource(originalSource)
        }
        // Do not overwrite a different source the user selected while this fixture ran.
        restored = Self.sourceID(TISCopyCurrentKeyboardInputSource().takeRetainedValue()) == originalID
        record("cleanup", flush: true)
        print("IME fixture original input source restored=\(restored)")
    }
}
