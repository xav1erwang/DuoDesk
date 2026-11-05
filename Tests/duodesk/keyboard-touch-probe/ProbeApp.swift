// Copyright 2026 DUO你电脑 contributors. SPDX-License-Identifier: Apache-2.0
// The production deck in a simulator-only fixture. No network or system input is sent.
import SwiftUI
import UIKit
import StreamProtocol

enum PointerPresence { enum Origin { case trackpad } }
enum TrackpadGestures { enum Gesture { case fixture } }

final class StreamClient: ObservableObject {
    @Published var hasNativeDesktopVideo = true
    @Published var result = "empty"
    var videoSize = CGSize(width: 1000, height: 700)
    var pointerFeedState: (anchor: CGPoint?, reseeds: Int) = (nil, 0)
    var events: [InputEvent] = []
    private func record(_ event: InputEvent) {
        events.append(event)
        if events == KeyChord.press(0x1A, with: .command) { result = "command-w" }
        else if events == KeyChord.press(0x1A, with: []) { result = "plain-w" }
        else if events == KeyChord.modifiersDown(.command)
            + [.pointer(.leftDown, x: 0.5, y: 0.5), .pointer(.leftUp, x: 0.5, y: 0.5)]
            + KeyChord.modifiersUp(.command) { result = "command-click" }
        else { result = "events: \(events.count)" }
    }
    func sendFromKeyRow(_ event: InputEvent) { record(event) }
    func sendInput(_ event: InputEvent) { record(event) }
    func setOwnPointer(_ point: CGPoint, from: PointerPresence.Origin) {}
    func trackpadFingers(_ count: Int) {}
    func sendGesture(_ gesture: TrackpadGestures.Gesture, fingers: Int) -> Bool { false }
    func disconnect() {}
}

struct TrackpadView: View {
    let send: (InputEvent) -> Void
    let setPointer: (CGPoint) -> Void
    let feed: () -> (anchor: CGPoint?, reseeds: Int)
    let onFingers: (Int) -> Void
    let latched: KeyModifiers
    let onModifiersConsumed: () -> Void
    let verticalSpan: CGFloat?
    let pointerFrameSize: CGSize?
    let sendGesture: (TrackpadGestures.Gesture, Int) -> Bool

    var body: some View {
        Button("Fixture click") {
            KeyChord.modifiersDown(latched).forEach(send)
            send(.pointer(.leftDown, x: 0.5, y: 0.5))
            send(.pointer(.leftUp, x: 0.5, y: 0.5))
            KeyChord.modifiersUp(latched).forEach(send)
            if !latched.isEmpty { onModifiersConsumed() }
        }
        .accessibilityIdentifier("probe.trackpad")
    }
}

@main
final class ProbeApp: UIResponder, UIApplicationDelegate {
    func application(_ application: UIApplication, configurationForConnecting session: UISceneSession,
                     options: UIScene.ConnectionOptions) -> UISceneConfiguration {
        let configuration = UISceneConfiguration(name: "Keyboard touch checks", sessionRole: session.role)
        configuration.delegateClass = ProbeScene.self
        return configuration
    }
}

struct Fixture: View {
    @ObservedObject var client: StreamClient
    @State var latched: KeyModifiers = []
    let uiChecks: Bool
    let holdCommand: () -> Void
    let releaseCommand: () -> Void
    var body: some View {
        VStack {
            if uiChecks {
                HStack {
                    Button("Hold Command", action: holdCommand).accessibilityIdentifier("probe.hold")
                    Button("Release Command", action: releaseCommand).accessibilityIdentifier("probe.release")
                    Button("Clear") { client.events = []; client.result = "empty" }.accessibilityIdentifier("probe.clear")
                }
                .padding(.top, 80)
                Text(client.result).accessibilityIdentifier("probe.result")
            }
            DuoControlDeck(client: client, latched: $latched, showSettings: {}, showSystemKeyboard: {}, showCleanImage: {})
        }
    }
}

