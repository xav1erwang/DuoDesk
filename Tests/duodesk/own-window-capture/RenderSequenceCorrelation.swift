// Copyright 2026 DUO你电脑 contributors. SPDX-License-Identifier: Apache-2.0
// Test-only correlation of an owned window's drawn marker across two restricted capture streams.
import Foundation

enum RenderSequenceCorrelation {
    struct Sample {
        let displayTime: UInt64?
        let arrival: UInt64
        let marker: Int?
    }

    struct Summary {
        let valid: Bool
        let reason: String
        let primaryCount: Int
        let secondaryCount: Int
        let primaryUnique: Int
        let secondaryUnique: Int
        let common: Int
        let primaryOnly: Int
        let secondaryOnly: Int
        let ambiguousDraws: Int
        let beforeDraw: Int
        let displayDeltaP50: Double
        let displayDeltaP95: Double
        let arrivalDeltaP50: Double
        let arrivalDeltaP95: Double

        var description: String {
            "RENDER SEQUENCE MATCH: valid=\(valid), reason=\(reason), primarySamples=\(primaryCount), secondarySamples=\(secondaryCount), primaryUnique=\(primaryUnique), secondaryUnique=\(secondaryUnique), common=\(common), primaryOnlyInterior=\(primaryOnly), secondaryOnlyInterior=\(secondaryOnly), ambiguousDraws=\(ambiguousDraws), firstDisplayBeforeDraw=\(beforeDraw), displayDeltaMsP50=\(displayDeltaP50), p95=\(displayDeltaP95), callbackDeltaMsP50=\(arrivalDeltaP50), p95=\(arrivalDeltaP95); signed delta is display-filter minus window-filter for first observation of the same drawn marker; it does not establish the same refresh or identical document pixels"
        }
    }

    private struct Seen { let display: UInt64; let arrival: UInt64 }

    /// Both display times are documented as mach absolute time. Only markers drawn exactly once
    /// are comparable; exclude the two streams' boundary markers from one-sided counts. A repeat,
    /// draw completion or matching marker does not establish when the document itself changed.
    static func compare(draws: [(Int, UInt64)], primary: [Sample], secondary: [Sample],
                        lower: UInt64, upper: UInt64, nanosecondsPerTick: Double) -> Summary {
        func invalid(_ reason: String, _ a: Int = 0, _ b: Int = 0) -> Summary {
            Summary(valid: false, reason: reason, primaryCount: a, secondaryCount: b,
                    primaryUnique: 0, secondaryUnique: 0, common: 0, primaryOnly: 0, secondaryOnly: 0,
                    ambiguousDraws: 0, beforeDraw: 0, displayDeltaP50: 0, displayDeltaP95: 0,
                    arrivalDeltaP50: 0, arrivalDeltaP95: 0)
        }
        guard lower < upper, nanosecondsPerTick.isFinite, nanosecondsPerTick > 0 else { return invalid("invalid-time-window") }
        guard primary.allSatisfy({ $0.displayTime != nil }), secondary.allSatisfy({ $0.displayTime != nil }) else {
            return invalid("missing-display-time")
        }
        let a = primary.filter { $0.displayTime.map { $0 >= lower && $0 <= upper } ?? false }
        let b = secondary.filter { $0.displayTime.map { $0 >= lower && $0 <= upper } ?? false }
        guard !a.isEmpty, !b.isEmpty else { return invalid("empty-overlap", a.count, b.count) }
        var drawTimes: [Int: UInt64] = [:], ambiguous = Set<Int>()
        for (marker, time) in draws where marker > 0 {
            if drawTimes[marker] != nil { ambiguous.insert(marker) }
            else { drawTimes[marker] = time }
        }
        func collect(_ samples: [Sample]) -> (seen: [Int: Seen], edges: Set<Int>, error: String?) {
            var seen: [Int: Seen] = [:], edgeMarkers: [Int] = [], previousTime: UInt64?, previousMarker: Int?
            for sample in samples {
                guard let time = sample.displayTime, let marker = sample.marker else { return ([:], [], "missing-marker") }
                if let previousTime, time < previousTime { return ([:], [], "display-time-backward") }
                previousTime = time
                if marker == 0 { continue }
                if let previousMarker, marker < previousMarker { return ([:], [], "marker-backward-or-wrap") }
                previousMarker = marker
                guard let draw = drawTimes[marker] else { return ([:], [], "unknown-marker") }
                if ambiguous.contains(marker) { continue }
                guard sample.arrival >= draw else { return ([:], [], "callback-before-draw") }
                edgeMarkers.append(marker)
                if seen[marker] == nil { seen[marker] = Seen(display: time, arrival: sample.arrival) }
            }
            guard let first = edgeMarkers.first, let last = edgeMarkers.last else { return (seen, [], "no-unambiguous-marker") }
            return (seen, Set([first, last]), nil)
        }
        let left = collect(a), right = collect(b)
        if let error = left.error ?? right.error { return invalid(error, a.count, b.count) }
        let commonIDs = Set(left.seen.keys).intersection(right.seen.keys)
        guard !commonIDs.isEmpty else { return invalid("no-matched-marker", a.count, b.count) }
        let edgeIDs = left.edges.union(right.edges)
        let onlyA = Set(left.seen.keys).subtracting(right.seen.keys).subtracting(edgeIDs)
        let onlyB = Set(right.seen.keys).subtracting(left.seen.keys).subtracting(edgeIDs)
        func signedMS(_ value: UInt64, _ reference: UInt64) -> Double {
            let delta = value >= reference ? Double(value - reference) : -Double(reference - value)
            return delta * nanosecondsPerTick / 1_000_000
        }
        let displayDeltas = commonIDs.map { signedMS(right.seen[$0]!.display, left.seen[$0]!.display) }.sorted()
        let arrivalDeltas = commonIDs.map { signedMS(right.seen[$0]!.arrival, left.seen[$0]!.arrival) }.sorted()
        func percentile(_ values: [Double], _ p: Int) -> Double { values[(values.count * p + 99) / 100 - 1] }
        let beforeDraw = commonIDs.reduce(0) { count, id in
            count + ((left.seen[id]!.display < drawTimes[id]! || right.seen[id]!.display < drawTimes[id]!) ? 1 : 0)
        }
        return Summary(valid: true, reason: "ok", primaryCount: a.count, secondaryCount: b.count,
                       primaryUnique: left.seen.count, secondaryUnique: right.seen.count, common: commonIDs.count,
                       primaryOnly: onlyA.count, secondaryOnly: onlyB.count, ambiguousDraws: ambiguous.count,
                       beforeDraw: beforeDraw, displayDeltaP50: percentile(displayDeltas, 50),
                       displayDeltaP95: percentile(displayDeltas, 95), arrivalDeltaP50: percentile(arrivalDeltas, 50),
                       arrivalDeltaP95: percentile(arrivalDeltas, 95))
    }
}
