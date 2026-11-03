// Copyright 2026 DUO你电脑 contributors. SPDX-License-Identifier: Apache-2.0
// Real client message handling with an owned loopback peer; no Mac or Duo is contacted.
import UIKit
import Network
import StreamProtocol
import SwiftUI

enum ProbeFailure: Error { case failed(String) }

final class LoopbackPeer: @unchecked Sendable {
    struct Message { let kind: StreamMessageKind; let payload: Data }
    private let queue = DispatchQueue(label: "duodesk.native-sizing-peer")
    private let lock = NSLock()
    private let listener: NWListener
    private var incoming: NWConnection?
    private var incomingBytes = Data()
    private var parsed: [Message] = []
    private var portValue: NWEndpoint.Port?
    private var readyValue = false
    private var endedValue = false
    private var errorValue: String?
    private(set) var outgoing: NWConnection?

    init() throws {
        let params = NWParameters.tcp
        params.requiredInterfaceType = .loopback
        params.requiredLocalEndpoint = .hostPort(host: .ipv4(.loopback), port: .any)
        listener = try NWListener(using: params)
        listener.stateUpdateHandler = { [weak self] state in
            guard let self else { return }
            switch state {
            case .ready: self.lock.withLock { self.portValue = self.listener.port }
            case .failed(let error): self.lock.withLock { self.errorValue = String(describing: error) }
            default: break
            }
        }
        listener.newConnectionHandler = { [weak self] connection in
            guard let self else { connection.cancel(); return }
            self.lock.withLock { self.incoming = connection }
            connection.start(queue: self.queue)
            self.read(connection)
        }
        listener.start(queue: queue)
    }

    var port: NWEndpoint.Port? { lock.withLock { portValue } }
    var ready: Bool { lock.withLock { readyValue } }
    var accepted: Bool { lock.withLock { incoming != nil } }
    var ended: Bool { lock.withLock { endedValue } }
    var error: String? { lock.withLock { errorValue } }
    var messages: [Message] { lock.withLock { parsed } }

    func connect(to port: NWEndpoint.Port) {
        let connection = NWConnection(host: .ipv4(.loopback), port: port, using: .tcp)
        outgoing = connection
        connection.stateUpdateHandler = { [weak self] state in
            guard let self else { return }
            switch state {
            case .ready: self.lock.withLock { self.readyValue = true }
            case .failed(let error): self.lock.withLock { self.errorValue = String(describing: error) }
            default: break
            }
        }
        connection.start(queue: queue)
    }

    func send(_ message: StreamMessage) {
        lock.withLock { incoming }?.send(content: message.serialized(), completion: .contentProcessed { _ in })
    }

    func closeIncoming() { lock.withLock { incoming }?.cancel() }

    private func read(_ connection: NWConnection) {
        connection.receive(minimumIncompleteLength: 1, maximumLength: 65536) { [weak self] data, _, done, error in
            guard let self else { return }
            if let data {
                self.lock.withLock {
                    self.incomingBytes.append(data)
                    while self.incomingBytes.count >= StreamMessage.headerLength {
                        let head = self.incomingBytes.prefix(StreamMessage.headerLength)
                        guard let header = StreamMessage.parseHeader(Data(head)),
                              header.payloadLength <= StreamMessage.maxClientPayload,
                              self.incomingBytes.count >= StreamMessage.headerLength + header.payloadLength else { break }
                        let end = StreamMessage.headerLength + header.payloadLength
                        let payload = self.incomingBytes.subdata(in: StreamMessage.headerLength..<end)
                        self.parsed.append(Message(kind: header.kind, payload: payload))
                        self.incomingBytes.removeSubrange(0..<end)
                    }
                }
            }
            if let error { self.lock.withLock { self.errorValue = String(describing: error) } }
            if done || error != nil { self.lock.withLock { self.endedValue = true } }
            if !done && error == nil { self.read(connection) }
        }
    }

    func close() { outgoing?.cancel(); lock.withLock { incoming }?.cancel(); listener.cancel() }
}

@main final class ProbeApp: UIResponder, UIApplicationDelegate {
    func application(_ application: UIApplication, configurationForConnecting session: UISceneSession,
                     options: UIScene.ConnectionOptions) -> UISceneConfiguration {
        let config = UISceneConfiguration(name: "Native sizing", sessionRole: session.role)
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
        window.makeKeyAndVisible()
        self.window = window
        Task { @MainActor in await run() }
    }

    @MainActor private func wait(_ name: String, _ condition: () -> Bool) async throws {
        let deadline = ContinuousClock.now + .seconds(6)
        while !condition() {
            guard ContinuousClock.now < deadline else { throw ProbeFailure.failed(name) }
            try await Task.sleep(for: .milliseconds(10))
        }
    }

    @MainActor private func peer() async throws -> LoopbackPeer {
        let peer = try LoopbackPeer()
        try await wait("listener") { peer.port != nil || peer.error != nil }
        guard let port = peer.port else { throw ProbeFailure.failed("listener did not open") }
        peer.connect(to: port)
        try await wait("loopback connection") { peer.ready || peer.error != nil }
        guard peer.ready, peer.outgoing != nil else { throw ProbeFailure.failed("loopback did not connect") }
        return peer
    }

    @MainActor private func barrier(_ client: StreamClient, _ peer: LoopbackPeer, _ tag: UInt8) async throws {
        client.send(.ping, payload: Data([tag]))
        try await wait("loopback barrier \(tag)") { peer.messages.contains { $0.kind == .ping && $0.payload == Data([tag]) } }
    }

    @MainActor private func deliver(_ list: WindowList, to client: StreamClient, from supplied: NWConnection? = nil) throws {
        let payload = Wire.encode(list)
        let bytes = StreamMessage(kind: .windowList, timestamp: 0, isKeyframe: false, payload: payload).serialized()
        guard let header = StreamMessage.parseHeader(Data(bytes.prefix(StreamMessage.headerLength))) else {
            throw ProbeFailure.failed("catalog header")
        }
        guard let source = supplied ?? client.connection else { throw ProbeFailure.failed("catalog source missing") }
        client.queue.async { client.handleNativeSizingTestCatalog(header, payload, from: source) }
    }

    private func relevant(_ peer: LoopbackPeer) -> [LoopbackPeer.Message] {
        peer.messages.filter { $0.kind == .viewport || $0.kind == .selectSource }
    }

    private func nativeActions(_ peer: LoopbackPeer) -> [LoopbackPeer.Message] {
        peer.messages.filter { $0.kind == .viewport || $0.kind == .selectSource || $0.kind == .launchApp }
    }

    @MainActor private func setInner(_ client: StreamClient, rendered: Bool) {
        client.nativeDisplayMetrics = DuoNativeDisplayMetrics(pixels: CGSize(width: 1878, height: 2670),
                                                              windowSize: CGSize(width: 669, height: 951),
                                                              renderPixels: rendered ? CGSize(width: 2007, height: 2853) : nil)
        client.updateDuoNativeResolution(innerDisplay: true, frame: CGRect(x: 0, y: 0, width: 669, height: 951),
                                         fold: CGRect(x: 0, y: 455.5, width: 669, height: 40))
    }