final class ProbeScene: UIResponder, UIWindowSceneDelegate {
    var window: UIWindow?
    private let client = StreamClient()
    private var rows: [[String: Any]] = []

    func scene(_ scene: UIScene, willConnectTo session: UISceneSession, options: UIScene.ConnectionOptions) {
        guard let scene = scene as? UIWindowScene else { return }
        UserDefaults.standard.set(DuoControlMode.combined.rawValue, forKey: "duodesk.controlMode")
        let uiChecks = ProcessInfo.processInfo.arguments.contains("-KeyboardTouchUI")
        let window = UIWindow(windowScene: scene)
        window.rootViewController = UIHostingController(rootView: Fixture(client: client, uiChecks: uiChecks,
            holdCommand: { self.commandAction(.touchDown) },
            releaseCommand: { self.commandAction(.touchUpInside) }))
        window.makeKeyAndVisible()
        self.window = window
        guard !uiChecks else { return }
        Task { @MainActor in
            try? await Task.sleep(for: .seconds(2))
            await self.checks()
        }
    }

    private func check(_ name: String, _ passed: Bool) {
        rows.append(["name": name, "passed": passed])
        print("Keyboard touch: \(passed ? "PASS" : "FAIL"): \(name)")
    }

    private func control(_ id: String, in view: UIView) -> UIControl? {
        if let control = view as? UIControl, control.accessibilityIdentifier == id { return control }
        for child in view.subviews {
            if let control = control(id, in: child) { return control }
        }
        return nil
    }

    private func commandAction(_ event: UIControl.Event) {
        guard let root = window?.rootViewController?.view,
              let command = control("duo.key.modifier-227", in: root) else {
            client.result = "command missing"
            return
        }
        command.sendActions(for: event)
        client.result = "command dispatched"
    }

    private func settle() async { try? await Task.sleep(for: .milliseconds(300)) }

    private func checks() async {
        guard let window, let root = window.rootViewController?.view else { return }
        guard let command = control("duo.key.modifier-227", in: root) else {
            check("production Command control is mounted", false)
            finish()
            return
        }
        check("production Command control is mounted", true)
        var parent = command.superview
        var keyboardScroll: UIScrollView?
        while let view = parent {
            if let scroll = view as? UIScrollView { keyboardScroll = scroll; break }
            parent = view.superview
        }
        check("keyboard scroll delivers touches immediately and can cancel them",
              keyboardScroll?.delaysContentTouches == false && keyboardScroll?.canCancelContentTouches == true)
        let center = command.convert(CGPoint(x: command.bounds.midX, y: command.bounds.midY), to: root)
        check("Command is the hit-tested view", root.hitTest(center, with: nil) === command)
        command.sendActions(for: .touchDown)
        await settle()
        check("touch-down selects Command", command.accessibilityTraits.contains(.selected))
        command.sendActions(for: .touchUpInside)
        await settle()
        check("an unused tap stays latched", command.accessibilityTraits.contains(.selected))
        check("Command accessibility activation succeeds", command.accessibilityActivate())
        await settle()
        check("accessibility activation can clear a latch", !command.accessibilityTraits.contains(.selected))
        command.sendActions(for: .touchDown)
        command.sendActions(for: .touchCancel)
        await settle()
        check("a cancelled touch leaves no latch", !command.accessibilityTraits.contains(.selected))
        finish()
    }

    private func finish() {
        let passed = rows.allSatisfy { $0["passed"] as? Bool == true }
        let report: [String: Any] = ["passed": passed, "checks": rows, "productionControlDeck": true,
            "modifierEventsProgrammatic": true, "networkUsed": false, "realDuoVerified": false]
        if let data = try? JSONSerialization.data(withJSONObject: report, options: [.prettyPrinted, .sortedKeys]) {
            try? data.write(to: URL.documentsDirectory.appending(path: "result.json"), options: .atomic)
        }
        print("KEYBOARD TOUCH: \(passed ? "PASS" : "FAIL") \(rows.count) checks")
        exit(passed ? 0 : 1)
    }
}
