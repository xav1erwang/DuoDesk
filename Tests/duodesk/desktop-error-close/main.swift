// Copyright 2026 DUO你电脑 contributors. SPDX-License-Identifier: Apache-2.0
// The real coordinator handles a simulated capture error over a loopback-only synthetic server.
// No screen capture, input injection, keychain access, external network or real Duo is involved.
import Foundation
import Network
import ScreenCaptureKit
import StreamProtocol

struct CheckFailure: Error { let message: String }

final class Once: @unchecked Sendable {
    private let lock = NSLock()
    private var done = false
    func first() -> Bool { lock.withLock { if done { return false }; done = true; return true } }
}

final class ClientState: @unchecked Sendable {
    private let lock = NSLock()
    private var ready = false
    func update(_ state: NWConnection.State) { if case .ready = state { lock.withLock { ready = true } } }
    var isReady: Bool { lock.withLock { ready } }
}

enum ReadResult {
    case data(Data)
    case ended
    case timeout
}

func read(_ count: Int, from connection: NWConnection) async -> ReadResult {
    let once = Once()
    return await withCheckedContinuation { continuation in
        connection.receive(minimumIncompleteLength: count, maximumLength: count) { data, _, complete, error in
            guard once.first() else { return }
            if let data, data.count == count { continuation.resume(returning: .data(data)) }
            else if complete || error != nil { continuation.resume(returning: .ended) }
            else { continuation.resume(returning: .ended) }
        }
        DispatchQueue.global().asyncAfter(deadline: .now() + 2) {
            guard once.first() else { return }
            connection.cancel()
            continuation.resume(returning: .timeout)
        }
    }
}

@main
@MainActor
struct Checks {
    static func waitFor(_ message: String, _ condition: () -> Bool) async throws {
        let deadline = ContinuousClock.now + .seconds(5)
        while !condition() {
            guard ContinuousClock.now < deadline else { throw CheckFailure(message: message) }
            try await Task.sleep(for: .milliseconds(10))
        }
    }

    static func run() async throws {
        let host = try StreamCoordinator(config: .standard, synthetic: true, appKitLoop: false)
        guard host.server.loopbackOnly else { throw CheckFailure(message: "Test listener is not restricted to loopback") }
        let server = host.server
        defer {
            host.shutdownForExit()
            server.queue.sync { server.listener.cancel() }
        }
        host.server.start()
        try await waitFor("loopback listener did not start") { host.server.port != nil }
        guard let port = host.server.port.flatMap(NWEndpoint.Port.init(rawValue:)) else {
            throw CheckFailure(message: "No loopback port")
        }
        let client = NWConnection(host: "127.0.0.1", port: port, using: .tcp)
        let state = ClientState()
        client.stateUpdateHandler = { state.update($0) }
        client.start(queue: DispatchQueue(label: "duo.test.desktop-error-client"))
        defer { client.cancel() }
        try await waitFor("loopback client was not admitted") { state.isReady && host.catalog.clientCount == 1 && host.routes.count == 1 }

        let generation = UUID()
        host.capture.generation = generation
        let stop = WindowCapture.Stop(error: WindowCapture.NativeGeometryFailure.frame, generation: generation)
        await host.captureStopped(stop)

        // Leave the peer open briefly, as a phone can still have requests in flight when a
        // terminal error arrives. An immediate cancel can reset the connection before goodbye.
        try await Task.sleep(for: .milliseconds(60))
        let draining = server.queue.sync { server.clients.values.contains { $0.touchBarClosing } }
        guard draining else { throw CheckFailure(message: "Terminal close cancelled the session before its goodbye could drain") }
        let late = Viewport(width: 669, height: 476, scale: nil, desktopResolution: .init(width: 2007, height: 1427))
        client.send(content: StreamMessage(kind: .viewport, timestamp: 0, isKeyframe: false, payload: Wire.encode(late)).serialized(),
                    completion: .idempotent)
        try await Task.sleep(for: .milliseconds(60))
        guard host.viewport == nil else { throw CheckFailure(message: "A closing session accepted a late viewport") }

        var goodbye: Goodbye?
        var ended = false
        for _ in 0..<20 {
            switch await read(StreamMessage.headerLength, from: client) {
            case .ended: ended = true
            case .timeout: throw CheckFailure(message: "Terminal error left the client connection open")
            case .data(let bytes):
                guard let header = StreamMessage.parseHeader(bytes), header.payloadLength <= StreamMessage.maxClientPayload else {
                    throw CheckFailure(message: "Invalid message header")
                }
                let payload: Data
                if header.payloadLength == 0 { payload = Data() }
                else {
                    guard case .data(let bytes) = await read(header.payloadLength, from: client) else {
                        throw CheckFailure(message: "Message ended before its payload")
                    }
                    payload = bytes
                }
                if header.kind == .goodbye { goodbye = Wire.decode(Goodbye.self, from: payload) }
            }
            if ended { break }
        }
        guard ended, let goodbye, goodbye.reason == "duoResolution", goodbye.reconnect == false,
              goodbye.message == WindowCapture.NativeGeometryFailure.frame.localizedDescription else {
            throw CheckFailure(message: "Missing error, expected message or bounded connection close")
        }
        print("DESKTOP ERROR CLOSE PASS: real coordinator sent the resolution error and closed the loopback session; no screen capture or input")
    }

