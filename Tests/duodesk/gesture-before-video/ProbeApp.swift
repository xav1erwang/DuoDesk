// Copyright 2026 DUO你电脑 contributors. SPDX-License-Identifier: Apache-2.0
// Production StreamClient, a fake session and an owned loopback TCP peer. No Mac receives input.
import UIKit
import Network
import StreamProtocol

enum ProbeFailure: Error { case failed(String) }

final class LoopbackPeer: @unchecked Sendable {
    private let queue = DispatchQueue(label: "duodesk.gesture-probe-peer")
    private let lock = NSLock()
    private let listener: NWListener
    private var incoming: NWConnection?
    private var portValue: NWEndpoint.Port?
    private var connectedValue = false
    private var received = Data()
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
    var connected: Bool { lock.withLock { connectedValue } }
    var error: String? { lock.withLock { errorValue } }

    func connect(to port: NWEndpoint.Port) {
        let connection = NWConnection(host: .ipv4(.loopback), port: port, using: .tcp)
        outgoing = connection
        connection.stateUpdateHandler = { [weak self] state in
            guard let self else { return }
            switch state {
            case .ready: self.lock.withLock { self.connectedValue = true }
            case .failed(let error): self.lock.withLock { self.errorValue = String(describing: error) }
            default: break
            }
        }
        connection.start(queue: queue)
    }

    private func read(_ connection: NWConnection) {
        connection.receive(minimumIncompleteLength: 1, maximumLength: 65536) { [weak self] data, _, done, error in
            guard let self else { return }
            if let data { self.lock.withLock { self.received.append(data) } }
            if let error { self.lock.withLock { self.errorValue = String(describing: error) } }
            if !done && error == nil { self.read(connection) }
        }
    }

    var kinds: [StreamMessageKind] {
        let data = lock.withLock { received }
        var offset = 0, kinds: [StreamMessageKind] = []
        while data.count - offset >= StreamMessage.headerLength {
            let headerData = data.subdata(in: offset..<(offset + StreamMessage.headerLength))
            guard let header = StreamMessage.parseHeader(headerData),
                  header.payloadLength <= StreamMessage.maxClientPayload,
                  data.count - offset - StreamMessage.headerLength >= header.payloadLength else { break }
            kinds.append(header.kind)
            offset += StreamMessage.headerLength + header.payloadLength
        }
        return kinds
    }

    func close() { outgoing?.cancel(); lock.withLock { incoming }?.cancel(); listener.cancel() }
}

@main final class ProbeApp: UIResponder, UIApplicationDelegate {
    func application(_ application: UIApplication, configurationForConnecting session: UISceneSession,
                     options: UIScene.ConnectionOptions) -> UISceneConfiguration {
        let config = UISceneConfiguration(name: "Gesture gate", sessionRole: session.role)
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
        Task { @MainActor in await run() }
    }

    @MainActor private func wait(_ name: String, _ condition: () -> Bool) async throws {
        let deadline = ContinuousClock.now + .seconds(5)
        while !condition() {
            guard ContinuousClock.now < deadline else { throw ProbeFailure.failed(name) }
            try await Task.sleep(for: .milliseconds(10))
        }
    }

