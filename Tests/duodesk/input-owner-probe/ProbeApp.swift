// Copyright 2026 DUO你电脑 contributors. SPDX-License-Identifier: Apache-2.0
// Real production overlay/proxy in an owned UIKit window. Input is collected in memory, never sent.
import UIKit
import StreamProtocol

@main
final class ProbeApp: UIResponder, UIApplicationDelegate {
    func application(_ application: UIApplication, configurationForConnecting session: UISceneSession,
                     options: UIScene.ConnectionOptions) -> UISceneConfiguration {
        let config = UISceneConfiguration(name: "Input owner checks", sessionRole: session.role)
        config.delegateClass = ProbeScene.self
        return config
    }
}

final class ProbeScene: UIResponder, UIWindowSceneDelegate {
    var window: UIWindow?
    private var rows: [[String: Any]] = []
    private var events: [InputEvent] = []
    private var ownChanges: [Bool] = []
    private var consumed = 0

    func scene(_ scene: UIScene, willConnectTo session: UISceneSession, options: UIScene.ConnectionOptions) {
        guard let scene = scene as? UIWindowScene else { return }
        let window = UIWindow(windowScene: scene)
        window.rootViewController = UIViewController()
        window.rootViewController?.view.backgroundColor = .systemBackground
        window.makeKeyAndVisible()
        self.window = window
        Task { @MainActor in
            try? await Task.sleep(for: .milliseconds(200))
            await self.checks()
        }
    }
    private func check(_ name: String, _ passed: Bool) { rows.append(["name": name, "passed": passed]) }
    private func overlay(_ proxy: InputOverlayProxy, surface: UIView) -> InputOverlayView {
        let view = InputOverlayView(frame: surface.bounds)
        view.keyboardProxy = proxy
        proxy.view = view
        view.makeTextInputFence = { { true } } // This probe owns input routing, not decoded-video readiness.
        view.send = { [weak self] in self?.events.append($0) }
        view.onModifiersConsumed = { [weak self] in self?.consumed += 1 }
        surface.addSubview(view)
        return view
    }
    private func settle() async { try? await Task.sleep(for: .milliseconds(100)) }
    private func checks() async {
        guard let surface = window?.rootViewController?.view else { return }
        let proxy = InputOverlayProxy()
        proxy.onOwnChange = { [weak self] in self?.ownChanges.append($0) }
        let view = overlay(proxy, surface: surface)
        await settle()
        check("current overlay joins the policy", proxy.policy.onScreen && !view.holdsKeyboard)
        proxy.setKeyboard(shown: true)
        check("keyboard button gives native child first responder", view.holdsKeyboard && view.textInput.isFirstResponder && !view.isFirstResponder)
        check("policy reports the person's keyboard", proxy.policy.isOwn && ownChanges.last == true)
        check("native child continues through the overlay responder chain", view.textInput.next === view)
        check("native child cannot intercept pointer hit testing", view.hitTest(CGPoint(x: 1, y: 1), with: nil) === view)
        view.textInput.setMarkedText("nihao", selectedRange: NSRange(location: 5, length: 0))
        check("overlay sends no provisional Pinyin", events.isEmpty)
        view.textInput.insertText("你好")
        check("overlay sends confirmed Chinese once", events == [.text("你好")])
        events = []
        view.latchedModifiers = .command
        view.textInput.insertText("s")
        check("native text still uses the production latched shortcut path", events == KeyChord.press(0x16, with: .command))
        check("confirmation consumes its modifier latch once", view.latchedModifiers.isEmpty && consumed == 1)
        events = []
        view.latchedModifiers = .shift
        view.textInput.insertText("\n")
        check("native return preserves the one-shot Shift chord", events == KeyChord.press(0x28, with: .shift))
        events = []
        let escape = view.keyCommands?.first { $0.input == UIKeyCommand.inputEscape && $0.modifierFlags.isEmpty }
        if let escape, let action = escape.action {
            let routed = UIApplication.shared.sendAction(action, to: nil, from: escape, for: nil)
            check("untargeted Escape action reaches overlay from native child", routed && events == KeyChord.press(HIDKey.escape, with: []))
            events = []
            view.textInput.setMarkedText("候选", selectedRange: NSRange(location: 2, length: 0))
            check("remote Escape commands disappear during native composition", view.keyCommands?.contains { $0.input == UIKeyCommand.inputEscape } != true)
            _ = UIApplication.shared.sendAction(action, to: nil, from: escape, for: nil)
            check("a stale Escape command cannot reach the Mac while composing", events.isEmpty)
        } else { check("an Escape command is registered for the native child's chain", false) }
        proxy.setKeyboard(shown: false)
        proxy.update(takers: [.settings])
        check("settings releases the native child and policy", !view.holdsKeyboard && proxy.policy.hold == .none)
        check("settings discards unfinished composition without sending", events.isEmpty && view.textInput.markedTextRange == nil)
        view.textInput.insertText("late")
        check("old overlay callbacks stay silent after dismissal", events.isEmpty)
        proxy.update(takers: [])
        proxy.setKeyboard(shown: true)
        check("closing settings can restore the person's keyboard", view.holdsKeyboard && proxy.policy.isOwn)
        proxy.update(attached: true)
        proxy.toggleKeyboard()
        check("hardware hold suppresses native software keyboard in place", view.holdsKeyboard && proxy.policy.hold == .automatic && view.textInput.inputView != nil)
        proxy.toggleKeyboard()
        check("keyboard button restores native software keyboard in place", view.holdsKeyboard && proxy.policy.isOwn && view.textInput.inputView == nil)
        proxy.setKeyboard(shown: false)
        proxy.update(takers: [.settings])
        proxy.update(takers: [])
        check("closing a taker restores automatic hardware ownership", view.holdsKeyboard && proxy.policy.hold == .automatic && !proxy.policy.isOwn)
        proxy.update(attached: false)
        check("hardware detach releases only automatic ownership", !view.holdsKeyboard && proxy.policy.hold == .none)
        proxy.setKeyboard(shown: true)
        let other = UITextField(frame: CGRect(x: 30, y: 120, width: 200, height: 50))
        surface.addSubview(other)
        _ = other.becomeFirstResponder()
        check("another native field updates the real overlay policy", other.isFirstResponder && !view.holdsKeyboard && !proxy.policy.isOwn)
        events = []
        if let escape, let action = escape.action { _ = UIApplication.shared.sendAction(action, to: nil, from: escape, for: nil) }
        check("Escape in another field cannot reach the old stream", events.isEmpty)
        other.removeFromSuperview()
        proxy.update(attached: true)
        await settle()
        let replacement = overlay(proxy, surface: surface)
        await settle()
        check("replacement overlay takes automatic native ownership", replacement.holdsKeyboard && proxy.policy.hold == .automatic)
        view.removeFromSuperview()
        check("old overlay teardown cannot release replacement ownership", replacement.holdsKeyboard && proxy.policy.onScreen && proxy.policy.hold == .automatic)
        events = []
        view.textInput.insertText("old")
        replacement.textInput.insertText("new")
        check("only replacement native input reaches the current sink", events == [.text("new")])
        replacement.removeFromSuperview()
        check("current overlay teardown clears policy ownership", !proxy.policy.onScreen && proxy.policy.hold == .none)
        events = []
        replacement.textInput.insertText("late")
        check("detached replacement cannot send text", events.isEmpty)
        let passed = rows.allSatisfy { $0["passed"] as? Bool == true }
        let report: [String: Any] = ["passed": passed, "checks": rows, "productionOverlayAndProxy": true,
            "nativeUIKit": true, "mockDecodedImageReadiness": true, "networkUsed": false,
            "actualHardwareKeysVerified": false, "systemKeyboardIMEVerified": false,
            "realDuoVerified": false, "performanceAcceptance": false]
        if let data = try? JSONSerialization.data(withJSONObject: report, options: [.prettyPrinted, .sortedKeys]) {
            try? data.write(to: URL.documentsDirectory.appending(path: "result.json"), options: .atomic)
        }
        let label = UILabel(frame: surface.bounds.insetBy(dx: 24, dy: 100))
        label.numberOfLines = 0
        label.text = "Input ownership\n\(rows.count) checks: \(passed ? "PASS" : "FAIL")\n\nReal overlay, proxy and native text view.\nInput collected in memory.\nNo Mac input, network or performance acceptance."
        surface.addSubview(label)
        print("INPUT OWNERSHIP: \(passed ? "PASS" : "FAIL") \(rows.count) checks")
        Task { @MainActor in try? await Task.sleep(for: .seconds(90)); exit(passed ? 0 : 1) }
    }
}