    @MainActor private func run() async {
        #if DUO_LAUNCH_ORDER_TESTING
        await runLaunchChecks()
        #elseif DUO_EXTENSION_TRANSITION_TESTING
        await runExtensionTransitionChecks()
        #elseif DUO_LEGACY_ORDER_TESTING
        await runLegacyOrderChecks()
        #elseif DUO_TERMINAL_GOODBYE_TESTING
        await runTerminalGoodbyeChecks()
        #elseif DUO_PHYSICAL_FALLBACK_TESTING
        await runPhysicalFallbackChecks()
        #elseif DUO_FULLSCREEN_MIRROR_TESTING
        await runFullscreenMirrorChecks()
        #else
        var rows: [[String: Any]] = []
        func check(_ name: String, _ passed: Bool) { rows.append(["name": name, "passed": passed]) }
        let legacy = DuoDesktopResolution(width: 1878, height: 1335)
        let rendered = DuoDesktopResolution(width: 2007, height: 1427)
        var peers: [LoopbackPeer] = []
        defer { peers.forEach { $0.close() } }
        do {
            UserDefaults.standard.removeObject(forKey: DuoStreamPolicy.legacyUpperDisplayKey)
            UserDefaults.standard.removeObject(forKey: DuoStreamPolicy.renderedUpperDisplayKey)
            let first = try await peer(); peers.append(first)
            let client = StreamClient()
            client.connection = first.outgoing; client.connected = true
            setInner(client, rendered: true)
            check("unknown host keeps legacy cache locally", client.nativeDesktopResolution == legacy)
            client.sendViewport(Viewport(width: 669, height: 475, scale: nil, desktopResolution: legacy))
            client.select(.desktop)
            try await barrier(client, first, 1)
            check("nothing size-related is sent before host capability", relevant(first).isEmpty)
            try deliver(WindowList(macName: "fixture", windows: [], active: .none,
                                   extendedDesktop: true, renderedNativeDesktop: true), to: client)
            try await wait("strict viewport and source") { self.relevant(first).count >= 2 }
            let initial = relevant(first)
            let firstViewport = initial.first.flatMap { Wire.decode(Viewport.self, from: $0.payload) }
            check("strict viewport precedes desktop pick", initial.prefix(2).map(\.kind) == [.viewport, .selectSource])
            check("strict viewport uses rendered upper pixels", firstViewport?.desktopResolution == rendered)
            check("strict desktop selected once", initial.filter { $0.kind == .selectSource }.count == 1)
            check("extension can start with measured strict size", client.beginExtendedDesktop())
            client.sendViewport(Viewport(width: 669, height: 951, scale: nil, desktopResolution: legacy))
            try await wait("extension viewport") {
                self.relevant(first).contains {
                    $0.kind == .viewport && Wire.decode(Viewport.self, from: $0.payload)?.extendedDesktop == true
                }
            }
            let extensionViewport = relevant(first).last { $0.kind == .viewport }
                .flatMap { Wire.decode(Viewport.self, from: $0.payload) }
            check("extension sends the whole render canvas and token",
                  extensionViewport?.desktopResolution == DuoDesktopResolution(width: 2007, height: 2853)
                  && extensionViewport?.extendedRequestID != nil)
            client.endExtendedDesktop()
            client.sendViewport(Viewport(width: 669, height: 475, scale: nil, desktopResolution: legacy,
                                         extendedDesktop: true, extendedRequestID: UUID()))
            try await wait("restored strict mirror") {
                guard let message = self.relevant(first).last, message.kind == .viewport,
                      let v = Wire.decode(Viewport.self, from: message.payload) else { return false }
                return v.desktopResolution == rendered && v.extendedDesktop == nil && v.extendedRequestID == nil
            }
            check("extension exit restores the strict upper mirror", true)

            client.connection = nil
            client.tearDown(status: "fixture ended", restartSearch: false)
            let old = try await peer(); peers.append(old)
            client.connection = old.outgoing; client.connected = true
            setInner(client, rendered: true)
            client.sendViewport(Viewport(width: 669, height: 475, scale: nil, desktopResolution: rendered))
            client.select(.desktop)
            try deliver(WindowList(macName: "old fixture", windows: [], active: .none), to: client)
            try await wait("legacy viewport and source") { self.relevant(old).count >= 2 }
            let oldMessages = relevant(old)
            let oldViewport = oldMessages.first.flatMap { Wire.decode(Viewport.self, from: $0.payload) }
            check("reconnect to legacy host sends the original size", oldViewport?.desktopResolution == legacy)
            check("legacy host receives its viewport before pending selection",
                  oldMessages.prefix(2).map(\.kind) == [.viewport, .selectSource])
            check("legacy host does not offer extension", !client.beginExtendedDesktop())
            client.connection = nil
            client.tearDown(status: "fixture ended", restartSearch: false)

            UserDefaults.standard.removeObject(forKey: DuoStreamPolicy.renderedUpperDisplayKey)
            let waiting = try await peer(); peers.append(waiting)
            let unmeasured = StreamClient()
            unmeasured.connection = waiting.outgoing; unmeasured.connected = true
            setInner(unmeasured, rendered: false)
            unmeasured.sendViewport(Viewport(width: 669, height: 475, scale: nil, desktopResolution: legacy))
            unmeasured.select(.desktop)
            try deliver(WindowList(macName: "strict fixture", windows: [], active: .none,
                                   extendedDesktop: true, renderedNativeDesktop: true), to: unmeasured)
            try await wait("strict capability") { unmeasured.hostRenderedNativeDesktop == true }
            try await barrier(unmeasured, waiting, 2)
            check("missing render metrics do not send a smaller request", relevant(waiting).isEmpty)
            check("extension waits for render metrics", !unmeasured.beginExtendedDesktop())
            unmeasured.nativeDisplayMetrics = DuoNativeDisplayMetrics(pixels: CGSize(width: 1878, height: 2670),
                                                                      windowSize: CGSize(width: 669, height: 951),
                                                                      renderPixels: CGSize(width: 2200, height: 3500))
            unmeasured.updateDuoNativeResolution(innerDisplay: true, frame: CGRect(x: 0, y: 0, width: 669, height: 951),
                                                   fold: CGRect(x: 0, y: 455.5, width: 669, height: 40))
            try await barrier(unmeasured, waiting, 4)
            check("a mismatched aspect cannot send a desktop request", relevant(waiting).isEmpty)
            unmeasured.select(.window(42))
            setInner(unmeasured, rendered: true)
            try await wait("measured viewport and source") { self.relevant(waiting).count >= 2 }
            let measured = relevant(waiting)
            let measuredViewport = measured.first.flatMap { Wire.decode(Viewport.self, from: $0.payload) }
            check("measurement releases viewport then selection", measured.prefix(2).map(\.kind) == [.viewport, .selectSource])
            check("released request retains all render pixels", measuredViewport?.desktopResolution == rendered)
            check("latest user choice replaces the pending choice",
                  measured.dropFirst().first.flatMap { Wire.decode(StreamSource.self, from: $0.payload) } == .window(42))
            guard let oldConnection = unmeasured.connection else { throw ProbeFailure.failed("missing old connection") }
            unmeasured.connection = nil
            unmeasured.tearDown(status: "fixture ended", restartSearch: false)
            try deliver(WindowList(macName: "stale fixture", windows: [], active: .none,
                                   renderedNativeDesktop: true), to: unmeasured, from: oldConnection)
            let drained = DispatchSemaphore(value: 0)
            unmeasured.queue.async { drained.signal() }
            try await wait("stale catalog drained") { drained.wait(timeout: .now()) == .success }
            check("a catalog received after disconnect cannot set host capability", unmeasured.hostRenderedNativeDesktop == nil)

            let replacement = try await peer(); peers.append(replacement)
            unmeasured.connection = replacement.outgoing; unmeasured.connected = true
            try deliver(WindowList(macName: "replaced fixture", windows: [], active: .none,
                                   renderedNativeDesktop: true), to: unmeasured, from: oldConnection)
            let swapped = DispatchSemaphore(value: 0)
            unmeasured.queue.async { swapped.signal() }
            try await wait("replaced catalog drained") { swapped.wait(timeout: .now()) == .success }
            check("a previous connection cannot set the new connection's capability", unmeasured.hostRenderedNativeDesktop == nil)
            unmeasured.connection = nil
            unmeasured.tearDown(status: "fixture ended", restartSearch: false)

            let automaticPeer = try await peer(); peers.append(automaticPeer)
            let automatic = StreamClient()
            automatic.connection = automaticPeer.outgoing; automatic.connected = true
            setInner(automatic, rendered: true)
            try deliver(WindowList(macName: "automatic fixture", windows: [], active: .none,
                                   renderedNativeDesktop: true), to: automatic)
            try await wait("automatic capability") { automatic.hostRenderedNativeDesktop == true }
            try await barrier(automatic, automaticPeer, 3)
            check("automatic desktop waits for the first sized viewport", relevant(automaticPeer).isEmpty)
            automatic.sendViewport(Viewport(width: 669, height: 475, scale: nil, desktopResolution: legacy))
            try await wait("automatic viewport and source") { self.relevant(automaticPeer).count >= 2 }
            let autoMessages = relevant(automaticPeer)
            check("automatic desktop follows the rendered viewport", autoMessages.prefix(2).map(\.kind) == [.viewport, .selectSource]
                  && autoMessages.first.flatMap { Wire.decode(Viewport.self, from: $0.payload) }?.desktopResolution == rendered)
            automatic.connection = nil
            automatic.tearDown(status: "fixture ended", restartSearch: false)

            UserDefaults.standard.removeObject(forKey: DuoStreamPolicy.legacyUpperDisplayKey)
            UserDefaults.standard.removeObject(forKey: DuoStreamPolicy.renderedUpperDisplayKey)
            let regularPeer = try await peer(); peers.append(regularPeer)
            let regular = StreamClient()
            regular.connection = regularPeer.outgoing; regular.connected = true
            regular.updateDuoNativeResolution(innerDisplay: false, frame: .zero, fold: nil)
            regular.sendViewport(Viewport(width: 390, height: 300, scale: nil))
            regular.select(.desktop)
            try deliver(WindowList(macName: "regular fixture", windows: [], active: .none,
                                   renderedNativeDesktop: true), to: regular)
            try await wait("regular viewport and source") { self.relevant(regularPeer).count >= 2 }
            let regularMessages = relevant(regularPeer)
            check("a non-Duo client is not blocked by strict sizing", regularMessages.prefix(2).map(\.kind) == [.viewport, .selectSource]
                  && regularMessages.first.flatMap { Wire.decode(Viewport.self, from: $0.payload) }?.desktopResolution == nil)
            regular.connection = nil
            regular.tearDown(status: "fixture ended", restartSearch: false)

            guard let container = window?.rootViewController?.view else { throw ProbeFailure.failed("fixture view missing") }
            let attached = StreamClient()
            let display = attached.displayView
            display.frame = container.bounds
            container.addSubview(display)
            try await wait("initial attached display metrics") { attached.nativeDisplayMetrics != nil }
            setInner(attached, rendered: true)
            attached.tearDown(status: "fixture ended", restartSearch: false)
            check("an attached view retains its scene context across reconnect", attached.nativeInnerDisplay == true)
            try await wait("attached display remeasured") {
                guard let measured = attached.nativeDisplayMetrics?.pixels,
                      let actual = self.window?.windowScene?.screen.nativeBounds.size else { return false }
                return measured == actual
            }
            check("an attached view supplies fresh screen pixels after reset", true)
            display.removeFromSuperview()
        } catch { rows.append(["name": "fixture error: \(error)", "passed": false]) }
        let passed = !rows.isEmpty && rows.allSatisfy { $0["passed"] as? Bool == true }
        let report: [String: Any] = ["passed": passed, "checks": rows,
            "scope": "Production iOS client, injected catalogs and loopback peer only; no real Mac, Duo, display capture or FPS measurement."]
        let url = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0].appendingPathComponent("native-render-result.json")
        if let data = try? JSONSerialization.data(withJSONObject: report, options: [.prettyPrinted, .sortedKeys]) {
            try? data.write(to: url, options: .atomic)
        }
        print("NATIVE RENDER PROBE \(passed ? "PASS" : "FAIL"): \(rows.count) checks")
        exit(passed ? 0 : 1)
        #endif
    }

    /// Real StreamClient and local peer: an offered full physical mode restores the desktop while
    /// extension and subsequent mirror requests keep their distinct resolution and mode flags.
    @MainActor private func runPhysicalFallbackChecks() async {
        var rows: [[String: Any]] = []
        func check(_ name: String, _ passed: Bool) { rows.append(["name": name, "passed": passed]) }
        var peers: [LoopbackPeer] = []
        defer { peers.forEach { $0.close() } }
        let upper = DuoDesktopResolution(width: 2007, height: 1427)
        let physical = DuoDesktopResolution(width: 3840, height: 2160)
        let issue = DuoDesktopIssue(resolution: upper, message: "原生镜像不可用", physicalFallback: physical)
        do {
            UserDefaults.standard.removeObject(forKey: DuoStreamPolicy.renderedUpperDisplayKey)
            let remote = try await peer(); peers.append(remote)
            let client = StreamClient()
            client.mockDiscovery = true
            client.connection = remote.outgoing; client.connected = true
            setInner(client, rendered: true)
            client.sendViewport(Viewport(width: 669, height: 475, scale: nil))
            try deliver(WindowList(macName: "fixture", windows: [], active: .none,
                                   extendedDesktop: true, renderedNativeDesktop: true), to: client)
            try await wait("initial desktop request") { self.relevant(remote).count >= 2 }
            let before = relevant(remote).count
            try deliver(WindowList(macName: "fixture", windows: [], active: .none,
                                   extendedDesktop: true, desktopIssue: issue, renderedNativeDesktop: true), to: client)
            try await wait("physical fallback request") { self.relevant(remote).count >= before + 2 }
            let next = Array(relevant(remote).dropFirst(before))
            let fallbackViewport = next.first.flatMap { Wire.decode(Viewport.self, from: $0.payload) }
            check("fallback sends full physical pixels before selecting desktop",
                  next.prefix(2).map(\.kind) == [.viewport, .selectSource]
                  && fallbackViewport?.desktopResolution == physical && fallbackViewport?.preservePhysicalMode == true)
            check("fallback is labeled and retains decoder requirement", client.usingPhysicalDesktopFallback
                  && client.nativeDesktopResolution == physical && client.nativeDesktopIssue == nil)
            setInner(client, rendered: true)
            check("layout remeasurement keeps the physical fallback", client.nativeDesktopResolution == physical)
            let extensionStart = relevant(remote).count
            check("extension can start from the fallback", client.beginExtendedDesktop())
            try await wait("extension after fallback") { self.relevant(remote).count > extensionStart }
            let extended = relevant(remote).last.flatMap { Wire.decode(Viewport.self, from: $0.payload) }
            check("extension has its own full size and no physical-mode flag", extended?.extendedDesktop == true
                  && extended?.desktopResolution == DuoDesktopResolution(width: 2007, height: 2853)
                  && extended?.preservePhysicalMode != true)
            let extensionEnd = relevant(remote).count
            client.endExtendedDesktop()
            try await wait("fallback after extension") { self.relevant(remote).count > extensionEnd }
            let restored = relevant(remote).last.flatMap { Wire.decode(Viewport.self, from: $0.payload) }
            check("leaving extension restores the physical fallback", restored?.extendedDesktop != true
                  && restored?.desktopResolution == physical && restored?.preservePhysicalMode == true)
            check("smaller physical displays are never offered", DuoExtendedDesktopPolicy.physicalFallback(
                DuoDesktopIssue(resolution: upper, message: "", physicalFallback: .init(width: 1920, height: 1080)),
                expected: upper, extending: false, active: .none) == nil)
            check("stale, extended and active issues cannot switch the source",
                  DuoExtendedDesktopPolicy.physicalFallback(issue, expected: .init(width: 1878, height: 1335), extending: false, active: .none) == nil
                  && DuoExtendedDesktopPolicy.physicalFallback(issue, expected: upper, extending: true, active: .none) == nil
                  && DuoExtendedDesktopPolicy.physicalFallback(issue, expected: upper, extending: false, active: .desktop) == nil)
            check("older hosts do not silently enable the fallback", DuoExtendedDesktopPolicy.physicalFallback(
                DuoDesktopIssue(resolution: upper, message: "旧主机"), expected: upper, extending: false, active: .none) == nil)
            let overlay = InputOverlayView(frame: CGRect(x: 0, y: 0, width: 669, height: 475))
            overlay.videoSize = CGSize(width: physical.width, height: physical.height)
            var inputs: [InputEvent] = []
            overlay.send = { inputs.append($0) }
            let rect = HEVCDisplayView.videoRect(in: overlay.bounds, videoSize: overlay.videoSize)
            overlay.scriptTap(x: 0.25, y: 0.75)
            check("letterboxed physical video maps taps to the displayed image", rect.minY > 0 && inputs.count == 3
                  && inputs.allSatisfy { event in
                      if case .pointer(_, let x, let y) = event { return abs(x - 0.25) < 0.0001 && abs(y - 0.75) < 0.0001 }
                      return false
                  })
            inputs.removeAll()
            overlay.scriptTap(x: -0.1, y: 0.5)
            check("taps in the letterbox send no input", inputs.isEmpty)
            client.connection = nil; client.tearDown(status: "fixture ended", restartSearch: false)
            check("disconnect clears the physical fallback", !client.usingPhysicalDesktopFallback)
        } catch { rows.append(["name": "fixture error: \(error)", "passed": false]) }
        let passed = !rows.isEmpty && rows.allSatisfy { $0["passed"] as? Bool == true }
        let report: [String: Any] = ["passed": passed, "checks": rows,
            "scope": "Production iOS client with injected catalogs and a local TCP peer; no real capture, display changes or Duo."]
        let url = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0].appendingPathComponent("physical-fallback-result.json")
        if let data = try? JSONSerialization.data(withJSONObject: report, options: [.prettyPrinted, .sortedKeys]) {
            try? data.write(to: url, options: .atomic)
        }
        print("PHYSICAL FALLBACK: \(passed ? "PASS" : "FAIL") (\(rows.count) checks)")
    }

    /// The installed legacy host can send a fatal desktop goodbye without closing its socket.
    /// Use a real local TCP connection and the production reader; no display or device is involved.
    @MainActor private func runTerminalGoodbyeChecks() async {
        var rows: [[String: Any]] = []
        func check(_ name: String, _ passed: Bool) { rows.append(["name": name, "passed": passed]) }
        var peers: [LoopbackPeer] = []
        defer { peers.forEach { $0.close() } }
        func message(_ goodbye: Goodbye) -> StreamMessage {
            StreamMessage(kind: .goodbye, timestamp: 0, isKeyframe: false, payload: Wire.encode(goodbye))
        }
        func clean(_ client: StreamClient) {
            client.connection?.cancel()
            client.connection = nil
            client.reconnect = nil
            client.tearDown(status: "fixture ended", restartSearch: false)
        }
        do {
            for reason in ["duoResolution", "duoStream", "duoPrivacy"] {
                let remote = try await peer(); peers.append(remote)
                try await wait("peer accepted \(reason)") { remote.accepted }
                guard let source = remote.outgoing else { throw ProbeFailure.failed("source missing") }
                let client = StreamClient()
                client.mockDiscovery = true
                client.connection = source; client.connected = true
                client.startTerminalGoodbyeTestReader(source)
                let text = "桌面故障：\(reason)"
                remote.send(message(Goodbye(reason: reason, message: text, reconnect: false)))
                try await wait("processed \(reason)") { client.goodbye != nil || !client.connected }
                if !client.connected { try await wait("peer saw close \(reason)") { remote.ended } }
                check("\(reason) ends session without host EOF", !client.connected && client.connection == nil)
                check("\(reason) closes TCP connection", remote.ended)
                check("\(reason) preserves host message", client.notice?.text == text && client.status == text)
                check("\(reason) respects reconnect false", !client.connected && client.reconnect == nil)
                clean(client)
            }

            let futurePeer = try await peer(); peers.append(futurePeer)
            try await wait("future peer accepted") { futurePeer.accepted }
            guard let futureSource = futurePeer.outgoing else { throw ProbeFailure.failed("future source missing") }
            let future = StreamClient()
            future.mockDiscovery = true
            future.connection = futureSource; future.connected = true
            future.startTerminalGoodbyeTestReader(futureSource)
            futurePeer.send(message(Goodbye(reason: "futureNotice", message: "稍后再试", reconnect: false)))
            try await wait("future goodbye read") { future.goodbye?.reason == "futureNotice" }
            check("other goodbye waits for the host's close", future.connected && !futurePeer.ended && future.notice == nil)
            futurePeer.closeIncoming()
            try await wait("future peer closed") { !future.connected }
            check("other goodbye retains normal close handling", future.notice?.text == "稍后再试" && future.reconnect == nil)
            clean(future)

            let retryPeer = try await peer(); peers.append(retryPeer)
            try await wait("retry peer accepted") { retryPeer.accepted }
            guard let retrySource = retryPeer.outgoing else { throw ProbeFailure.failed("retry source missing") }
            let retry = StreamClient()
            retry.mockDiscovery = true
            retry.connection = retrySource; retry.connected = true
            retry.startTerminalGoodbyeTestReader(retrySource)
            retryPeer.send(message(Goodbye(reason: "duoStream", message: "自动重试", reconnect: true)))
            try await wait("retry goodbye read") { retry.goodbye != nil || !retry.connected }
            check("fatal goodbye respects reconnect true", !retry.connected && retry.notice?.text == "自动重试" && retry.reconnect != nil)
            clean(retry)

            let first = try await peer(); peers.append(first)
            let second = try await peer(); peers.append(second)
            guard let stale = first.outgoing, let current = second.outgoing else { throw ProbeFailure.failed("replacement source missing") }
            let replacement = StreamClient()
            replacement.mockDiscovery = true
            replacement.connection = stale; replacement.connected = true
            let oldMessage = message(Goodbye(reason: "duoResolution", message: "旧连接", reconnect: false))
            let bytes = oldMessage.serialized()
            guard let header = StreamMessage.parseHeader(Data(bytes.prefix(StreamMessage.headerLength))) else {
                throw ProbeFailure.failed("goodbye header")
            }
            // The old message schedules its main-thread work while this main actor still holds it.
            replacement.queue.sync {
                replacement.handleTerminalGoodbyeTest(header, Wire.encode(Goodbye(reason: "duoResolution", message: "旧连接", reconnect: false)), from: stale)
            }
            replacement.connection = current
            try await Task.sleep(for: .milliseconds(100))
            check("queued goodbye cannot end a replacement connection", replacement.connected && replacement.connection === current && replacement.goodbye == nil)
            replacement.connectionLost(stale)
            try await Task.sleep(for: .milliseconds(100))
            check("old close callback cannot end a replacement connection", replacement.connected && replacement.connection === current && replacement.notice == nil)
            clean(replacement)
        } catch { rows.append(["name": "fixture error: \(error)", "passed": false]) }
        let passed = !rows.isEmpty && rows.allSatisfy { $0["passed"] as? Bool == true }
        let report: [String: Any] = ["passed": passed, "checks": rows,
            "scope": "Production iOS message reader on local TCP peers; injected stale-message race only. No real Mac, Duo, display capture or FPS measurement."]
        let url = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0].appendingPathComponent("terminal-goodbye-result.json")
        if let data = try? JSONSerialization.data(withJSONObject: report, options: [.prettyPrinted, .sortedKeys]) {
            try? data.write(to: url, options: .atomic)
        }
        print("TERMINAL GOODBYE: \(passed ? "PASS" : "FAIL") (\(rows.count) checks)")
    }

    /// A legacy host must get the measured viewport before the first desktop request, even if
    /// its first catalog arrives before SwiftUI has measured the panel or the Duo screen.
    @MainActor private func runLegacyOrderChecks() async {
        var rows: [[String: Any]] = []
        func check(_ name: String, _ passed: Bool) { rows.append(["name": name, "passed": passed]) }
        var peers: [LoopbackPeer] = []
        defer { peers.forEach { $0.close() } }
        let legacy = DuoDesktopResolution(width: 1878, height: 1335)
        let frame = CGRect(x: 0, y: 0, width: 669, height: 951)
        let fold = CGRect(x: 0, y: 455.5, width: 669, height: 40)
        let list = WindowList(macName: "legacy fixture", windows: [], active: .none)
        func clearCache() {
            UserDefaults.standard.removeObject(forKey: DuoStreamPolicy.legacyUpperDisplayKey)
            UserDefaults.standard.removeObject(forKey: DuoStreamPolicy.renderedUpperDisplayKey)
        }
        do {
            clearCache()
            let first = try await peer(); peers.append(first)
            let client = StreamClient()
            client.connection = first.outgoing; client.connected = true
            client.updateDuoNativeResolution(innerDisplay: true, frame: frame, fold: fold)
            client.sendViewport(Viewport(width: 669, height: 475, scale: nil))
            try deliver(list, to: client)
            try await wait("legacy capability") { client.hostRenderedNativeDesktop == false }
            try await barrier(client, first, 41)
            check("legacy host waits while Duo screen pixels are unknown", relevant(first).isEmpty)
            setInner(client, rendered: true)
            try await wait("legacy viewport and desktop") { self.relevant(first).count >= 2 }
            let firstMessages = relevant(first)
            let firstViewport = firstMessages.first.flatMap { Wire.decode(Viewport.self, from: $0.payload) }
            check("legacy host receives native viewport before desktop", firstMessages.prefix(2).map(\.kind) == [.viewport, .selectSource]
                  && firstViewport?.desktopResolution == legacy)
            client.connection = nil; client.tearDown(status: "fixture ended", restartSearch: false)

            clearCache()
            let second = try await peer(); peers.append(second)
            let unmeasured = StreamClient()
            unmeasured.connection = second.outgoing; unmeasured.connected = true
            setInner(unmeasured, rendered: true)
            try deliver(list, to: unmeasured)
            try await wait("legacy capability before viewport") { unmeasured.hostRenderedNativeDesktop == false }
            try await barrier(unmeasured, second, 42)
            check("legacy host waits for the first panel viewport", relevant(second).isEmpty)
            unmeasured.sendViewport(Viewport(width: 669, height: 475, scale: nil))
            try await wait("legacy measured viewport and desktop") { self.relevant(second).count >= 2 }
            check("legacy desktop follows its first viewport", relevant(second).prefix(2).map(\.kind) == [.viewport, .selectSource])
            unmeasured.connection = nil; unmeasured.tearDown(status: "fixture ended", restartSearch: false)

            clearCache()
            let third = try await peer(); peers.append(third)
            let regular = StreamClient()
            regular.connection = third.outgoing; regular.connected = true
            regular.sendViewport(Viewport(width: 390, height: 300, scale: nil))
            try deliver(list, to: regular)
            try await wait("legacy capability before scene") { regular.hostRenderedNativeDesktop == false }
            try await barrier(regular, third, 43)
            check("legacy host waits until scene type is known", relevant(third).isEmpty)
            regular.updateDuoNativeResolution(innerDisplay: false, frame: .zero, fold: nil)
            try await wait("regular legacy viewport and desktop") { self.relevant(third).count >= 2 }
            let normal = relevant(third)
            let normalViewport = normal.first.flatMap { Wire.decode(Viewport.self, from: $0.payload) }
            check("ordinary legacy scene still sends its viewport then desktop", normal.prefix(2).map(\.kind) == [.viewport, .selectSource]
                  && normalViewport?.desktopResolution == nil)
            regular.connection = nil; regular.tearDown(status: "fixture ended", restartSearch: false)

            clearCache()
            let fourth = try await peer(); peers.append(fourth)
            let strict = StreamClient()
            strict.connection = fourth.outgoing; strict.connected = true
            setInner(strict, rendered: false)
            strict.sendViewport(Viewport(width: 669, height: 475, scale: nil))
            try deliver(WindowList(macName: "strict fixture", windows: [], active: .none,
                                   renderedNativeDesktop: true), to: strict)
            try await wait("strict capability") { strict.hostRenderedNativeDesktop == true }
            strict.launch(bundleID: "org.duodesk.fixture.launch")
            try await barrier(strict, fourth, 44)
            check("strict host still waits for render pixels and holds launches", nativeActions(fourth).isEmpty)
            setInner(strict, rendered: true)
            try await wait("strict viewport, desktop and launch") { self.nativeActions(fourth).count >= 3 }
            let strictMessages = nativeActions(fourth)
            let strictViewport = strictMessages.first.flatMap { Wire.decode(Viewport.self, from: $0.payload) }
            check("strict viewport still precedes desktop and launch", strictMessages.prefix(3).map(\.kind) == [.viewport, .selectSource, .launchApp]
                  && strictViewport?.desktopResolution == DuoDesktopResolution(width: 2007, height: 1427))
            strict.connection = nil; strict.tearDown(status: "fixture ended", restartSearch: false)

            // Mount the real stream screen without injecting geometry callbacks. This checks that
            // its own lifecycle can release the startup gate; the peer still carries no video.
            clearCache()
            let fifth = try await peer(); peers.append(fifth)
            let screenClient = StreamClient()
            screenClient.connection = fifth.outgoing; screenClient.connected = true
            guard let window else { throw ProbeFailure.failed("missing simulator window") }
            window.rootViewController = UIHostingController(rootView: StreamScreen(client: screenClient))
            window.makeKeyAndVisible()
            try deliver(list, to: screenClient)
            try await wait("real stream screen released legacy viewport") { self.relevant(fifth).count >= 2 }
            let screenMessages = relevant(fifth)
            let screenViewport = screenMessages.first.flatMap { Wire.decode(Viewport.self, from: $0.payload) }
            check("real stream screen supplies its scene and viewport", screenClient.nativeInnerDisplay != nil
                  && screenMessages.prefix(2).map(\.kind) == [.viewport, .selectSource])
            check("inner Duo never starts the legacy desktop without its native size",
                  screenClient.nativeInnerDisplay != true || screenViewport?.desktopResolution != nil)
            screenClient.connection = nil; screenClient.tearDown(status: "fixture ended", restartSearch: false)
            window.rootViewController = UIViewController()
        } catch { rows.append(["name": "fixture error: \(error)", "passed": false]) }
        let passed = !rows.isEmpty && rows.allSatisfy { $0["passed"] as? Bool == true }
        let report: [String: Any] = ["passed": passed, "checks": rows,
            "scope": "Production iOS client and local legacy-protocol fixture; no real Mac, Duo or screen capture."]
        let url = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0].appendingPathComponent("legacy-viewport-order-result.json")
        if let data = try? JSONSerialization.data(withJSONObject: report, options: [.prettyPrinted, .sortedKeys]) {
            try? data.write(to: url, options: .atomic)
        }
        print("LEGACY VIEWPORT ORDER: \(passed ? "PASS" : "FAIL") (\(rows.count) checks)")
    }

    @MainActor private func runFullscreenMirrorChecks() async {
        var rows: [[String: Any]] = []
        func check(_ name: String, _ passed: Bool) { rows.append(["name": name, "passed": passed]) }
        var peers: [LoopbackPeer] = []
        defer { peers.forEach { $0.close() } }
        let upper = DuoDesktopResolution(width: 2007, height: 1427)
        let full = DuoDesktopResolution(width: 2007, height: 2853)
        let landscape = DuoDesktopResolution(width: 2853, height: 2007)
        func viewports(_ peer: LoopbackPeer) -> [Viewport] {
            peer.messages.filter { $0.kind == .viewport }.compactMap { Wire.decode(Viewport.self, from: $0.payload) }
        }
        do {
            UserDefaults.standard.removeObject(forKey: DuoStreamPolicy.legacyUpperDisplayKey)
            UserDefaults.standard.removeObject(forKey: DuoStreamPolicy.renderedUpperDisplayKey)
            let peer = try await peer(); peers.append(peer)
            let client = StreamClient()
            client.connection = peer.outgoing; client.connected = true
            setInner(client, rendered: true)
            client.sendViewport(Viewport(width: 669, height: 475, scale: nil))
            try deliver(WindowList(macName: "resizable fixture", windows: [], active: .none,
                                   extendedDesktop: true, renderedNativeDesktop: true, resizableMirror: true), to: client)
            try await wait("initial mirror viewport") { !viewports(peer).isEmpty }
            try await barrier(client, peer, 61)
            check("ordinary remote requests the complete native upper panel", viewports(peer).last?.desktopResolution == upper)
            client.setMirrorFullscreen(true)
            try await barrier(client, peer, 62)
            let immersive = viewports(peer).last
            check("pure mirror immediately requests the whole panel without extension or fallback",
                  immersive?.desktopResolution == full && immersive?.extendedDesktop == nil && immersive?.preservePhysicalMode == nil)
            check("full panel does not overwrite the remembered upper-panel size",
                  DuoStreamPolicy.cachedUpperDisplay(in: .standard, rendered: true) == upper)
            client.nativeDisplayMetrics = DuoNativeDisplayMetrics(pixels: CGSize(width: 2670, height: 1878),
                windowSize: CGSize(width: 951, height: 669), renderPixels: CGSize(width: 2853, height: 2007))
            client.updateDuoNativeResolution(innerDisplay: true, frame: CGRect(x: 0, y: 0, width: 951, height: 669),
                fold: CGRect(x: 455.5, y: 0, width: 40, height: 669), fillDisplay: true)
            try await barrier(client, peer, 63)
            check("rotating pure mirror requests a landscape native canvas", viewports(peer).last?.desktopResolution == landscape)
            client.setMirrorFullscreen(false)
            try await barrier(client, peer, 64)
            check("leaving pure mirror immediately restores the upper panel", viewports(peer).last?.desktopResolution == upper)
            setInner(client, rendered: true)
            for tag: UInt8 in [65, 66] {
                client.setMirrorFullscreen(true)
                try await barrier(client, peer, tag)
                check("repeated pure entry \(tag) stays native", viewports(peer).last?.desktopResolution == full)
                client.setMirrorFullscreen(false)
            }
            try await barrier(client, peer, 67)
            check("repeated pure exits return to the upper panel", viewports(peer).last?.desktopResolution == upper)
            check("extension remains selectable after pure mirror", client.beginExtendedDesktop())
            client.setMirrorFullscreen(true)
            try await barrier(client, peer, 68)
            let extensionViewport = viewports(peer).last
            check("extension uses its own full panel and request identifier",
                  extensionViewport?.desktopResolution == full && extensionViewport?.extendedDesktop == true
                    && extensionViewport?.extendedRequestID != nil)
            let beforeExit = viewports(peer).count
            client.setMirrorFullscreen(false)
            client.endExtendedDesktop()
            try await barrier(client, peer, 69)
            let exiting = Array(viewports(peer).dropFirst(beforeExit))
            check("extension exit sends only one upper mirror, without an intermediate full mirror",
                  exiting.count == 1 && exiting[0].desktopResolution == upper && exiting[0].extendedDesktop == nil)
            try deliver(WindowList(macName: "resizable fixture", windows: [], active: .none,
                extendedDesktop: true, desktopIssue: DuoDesktopIssue(resolution: upper, message: "fixture refusal",
                    physicalFallback: DuoDesktopResolution(width: 3840, height: 2160)),
                renderedNativeDesktop: true, resizableMirror: true), to: client)
            try await wait("native mirror refusal") { client.nativeDesktopIssue != nil }
            check("a new host never silently substitutes the Mac's old aspect",
                  !client.usingPhysicalDesktopFallback && client.nativeDesktopResolution == upper)
            client.connection = nil; client.tearDown(status: "fixture ended", restartSearch: false)
            check("disconnect forgets the resize capability", !client.hostResizableMirror)

            let oldPeer = try await self.peer(); peers.append(oldPeer)
            let old = StreamClient()
            old.connection = oldPeer.outgoing; old.connected = true
            setInner(old, rendered: true)
            old.sendViewport(Viewport(width: 669, height: 475, scale: nil))
            try deliver(WindowList(macName: "older fixture", windows: [], active: .none,
                extendedDesktop: true, renderedNativeDesktop: true), to: old)
            try await wait("older host viewport") { !viewports(oldPeer).isEmpty }
            old.setMirrorFullscreen(true)
            try await barrier(old, oldPeer, 70)
            check("an older host keeps its established native size", viewports(oldPeer).last?.desktopResolution == upper)
            old.connection = nil; old.tearDown(status: "fixture ended", restartSearch: false)
        } catch { rows.append(["name": "fixture error: \(error)", "passed": false]) }
        let passed = !rows.isEmpty && rows.allSatisfy { $0["passed"] as? Bool == true }
        let report: [String: Any] = ["passed": passed, "checks": rows,
            "scope": "Production iOS client and loopback peer; no real Mac, Duo, video capture or input."]
        let url = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0].appendingPathComponent("fullscreen-mirror-result.json")
        if let data = try? JSONSerialization.data(withJSONObject: report, options: [.prettyPrinted, .sortedKeys]) {
            try? data.write(to: url, options: .atomic)
        }
        print("FULLSCREEN MIRROR: \(passed ? "PASS" : "FAIL") (\(rows.count) checks)")
    }

    /// Exercises production StreamClient transitions with a loopback peer and no SwiftUI view
    /// change callbacks. A mode change needs its own viewport even before layout remeasures.
    @MainActor private func runExtensionTransitionChecks() async {
        var rows: [[String: Any]] = []
        func check(_ name: String, _ passed: Bool) { rows.append(["name": name, "passed": passed]) }
        var peers: [LoopbackPeer] = []
        defer { peers.forEach { $0.close() } }
        do {
            let peer = try await peer(); peers.append(peer)
            let client = StreamClient()
            client.connection = peer.outgoing; client.connected = true
            setInner(client, rendered: true)
            client.sendViewport(Viewport(width: 669, height: 475, scale: nil))
            try deliver(WindowList(macName: "fixture", windows: [], active: .none,
                                   extendedDesktop: true, renderedNativeDesktop: true), to: client)
            try await wait("initial viewport") {
                self.relevant(peer).contains { $0.kind == .viewport }
            }
            try await barrier(client, peer, 31)
            let initialCount = relevant(peer).count
            check("extension begins", client.beginExtendedDesktop())
            try await barrier(client, peer, 32)
            let afterBegin = Array(relevant(peer).dropFirst(initialCount))
            let began = afterBegin.last.flatMap { $0.kind == .viewport ? Wire.decode(Viewport.self, from: $0.payload) : nil }
            check("begin sends a full extension viewport without a layout callback",
                  began?.extendedDesktop == true && began?.extendedRequestID != nil
                  && began?.desktopResolution == DuoDesktopResolution(width: 2007, height: 2853))
            let afterBeginCount = relevant(peer).count
            client.endExtendedDesktop(resumePaths: false)
            try await barrier(client, peer, 33)
            check("disconnect teardown sends no viewport", relevant(peer).count == afterBeginCount)
            check("a second extension begins", client.beginExtendedDesktop())
            try await barrier(client, peer, 34)
            let beforeExit = relevant(peer).count
            client.endExtendedDesktop()
            try await barrier(client, peer, 35)
            let afterExit = Array(relevant(peer).dropFirst(beforeExit))
            let ended = afterExit.last.flatMap { $0.kind == .viewport ? Wire.decode(Viewport.self, from: $0.payload) : nil }
            check("exit sends the upper mirror without a layout callback",
                  ended?.extendedDesktop == nil && ended?.extendedRequestID == nil
                  && ended?.desktopResolution == DuoDesktopResolution(width: 2007, height: 1427))
            client.connection = nil
            client.tearDown(status: "fixture ended", restartSearch: false)
        } catch { rows.append(["name": "fixture error: \(error)", "passed": false]) }
        let passed = !rows.isEmpty && rows.allSatisfy { $0["passed"] as? Bool == true }
        let report: [String: Any] = ["passed": passed, "checks": rows,
            "scope": "Production iOS client and loopback peer; no SwiftUI layout callback, Mac, real Duo or desktop capture."]
        let url = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0].appendingPathComponent("extension-transition-result.json")
        if let data = try? JSONSerialization.data(withJSONObject: report, options: [.prettyPrinted, .sortedKeys]) {
            try? data.write(to: url, options: .atomic)
        }
        print("EXTENSION TRANSITION: \(passed ? "PASS" : "FAIL") (\(rows.count) checks)")
    }

    @MainActor private func runLaunchChecks() async {
        var rows: [[String: Any]] = []
        func check(_ name: String, _ passed: Bool) { rows.append(["name": name, "passed": passed]) }
        let legacy = DuoDesktopResolution(width: 1878, height: 1335)
        let rendered = DuoDesktopResolution(width: 2007, height: 1427)
        let strict = WindowList(macName: "strict fixture", windows: [], active: .none, renderedNativeDesktop: true)
        var peers: [LoopbackPeer] = []
        defer { peers.forEach { $0.close() } }
        do {
            UserDefaults.standard.removeObject(forKey: DuoStreamPolicy.legacyUpperDisplayKey)
            UserDefaults.standard.removeObject(forKey: DuoStreamPolicy.renderedUpperDisplayKey)
            let first = try await peer(); peers.append(first)
            let client = StreamClient()
            client.connection = first.outgoing; client.connected = true
            setInner(client, rendered: false)
            client.sendViewport(Viewport(width: 669, height: 475, scale: nil, desktopResolution: legacy))
            client.launch(bundleID: "org.duodesk.fixture.first")
            client.launch(bundleID: "org.duodesk.fixture.second")
            client.select(.window(41))
            client.select(.window(42))
            try await barrier(client, first, 11)
            check("launches and source wait for an unknown host", nativeActions(first).isEmpty)
            try deliver(strict, to: client)
            try await wait("strict capability") { client.hostRenderedNativeDesktop == true }
            try await barrier(client, first, 12)
            check("launches wait for the render canvas", nativeActions(first).isEmpty)
            setInner(client, rendered: true)
            try await wait("sized launches and source") { self.nativeActions(first).count >= 4 }
            let actions = nativeActions(first)
            check("viewport precedes both launches and the later source",
                  actions.prefix(4).map(\.kind) == [.viewport, .launchApp, .launchApp, .selectSource])
            check("the viewport contains the render size",
                  actions.first.flatMap { Wire.decode(Viewport.self, from: $0.payload) }?.desktopResolution == rendered)
            let launches = actions.filter { $0.kind == .launchApp }.compactMap { Wire.decode(LaunchApp.self, from: $0.payload)?.bundleID }
            check("every launch is retained in order", launches == ["org.duodesk.fixture.first", "org.duodesk.fixture.second"])
            check("consecutive source choices keep only the latest",
                  actions.filter { $0.kind == .selectSource }.count == 1
                  && actions.last.flatMap { Wire.decode(StreamSource.self, from: $0.payload) } == .window(42))
            client.launch(bundleID: "org.duodesk.fixture.ready")
            try await wait("ready launch") { self.nativeActions(first).filter { $0.kind == .launchApp }.count == 3 }
            check("a ready connection launches without waiting for another viewport",
                  nativeActions(first).last.flatMap { Wire.decode(LaunchApp.self, from: $0.payload)?.bundleID } == "org.duodesk.fixture.ready")
            client.connection = nil; client.tearDown(status: "fixture ended", restartSearch: false)

            let launchOnlyPeer = try await peer(); peers.append(launchOnlyPeer)
            let launchOnly = StreamClient()
            launchOnly.connection = launchOnlyPeer.outgoing; launchOnly.connected = true
            setInner(launchOnly, rendered: false)
            launchOnly.sendViewport(Viewport(width: 669, height: 475, scale: nil, desktopResolution: legacy))
            launchOnly.launch(bundleID: "org.duodesk.fixture.may-fail")
            try deliver(strict, to: launchOnly)
            try await wait("launch-only capability") { launchOnly.hostRenderedNativeDesktop == true }
            try await barrier(launchOnly, launchOnlyPeer, 13)
            check("a launch-only request still waits for render geometry", nativeActions(launchOnlyPeer).isEmpty)
            setInner(launchOnly, rendered: true)
            try await wait("launch with desktop fallback") { self.nativeActions(launchOnlyPeer).count >= 3 }
            let launchOnlyActions = nativeActions(launchOnlyPeer)
            check("a pending launch retains an automatic desktop fallback",
                  launchOnlyActions.prefix(3).map(\.kind) == [.viewport, .selectSource, .launchApp])
            launchOnly.connection = nil; launchOnly.tearDown(status: "fixture ended", restartSearch: false)

            let automaticPeer = try await peer(); peers.append(automaticPeer)
            let automatic = StreamClient()
            automatic.connection = automaticPeer.outgoing; automatic.connected = true
            setInner(automatic, rendered: false)
            automatic.sendViewport(Viewport(width: 669, height: 475, scale: nil, desktopResolution: legacy))
            try deliver(strict, to: automatic)
            try await wait("automatic strict capability") { automatic.hostRenderedNativeDesktop == true }
            automatic.launch(bundleID: "org.duodesk.fixture.after-auto")
            setInner(automatic, rendered: true)
            try await wait("automatic desktop and launch") { self.nativeActions(automaticPeer).count >= 3 }
            let autoActions = nativeActions(automaticPeer)
            check("an already pending automatic desktop precedes the explicit launch",
                  autoActions.prefix(3).map(\.kind) == [.viewport, .selectSource, .launchApp])
            automatic.connection = nil; automatic.tearDown(status: "fixture ended", restartSearch: false)

            let choicePeer = try await peer(); peers.append(choicePeer)
            let choice = StreamClient()
            choice.connection = choicePeer.outgoing; choice.connected = true
            setInner(choice, rendered: false)
            choice.sendViewport(Viewport(width: 669, height: 475, scale: nil, desktopResolution: legacy))
            try deliver(strict, to: choice)
            try await wait("choice capability") { choice.hostRenderedNativeDesktop == true }
            choice.launch(bundleID: "org.duodesk.fixture.keep")
            choice.select(.window(7))
            setInner(choice, rendered: true)
            try await wait("launch and later choice") { self.nativeActions(choicePeer).count >= 3 }
            let choiceActions = nativeActions(choicePeer)
            check("a later source replaces automatic selection without losing the launch",
                  choiceActions.prefix(3).map(\.kind) == [.viewport, .launchApp, .selectSource]
                  && choiceActions.last.flatMap { Wire.decode(StreamSource.self, from: $0.payload) } == .window(7))
            choice.connection = nil; choice.tearDown(status: "fixture ended", restartSearch: false)

            let oldPeer = try await peer(); peers.append(oldPeer)
            let old = StreamClient()
            old.connection = oldPeer.outgoing; old.connected = true
            setInner(old, rendered: true)
            old.sendViewport(Viewport(width: 669, height: 475, scale: nil, desktopResolution: legacy))
            old.launch(bundleID: "org.duodesk.fixture.legacy")
            try deliver(WindowList(macName: "old fixture", windows: [], active: .none), to: old)
            try await wait("legacy launch") { self.nativeActions(oldPeer).count >= 2 }
            let oldActions = nativeActions(oldPeer)
            check("legacy host receives its original viewport then the launch",
                  oldActions.prefix(2).map(\.kind) == [.viewport, .launchApp]
                  && oldActions.first.flatMap { Wire.decode(Viewport.self, from: $0.payload) }?.desktopResolution == legacy)
            old.connection = nil; old.tearDown(status: "fixture ended", restartSearch: false)

            let gonePeer = try await peer(); peers.append(gonePeer)
            let gone = StreamClient()
            gone.connection = gonePeer.outgoing; gone.connected = true
            setInner(gone, rendered: false)
            gone.launch(bundleID: "org.duodesk.fixture.cancelled")
            gone.connection = nil; gone.tearDown(status: "fixture ended", restartSearch: false)
            let freshPeer = try await peer(); peers.append(freshPeer)
            gone.connection = freshPeer.outgoing; gone.connected = true
            setInner(gone, rendered: true)
            gone.sendViewport(Viewport(width: 669, height: 475, scale: nil, desktopResolution: legacy))
            try deliver(strict, to: gone)
            try await wait("fresh session desktop") { self.nativeActions(freshPeer).count >= 2 }
            check("a disconnected session cannot launch an app in the next session",
                  !nativeActions(freshPeer).contains { $0.kind == .launchApp })
            gone.connection = nil; gone.tearDown(status: "fixture ended", restartSearch: false)
        } catch { rows.append(["name": "fixture error: \(error)", "passed": false]) }
        let passed = !rows.isEmpty && rows.allSatisfy { $0["passed"] as? Bool == true }
        let report: [String: Any] = ["passed": passed, "checks": rows,
            "scope": "Production iOS client and loopback peer only; no Mac app was launched, no real Duo or desktop capture."]
        let url = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0].appendingPathComponent("native-launch-result.json")
        if let data = try? JSONSerialization.data(withJSONObject: report, options: [.prettyPrinted, .sortedKeys]) {
            try? data.write(to: url, options: .atomic)
        }
        print("NATIVE LAUNCH ORDER PROBE \(passed ? "PASS" : "FAIL"): \(rows.count) checks")
        exit(passed ? 0 : 1)
    }
}