    static func recoverableMirror() async throws {
        let host = try StreamCoordinator(config: .standard, synthetic: true, appKitLoop: false)
        guard host.server.loopbackOnly else { throw CheckFailure(message: "Test listener is not restricted to loopback") }
        let server = host.server
        host.extendedDesktopAvailable = true
        defer {
            host.shutdownForExit()
            server.queue.sync { server.listener.cancel() }
        }
        server.start()
        try await waitFor("recovery listener did not start") { server.port != nil }
        guard let port = server.port.flatMap(NWEndpoint.Port.init(rawValue:)) else {
            throw CheckFailure(message: "No loopback port for recovery")
        }
        let client = NWConnection(host: "127.0.0.1", port: port, using: .tcp)
        let state = ClientState()
        client.stateUpdateHandler = { state.update($0) }
        client.start(queue: DispatchQueue(label: "duo.test.desktop-recovery-client"))
        defer { client.cancel() }
        try await waitFor("recovery client was not admitted") { state.isReady && host.routes.count == 1 }
        guard let id = host.routes.keys.first else { throw CheckFailure(message: "Missing recovery client") }
        let upper = DuoDesktopResolution(width: 2007, height: 1427)
        let failure = DuoDesktopDisplay.Failure.refreshInvariantUnavailable
        guard !host.offerExtensionAfterMirrorFailure(failure, resolution: upper) else {
            throw CheckFailure(message: "An older client was offered an issue it cannot handle")
        }
        let viewport = Viewport(width: 669, height: 475, scale: nil, desktopResolution: upper,
                                recoverableDesktopFailure: true)
        let message = StreamMessage(kind: .viewport, timestamp: 0, isKeyframe: false, payload: Wire.encode(viewport))
        client.send(content: message.serialized(), completion: .idempotent)
        try await waitFor("recovery capability did not reach the coordinator") {
            host.clientsWithDesktopRecovery.contains(id) && host.clientDesktopResolutions[id] == upper
        }
        guard !host.offerExtensionAfterMirrorFailure(DuoDesktopDisplay.Failure.restorePending, resolution: upper),
              !host.offerExtensionAfterMirrorFailure(failure, resolution: DuoDesktopResolution(width: 1878, height: 1335)) else {
            throw CheckFailure(message: "An unrelated failure or stale size was treated as recoverable")
        }
        let other = NWConnection(host: "127.0.0.1", port: 9, using: .tcp)
        host.routes[ObjectIdentifier(other)] = .home(.loopback, peer: nil)
        guard !host.offerExtensionAfterMirrorFailure(failure, resolution: upper) else {
            throw CheckFailure(message: "A shared pipeline was treated as a one-device recovery")
        }
        host.routes[ObjectIdentifier(other)] = nil
        guard host.offerExtensionAfterMirrorFailure(failure, resolution: upper) else {
            throw CheckFailure(message: "The capable sole client was not offered an extension")
        }
        host.broadcastList()
        var receivedIssue = false
        for _ in 0..<20 {
            guard case .data(let bytes) = await read(StreamMessage.headerLength, from: client),
                  let header = StreamMessage.parseHeader(bytes), header.payloadLength <= StreamMessage.maxOtherHostPayload else {
                throw CheckFailure(message: "Recovery connection ended before its issue")
            }
            let payload: Data
            if header.payloadLength == 0 { payload = Data() }
            else {
                guard case .data(let bytes) = await read(header.payloadLength, from: client) else {
                    throw CheckFailure(message: "Recovery message ended before its payload")
                }
                payload = bytes
            }
            if header.kind == .goodbye { throw CheckFailure(message: "Recoverable failure sent a goodbye") }
            if header.kind == .windowList, let list = Wire.decode(WindowList.self, from: payload),
               list.desktopIssue?.resolution == upper, list.extendedDesktop == true {
                receivedIssue = true
                break
            }
        }
        guard receivedIssue else { throw CheckFailure(message: "No recovery issue arrived") }
        // Hold the coordinator in its existing switch state so this checks admission and cleanup
        // without starting a synthetic video source or creating any virtual display.
        host.switching = true
        let token = UUID()
        let extended = Viewport(width: 669, height: 951, scale: nil,
                                desktopResolution: DuoDesktopResolution(width: 2007, height: 2853),
                                extendedDesktop: true, extendedRequestID: token, recoverableDesktopFailure: true)
        let request = StreamMessage(kind: .viewport, timestamp: 0, isKeyframe: false, payload: Wire.encode(extended))
        client.send(content: request.serialized(), completion: .idempotent)
        try await waitFor("extension request was not admitted after recovery") {
            host.clientExtendedRequests[id] == token && host.desktopIssue == nil && host.viewportArrivedWhileSwitching
        }
        let laneOpen = server.queue.sync { server.clients[id].map { !$0.touchBarClosing } ?? false }
        guard laneOpen else { throw CheckFailure(message: "Recovery revoked the live video lane") }
        host.switching = false
        print("DESKTOP RECOVERY PASS: negotiated issue reached one loopback client, then extension was admitted with its video lane open; no capture, input or display mutation")
    }

    static func main() async {
        do { try await run(); try await recoverableMirror() }
        catch { print("DESKTOP ERROR CLOSE FAIL: \(error)"); exit(1) }
    }
}
