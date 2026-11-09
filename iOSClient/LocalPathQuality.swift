// Copyright 2026 DUO你电脑 contributors. SPDX-License-Identifier: Apache-2.0
import Foundation

/// A short observation of a reliable connection, not a physical Wi-Fi packet-loss test.
/// Late echoes and transport retransmissions remain separate: TCP/QUIC can hide lost packets.
struct LocalPathQuality {
    struct Echo {
        let milliseconds: Double
        let bytes: Int
    }

    let sent: Int
    let echoes: [Echo]
    var retransmittedBytes: UInt64 = 0
    var sentTransportBytes: UInt64 = 0

    var usable: Bool { sent >= 6 && echoes.count >= 5 }
    var lateFraction: Double {
        guard sent > 0 else { return 1 }
        let onTime = echoes.count { $0.milliseconds <= 150 }
        return Double(max(0, sent - onTime)) / Double(sent)
    }
    var retransmissionFraction: Double {
        guard sentTransportBytes > 0 else { return 0 }
        return min(1, Double(retransmittedBytes) / Double(sentTransportBytes))
    }
    var tailMilliseconds: Double { percentile(0.9) }
    var jitterMilliseconds: Double { max(0, percentile(0.9) - percentile(0.5)) }
    /// Echo delivery rate under the current workload; deliberately not called link capacity.
    var deliveryBytesPerSecond: Double {
        let bulk = echoes.filter { $0.bytes >= 16_384 }
        let seconds = bulk.reduce(0) { $0 + $1.milliseconds / 1000 }
        return seconds > 0 ? Double(bulk.reduce(0) { $0 + $1.bytes }) / seconds : 0
    }

    private func percentile(_ fraction: Double) -> Double {
        let sorted = echoes.map(\.milliseconds).filter { $0.isFinite && $0 >= 0 }.sorted()
        guard !sorted.isEmpty else { return 1_000 }
        return sorted[min(sorted.count - 1, Int(ceil(Double(sorted.count) * fraction)) - 1)]
    }

    /// Reliability first, then tail latency and jitter, then delivery rate. Small differences
    /// keep the working network connection; when both are equivalent, LAN avoids an AWDL radio hop.
    static func prefersCandidate(current: Self, candidate: Self, candidateIsDirect: Bool) -> Bool {
        guard candidate.usable else { return false }
        guard current.usable else { return true }
        let lateDifference = candidate.lateFraction - current.lateFraction
        if abs(lateDifference) >= 0.12 { return lateDifference < 0 }
        let retransmissionDifference = candidate.retransmissionFraction - current.retransmissionFraction
        if abs(retransmissionDifference) >= 0.02 { return retransmissionDifference < 0 }
        let currentStability = current.tailMilliseconds + 2 * current.jitterMilliseconds
        let candidateStability = candidate.tailMilliseconds + 2 * candidate.jitterMilliseconds
        let margin = max(6, min(currentStability, candidateStability) * 0.2)
        if abs(candidateStability - currentStability) >= margin { return candidateStability < currentStability }
        if candidate.tailMilliseconds <= current.tailMilliseconds + 3,
           candidate.jitterMilliseconds <= current.jitterMilliseconds + 2,
           candidate.deliveryBytesPerSecond > current.deliveryBytesPerSecond * 1.5 { return true }
        return !candidateIsDirect
    }
}
