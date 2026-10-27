// Copyright 2026 DUO你电脑 contributors. SPDX-License-Identifier: Apache-2.0
// Production QUIC door and framing over localhost, with fresh identities held only in memory.
import Foundation
import Network
import Security
import StreamProtocol

final class LoopbackVideo: @unchecked Sendable {
    enum Failure: Error { case configuration, identity, timeout, authentication, framing, disconnected }
    private final class State: @unchecked Sendable {
        private let lock = NSLock()
        private var admitted = false, ended = false
        private var failure: String?
        private var frames = 0, keyframes = 0, parameters = 0, resets = 0
        private var wireLatencies: [Double] = []
        private var invalidLatencies = 0
        func accept() { lock.withLock { admitted = true } }
        func stop() { lock.withLock { ended = true } }
        func fail(_ text: String) { lock.withLock { if !ended { failure = text } } }
        var snapshot: (Bool, String?) { lock.withLock { (admitted, failure) } }
        func received(_ kind: StreamMessageKind, keyframe: Bool, sentAt: Double) {
            lock.withLock {
                switch kind {
                case .frame:
                    frames += 1; if keyframe { keyframes += 1 }
                    let milliseconds = (Date().timeIntervalSince1970 - sentAt) * 1000
                    if milliseconds.isFinite && milliseconds >= 0 && milliseconds < 60_000 { wireLatencies.append(milliseconds) }
                    else { invalidLatencies += 1 }
                case .parameterSets: parameters += 1
                case .streamReset: resets += 1
                default: break
                }
            }
        }
        var counters: (frames: Int, keyframes: Int, parameters: Int, resets: Int) {
            lock.withLock { (frames, keyframes, parameters, resets) }
        }
        var latencyReport: String {
            lock.withLock {
                let values = wireLatencies.sorted()
                guard !values.isEmpty else { return "LOOPBACK WIRE MS unavailable; invalid=\(invalidLatencies)" }
                let p95 = values[(values.count * 95 + 99) / 100 - 1]
                return String(format: "LOOPBACK WIRE MS: n=%d p50=%.3f p95=%.3f max=%.3f invalid=%d; encoder callback to full framed receipt only; capture, encoding, decode, display, input and public network excluded",
                              values.count, values[values.count / 2], p95, values.last ?? 0, invalidLatencies)
            }
        }
    }
    private final class Once: @unchecked Sendable {
        private let lock = NSLock(); private var answered = false
        func first() -> Bool { lock.withLock { if answered { return false }; answered = true; return true } }
    }

    private let server: StreamServer
    private let connection: NWConnection
    private let decoder: HardwareHEVCDecoder
    private let state: State
    private let token = UUID()
    private var reader: Task<Void, Never>?

    private init(server: StreamServer, connection: NWConnection, decoder: HardwareHEVCDecoder, state: State) {
        self.server = server; self.connection = connection; self.decoder = decoder; self.state = state
    }

    static func connect(decoder: HardwareHEVCDecoder, encoder: HEVCEncoder) async throws -> LoopbackVideo {
        let env = ProcessInfo.processInfo.environment
        guard env["SILL_TEST_LOOPBACK"] == "1", (env["SILL_TEST_SERVICE_TYPE"] ?? "").isEmpty else {
            throw Failure.configuration
        }
        let store = MemoryIdentityStore()
        guard let host = HostIdentity(privateKey: try store.loadOrCreateKey(), recognitionKey: try store.loadOrCreateRecognitionKey()),
              let deviceKey = RemoteKey.generate(), let device = RemoteIdentity(privateKey: deviceKey) else { throw Failure.identity }
        let trust = TrustBox()
        trust.update { $0.paired[device.fingerprint] = "Own local test" }
        let state = State()
        let server = try StreamServer(advertise: false, home: .tls(.init(identity: host, trust: trust)), testHooks: true)
        guard server.loopbackOnly else { throw Failure.configuration }
        server.onListenerFailed = { state.fail("listener: \($0)") }
        server.onClientConnected = { _, _, _ in state.accept() }
        server.onClientDisconnected = { _ in state.fail("client disconnected") }
        server.onKeyframeNeeded = { [weak encoder] in encoder?.requestKeyframe() }
        server.start()
        let limit = ProcessInfo.processInfo.systemUptime + 8
        var port: UInt16?
        while ProcessInfo.processInfo.systemUptime < limit {
            if let error = state.snapshot.1 { throw NSError(domain: "DuoLoopback", code: 1, userInfo: [NSLocalizedDescriptionKey: error]) }
            if let ready = server.port { port = ready; break }
            try await Task.sleep(for: .milliseconds(40))
        }
        guard let port else { throw Failure.timeout }
        // UDP companion starts after TCP becomes ready; no external address or Bonjour service.
        try await Task.sleep(for: .milliseconds(300))
        let networkQueue = DispatchQueue(label: "duodesk.owned-loopback-client", qos: .userInteractive)
        let options = RemoteTLS.quicOptions(identity: device.tls, role: .client(alpn: RemoteTLS.sessionALPN), queue: networkQueue) { peer, alpn in
            peer == host.fingerprint && alpn == RemoteTLS.sessionALPN
        }
        let parameters = RemoteTLS.quicParameters(options: options)
        let connection = NWConnection(host: "127.0.0.1", port: NWEndpoint.Port(rawValue: port)!, using: parameters)
        try await ready(connection, hostFingerprint: host.fingerprint, queue: networkQueue)
        let loop = LoopbackVideo(server: server, connection: connection, decoder: decoder, state: state)
        loop.reader = Task.detached { [weak loop] in await loop?.receiveLoop() }
        let hello = Hello(appVersion: "0.1.0", build: "local", protocol: SillProtocol.current, device: "Own local test")
        loop.sendControl(.hello, payload: Wire.encode(hello))
        let admissionDeadline = ProcessInfo.processInfo.systemUptime + 8
        while ProcessInfo.processInfo.systemUptime < admissionDeadline {
            let (admitted, error) = state.snapshot
            if let error { connection.cancel(); throw NSError(domain: "DuoLoopback", code: 2, userInfo: [NSLocalizedDescriptionKey: error]) }
            if admitted {
                var epoch = VideoStreamEpoch()
                server.beginVideoStream(loop.token, reset: epoch.nextReset())
                print("OWN LOOPBACK QUIC READY: 127.0.0.1 only, mutual TLS 1.3, ephemeral in-memory identities")
                return loop
            }
            try await Task.sleep(for: .milliseconds(40))
        }
        connection.cancel(); throw Failure.timeout
    }

