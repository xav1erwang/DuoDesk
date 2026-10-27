// Live loopback checks against the production Door and StreamServer. No capture, input,
// keychain, Bonjour, saved identities or permission prompts. Every identity is ephemeral.
@preconcurrency import Foundation
import Network
import Security
import StreamProtocol

enum CheckError: Error { case failed(String) }
struct DialFailure: Error { let failure: RemoteDialPolicy.Failure }
func require(_ condition: @autoclosure () -> Bool, _ text: String) throws {
    if !condition() { throw CheckError.failed(text) }
}
final class Once: @unchecked Sendable {
    private let lock = NSLock()
    private var answered = false
    func take() -> Bool { lock.withLock { if answered { return false }; answered = true; return true } }
}
final class Counter: @unchecked Sendable {
    private let lock = NSLock()
    private var count = 0
    func add() { lock.withLock { count += 1 } }
    var value: Int { lock.withLock { count } }
}
let clientQueue = DispatchQueue(label: "duodesk.quic-admission.client")
let mode = CommandLine.arguments.dropFirst().first ?? "baseline"
let remoteMode = mode.hasPrefix("remote-")
let trust = TrustBox()
let clientIdentity = RemoteIdentity(privateKey: RemoteKey.generate()!)!
let strangerIdentity = RemoteIdentity(privateKey: RemoteKey.generate()!)!
let hostIdentity = HostIdentity(privateKey: RemoteKey.generate()!, recognitionKey: Data(repeating: 13, count: 32))!
trust.update {
    $0.paired[clientIdentity.fingerprint] = "Ephemeral QUIC check"
    $0.remoteAccess = true
    $0.internetAccess = ["remote-internet-toggle", "remote-internet-outbound-toggle"].contains(mode)
}
let server = try StreamServer(advertise: false, home: .tls(.init(identity: hostIdentity, trust: trust)))
let decoderRecoveryRequests = Counter()
if mode == "decoder-recovery" { server.onKeyframeNeeded = { decoderRecoveryRequests.add() } }
var remote: RemoteServer?
var admitted = Set<ObjectIdentifier>() // server.queue only
var remotePort: UInt16?               // server.queue only
server.onClientConnected = { connection, _, _ in admitted.insert(ObjectIdentifier(connection)) }
server.onClientDisconnected = { connection in admitted.remove(ObjectIdentifier(connection)) }
if remoteMode {
    let door = RemoteServer(server: server, identity: hostIdentity, trust: trust)
    door.onListener = { if case .listening(let port) = $0 { remotePort = UInt16(port) } }
    remote = door
    door.set(wanted: true, port: 0)
}
server.start()

