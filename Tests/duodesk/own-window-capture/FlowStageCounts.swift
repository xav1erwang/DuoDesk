// Copyright 2026 DUO你电脑 contributors. SPDX-License-Identifier: Apache-2.0
// Aggregate diagnostic stage counts; no image data or credentials are retained.
import Foundation

final class FlowStageCounts: @unchecked Sendable {
    enum Stage { case capture, encode, receive, decode }
    struct Counts: Equatable {
        var capture = 0, encode = 0, receive = 0, decode = 0
        mutating func add(_ stage: Stage) {
            switch stage {
            case .capture: capture += 1
            case .encode: encode += 1
            case .receive: receive += 1
            case .decode: decode += 1
            }
        }
    }
    private let lock = NSLock()
    private var start = Double.infinity, end = Double.infinity
    private var totals = Counts(), seconds: [Counts] = []

    func begin(at start: TimeInterval, seconds: Int) {
        precondition(start.isFinite && seconds > 0)
        lock.withLock {
            self.start = start; end = start + Double(seconds)
            totals = Counts(); self.seconds = [Counts](repeating: Counts(), count: seconds)
        }
    }

    func record(_ stage: Stage, at time: TimeInterval = ProcessInfo.processInfo.systemUptime) {
        lock.withLock {
            guard time.isFinite, time >= start, time < end else { return }
            let index = Int(time - start)
            guard seconds.indices.contains(index) else { return }
            totals.add(stage); seconds[index].add(stage)
        }
    }

    var snapshot: (totals: Counts, seconds: [Counts]) { lock.withLock { (totals, seconds) } }

    func report() -> String {
        let value = snapshot
        let buckets = value.seconds.map { "\($0.capture)/\($0.encode)/\($0.receive)/\($0.decode)" }.joined(separator: ",")
        let c = value.totals
        return "FLOW STAGES: activeSeconds=\(value.seconds.count), capture=\(c.capture), encoded=\(c.encode), "
            + "received=\(c.receive), decoded=\(c.decode), perSecond(capture/encoded/received/decoded)=[\(buckets)]; "
            + "same monotonic time window, not matched individual frames; boundary transit may affect counts"
    }
}
