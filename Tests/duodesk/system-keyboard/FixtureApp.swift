// Copyright 2026 DUO你电脑 contributors. SPDX-License-Identifier: Apache-2.0
// UI-test-only host for the production native text responder; never opens a Mac connection.
import UIKit

@main
final class KeyboardFixtureApp: UIResponder, UIApplicationDelegate {
    func application(_ application: UIApplication, configurationForConnecting session: UISceneSession,
                     options: UIScene.ConnectionOptions) -> UISceneConfiguration {
        let config = UISceneConfiguration(name: "Keyboard fixture", sessionRole: session.role)
        config.delegateClass = KeyboardFixtureScene.self
        return config
    }
}

final class KeyboardFixtureScene: UIResponder, UIWindowSceneDelegate {
    var window: UIWindow?
    func scene(_ scene: UIScene, willConnectTo session: UISceneSession, options: UIScene.ConnectionOptions) {
        guard let scene = scene as? UIWindowScene else { return }
        let window = UIWindow(windowScene: scene)
        window.rootViewController = KeyboardFixtureController()
        window.makeKeyAndVisible()
        self.window = window
    }
}

final class KeyboardFixtureController: UIViewController {
    private let input = StreamTextInputView()
    private var labels: [String: UILabel] = [:]
    private var received = ""
    private var commits: [String] = []
    private var deletes = 0
    private var generation = 1
    private var timer: Timer?
    private let startedAt = Date.now.timeIntervalSince1970
    private var lastSnapshot = ""
    private var history: [[String: Any]] = []
    private var textChanges = 0
    private var textObserver: NSObjectProtocol?

    override func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = .systemBackground
        let stack = UIStackView()
        stack.axis = .vertical
        stack.spacing = 12
        stack.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(stack)
        NSLayoutConstraint.activate([
            stack.topAnchor.constraint(equalTo: view.safeAreaLayoutGuide.topAnchor, constant: 24),
            stack.leadingAnchor.constraint(equalTo: view.leadingAnchor, constant: 24),
            stack.trailingAnchor.constraint(equalTo: view.trailingAnchor, constant: -24)])
        for (id, title) in [("title", "System keyboard input check"), ("received", ""),
                            ("preedit", "<none>"), ("source", ""), ("focus", "idle"),
                            ("languages", "")] {
            let label = UILabel()
            label.numberOfLines = 0
            label.text = title
            label.accessibilityIdentifier = "ime." + id
            labels[id] = label
            stack.addArrangedSubview(label)
        }
        func button(_ id: String, _ title: String, _ action: @escaping () -> Void) {
            let button = UIButton(type: .system)
            button.setTitle(title, for: .normal)
            button.accessibilityIdentifier = "ime." + id
            button.addAction(UIAction { _ in action() }, for: .touchUpInside)
            stack.addArrangedSubview(button)
        }
        button("start", "Start keyboard") { [weak self] in _ = self?.input.becomeFirstResponder(); self?.refresh() }
        button("close", "Close keyboard") { [weak self] in _ = self?.input.resignFirstResponder(); self?.refresh() }
        button("reset", "Reset owned text") { [weak self] in
            guard let self else { return }
            self.input.discardComposition(); self.received = ""; self.commits = []; self.deletes = 0; self.refresh()
        }
        button("epoch", "Replace owned video generation") { [weak self] in self?.generation += 1; self?.refresh() }
        input.frame = CGRect(x: 0, y: 0, width: 2, height: 2)
        view.addSubview(input)
        input.makeInputFence = { [weak self] in
            let generation = self?.generation
            return { [weak self] in self != nil && self?.generation == generation }
        }
        input.commit = { [weak self] text in
            guard let self else { return }
            self.received += text; self.commits.append(text); self.refresh()
        }
        input.remoteDelete = { [weak self] in
            guard let self else { return }
            self.deletes += 1
            if !self.received.isEmpty { self.received.removeLast() }
            self.refresh()
        }
        textObserver = NotificationCenter.default.addObserver(forName: UITextView.textDidChangeNotification,
            object: input, queue: .main) { [weak self] _ in self?.textChanges += 1; self?.refresh() }
        let timer = Timer(timeInterval: 0.1, repeats: true) { [weak self] _ in self?.refresh() }
        self.timer = timer
        RunLoop.main.add(timer, forMode: .common)
        refresh()
        Task { @MainActor in
            try? await Task.sleep(for: .seconds(180))
            _ = self.input.resignFirstResponder(); self.refresh(); exit(2)
        }
    }
    private func refresh() {
        let marked = input.markedTextRange == nil ? "" : input.text ?? ""
        let source = input.textInputMode?.primaryLanguage ?? "<none>"
        let languages = UITextInputMode.activeInputModes.compactMap(\.primaryLanguage)
        let state: [String: Any] = ["received": received, "marked": marked, "commits": commits,
            "remoteDeletes": deletes, "generation": generation, "source": source,
            "nativeText": input.text ?? "", "textChanges": textChanges,
            "languages": languages, "focused": input.isFirstResponder]
        guard let snapshot = try? JSONSerialization.data(withJSONObject: state, options: [.sortedKeys]),
              let key = String(data: snapshot, encoding: .utf8), key != lastSnapshot else { return }
        lastSnapshot = key
        labels["received"]?.text = received.isEmpty ? "<empty>" : received
        labels["preedit"]?.text = marked.isEmpty ? "<none>" : marked
        labels["source"]?.text = source
        labels["focus"]?.text = input.isFirstResponder ? "editing" : "idle"
        labels["languages"]?.text = languages.joined(separator: ",")
        var row = state; row["unix"] = Date.now.timeIntervalSince1970
        history.append(row)
        if history.count > 100 { history.removeFirst(history.count - 100) }
        let report: [String: Any] = ["processID": getpid(), "startedAt": startedAt, "states": history,
            "productionNativeTextView": true, "mockVideoGeneration": true, "networkUsed": false,
            "realDuoVerified": false, "performanceAcceptance": false]
        if let data = try? JSONSerialization.data(withJSONObject: report, options: [.prettyPrinted, .sortedKeys]) {
            try? data.write(to: URL.documentsDirectory.appending(path: "result.json"), options: .atomic)
        }
    }
}
