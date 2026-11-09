// Copyright 2026 DUO你电脑 contributors. SPDX-License-Identifier: Apache-2.0
import Foundation
import Network
#if canImport(StreamProtocol)
import StreamProtocol
#endif

/// Queue-confined comparison beside the live session. The existing session continues its native
/// display negotiation and video throughout. Only the candidate has a reader here; the session's
/// existing reader forwards marked pongs. A final echo stops the candidate at a message boundary
/// before its reader can be handed to the session. Cancelling never cancels the live connection.
final class LocalPathTrial {
    typealias Message = (header: StreamHeader, payload: Data)
    struct Result {
        let useCandidate: Bool
        let kept: [Message]
        let current: LocalPathQuality?
        let candidate: LocalPathQuality?
    }

    private static let signature = Data("DUOPATH1".utf8)
    static func isTrialPong(_ payload: Data) -> Bool { payload.count >= 28 && payload.starts(with: signature) }

    let current: NWConnection
    let candidate: NWConnection
    private let queue: DispatchQueue
    private let candidateIsDirect: Bool
    private let admits: (StreamHeader, Data) -> Bool?
    private let readyPathMatches: (NWConnection) -> Bool
    private let completion: (Result) -> Void
    private var prefix = Data()
    private var completed = false
    private var reading = false
    private var admitted = false
    private var measuring = false
    private var samplesFinished = false
    private var draining = false
    private var paused = false
    private var kept: [Message] = []
    private var keptBytes = 0
    private var works: [DispatchWorkItem] = []
    private var reports: [ObjectIdentifier: NWConnection.PendingDataTransferReport] = [:]
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
    private var observations: [ObjectIdentifier: Observation] = [:]

    /// `admits` returns nil for non-catalog messages, true only for the same authorized host
    /// launch, and false for a refusal or a different launch. TLS and its saved pin are supplied
    /// by the caller before this object is made.
    init(current: NWConnection, candidate: NWConnection, candidateIsDirect: Bool, queue: DispatchQueue,
         readyPathMatches: @escaping (NWConnection) -> Bool,
         admits: @escaping (StreamHeader, Data) -> Bool?, completion: @escaping (Result) -> Void) {
        self.current = current
        self.candidate = candidate
        self.candidateIsDirect = candidateIsDirect
        self.queue = queue
        self.readyPathMatches = readyPathMatches
        self.admits = admits
        self.completion = completion
        var nonce = UUID().uuid
        prefix = Self.signature + withUnsafeBytes(of: &nonce) { Data($0) }
    }

    /// The hello must already be queued as the candidate's first message.
    func start() {
        candidate.stateUpdateHandler = { [weak self] state in
            guard let self, !self.completed else { return }
            switch state {
            case .ready:
                guard !self.reading else { return }
                guard self.readyPathMatches(self.candidate) else { self.finish(useCandidate: false); return }
                self.reading = true
                MessageReader(connection: self.candidate, stillReads: { [weak self] in
                    self.map { !$0.completed && !$0.paused } ?? false
                }, onBytes: { _ in }, onMessage: { [weak self] header, data in
                    self?.receiveCandidate(header, data)
                }, onEnd: { [weak self] _ in self?.finish(useCandidate: false) }).start()
                // The saved TLS pin already identifies the Mac. Measure while its UI prepares
                // the desktop; the same-launch catalog is still required before any handover.
                self.beginSamples()
            case .failed, .cancelled: self.finish(useCandidate: false)
            default: break
            }
        }
        candidate.start(queue: queue)
        later(3) { [weak self] in
            guard let self, !self.admitted else { return }
            self.finish(useCandidate: false)
        }
    }

    func cancel() {
        guard !completed else { return }
        completed = true
        works.forEach { $0.cancel() }
        reports.removeAll()
        candidate.cancel()
    }

    /// Called by the live session's existing reader, on the same queue.
    func receivePong(_ data: Data, from connection: NWConnection) {
        guard !completed, data.starts(with: prefix), data.count >= prefix.count + 4 else { return }
        let offset = prefix.count
        let sequence = data[offset..<(offset + 4)].reduce(UInt32(0)) { ($0 << 8) | UInt32($1) }
        if connection === candidate, draining, sequence == UInt32.max {
            paused = true   // MessageReader asks stillReads before starting its next header.
            collectReports()
            return
        }
        let id = ObjectIdentifier(connection)
        guard let sent = observations[id]?.sent[sequence], observations[id]?.echoes[sequence] == nil else { return }
        let elapsed = (ProcessInfo.processInfo.systemUptime - sent.at) * 1000
        observations[id]?.echoes[sequence] = .init(milliseconds: max(0, elapsed), bytes: sent.bytes)
    }