    private static func ready(_ connection: NWConnection, hostFingerprint: Data, queue: DispatchQueue) async throws {
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, any Error>) in
            let once = Once()
            @Sendable func finish(_ result: Result<Void, any Error>) {
                guard once.first() else { return }
                connection.stateUpdateHandler = nil
                continuation.resume(with: result)
            }
            connection.stateUpdateHandler = { state in
                switch state {
                case .ready:
                    guard connection.metadata(definition: NWProtocolQUIC.definition) != nil,
                          RemoteTLS.negotiatedALPN(connection) == RemoteTLS.sessionALPN,
                          RemoteTLS.peerFingerprint(connection) == hostFingerprint,
                          let metadata = RemoteTLS.securityMetadata(connection),
                          sec_protocol_metadata_get_negotiated_tls_protocol_version(metadata) == .TLSv13 else {
                        connection.cancel(); finish(.failure(Failure.authentication)); return
                    }
                    finish(.success(()))
                case .failed(let error): connection.cancel(); finish(.failure(error))
                case .cancelled: finish(.failure(Failure.disconnected))
                default: break
                }
            }
            connection.start(queue: queue)
            queue.asyncAfter(deadline: .now() + 8) {
                guard once.first() else { return }
                connection.stateUpdateHandler = nil
                connection.cancel()
                continuation.resume(throwing: Failure.timeout)
            }
        }
    }

    func sendEncoded(_ bytes: Data, keyframe: Bool, parameters: ParameterSets?) {
        let now = Date().timeIntervalSince1970
        if let parameters {
            server.broadcast(StreamMessage(kind: .parameterSets, timestamp: now, isKeyframe: true,
                                           payload: parameters.encoded()), videoToken: token)
        }
        server.broadcast(StreamMessage(kind: .frame, timestamp: now, isKeyframe: keyframe, payload: bytes), videoToken: token)
    }

    func requestKeyframe() { sendControl(.requestKeyframe) }
    private func sendControl(_ kind: StreamMessageKind, payload: Data = Data()) {
        let data = StreamMessage(kind: kind, timestamp: Date().timeIntervalSince1970, isKeyframe: false, payload: payload).serialized()
        connection.send(content: data, completion: .contentProcessed { [state] error in
            if let error { state.fail("send: \(error)") }
        })
    }

    private func read(_ count: Int) async throws -> Data {
        if count == 0 { return Data() }
        return try await withCheckedThrowingContinuation { continuation in
            connection.receive(minimumIncompleteLength: count, maximumLength: count) { data, _, _, error in
                if let data, data.count == count { continuation.resume(returning: data) }
                else { continuation.resume(throwing: error ?? Failure.disconnected) }
            }
        }
    }

    private func receiveLoop() async {
        var epoch = VideoStreamEpoch()
        do {
            while !Task.isCancelled {
                let head = try await read(StreamMessage.headerLength)
                guard let header = StreamMessage.parseHeader(head), header.payloadLength <=
                    (header.kind == .frame ? StreamMessage.maxFramePayload : StreamMessage.maxOtherHostPayload) else { throw Failure.framing }
                let payload = try await read(header.payloadLength)
                state.received(header.kind, keyframe: header.isKeyframe, sentAt: header.timestamp)
                switch header.kind {
                case .streamReset:
                    if epoch.acceptReset(payload) { decoder.clear() }
                case .parameterSets:
                    guard let parameters = ParameterSets(encoded: payload) else { throw Failure.framing }
                    decoder.apply(parameters)
                case .frame: decoder.enqueue(payload, isKeyframe: header.isKeyframe)
                default: break
                }
            }
        } catch { state.fail("receive: \(error)") }
    }

    func check() throws {
        if let error = state.snapshot.1 { throw NSError(domain: "DuoLoopback", code: 3, userInfo: [NSLocalizedDescriptionKey: error]) }
    }
    var counters: (frames: Int, keyframes: Int, parameters: Int, resets: Int) { state.counters }
    var latencyReport: String { state.latencyReport }
    func close() {
        state.stop(); reader?.cancel(); reader = nil; connection.cancel()
    }
}
