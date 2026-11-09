import Foundation
import Network

var failures = 0
func check(_ value: Bool, _ message: String) {
    print("\(value ? "PASS" : "FAIL"): \(message)")
    if !value { failures += 1 }
}

func quality(_ samples: [Double], sent: Int = 8, retransmitted: UInt64 = 0) -> LocalPathQuality {
    LocalPathQuality(sent: sent, echoes: samples.enumerated().map { .init(milliseconds: $0.element, bytes: $0.offset.isMultiple(of: 2) ? 256 : 16_384) },
                     retransmittedBytes: retransmitted, sentTransportBytes: 100_000)
}
let stable = quality(Array(repeating: 15, count: 8))
check(!LocalPathQuality.prefersCandidate(current: stable, candidate: quality([2, 2, 2, 2, 2, 2, 200, 200]), candidateIsDirect: true), "a fast median cannot hide late echoes")
check(!LocalPathQuality.prefersCandidate(current: stable, candidate: quality(Array(repeating: 3, count: 8), retransmitted: 10_000), candidateIsDirect: true), "transport retransmissions outrank latency")
check(!LocalPathQuality.prefersCandidate(current: stable, candidate: quality([1, 1, 1, 1]), candidateIsDirect: true), "four lucky echoes cannot win")
check(LocalPathQuality.prefersCandidate(current: quality([10, 10, 12, 18, 25, 45, 65, 70]), candidate: stable, candidateIsDirect: true), "a stable nearby path beats erratic LAN")
check(!LocalPathQuality.prefersCandidate(current: stable, candidate: stable, candidateIsDirect: true), "equivalent direct path does not displace LAN")
check(LocalPathQuality.prefersCandidate(current: stable, candidate: stable, candidateIsDirect: false), "equivalent LAN displaces AWDL")
check(LocalPathQuality.prefersCandidate(current: quality([20, 20, 20, 20]), candidate: stable, candidateIsDirect: true), "a responsive candidate recovers a poorly responding current path")

/// Two loopback routes to a stand-in host, with controlled echo delays. All client activity is
/// serialized on the same queue as the production reader/trial. No screen, input or identity
/// material is touched by this fixture.
final class Host {
    let queue = DispatchQueue(label: "duo.path.test.host")
    let listener: NWListener
    var connections: [NWConnection] = []
    var hellos = 0
    var pingBeforeHello = false
    let launch: String
    let delay: (Int) -> Double
    let silent: Bool
    let catalogDelay: Double
    var firstPingAt: Double?
    var catalogSentAt: Double?

    init(launch: String = "same-launch", silent: Bool = false, catalogDelay: Double = 0,
         delay: @escaping (Int) -> Double) throws {
        self.launch = launch; self.delay = delay; self.silent = silent; self.catalogDelay = catalogDelay
        let parameters = NWParameters.tcp
        parameters.requiredLocalEndpoint = .hostPort(host: "127.0.0.1", port: 0)
        listener = try NWListener(using: parameters)
        let ready = DispatchSemaphore(value: 0)
        listener.stateUpdateHandler = { if case .ready = $0 { ready.signal() } }
        listener.newConnectionHandler = { [weak self] connection in
            guard let self else { return }
            self.connections.append(connection)
            var greeted = false
            var sample = 0
            connection.stateUpdateHandler = { [weak self] state in
                guard let self, case .ready = state else { return }
                MessageReader(connection: connection, stillReads: { true }, onBytes: { _ in }, onMessage: { header, payload in
                    if header.kind == .hello {
                        greeted = true
                        self.hellos += 1
                        self.queue.asyncAfter(deadline: .now() + self.catalogDelay) {
                            self.catalogSentAt = ProcessInfo.processInfo.systemUptime
                            self.send(.windowList, Data(self.launch.utf8), on: connection)
                        }
                    } else if header.kind == .ping {
                        if self.firstPingAt == nil { self.firstPingAt = ProcessInfo.processInfo.systemUptime }
                        if !greeted { self.pingBeforeHello = true }
                        if self.silent { return }
                        let fence = LocalPathTrial.isTrialPong(payload) && payload[24..<28].allSatisfy { $0 == 0xff }
                        let wait = fence ? 0 : self.delay(sample)
                        sample += 1
                        self.queue.asyncAfter(deadline: .now() + wait) {
                            self.send(.pong, payload, on: connection)
                            if fence {
                                self.send(.appList, Data("AFTER_BOUNDARY".utf8), on: connection)
                            }
                        }
                    }
                }, onEnd: { _ in }).start()
            }
            connection.start(queue: self.queue)
        }
        listener.start(queue: queue)
        precondition(ready.wait(timeout: .now() + 3) == .success)
    }

    func send(_ kind: StreamMessageKind, _ data: Data, on connection: NWConnection) {
        let message = StreamMessage(kind: kind, timestamp: Date.now.timeIntervalSince1970, isKeyframe: false, payload: data)
        connection.send(content: message.serialized(), completion: .contentProcessed { _ in })
    }

    var endpoint: NWEndpoint { .hostPort(host: "127.0.0.1", port: listener.port!) }
    func stop() { queue.sync { connections.forEach { $0.cancel() }; listener.cancel() } }
}