    @MainActor private func run() async {
        var rows: [[String: Any]] = []
        func check(_ name: String, _ value: Bool) { rows.append(["name": name, "passed": value]) }
        var heldQueue: DispatchSemaphore?
        do {
            UserDefaults.standard.removeObject(forKey: "duodesk.nativeUpperDisplay")
            UserDefaults.standard.set(true, forKey: StreamClient.gesturesKey)
            let peer = try LoopbackPeer()
            defer { peer.close(); heldQueue?.signal() }
            try await wait("loopback listener") { peer.port != nil || peer.error != nil }
            guard let port = peer.port else { throw ProbeFailure.failed("loopback listener failed") }
            peer.connect(to: port)
            try await wait("loopback connection") { peer.connected || peer.error != nil }
            guard peer.connected, let connection = peer.outgoing else { throw ProbeFailure.failed("loopback connection failed") }
            let client = StreamClient()
            client.connection = connection
            client.connected = true
            client.hostGestures = TrackpadGesture.generation
            client.active = .desktop

            // The existing non-Duo path must retain its working gesture behavior.
            check("legacy gesture accepted", client.sendGesture(.swipeUp, fingers: 3))
            try await wait("first legacy gesture") { peer.kinds == [.gesture] }
            let entered = DispatchSemaphore(value: 0), release = DispatchSemaphore(value: 0)
            heldQueue = release
            client.queue.async { entered.signal(); release.wait() }
            try await wait("held client network queue") { entered.wait(timeout: .now()) == .success }
            check("queued legacy gesture initially accepted", client.sendGesture(.swipeLeft, fingers: 3))
            // The hinge has reported the inner display, but metrics and its first native image
            // have not yet arrived. Revoke any legacy gesture held on the network queue.
            client.updateDuoNativeResolution(innerDisplay: true, frame: .zero, fold: nil)
            release.signal(); heldQueue = nil
            let firstBarrier = StreamMessage(kind: .ping, timestamp: 0, isKeyframe: false, payload: Data([1])).serialized()
            client.queue.async { connection.send(content: firstBarrier, completion: .contentProcessed { _ in }) }
            try await wait("first barrier") { peer.kinds.contains(.ping) }
            check("queued gesture fenced when Duo is detected", peer.kinds == [.gesture, .ping])
            check("Duo gesture withheld before native metrics", !client.sendGesture(.swipeDown, fingers: 3))
            client.updateDuoNativeResolution(innerDisplay: false, frame: .zero, fold: nil)
            check("folding again cannot restore legacy gestures", !client.sendGesture(.pinch, fingers: 3))

            client.nativeDisplayMetrics = DuoNativeDisplayMetrics(pixels: CGSize(width: 2007, height: 2853),
                                                                 windowSize: CGSize(width: 669, height: 951))
            client.updateDuoNativeResolution(innerDisplay: true, frame: CGRect(x: 0, y: 0, width: 669, height: 951),
                                             fold: CGRect(x: 0, y: 455.5, width: 669, height: 40))
            check("native size established", client.nativeDesktopResolution == DuoDesktopResolution(width: 2007, height: 1427))
            check("Duo gesture withheld until native image", !client.sendGesture(.spread, fingers: 3))
            let secondBarrier = StreamMessage(kind: .ping, timestamp: 0, isKeyframe: false, payload: Data([2])).serialized()
            client.queue.async { connection.send(content: secondBarrier, completion: .contentProcessed { _ in }) }
            try await wait("second barrier") { peer.kinds.filter { $0 == .ping }.count == 2 }
            check("no blocked gesture reached peer", peer.kinds == [.gesture, .ping, .ping])

            // Also exercise the actual session handover buffer: the network queue has already
            // delivered this gesture to SessionLink, but its held connection has not sent it.
            UserDefaults.standard.removeObject(forKey: "duodesk.nativeUpperDisplay")
            let moving = StreamClient()
            moving.connection = connection; moving.connected = true
            moving.hostGestures = TrackpadGesture.generation; moving.active = .desktop
            guard moving.holdGestureLinkForTesting(connection) else { throw ProbeFailure.failed("session hold") }
            check("held legacy gesture initially accepted", moving.sendGesture(.swipeUp, fingers: 3))
            let queued = DispatchSemaphore(value: 0)
            moving.queue.async { queued.signal() }
            try await wait("gesture reached held session link") { queued.wait(timeout: .now()) == .success }
            moving.updateDuoNativeResolution(innerDisplay: true, frame: .zero, fold: nil)
            moving.releaseGestureLinkForTesting(connection)
            let thirdBarrier = StreamMessage(kind: .ping, timestamp: 0, isKeyframe: false, payload: Data([3])).serialized()
            moving.queue.async { connection.send(content: thirdBarrier, completion: .contentProcessed { _ in }) }
            try await wait("handover barrier") { peer.kinds.filter { $0 == .ping }.count == 3 }
            check("held session gesture fenced when Duo is detected", peer.kinds == [.gesture, .ping, .ping, .ping])
        } catch { rows.append(["name": "fixture error: \(error)", "passed": false]) }
        let passed = !rows.isEmpty && rows.allSatisfy { $0["passed"] as? Bool == true }
        let report: [String: Any] = ["passed": passed, "checks": rows,
            "scope": "Production client with fake connection state and a loopback peer; no Mac, real Duo, display capture or system input."]
        let url = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0].appendingPathComponent("gesture-result.json")
        if let data = try? JSONSerialization.data(withJSONObject: report, options: [.prettyPrinted, .sortedKeys]) {
            try? data.write(to: url, options: .atomic)
        }
    }
}
