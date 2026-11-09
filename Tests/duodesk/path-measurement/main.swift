import Foundation
import Network

// The echo-only server treats a route as an opaque close/filter key. Real trust is separately
// checked by door-policy; no production identity, clipboard, display or input is accessed here.
typealias ClientRoute = Int
var failures = 0
func check(_ condition: Bool, _ description: String) {
    print("\(condition ? "PASS" : "FAIL"): \(description)")
    if !condition { failures += 1 }
}

let cache = LocalPathMeasurements<String>()
cache.enqueue("Pro", now: 0)
cache.enqueue("Air", now: 0)
let pro = cache.beginNext()!
cache.enqueue("Pro", now: 0.1, prioritize: true)
check(cache.active == pro && cache.beginNext() == nil, "a tap keeps the same active measurement; devices run serially")
cache.enqueue("Mini", now: 0.1)
cache.enqueue("Mini", now: 0.2, prioritize: true)
check(cache.pending == ["Mini", "Air"], "tapping a queued device promotes it without cancelling another device")
check(cache.finish(pro, value: "LAN", now: 1), "the active observation completes")
for _ in 0..<3 { cache.enqueue("Pro", now: 17_999) }
check(cache.value(for: "Pro", now: 18_000) == "LAN" && !cache.pending.contains("Pro"), "reconnections reuse a result for five hours after completion")
check(cache.value(for: "Pro", now: 18_001) == nil, "the exact five-hour boundary expires the result")
let mini = cache.beginNext()!
cache.refresh()
cache.enqueue("Mini", now: 20_000)
let freshMini = cache.beginNext()!
check(!cache.finish(mini, value: "stale", now: 20_001) && cache.active == freshMini, "a completion queued before refresh cannot overwrite the new measurement")
cache.finish(freshMini, value: "nearby", now: 20_002)
check(cache.value(for: "Mini", now: 20_003) == "nearby", "the refreshed observation is cached")
check(LocalPathMeasurements<String>().value(for: "Mini", now: 20_003) == nil, "a new app process starts without cached measurements")
cache.enqueue("Pro", now: 20_004)
let suspended = cache.beginNext()!
cache.suspend()
let resumed = cache.beginNext()!
check(suspended != resumed && !cache.finish(suspended, value: "old", now: 20_005), "a suspended callback cannot complete a later task")
cache.remove("Pro")
check(!cache.finish(resumed, value: "removed", now: 20_006), "removing trust discards queued and in-flight observations")

final class EchoHost {
    let queue = DispatchQueue(label: "duo.path.measurement.fixture.host")
    let listener: NWListener
    var connections: [NWConnection] = []
    var firstPingAt: Double?
    var replyAt: Double?
    var sizes: [Int] = []
    let launch: String
    let setup: Double
    let delay: Double
    let realService: Bool
    let service: LocalPathProbeServer
    var permits = true

    init(launch: String = "same-launch", setup: Double = 0, delay: Double = 0, realService: Bool = false) throws {
        self.launch = launch; self.setup = setup; self.delay = delay; self.realService = realService
        service = LocalPathProbeServer(queue: queue)
        service.launchID = launch
        let parameters = NWParameters.tcp
        parameters.requiredLocalEndpoint = .hostPort(host: "127.0.0.1", port: 0)
        listener = try NWListener(using: parameters)
        let ready = DispatchSemaphore(value: 0)
        listener.stateUpdateHandler = { if case .ready = $0 { ready.signal() } }
        listener.newConnectionHandler = { [weak self] connection in
            guard let self else { return }
            connections.append(connection)
            var handedOff = false
            connection.stateUpdateHandler = { [weak self] state in
                guard let self, case .ready = state else { return }
                MessageReader(connection: connection, stillReads: { !handedOff }, onBytes: { _ in }, onMessage: { [weak self] header, payload in
                    guard let self else { return }
                    if header.kind == .hello {
                        if realService {
                            handedOff = true
                            service.serve(connection, route: 1, permits: { [weak self] in self?.permits == true }, ended: {})
                        } else {
                            queue.asyncAfter(deadline: .now() + setup) {
                                self.replyAt = ProcessInfo.processInfo.systemUptime
                                self.send(.hello, Wire.encode(LocalPathProbeReply(launchID: self.launch)), on: connection)
                            }
                        }
                    } else if header.kind == .ping {
                        if firstPingAt == nil { firstPingAt = ProcessInfo.processInfo.systemUptime }
                        sizes.append(payload.count)
                        queue.asyncAfter(deadline: .now() + delay) { self.send(.pong, payload, on: connection) }
                    }
                }, onEnd: { _ in }).start()
            }
            connection.start(queue: queue)
        }
        listener.start(queue: queue)
        precondition(ready.wait(timeout: .now() + 3) == .success)
    }
    func send(_ kind: StreamMessageKind, _ payload: Data, on connection: NWConnection) {
        connection.send(content: StreamMessage(kind: kind, timestamp: Date().timeIntervalSince1970, isKeyframe: false, payload: payload).serialized(), completion: .contentProcessed { _ in })
    }
    func dial() -> NWConnection {
        let tcp = NWProtocolTCP.Options(); tcp.noDelay = true
        return NWConnection(to: .hostPort(host: "127.0.0.1", port: listener.port!), using: NWParameters(tls: nil, tcp: tcp))
    }
    func stop() { queue.sync { service.close { _, _ in true }; connections.forEach { $0.cancel() }; listener.cancel() } }
}

