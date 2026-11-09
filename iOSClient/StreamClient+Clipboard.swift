// Modified for DUO你电脑, 2026. See NOTICE for upstream attribution.
import Foundation
import UIKit
import UniformTypeIdentifiers
import StreamProtocol

/// Clipboard contents stay off the interface. Mac copies arrive through the background
/// subscription; device copies are read only when the person actually requests a paste.
extension StreamClient {
    static let clipboardKey = "Sill.shareClipboard"
    static var clipboardOn: Bool {
        let defaults = UserDefaults.standard
        return defaults.object(forKey: clipboardKey) == nil || defaults.bool(forKey: clipboardKey)
    }
    static let clipboardHandledKey = "Sill.clipboardHandled"
    var clipboardHandled: Int? {
        get { UserDefaults.standard.object(forKey: Self.clipboardHandledKey) as? Int }
        set { UserDefaults.standard.set(newValue, forKey: Self.clipboardHandledKey) }
    }

    func hostClipboardChanged(_ value: Int?) {
        if hostClipboard != value { hostClipboard = value }
        updateClipboardSubscription()
    }

    func updateClipboardSubscription() {
        let step = ClipboardPolicy.deviceSubscription(hostClipboard: hostClipboard, switchOn: Self.clipboardOn,
                                                      subscribed: clipboardSubscribed)
        clipboardSubscribed = step.subscribed
        switch step.send {
        case .subscribe: send(.clipboard, payload: ClipboardPolicy.subscription)
        case .stop: send(.clipboard, payload: ClipboardPolicy.stopping)
        case .none: break
        }
    }

    func clipboardSwitchChanged() { updateClipboardSubscription() }
    func clipboardMoved() {
        clipboardSubscribed = false
        updateClipboardSubscription()
    }
    func resetClipboard() {
        hostClipboard = nil
        clipboardSubscribed = false
        clipboardSent = nil
    }

    func receiveClipboard(_ payload: Data) {
        let board = UIPasteboard.general
        guard let text = ClipboardPolicy.deviceWrites(payload, switchOn: Self.clipboardOn, hostClipboard: hostClipboard,
                                                      lastSent: clipboardSent, changeCount: board.changeCount) else { return }
        board.setItems([[UTType.utf8PlainText.identifier: text]],
                       options: [.localOnly: true, .expirationDate: Date.now.addingTimeInterval(ClipboardPolicy.deviceExpiry)])
        clipboardHandled = board.changeCount
    }

    /// Command-V remains the user's paste. Queue the copied text before its key event, on the
    /// same ordered connection, so the Mac updates its clipboard before handling the shortcut.
    /// No read at connection time: iOS's clipboard access prompt cannot interrupt connecting.
    func prepareClipboardForPaste(_ event: InputEvent) {
        guard case .key(let usage, true, let modifiers) = event, usage == 0x19,
              modifiers & KeyModifiers.command.rawValue != 0,
              Self.clipboardOn, ClipboardPolicy.hostTakes(hostClipboard) else { return }
        let board = UIPasteboard.general
        guard board.changeCount != clipboardHandled, let text = board.string, !text.isEmpty else { return }
        sendClipboard([text])
    }

    func sendClipboard(_ strings: [String]) {
        guard case .send(let payload) = ClipboardPolicy.deviceSends(strings, connected: connected,
                                                                   hostClipboard: hostClipboard, switchOn: Self.clipboardOn) else { return }
        send(.clipboard, payload: payload)
        let count = UIPasteboard.general.changeCount
        if let text = strings.first(where: { !$0.isEmpty }) { clipboardSent = .init(text: text, changeCount: count) }
        clipboardHandled = count
    }
}