    private func receiveCandidate(_ header: StreamHeader, _ data: Data) {
        if header.kind == .pong { receivePong(data, from: candidate); return }
        if let accepted = admits(header, data) {
            guard accepted else { finish(useCandidate: false); return }
            if !admitted {
                admitted = true
                drainIfReady()
            }
        }
        // These snapshots describe the currently running capture. Video is read and discarded
        // while comparing, so it cannot replay an old picture after handover. A fresh keyframe is
        // requested through SessionLink once the old connection's input fence has returned.
        let snapshots: [StreamMessageKind] = [.windowList, .hostSettings, .macInfo, .streamReset, .parameterSets, .cursorShape, .macPointer]
        guard snapshots.contains(header.kind) else { return }
        if header.kind == .streamReset {
            kept.removeAll { $0.header.kind == .parameterSets }
        }
        kept.removeAll { $0.header.kind == header.kind }
        kept.append((header, data))
        keptBytes = kept.reduce(0) { $0 + $1.payload.count }
        if keptBytes > 8 << 20 { finish(useCandidate: false) }
    }

    private func beginSamples() {
        guard !measuring else { return }
        measuring = true
        for connection in [current, candidate] {
            let id = ObjectIdentifier(connection)
            observations[id] = Observation()
            reports[id] = connection.startDataTransferReport()
        }
        // Eight paired samples span multiple AWDL time slots, with a small and a larger echo.
        // They never wait for display sizing or run on the UI thread.
        for sequence in UInt32(0)..<8 {
            later(Double(sequence) * 0.075) { [weak self] in
                guard let self, !self.completed else { return }
                for connection in [self.current, self.candidate] {
                    self.ping(sequence, bytes: sequence.isMultiple(of: 2) ? 256 : 16_384, on: connection)
                }
            }
        }
        later(0.75) { [weak self] in
            guard let self, !self.completed else { return }
            self.samplesFinished = true
            self.drainIfReady()
        }
    }

    private func drainIfReady() {
        guard admitted, samplesFinished, !draining, !completed else { return }
        draining = true
        ping(UInt32.max, bytes: 64, on: candidate, sample: false)
        later(0.25) { [weak self] in
            guard let self, !self.paused else { return }
            self.finish(useCandidate: false)
        }
    }

    private func ping(_ sequence: UInt32, bytes: Int, on connection: NWConnection, sample: Bool = true) {
        var payload = prefix
        var bigEndian = sequence.bigEndian
        withUnsafeBytes(of: &bigEndian) { payload.append(contentsOf: $0) }
        payload.append(Data(repeating: 0x5a, count: max(0, bytes - payload.count)))
        if sample { observations[ObjectIdentifier(connection)]?.sent[sequence] = (ProcessInfo.processInfo.systemUptime, payload.count) }
        let message = StreamMessage(kind: .ping, timestamp: Date.now.timeIntervalSince1970, isKeyframe: false, payload: payload)
        connection.send(content: message.serialized(), completion: .contentProcessed { [weak self] error in
            if error != nil, connection === self?.candidate { self?.finish(useCandidate: false) }
        })
    }

    private func collectReports() {
        let pending = reports
        reports.removeAll()
        var remaining = pending.count
        for (id, report) in pending {
            report.collect(queue: queue) { [weak self] report in
                guard let self, !self.completed else { return }
                self.observations[id]?.retransmitted = report.aggregatePathReport.retransmittedTransportByteCount
                self.observations[id]?.transportBytes = report.aggregatePathReport.sentTransportByteCount
                remaining -= 1
                if remaining == 0 { self.choose() }
            }
        }
        // The OS report is an optional signal, never a new wait in the connection flow.
        later(0.08) { [weak self] in self?.choose() }
    }

    private func choose() {
        guard !completed, paused,
              let current = observations[ObjectIdentifier(self.current)]?.quality,
              let candidate = observations[ObjectIdentifier(self.candidate)]?.quality else { return }
        finish(useCandidate: LocalPathQuality.prefersCandidate(current: current, candidate: candidate, candidateIsDirect: candidateIsDirect))
    }

    private func finish(useCandidate: Bool) {
        guard !completed else { return }
        completed = true
        works.forEach { $0.cancel() }
        reports.removeAll()
        if !useCandidate { candidate.cancel() }
        completion(Result(useCandidate: useCandidate, kept: useCandidate ? kept : [],
                          current: observations[ObjectIdentifier(current)]?.quality,
                          candidate: observations[ObjectIdentifier(candidate)]?.quality))
    }

    private func later(_ seconds: Double, _ action: @escaping () -> Void) {
        let work = DispatchWorkItem(block: action)
        works.append(work)
        queue.asyncAfter(deadline: .now() + seconds, execute: work)
    }
}