func compare(_ lan: EchoHost, _ nearby: EchoHost, accept: Bool = true) -> LocalPathProbe.Result? {
    let queue = DispatchQueue(label: "duo.path.measurement.fixture.client")
    let done = DispatchSemaphore(value: 0)
    var answer: LocalPathProbe.Result?
    let probe = LocalPathProbe(connections: [.lan: lan.dial(), .nearby: nearby.dial()], queue: queue,
                               hello: Wire.encode(Hello()), accepts: { _, _ in accept }) { answer = $0; done.signal() }
    queue.async { probe.start() }
    check(done.wait(timeout: .now() + 6) == .success, "comparison has a bounded completion")
    queue.sync {}
    return answer
}

let lan = try EchoHost(delay: 0.002)
let near = try EchoHost(setup: 0.35, delay: 0.03)
let observed = compare(lan, near)!
check(observed.winner == .lan, "stable LAN wins over a slower nearby route")
check(observed.qualities[.lan]?.sent == 8 && observed.qualities[.nearby]?.sent == 8 && lan.sizes == near.sizes,
      "both routes receive all eight identical small/large samples")
check(lan.firstPingAt! >= near.replyAt! && abs(lan.firstPingAt! - near.firstPingAt!) < 0.02,
      "the faster handshake does not get a head start in the sampling window")
check(observed.elapsedSeconds >= 1.05 && observed.setupSeconds >= 0.3,
      "timing includes connection setup rather than reporting only the 750 ms sample window")
print("MEASURE fixture cold: \(observed.elapsedSeconds) s (setup \(observed.setupSeconds), sampling/report \(observed.sampleSeconds))")
lan.stop(); near.stop()

let slow = try EchoHost(delay: 0.05)
let fast = try EchoHost(delay: 0.002)
check(compare(slow, fast)?.winner == .nearby, "nearby can win; LAN is not unconditionally preferred")
slow.stop(); fast.stop()
let first = try EchoHost(launch: "first")
let other = try EchoHost(launch: "other")
check(compare(first, other)?.winner == nil, "routes reaching different host launches cannot be combined")
first.stop(); other.stop()
let rejected = try EchoHost()
check(compare(rejected, rejected, accept: false)?.winner == nil && rejected.sizes.isEmpty,
      "rejected pin/interface validation sends no measurement samples")
rejected.stop()

let serviceLAN = try EchoHost(realService: true)
let serviceNear = try EchoHost(realService: true)
let real = compare(serviceLAN, serviceNear)
check(real?.qualities[.lan]?.echoes.count == 8 && real?.qualities[.nearby]?.echoes.count == 8,
      "the actual lightweight host service echoes both paths without a catalog or viewer")
serviceLAN.stop(); serviceNear.stop()

let cancelHost = try EchoHost(setup: 0.4)
let cancelQueue = DispatchQueue(label: "duo.path.measurement.fixture.cancel")
let unwanted = DispatchSemaphore(value: 0)
let cancelled = LocalPathProbe(connections: [.lan: cancelHost.dial()], queue: cancelQueue, hello: Wire.encode(Hello()), accepts: { _, _ in true }) { _ in unwanted.signal() }
cancelQueue.async { cancelled.start(); cancelled.cancel() }
check(unwanted.wait(timeout: .now() + 1) == .timedOut, "cancelling a measurement never delivers a late result")
cancelHost.stop()

// The actual host service rejects everything except echo packets and rechecks its permit.
func serviceCloses(onInput: Bool) throws -> Bool {
    let host = try EchoHost(realService: true)
    let queue = DispatchQueue(label: "duo.path.measurement.fixture.reject")
    let closed = DispatchSemaphore(value: 0)
    let connection = host.dial()
    connection.send(content: StreamMessage(kind: .hello, timestamp: 0, isKeyframe: false, payload: Wire.encode(Hello())).serialized(), completion: .contentProcessed { _ in })
    connection.stateUpdateHandler = { state in
        guard case .ready = state else { return }
        MessageReader(connection: connection, stillReads: { true }, onBytes: { _ in }, onMessage: { header, _ in
            guard header.kind == .hello else { return }
            if !onInput { host.queue.sync { host.permits = false } }
            let message = StreamMessage(kind: onInput ? .input : .ping, timestamp: 0, isKeyframe: false, payload: Data([1]))
            connection.send(content: message.serialized(), completion: .contentProcessed { _ in })
        }, onEnd: { _ in closed.signal() }).start()
    }
    connection.start(queue: queue)
    let result = closed.wait(timeout: .now() + 2) == .success
    connection.cancel(); host.stop()
    return result
}
check(try serviceCloses(onInput: true), "input on a probe is closed instead of being forwarded as control")
check(try serviceCloses(onInput: false), "revoking trust closes a probe before another echo")
exit(failures == 0 ? 0 : 1)
