// Copyright 2026 DUO你电脑 contributors. SPDX-License-Identifier: Apache-2.0
// Offline comparison of arrival-time sampling phases. Signatures are supplied by a diagnostic;
// this does not control capture or manufacture frames.
import Foundation

enum PhaseSelection {
    struct Sample {
        let pts: Double
        let arrived: Double
        let signature: [UInt8]
    }
    struct Output {
        let pts: Double
        let delivered: Double
    }
    struct Result {
        var slots = 0, comparisons = 0, changed = 0, reusedSource = 0, missing = 0
        var sourceAges: [Double] = []
    }

    /// This is an intentionally conservative comparison of the sampled document center: a
    /// change requires at least 13 sampled pixels differing by three levels and mean delta 0.12.
    /// It cannot establish that two complete desktop images are equal.
    static func changed(_ a: [UInt8], _ b: [UInt8]) -> Bool {
        guard !a.isEmpty, a.count == b.count else { return false }
        var pixels = 0, sum = 0
        for i in a.indices {
            let delta = abs(Int(a[i]) - Int(b[i]))
            if delta >= 3 { pixels += 1; sum += delta }
        }
        return pixels >= 13 && Double(sum) / Double(a.count) >= 0.12
    }

    /// At each hypothetical output deadline take the latest source callback already delivered.
    /// This is an offline comparison, not an exact replay of dispatch scheduling in WindowCapture.
    static func candidate(_ raw: [Sample], start: Double, end: Double, fps: Int, phase: Double) -> Result {
        var result = Result()
        guard let first = raw.first, start.isFinite, end.isFinite, end > start,
              fps > 0, phase.isFinite, phase >= 0, phase < 1.0 / Double(fps) else { return result }
        let interval = 1.0 / Double(fps)
        let base = first.pts + interval + phase
        var tick = max(0, Int(floor((start - base) / interval)) - 1)
        var index = -1, previous = -1
        while true {
            let deadline = base + Double(tick) * interval
            if deadline >= end { break }
            while index + 1 < raw.count && raw[index + 1].arrived <= deadline { index += 1 }
            if deadline >= start {
                result.slots += 1
                if index < 0 || previous < 0 { result.missing += 1 }
                else if index == previous { result.reusedSource += 1 }
                else {
                    result.comparisons += 1
                    if changed(raw[index].signature, raw[previous].signature) { result.changed += 1 }
                    result.sourceAges.append(max(0, deadline - raw[index].pts))
                }
            }
            previous = index
            tick += 1
        }
        return result
    }

    /// Match the actual pacer's emitted PTS back to its raw sample; no image is persisted.
    static func actual(_ raw: [Sample], outputs: [Output], start: Double, end: Double) -> Result {
        var result = Result(), byPTS: [Double: Int] = [:]
        for (i, sample) in raw.enumerated() { byPTS[sample.pts] = i }
        var previous: Int?
        for output in outputs where output.delivered < end {
            let index = byPTS[output.pts].flatMap { output.delivered >= raw[$0].arrived ? $0 : nil }
            if output.delivered >= start {
                result.slots += 1
                guard let index, let before = previous else { result.missing += 1; previous = index; continue }
                if index == before { result.reusedSource += 1 }
                else {
                    result.comparisons += 1
                    if changed(raw[index].signature, raw[before].signature) { result.changed += 1 }
                    result.sourceAges.append(max(0, output.delivered - raw[index].pts))
                }
            }
            previous = index
        }
        return result
    }
}