func count() -> Int { server.queue.sync { admitted.count } }
func waitCount(_ wanted: Int) async throws {
    for _ in 0..<150 {
        if count() == wanted { return }
        try await Task.sleep(for: .milliseconds(20))
    }
    throw CheckError.failed("expected \(wanted) admitted streams, observed \(count())")
}
func ready(_ connection: NWConnection, timeout: Double = 3) async throws {
    try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
        let once = Once()
        let deadline = DispatchWorkItem {
            if once.take() { continuation.resume(throwing: CheckError.failed("connection deadline")); connection.cancel() }
        }
        connection.stateUpdateHandler = { state in
            switch state {
            case .ready:
                if once.take() { deadline.cancel(); connection.stateUpdateHandler = nil; continuation.resume() }
            case .failed(let error):
                if once.take() { deadline.cancel(); continuation.resume(throwing: error); connection.cancel() }
            case .cancelled:
                if once.take() { deadline.cancel(); continuation.resume(throwing: CheckError.failed("cancelled")) }
            default: break
            }
        }
        clientQueue.asyncAfter(deadline: .now() + timeout, execute: deadline)
        connection.start(queue: clientQueue)
    }
}
func parameters(identity: RemoteIdentity = clientIdentity, pin: Data = hostIdentity.fingerprint,
                alpn: String = RemoteTLS.sessionALPN, verified: Counter? = nil) -> NWParameters {
    let options = RemoteTLS.quicOptions(identity: identity.tls, role: .client(alpn: alpn), queue: clientQueue) { fingerprint, negotiated in
        verified?.add()
        return fingerprint == pin && negotiated == alpn
    }
    return RemoteTLS.quicParameters(options: options)
}
func dial(_ port: UInt16, using parameters: NWParameters? = nil, timeout: Double = 3) async throws -> NWConnection {
    let connection = NWConnection(host: .ipv4(.loopback), port: NWEndpoint.Port(rawValue: port)!, using: parameters ?? selfParameters())
    try await ready(connection, timeout: timeout)
    return connection
}
func selfParameters() -> NWParameters { parameters() }
func productionDial(_ port: UInt16, identity: RemoteIdentity = clientIdentity,
                    preferQUIC: Bool = true) async throws -> RemoteConnector.Winner {
    let candidate = RemoteDialPolicy.Candidate(host: "127.0.0.1", port: Int(port), kind: MacAddress.lan, via: "")
    let dialer = RemoteConnector(candidates: [candidate], mode: .session(pin: hostIdentity.fingerprint),
                                identity: identity, queue: clientQueue, preferQUIC: preferQUIC)
    return try await withCheckedThrowingContinuation { continuation in
        let once = Once()
        let deadline = DispatchWorkItem {
            if once.take() {
                dialer.cancel(); dialer.onWinner = nil; dialer.onFailed = nil
                continuation.resume(throwing: CheckError.failed("production dial deadline"))
            }
        }
        dialer.onWinner = { winner in
            guard once.take() else { winner.connection.cancel(); return }
            deadline.cancel(); dialer.onWinner = nil; dialer.onFailed = nil
            continuation.resume(returning: winner)
        }
        dialer.onFailed = { failure in
            guard once.take() else { return }
            deadline.cancel(); dialer.onWinner = nil; dialer.onFailed = nil
            continuation.resume(throwing: DialFailure(failure: failure.failure))
        }
        clientQueue.asyncAfter(deadline: .now() + 5, execute: deadline)
        dialer.start()
    }
}
func browseOwnedService() async throws -> NWEndpoint {
    let browser = NWBrowser(for: .bonjour(type: "_silltest._tcp", domain: nil), using: NWParameters())
    return try await withCheckedThrowingContinuation { continuation in
        let once = Once()
        let deadline = DispatchWorkItem {
            if once.take() { continuation.resume(throwing: CheckError.failed("test Bonjour discovery deadline")); browser.cancel() }
        }
        browser.browseResultsChangedHandler = { results, _ in
            for result in results {
                if case .service(let name, _, _, _) = result.endpoint, name == "Sill test \(ProcessInfo.processInfo.processIdentifier)", once.take() {
                    deadline.cancel(); continuation.resume(returning: result.endpoint); browser.cancel(); return
                }
            }
        }
        clientQueue.asyncAfter(deadline: .now() + 5, execute: deadline)
        browser.start(queue: clientQueue)
    }
}
func read(_ bytes: Int, from connection: NWConnection, timeout: Double = 2) async throws -> Data {
    try await withCheckedThrowingContinuation { continuation in
        let once = Once()
        let deadline = DispatchWorkItem {
            if once.take() { continuation.resume(throwing: CheckError.failed("read deadline")); connection.cancel() }
        }
        clientQueue.asyncAfter(deadline: .now() + timeout, execute: deadline)
        connection.receive(minimumIncompleteLength: bytes, maximumLength: bytes) { data, _, _, error in
            guard once.take() else { return }
            deadline.cancel()
            if let data, data.count == bytes { continuation.resume(returning: data) }
            else { continuation.resume(throwing: error ?? CheckError.failed("closed or truncated")) }
        }
    }
}
func exchange(_ connection: NWConnection) async throws -> (StreamHeader, Data) {
    let request = StreamMessage(kind: .ping, timestamp: 123.25, isKeyframe: false, payload: Data("QUIC admission check".utf8))
    connection.send(content: request.serialized(), completion: .contentProcessed { _ in })
    let data = try await read(StreamMessage.headerLength, from: connection)
    guard let header = StreamMessage.parseHeader(data), header.payloadLength <= StreamMessage.maxOtherHostPayload else {
        throw CheckError.failed("invalid bounded response")
    }
    let payload = header.payloadLength == 0 ? Data() : try await read(header.payloadLength, from: connection)
    return (header, payload)
}
func echo(_ connection: NWConnection) async throws {
    let (header, data) = try await exchange(connection)
    try require(header.kind == .pong && header.timestamp == 123.25 && data == Data("QUIC admission check".utf8), "incorrect echo")
}
func refused(_ port: UInt16, using parameters: NWParameters, noCertificate: Counter? = nil) async throws {
    var connection: NWConnection?
    var echoed = false
    do {
        connection = try await dial(port, using: parameters, timeout: 1.5)
        try await echo(connection!)
        echoed = true
    } catch { /* An authenticated rejection may arrive after the client's TLS .ready. */ }
    connection?.cancel()
    try require(!echoed, "a refused client received application data")
    try await waitCount(0)
    if let noCertificate { try require(noCertificate.value == 0, "refused source received the host certificate") }
}