func runTrial(_ name: String, currentDelay: @escaping (Int) -> Double, candidateDelay: @escaping (Int) -> Double,
              expectedWinner: Bool, launch: String = "same-launch", pathMatches: Bool = true, silent: Bool = false,
              cancel: Bool = false, catalogDelay: Double = 0) throws {
    let currentHost = try Host(delay: currentDelay)
    let candidateHost = try Host(launch: launch, silent: silent, catalogDelay: catalogDelay, delay: candidateDelay)
    defer { currentHost.stop(); candidateHost.stop() }
    let queue = DispatchQueue(label: "duo.path.test.client")
    let current = NWConnection(to: currentHost.endpoint, using: .tcp)
    let candidate = NWConnection(to: candidateHost.endpoint, using: .tcp)
    let ready = DispatchSemaphore(value: 0)
    let done = DispatchSemaphore(value: 0)
    let boundary = DispatchSemaphore(value: 0)
    let alive = DispatchSemaphore(value: 0)
    var trial: LocalPathTrial?
    var result: LocalPathTrial.Result?
    var completionCount = 0
    current.stateUpdateHandler = { state in
        guard case .ready = state else { return }
        MessageReader(connection: current, stillReads: { true }, onBytes: { _ in }, onMessage: { header, payload in
            if header.kind == .windowList { ready.signal() }
            if header.kind == .pong {
                trial?.receivePong(payload, from: current)
                if payload == Data("LIVE".utf8) { alive.signal() }
            }
        }, onEnd: { _ in }).start()
    }
    func send(_ kind: StreamMessageKind, _ payload: Data, on connection: NWConnection) {
        connection.send(content: StreamMessage(kind: kind, timestamp: 0, isKeyframe: false, payload: payload).serialized(),
                        completion: .contentProcessed { _ in })
    }
    send(.hello, Data(), on: current)
    current.start(queue: queue)
    precondition(ready.wait(timeout: .now() + 3) == .success)
    let began = ProcessInfo.processInfo.systemUptime
    queue.sync {
        trial = LocalPathTrial(current: current, candidate: candidate, candidateIsDirect: true, queue: queue,
                               readyPathMatches: { _ in pathMatches }, admits: { header, payload in
            guard header.kind == .windowList else { return nil }
            return payload == Data("same-launch".utf8)
        }, completion: { value in
            result = value
            completionCount += 1
            if value.useCandidate {
                MessageReader(connection: candidate, stillReads: { true }, onBytes: { _ in }, onMessage: { header, data in
                    if header.kind == .appList && data == Data("AFTER_BOUNDARY".utf8) { boundary.signal() }
                }, onEnd: { _ in }).start()
            }
            done.signal()
        })
        send(.hello, Data(), on: candidate)
        trial?.start()
        if cancel { queue.asyncAfter(deadline: .now() + 0.1) { trial?.cancel() } }
    }
    let finished = done.wait(timeout: .now() + (cancel ? 1.2 : 3)) == .success
    if cancel {
        check(!finished, "\(name): cancellation cannot deliver a late winner")
    } else {
        check(finished && result?.useCandidate == expectedWinner, "\(name): expected selection")
        check(ProcessInfo.processInfo.systemUptime - began < 2.2, "\(name): comparison has a bounded end")
        if expectedWinner { check(boundary.wait(timeout: .now() + 1) == .success, "\(name): handover preserves the next complete message") }
    }
    queue.sync { send(.ping, Data("LIVE".utf8), on: current) }
    check(alive.wait(timeout: .now() + 1) == .success, "\(name): existing connection remains live")
    queue.sync {
        check(completionCount == (cancel ? 0 : 1), "\(name): completion is delivered once")
        trial?.cancel()
        current.cancel(); candidate.cancel()
    }
    check(!candidateHost.queue.sync { candidateHost.pingBeforeHello }, "\(name): hello precedes all measurements")
    if catalogDelay > 0 {
        check(candidateHost.queue.sync {
            guard let ping = candidateHost.firstPingAt, let catalog = candidateHost.catalogSentAt else { return false }
            return ping < catalog
        }, "\(name): measurements run while the desktop catalog is preparing")
    }
}

try runTrial("stable candidate", currentDelay: { $0.isMultiple(of: 3) ? 0.12 : 0.025 }, candidateDelay: { _ in 0.004 }, expectedWinner: true)
try runTrial("jittery candidate", currentDelay: { _ in 0.006 }, candidateDelay: { $0.isMultiple(of: 3) ? 0.22 : 0.002 }, expectedWinner: false)
try runTrial("slow desktop preparation", currentDelay: { _ in 0.06 }, candidateDelay: { _ in 0.004 }, expectedWinner: true, catalogDelay: 1.25)
try runTrial("different launch", currentDelay: { _ in 0.006 }, candidateDelay: { _ in 0.001 }, expectedWinner: false, launch: "another-launch")
try runTrial("wrong interface", currentDelay: { _ in 0.006 }, candidateDelay: { _ in 0.001 }, expectedWinner: false, pathMatches: false)
try runTrial("stalled candidate", currentDelay: { _ in 0.006 }, candidateDelay: { _ in 0 }, expectedWinner: false, silent: true)
try runTrial("cancelled trial", currentDelay: { _ in 0.006 }, candidateDelay: { _ in 0.001 }, expectedWinner: false, cancel: true)
print("\(failures) failures")
exit(failures == 0 ? 0 : 1)
