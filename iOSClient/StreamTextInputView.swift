// Copyright 2026 DUO你电脑 contributors. SPDX-License-Identifier: Apache-2.0
import UIKit

/// UIKit owns positions, selection, and marked text. Only confirmed text leaves this buffer.
/// A UIKeyInput-only responder cannot offer all of the system's language keyboards.
final class StreamTextInputView: UITextView {
    var commit: (String) -> Void = { _ in }
    var remoteDelete: () -> Void = {}
    var makeInputFence: () -> (() -> Bool) = { { false } }
    var prepareToBecome: () -> Bool = { false }
    var didBecome: (Bool, Bool) -> Void = { _, _ in }
    var didResign: () -> Void = {}
    var routePresses: (Set<UIPress>, Bool, String) -> Set<UIPress> = { presses, _, _ in presses }
    var suppressKeyboard = false {
        didSet { inputView = suppressKeyboard ? emptyKeyboard : nil }
    }
    private lazy var emptyKeyboard = UIView(frame: .zero)
    private var compositionFence: (() -> Bool)?
    private var mutationDepth = 0
    private var discarding = false

    init() {
        super.init(frame: .zero, textContainer: nil)
        backgroundColor = .clear
        textColor = .clear
        tintColor = .clear
        isOpaque = false
        isScrollEnabled = false
        clipsToBounds = true
        isAccessibilityElement = false
        accessibilityElementsHidden = true
        autocorrectionType = .no
        autocapitalizationType = .none
        smartQuotesType = .no
        smartDashesType = .no
        smartInsertDeleteType = .no
        spellCheckingType = .no
    }
    required init?(coder: NSCoder) { fatalError("not from a nib") }

    // The surrounding overlay owns all touches; this small native text view owns only the keyboard.
    override func hitTest(_ point: CGPoint, with event: UIEvent?) -> UIView? { nil }
    override var editingInteractionConfiguration: UIEditingInteractionConfiguration { .none }
    // The remote document may contain text even when this local composition buffer is empty.
    override var hasText: Bool { true }
    override func canPerformAction(_ action: Selector, withSender sender: Any?) -> Bool { false }

    override func becomeFirstResponder() -> Bool {
        let previousAutomatic = prepareToBecome()
        let became = super.becomeFirstResponder()
        didBecome(became, previousAutomatic)
        return became
    }
    override func resignFirstResponder() -> Bool {
        // Leaving the stream or opening settings must not confirm an unfinished candidate.
        discardComposition()
        let resigned = super.resignFirstResponder()
        if resigned { didResign() }
        return resigned
    }

    func discardComposition() {
        guard !discarding else { return }
        discarding = true
        super.unmarkText()
        text = ""
        undoManager?.removeAllActions()
        compositionFence = nil
        discarding = false
    }

    private func mutate(_ change: () -> Void) {
        guard !discarding else { change(); return }
        guard isFirstResponder, window != nil else { discardComposition(); return }
        if compositionFence == nil { compositionFence = makeInputFence() }
        guard compositionFence?() == true else { discardComposition(); return }
        mutationDepth += 1
        change()
        mutationDepth -= 1
        guard mutationDepth == 0, markedTextRange == nil else { return }
        let confirmed = text ?? ""
        let stillCurrent = isFirstResponder && window != nil && compositionFence?() == true
        discardComposition()
        if stillCurrent, !confirmed.isEmpty { commit(confirmed) }
    }

    override func insertText(_ text: String) { mutate { super.insertText(text) } }
    override func setMarkedText(_ markedText: String?, selectedRange: NSRange) {
        mutate { super.setMarkedText(markedText, selectedRange: selectedRange) }
    }
    override func setAttributedMarkedText(_ markedText: NSAttributedString?, selectedRange: NSRange) {
        mutate { super.setAttributedMarkedText(markedText, selectedRange: selectedRange) }
    }
    override func unmarkText() { mutate { super.unmarkText() } }
    override func replace(_ range: UITextRange, withText text: String) {
        mutate { super.replace(range, withText: text) }
    }
    override func deleteBackward() {
        guard isFirstResponder, window != nil else { discardComposition(); return }
        if markedTextRange != nil || !(text ?? "").isEmpty {
            mutate { super.deleteBackward() }
        } else if makeInputFence()() { remoteDelete() }
    }

    override func pressesBegan(_ presses: Set<UIPress>, with event: UIPressesEvent?) {
        let unhandled = routePresses(presses, true, "pressesBegan")
        if !unhandled.isEmpty { super.pressesBegan(unhandled, with: event) }
    }
    override func pressesEnded(_ presses: Set<UIPress>, with event: UIPressesEvent?) {
        let unhandled = routePresses(presses, false, "pressesEnded")
        if !unhandled.isEmpty { super.pressesEnded(unhandled, with: event) }
    }
    override func pressesCancelled(_ presses: Set<UIPress>, with event: UIPressesEvent?) {
        let unhandled = routePresses(presses, false, "pressesCancelled")
        if !unhandled.isEmpty { super.pressesCancelled(unhandled, with: event) }
    }
}
