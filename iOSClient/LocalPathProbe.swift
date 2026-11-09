// Copyright 2026 DUO你电脑 contributors. SPDX-License-Identifier: Apache-2.0
import Foundation
import Network
#if canImport(StreamProtocol)
import StreamProtocol
#endif

/// Two fresh, authenticated echo connections, with identical transport, payloads and deadlines.
/// Samples start at a shared barrier, after both lightweight replies (or the setup deadline).
/// This owns neither the viewer nor its input reader; clicking a device never restarts it.
final class LocalPathProbe {
    enum Lane: String, Hashable { case lan, nearby }
    struct Result {
        let qualities: [Lane: LocalPathQuality]
        let winner: Lane?
        let launchID: String?
        let setupSeconds: Double
        let sampleSeconds: Double
        let elapsedSeconds: Double
    }
    private struct Observation {
        var sent: [UInt32: (at: Double, bytes: Int)] = [:]
        var echoes: [UInt32: LocalPathQuality.Echo] = [:]
        var retransmitted: UInt64 = 0
        var transportBytes: UInt64 = 0
        var quality: LocalPathQuality {
            LocalPathQuality(sent: sent.count, echoes: Array(echoes.values),
                             retransmittedBytes: retransmitted, sentTransportBytes: transportBytes)
        }
    }
    private let connections: [Lane: NWConnection]
    private let queue: DispatchQueue
    private let hello: Data
    private let accepts: (Lane, NWConnection) -> Bool
    private let completion: (Result) -> Void
    private let prefix = Data(UUID().uuidString.utf8)
    private var works: [DispatchWorkItem] = []
    private var launches: [Lane: String] = [:]
    private var failed: Set<Lane> = []
    private var observations: [Lane: Observation] = [:]
    private var reports: [Lane: NWConnection.PendingDataTransferReport] = [:]
    private var completed = false
    private var measuring = false
    private var collecting = false
    private var startedAt = 0.0
    private var samplesAt = 0.0

    init(connections: [Lane: NWConnection], queue: DispatchQueue, hello: Data,
         accepts: @escaping (Lane, NWConnection) -> Bool, completion: @escaping (Result) -> Void) {
        self.connections = connections; self.queue = queue; self.hello = hello
        self.accepts = accepts; self.completion = completion
    }

    func start() {
        startedAt = ProcessInfo.processInfo.systemUptime
        guard !connections.isEmpty else { finish(); return }
        for lane in [Lane.lan, .nearby] {
            guard let connection = connections[lane] else { continue }
            let message = StreamMessage(kind: .hello, timestamp: Date().timeIntervalSince1970, isKeyframe: false, payload: hello)
            connection.send(content: message.serialized(), completion: .contentProcessed { [weak self] error in
                if error != nil { self?.fail(lane) }
            })
            connection.stateUpdateHandler = { [weak self] state in
                guard let self, !completed else { return }
                switch state {
                case .ready:
                    guard accepts(lane, connection) else { fail(lane); return }
                    MessageReader(connection: connection, stillReads: { [weak self] in
                        self.map { !$0.completed && !$0.failed.contains(lane) } ?? false
                    }, onBytes: { _ in }, onMessage: { [weak self] header, data in
                        self?.receive(header, data, from: lane)
                    }, onEnd: { [weak self] _ in self?.fail(lane) }).start()
                case .failed, .cancelled: fail(lane)
                default: break
                }
            }
            connection.start(queue: queue)
        }
        later(3) { [weak self] in
            guard let self, !measuring, !completed else { return }
            for lane in connections.keys where launches[lane] == nil { failed.insert(lane); connections[lane]?.cancel() }
            beginIfReady()
        }
    }

    func cancel() {
        guard !completed else { return }
        completed = true
        cleanup()
    }

    private func fail(_ lane: Lane) {
        guard !completed, !failed.contains(lane) else { return }
        failed.insert(lane)
        connections[lane]?.cancel()
        // A failed lane cannot win using echoes taken before it disconnected.
        observations[lane] = nil
        if !measuring { beginIfReady() }
    }

