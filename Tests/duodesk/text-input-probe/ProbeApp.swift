// Copyright 2026 DUO你电脑 contributors. SPDX-License-Identifier: Apache-2.0
// Exercises the production UIKit text responder in its own simulator window; no network or Mac input.
import UIKit
import StreamProtocol

@main
final class ProbeApp: UIResponder, UIApplicationDelegate {
    func application(_ application: UIApplication, configurationForConnecting session: UISceneSession,
                     options: UIScene.ConnectionOptions) -> UISceneConfiguration {
        let config = UISceneConfiguration(name: "Text input checks", sessionRole: session.role)
        config.delegateClass = ProbeScene.self
        return config
    }
}

final class ProbeScene: UIResponder, UIWindowSceneDelegate {
    var window: UIWindow?
    func scene(_ scene: UIScene, willConnectTo session: UISceneSession, options: UIScene.ConnectionOptions) {
        guard let scene = scene as? UIWindowScene else { return }
        let window = UIWindow(windowScene: scene)
        window.rootViewController = UIViewController()
        window.rootViewController?.view.backgroundColor = .systemBackground
        window.makeKeyAndVisible()
        self.window = window
        Task { @MainActor in
            try? await Task.sleep(for: .milliseconds(500))
            self.checks()
        }
    }

    private func checks() {
        guard let surface = window?.rootViewController?.view else { return }
        let input = StreamTextInputView()
        input.frame = CGRect(x: 20, y: 100, width: 300, height: 80)
        input.suppressKeyboard = true
        surface.addSubview(input)
        var outputs: [String] = []
        var deletes = 0
        var generation = 1
        var ready = true
        input.makeInputFence = { let captured = generation; return { ready && captured == generation } }
        input.commit = { outputs.append($0) }
        input.remoteDelete = { deletes += 1 }
        var rows: [[String: Any]] = []
        func check(_ name: String, _ passed: Bool) { rows.append(["name": name, "passed": passed]) }
        func reset() { input.discardComposition(); outputs = []; deletes = 0; ready = true }
        check("native responder takes keyboard in its own window", input.becomeFirstResponder() && input.isFirstResponder)
        check("empty local buffer still permits deleting remote text", input.hasText)
        input.insertText("a")
        check("plain character committed once and cleared", outputs == ["a"] && input.text.isEmpty)
        reset()
        input.setMarkedText("ni", selectedRange: NSRange(location: 2, length: 0))
        check("preedit stays local", outputs.isEmpty && input.markedTextRange != nil && input.text == "ni")
        input.setMarkedText("nihao", selectedRange: NSRange(location: 5, length: 0))
        check("updated preedit stays local", outputs.isEmpty && input.text == "nihao")
        input.insertText("你好")
        check("candidate confirmation emits Chinese once", outputs == ["你好"] && input.markedTextRange == nil && input.text.isEmpty)
        input.unmarkText()
        check("later unmark cannot repeat the confirmation", outputs == ["你好"])
        reset()
        input.setMarkedText("中文", selectedRange: NSRange(location: 2, length: 0))
        input.unmarkText()
        check("unmark confirms the current candidate once", outputs == ["中文"] && input.text.isEmpty)
        reset()
        input.setAttributedMarkedText(NSAttributedString(string: "にほん"), selectedRange: NSRange(location: 3, length: 0))
        check("attributed multistage preedit stays local", outputs.isEmpty && input.markedTextRange != nil)
        input.insertText("日本")
        check("attributed composition confirms once", outputs == ["日本"])
        reset()
        input.setMarkedText("ni", selectedRange: NSRange(location: 2, length: 0))
        input.deleteBackward()
        check("deleting preedit does not delete the remote document", deletes == 0 && outputs.isEmpty)
        input.discardComposition()
        input.deleteBackward()
        check("delete with no preedit reaches remote document", deletes == 1 && outputs.isEmpty)
        reset()
        input.setMarkedText("ni", selectedRange: NSRange(location: 2, length: 0))
        input.setMarkedText(nil, selectedRange: NSRange(location: 0, length: 0))
        check("clearing marked text cancels without sending phonetics", outputs.isEmpty && input.text.isEmpty)
        reset()
        input.setMarkedText("未确认", selectedRange: NSRange(location: 3, length: 0))
        _ = input.resignFirstResponder()
        check("leaving the stream discards unfinished text", outputs.isEmpty && input.markedTextRange == nil && input.text.isEmpty)
        input.insertText("late"); input.deleteBackward()
        check("late text callbacks after focus loss send nothing", outputs.isEmpty && deletes == 0)
        _ = input.becomeFirstResponder()
        reset()
        input.setMarkedText("old", selectedRange: NSRange(location: 3, length: 0))
        generation += 1
        input.insertText("旧")
        check("video generation change rejects a stale candidate", outputs.isEmpty && input.text.isEmpty)
        input.insertText("新")
        check("new input can start on the current generation", outputs == ["新"])
        reset()
        ready = false
        input.insertText("blocked"); input.deleteBackward()
        check("missing current image rejects text and deletion", outputs.isEmpty && deletes == 0)
        reset()
        input.setMarkedText("👨‍👩‍👧‍👦", selectedRange: NSRange(location: 11, length: 0))
        check("native ranges count UTF-16 without splitting graphemes", input.offset(from: input.beginningOfDocument, to: input.endOfDocument) == 11 && outputs.isEmpty)
        input.insertText("👨‍👩‍👧‍👦é")
        check("composed Unicode confirmed intact", outputs == ["👨‍👩‍👧‍👦é"])
        reset()
        input.setMarkedText("候选", selectedRange: NSRange(location: 2, length: 0))
        if let range = input.markedTextRange { input.replace(range, withText: "选择") }
        input.unmarkText()
        check("native replacement confirms once", outputs == ["选择"])
        reset()
        input.setMarkedText("离开", selectedRange: NSRange(location: 2, length: 0))
        input.removeFromSuperview()
        input.insertText("late"); input.deleteBackward()
        check("detached input surface cannot send late text", outputs.isEmpty && deletes == 0)
        surface.addSubview(input)

        var forwarded = ForwardedKeys()
        for usage: UInt16 in [0x29, 0x50, 0x28, 0x2B] {
            check("composition key \(usage) stays local", forwarded.pressed(usage, modifiers: 0, at: 1, locallyComposing: true) == .text)
            check("composition release \(usage) stays local", forwarded.released(usage) == .text)
        }
        check("ordinary arrow still reaches Mac", forwarded.pressed(0x50, modifiers: 0, at: 2) == .send(.key(hidUsage: 0x50, down: true, modifiers: 0)))
        check("ordinary arrow release matches", forwarded.released(0x50) == .send(.key(hidUsage: 0x50, down: false, modifiers: 0)))
        check("shortcut remains raw during composition", forwarded.pressed(0x16, modifiers: KeyModifiers.command.rawValue, at: 3, locallyComposing: true) == .send(.key(hidUsage: 0x16, down: true, modifiers: KeyModifiers.command.rawValue)))
        _ = forwarded.releaseAll()
        input.discardComposition(); _ = input.resignFirstResponder()
        let passed = rows.allSatisfy { $0["passed"] as? Bool == true }
        let report: [String: Any] = ["passed": passed, "checks": rows, "nativeUIKit": true,
                                     "systemKeyboardIMEVerified": false, "realDuoVerified": false,
                                     "performanceAcceptance": false]
        let url = URL.documentsDirectory.appending(path: "result.json")
        if let data = try? JSONSerialization.data(withJSONObject: report, options: [.prettyPrinted, .sortedKeys]) {
            try? data.write(to: url, options: .atomic)
        }
        let label = UILabel(frame: surface.bounds.insetBy(dx: 24, dy: 100))
        label.autoresizingMask = [.flexibleWidth, .flexibleHeight]
        label.numberOfLines = 0
        label.text = "Native text input\n\(rows.count) checks: \(passed ? "PASS" : "FAIL")\n\nProgrammatic UIKit checks.\nNo Mac input or network.\nNot real device or performance acceptance."
        surface.addSubview(label)
        print("NATIVE TEXT INPUT: \(passed ? "PASS" : "FAIL") \(rows.count) checks")
        Task { @MainActor in try? await Task.sleep(for: .seconds(90)); exit(passed ? 0 : 1) }
    }
}