func run() async throws {
    var selected: UInt16?
    for _ in 0..<150 {
        selected = remoteMode ? server.queue.sync { remotePort } : server.port
        if selected != nil { break }
        try await Task.sleep(for: .milliseconds(20))
    }
    guard let port = selected else { throw CheckError.failed("listener not ready") }
    // TCP publishes its bound port before the UDP companion's ready callback.
    try await Task.sleep(for: .milliseconds(100))
    switch mode {
    case "decoder-recovery":
        let connection = try await dial(port)
        defer { connection.cancel() }
        try await echo(connection)
        let second = try await dial(port)
        defer { second.cancel() }
        try await echo(second)
        func sendRequest(_ target: NWConnection, _ payload: Data = Data()) {
            let request = StreamMessage(kind: .requestKeyframe, timestamp: 0, isKeyframe: false, payload: payload)
            target.send(content: request.serialized(), completion: .contentProcessed { _ in })
        }
        func waitRequests(_ count: Int) async throws {
            for _ in 0..<100 {
                if decoderRecoveryRequests.value >= count { return }
                try await Task.sleep(for: .milliseconds(20))
            }
            throw CheckError.failed("expected \(count) decoder recovery requests; got \(decoderRecoveryRequests.value)")
        }
        sendRequest(connection)
        try await waitRequests(1)
        sendRequest(connection, Data([1])) // malformed, must not consume a request or schedule one
        for _ in 0..<5 { sendRequest(connection) }
        sendRequest(second)
        try await waitRequests(2)
        try await Task.sleep(for: .milliseconds(150))
        try require(decoderRecoveryRequests.value == 2, "recovery burst was not coalesced")
        sendRequest(connection); sendRequest(second)
        try await echo(connection); try await echo(second) // both requests reached the host
        connection.cancel(); try await waitCount(1)
        try await waitRequests(3)

        sendRequest(second)
        try await echo(second) // the pending request is registered before the stream reset
        var epoch = VideoStreamEpoch()
        server.beginVideoStream(UUID(), reset: epoch.nextReset())
        server.queue.sync { }
        let resetBytes = try await read(StreamMessage.headerLength, from: second)
        guard let reset = StreamMessage.parseHeader(resetBytes), reset.kind == .streamReset else {
            throw CheckError.failed("stream reset did not reach the remaining client")
        }
        _ = try await read(reset.payloadLength, from: second)
        try await Task.sleep(for: .milliseconds(600))
        try require(decoderRecoveryRequests.value == 3, "old stream kept a pending request")

        sendRequest(second)
        try await waitRequests(4)
        sendRequest(second)
        try await echo(second)
        second.cancel(); try await waitCount(0)
        try await Task.sleep(for: .milliseconds(600))
        try require(decoderRecoveryRequests.value == 4, "disconnected client kept a pending request")
        print("Decoder recovery over QUIC: burst coalesced, another peer survives disconnect, old stream and disconnected requests cancelled")
    case "remote-connector-session":
        let winner = try await productionDial(port)
        try require(winner.fingerprint == hostIdentity.fingerprint, "production dial lost the host pin")
        try require(winner.connection.metadata(definition: NWProtocolQUIC.definition) != nil, "production dial did not prefer QUIC")
        try await echo(winner.connection)
        winner.connection.cancel(); try await waitCount(0)
    case "remote-connector-tcp-session":
        let winner = try await productionDial(port, preferQUIC: false)
        try require(winner.fingerprint == hostIdentity.fingerprint, "TCP retry lost the original host pin")
        try require(winner.connection.metadata(definition: NWProtocolQUIC.definition) == nil, "TCP retry opened QUIC again")
        try await echo(winner.connection)
        winner.connection.cancel(); try await waitCount(0)
    case "remote-connector-revoked":
        let admitted = try await productionDial(port)
        try await echo(admitted.connection)
        admitted.connection.cancel(); try await waitCount(0)
        trust.update { $0.paired.removeValue(forKey: clientIdentity.fingerprint) }
        let winner = try await productionDial(port)
        do {
            try await echo(winner.connection)
            throw CheckError.failed("unpaired production dial received application data")
        } catch let error as NWError {
            let end = RemoteConnector.end(of: error)
            print("Production dial rejected after client ready: \(end), classification \(String(describing: RemoteDialPolicy.classify(end, candidate: winner.candidate, usedTunnel: false)))")
        }
        winner.connection.cancel(); try await waitCount(0)
        var classified: RemoteDialPolicy.Failure?
        var retry: NWConnection?
        do {
            let tcp = try await productionDial(port, preferQUIC: false)
            retry = tcp.connection
            try require(tcp.fingerprint == winner.fingerprint, "retry changed the responding Mac")
            try await echo(tcp.connection)
            throw CheckError.failed("unpaired TCP retry received application data")
        } catch let failure as DialFailure {
            classified = failure.failure
        } catch let error as NWError {
            let end: RemoteDialPolicy.End
            if case .tls(let status) = error { end = .tlsAfterReady(status) }
            else { end = RemoteConnector.end(of: error) }
            classified = RemoteDialPolicy.classify(end, candidate: winner.candidate, usedTunnel: false)
        }
        retry?.cancel(); try await waitCount(0)
        // TLS may deliver the rejection alert or close/reset before its alert reaches the peer.
        // Both are denied, actionable results; the client must never mistake either for admission.
        try require(classified == .revoked || classified == .refused,
                    "same-pin TCP retry did not report a refusal: \(String(describing: classified))")
        print("Same-pin TCP retry after revocation: \(classified!)")
    case "bonjour":
        let endpoint = try await browseOwnedService()
        let connection = NWConnection(to: endpoint, using: parameters())
        try await ready(connection)
        try await echo(connection)
        try require(connection.metadata(definition: NWProtocolQUIC.definition) != nil, "Bonjour session did not use QUIC")
        connection.cancel(); try await waitCount(0)
    case "baseline":
        for _ in 0..<80 { // More than the total tunnel cap: closed streams must release their groups.
            let connection = try await dial(port)
            try await echo(connection)
            connection.cancel()
            try await waitCount(0)
        }
        let held = try await dial(port)
        try await echo(held)
        trust.update { $0.paired.removeValue(forKey: clientIdentity.fingerprint) }
        var echoed = false
        do { try await echo(held); echoed = true } catch {}
        held.cancel()
        try require(!echoed, "a removed key continued using its existing tunnel")
        try await waitCount(0)
    case "wrong-server-pin":
        try await refused(port, using: parameters(pin: Data(repeating: 0, count: 32)))
    case "wrong-client-pin":
        try await refused(port, using: parameters(identity: strangerIdentity))
    case "wrong-alpn":
        try await refused(port, using: parameters(alpn: "duodesk-invalid/1"))
    case "backoff", "backoff-tcp-recovery":
        for _ in 0..<Door.failuresForBackoff { try await refused(port, using: parameters(identity: strangerIdentity)) }
        let verified = Counter()
        try await refused(port, using: parameters(verified: verified), noCertificate: verified)
        if mode == "backoff" { try await Task.sleep(for: .seconds(2.1)) }
        else {
            let tls = RemoteTLS.options(identity: clientIdentity.tls, role: .client(alpn: RemoteTLS.sessionALPN),
                                        verify: { $0 == hostIdentity.fingerprint }, queue: clientQueue)
            let tcp = try await dial(port, using: RemoteTLS.parameters(tls: tls, dialing: true))
            try await echo(tcp)
            tcp.cancel(); try await waitCount(0)
        }
        let recovered = try await dial(port)
        try await echo(recovered)
        recovered.cancel(); try await waitCount(0)
    case "home-internet", "remote-internet-off":
        let verified = Counter()
        try await refused(port, using: parameters(verified: verified), noCertificate: verified)
    case "idle-budget":
        let first = try await dial(port)
        let second = try await dial(port)
        try require(count() == 0, "an idle handshake became an admitted session")
        let verified = Counter()
        try await refused(port, using: parameters(verified: verified), noCertificate: verified)
        try await Task.sleep(for: .seconds(9)) // Beyond the host's 10 s deadline, before QUIC's 15 s idle timeout.
        let recovered = try await dial(port)
        try await echo(recovered)
        recovered.cancel(); first.cancel(); second.cancel()
        try await waitCount(0)
    case "stream-limit":
        let connection = try await dial(port)
        try await echo(connection)
        guard let metadata = connection.metadata(definition: NWProtocolQUIC.definition) as? NWProtocolQUIC.Metadata else {
            throw CheckError.failed("missing negotiated QUIC stream limits")
        }
        try require(metadata.streamIdentifier == 0 && metadata.remoteMaxStreamsBidirectional == 1
                    && metadata.remoteMaxStreamsUnidirectional == 0 && metadata.localMaxStreamsBidirectional == 0,
                    "the peer advertised additional streams")
        connection.cancel()
        try await waitCount(0)
    case "remote-limit":
        var held: [NWConnection] = []
        for _ in 0..<DoorPolicy.maxRemoteSessions {
            let connection = try await dial(port)
            try await echo(connection); held.append(connection)
        }
        let ninth = try await dial(port)
        let (header, payload) = try await exchange(ninth)
        try require(header.kind == .goodbye && Wire.decode(Goodbye.self, from: payload)?.reason == Goodbye.busy,
                    "the ninth remote session was not refused as busy")
        try require(count() == DoorPolicy.maxRemoteSessions, "remote session cap was exceeded")
        ninth.cancel(); held.forEach { $0.cancel() }
        try await waitCount(0)
    case "remote-internet-toggle", "remote-internet-outbound-toggle":
        let connection = try await dial(port)
        try await echo(connection)
        trust.update { $0.internetAccess = false }
        if mode == "remote-internet-outbound-toggle" {
            // No new client message: an outgoing heartbeat must apply the new access policy too.
            server.setStreaming(true)
            try await waitCount(0)
        } else {
            var echoed = false
            do { try await echo(connection); echoed = true } catch {}
            try require(!echoed, "internet access off left an existing QUIC stream usable")
        }
        connection.cancel(); try await waitCount(0)
    default: throw CheckError.failed("unknown test case")
    }
    print("QUIC admission PASS: \(mode)")
}
Task {
    do { try await run(); exit(0) }
    catch { print("QUIC admission FAIL: \(mode): \(error)"); exit(1) }
}
dispatchMain()
