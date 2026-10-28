// Copyright 2026 DUO你电脑 contributors. SPDX-License-Identifier: Apache-2.0
// Diagnostic only: compare a drawn marker and a document-center grid from the same owned sample.
import Foundation

enum MarkerContentCorrelation {
    static let bitCount = 12, cellCount = bitCount + 4

    /// The first and last pairs are fixed sentinels. Reject a partially rendered or misplaced
    /// marker; its value must never be counted as a changing desktop image.
    static func decode(_ cells: [UInt8]) -> Int? {
        guard cells.count == cellCount else { return nil }
        var bits: [Bool] = []
        for value in cells {
            guard value <= 80 || value >= 175 else { return nil }
            bits.append(value >= 175)
        }
        guard bits[0], !bits[1], bits[cellCount - 2], !bits[cellCount - 1] else { return nil }
        return (0..<bitCount).reduce(0) { $0 | (bits[$1 + 2] ? 1 << $1 : 0) }
    }

    struct Draw { let marker: Int; let time: Double }
    struct Counts {
        var sameMarkerSameCenter = 0, sameMarkerChangedCenter = 0
        var changedMarkerSameCenter = 0, changedMarkerChangedCenter = 0
        var drawBetweenZero = 0, drawBetweenOne = 0, drawBetweenMany = 0
        var missing = 0, unknown = 0, ambiguous = 0, backward = 0, beforeDraw = 0, reused = 0
        var comparisons: Int { sameMarkerSameCenter + sameMarkerChangedCenter + changedMarkerSameCenter + changedMarkerChangedCenter }
        var valid: Bool { comparisons > 0 && missing == 0 && unknown == 0 && ambiguous == 0 && backward == 0 && beforeDraw == 0 }
        var description: String {
            "pairs=\(comparisons),sameMarkerSameCenter=\(sameMarkerSameCenter),sameMarkerChangedCenter=\(sameMarkerChangedCenter),changedMarkerSameCenter=\(changedMarkerSameCenter),changedMarkerChangedCenter=\(changedMarkerChangedCenter),sameBothDrawsBetweenZeroOneMany=[\(drawBetweenZero),\(drawBetweenOne),\(drawBetweenMany)],missing=\(missing),unknown=\(unknown),ambiguous=\(ambiguous),backward=\(backward),beforeDraw=\(beforeDraw),reusedSource=\(reused)"
        }
    }
    struct Summary {
        let valid: Bool
        let reason: String
        let raw: Counts
        let output: Counts
        var description: String {
            "MARKER CONTENT CORRELATION: valid=\(valid), reason=\(reason), raw={\(raw.description)}, output={\(output.description)}; same-buffer marker and center grid, own window only; draw-between counts use callback arrival times and do not establish compositor presentation"
        }
    }

    static func analyze(raw: [PhaseSelection.Sample], outputs: [PhaseSelection.Output], draws: [Draw],
                        start: Double, end: Double) -> Summary {
        func invalid(_ reason: String) -> Summary { Summary(valid: false, reason: reason, raw: Counts(), output: Counts()) }
        guard start.isFinite, end.isFinite, end > start, !raw.isEmpty, !outputs.isEmpty else { return invalid("empty-or-invalid-window") }
        guard raw.allSatisfy({ $0.pts.isFinite && $0.arrived.isFinite && $0.arrived >= $0.pts && $0.arrived - $0.pts <= 1 }),
              zip(raw, raw.dropFirst()).allSatisfy({ $0.pts < $1.pts && $0.arrived <= $1.arrived }),
              outputs.allSatisfy({ $0.pts.isFinite && $0.delivered.isFinite }),
              zip(outputs, outputs.dropFirst()).allSatisfy({ $0.delivered <= $1.delivered }),
              draws.allSatisfy({ $0.marker >= 0 && $0.time.isFinite }) else { return invalid("invalid-clock-or-order") }
        var drawTime: [Int: Double] = [:], ambiguous = Set<Int>()
        for draw in draws where draw.marker > 0 {
            if drawTime[draw.marker] != nil { ambiguous.insert(draw.marker) }
            else { drawTime[draw.marker] = draw.time }
        }
        let drawTimes = draws.map(\.time).sorted()
        func upperBound(_ value: Double) -> Int {
            var lower = 0, upper = drawTimes.count
            while lower < upper {
                let middle = (lower + upper) / 2
                if drawTimes[middle] <= value { lower = middle + 1 } else { upper = middle }
            }
            return lower
        }
        func add(_ previous: PhaseSelection.Sample, _ current: PhaseSelection.Sample, to counts: inout Counts) {
            guard let before = previous.marker, let after = current.marker, before > 0, after > 0,
                  !previous.signature.isEmpty, previous.signature.count == current.signature.count else { counts.missing += 1; return }
            guard let beforeDraw = drawTime[before], let afterDraw = drawTime[after] else { counts.unknown += 1; return }
            guard !ambiguous.contains(before), !ambiguous.contains(after) else { counts.ambiguous += 1; return }
            guard after >= before else { counts.backward += 1; return }
            guard beforeDraw <= previous.arrived, afterDraw <= current.arrived else { counts.beforeDraw += 1; return }
            let centerChanged = PhaseSelection.changed(previous.signature, current.signature)
            if before == after {
                if centerChanged { counts.sameMarkerChangedCenter += 1 }
                else {
                    counts.sameMarkerSameCenter += 1
                    let between = upperBound(current.arrived) - upperBound(previous.arrived)
                    if between == 0 { counts.drawBetweenZero += 1 }
                    else if between == 1 { counts.drawBetweenOne += 1 }
                    else { counts.drawBetweenMany += 1 }
                }
            } else if centerChanged { counts.changedMarkerChangedCenter += 1 }
            else { counts.changedMarkerSameCenter += 1 }
        }
        var rawCounts = Counts(), previousRaw: PhaseSelection.Sample?
        for sample in raw where sample.arrived < end {
            if sample.arrived >= start {
                if let previousRaw { add(previousRaw, sample, to: &rawCounts) } else { rawCounts.missing += 1 }
            }
            previousRaw = sample
        }
        let byPTS = Dictionary(uniqueKeysWithValues: raw.enumerated().map { ($0.element.pts, $0.offset) })
        var outputCounts = Counts(), previousIndex: Int?
        for output in outputs where output.delivered < end {
            let index = byPTS[output.pts].flatMap { output.delivered >= raw[$0].arrived ? $0 : nil }
            if output.delivered >= start {
                guard let currentIndex = index, let priorIndex = previousIndex else {
                    outputCounts.missing += 1; previousIndex = index; continue
                }
                if currentIndex == priorIndex { outputCounts.reused += 1 }
                else if currentIndex < priorIndex { outputCounts.backward += 1 }
                else { add(raw[priorIndex], raw[currentIndex], to: &outputCounts) }
            }
            previousIndex = index
        }
        let valid = rawCounts.valid && outputCounts.valid && outputCounts.reused == 0
        return Summary(valid: valid, reason: valid ? "ok" : "missing-or-inconsistent-marker", raw: rawCounts, output: outputCounts)
    }
}