    private func receive(_ header: StreamHeader, _ data: Data, from lane: Lane) {
        guard !completed, !failed.contains(lane) else { return }
        if launches[lane] == nil {
            guard header.kind == .hello, let reply = Wire.decode(LocalPathProbeReply.self, from: data),
                  reply.version == LocalPathProbeReply.generation, !reply.launchID.isEmpty else { fail(lane); return }
            launches[lane] = reply.launchID
            guard Set(launches.values).count == 1 else { finish(); return }
            beginIfReady()
            return
        }
        guard header.kind == .pong, measuring, !collecting, data.starts(with: prefix), data.count >= prefix.count + 4 else { return }
        let offset = prefix.count
        let sequence = data[offset..<(offset + 4)].reduce(UInt32(0)) { ($0 << 8) | UInt32($1) }
        guard let sent = observations[lane]?.sent[sequence], sent.bytes == data.count,
              observations[lane]?.echoes[sequence] == nil else { return }
        observations[lane]?.echoes[sequence] = .init(milliseconds: max(0, (ProcessInfo.processInfo.systemUptime - sent.at) * 1000), bytes: sent.bytes)
    }

    private func beginIfReady() {
        guard !completed, !measuring, connections.keys.allSatisfy({ launches[$0] != nil || failed.contains($0) }) else { return }
        guard connections.keys.contains(where: { launches[$0] != nil && !failed.contains($0) }) else { finish(); return }
        measuring = true
        samplesAt = ProcessInfo.processInfo.systemUptime
        for (lane, connection) in connections where !failed.contains(lane) {
            observations[lane] = Observation()
            reports[lane] = connection.startDataTransferReport()
        }
        for sequence in UInt32(0)..<8 {
            later(Double(sequence) * 0.075) { [weak self] in
                guard let self, !completed else { return }
                // Reverse submission order every pair so neither lane always gets first send.
                let order: [Lane] = sequence.isMultiple(of: 2) ? [.lan, .nearby] : [.nearby, .lan]
                for lane in order where observations[lane] != nil {
                    ping(sequence, bytes: sequence.isMultiple(of: 2) ? 256 : 16_384, lane: lane)
                }
            }
        }
        later(0.75) { [weak self] in self?.collect() }
    }

    private func ping(_ sequence: UInt32, bytes: Int, lane: Lane) {
        guard let connection = connections[lane], !failed.contains(lane) else { return }
        var payload = prefix
        var bigEndian = sequence.bigEndian
        withUnsafeBytes(of: &bigEndian) { payload.append(contentsOf: $0) }
        payload.append(Data(repeating: 0x5a, count: max(0, bytes - payload.count)))
        observations[lane]?.sent[sequence] = (ProcessInfo.processInfo.systemUptime, payload.count)
        let message = StreamMessage(kind: .ping, timestamp: Date().timeIntervalSince1970, isKeyframe: false, payload: payload)
        connection.send(content: message.serialized(), completion: .contentProcessed { [weak self] error in
            if error != nil { self?.fail(lane) }
        })
    }

    private func collect() {
        guard !completed, !collecting else { return }
        collecting = true // Both lanes have exactly the same observation cutoff.
        let pending = reports
        reports.removeAll()
        var remaining = pending.count
        if remaining == 0 { finish(); return }
        for (lane, report) in pending {
            report.collect(queue: queue) { [weak self] report in
                guard let self, !completed else { return }
                observations[lane]?.retransmitted = report.aggregatePathReport.retransmittedTransportByteCount
                observations[lane]?.transportBytes = report.aggregatePathReport.sentTransportByteCount
                remaining -= 1
                if remaining == 0 { finish() }
            }
        }
        later(0.08) { [weak self] in self?.finish() }
    }

    private func finish() {
        guard !completed else { return }
        completed = true
        let now = ProcessInfo.processInfo.systemUptime
        let qualities = observations.mapValues(\.quality)
        let winner: Lane?
        if Set(launches.values).count > 1 { winner = nil }
        else if let lan = qualities[.lan], let nearby = qualities[.nearby] {
            winner = LocalPathQuality.prefersCandidate(current: lan, candidate: nearby, candidateIsDirect: true)
                ? .nearby : (lan.usable ? .lan : nil)
        } else { winner = qualities.first { $0.value.usable }?.key }
        let result = Result(qualities: qualities, winner: winner,
                            launchID: Set(launches.values).count == 1 ? launches.values.first : nil,
                            setupSeconds: (samplesAt > 0 ? samplesAt : now) - startedAt,
                            sampleSeconds: samplesAt > 0 ? now - samplesAt : 0, elapsedSeconds: now - startedAt)
        cleanup()
        completion(result)
    }

    private func cleanup() {
        works.forEach { $0.cancel() }; works.removeAll(); reports.removeAll()
        for connection in connections.values {
            connection.stateUpdateHandler = nil
            connection.cancel()
        }
    }

    private func later(_ seconds: Double, _ action: @escaping () -> Void) {
        let work = DispatchWorkItem(block: action)
        works.append(work)
        queue.asyncAfter(deadline: .now() + seconds, execute: work)
    }
}
