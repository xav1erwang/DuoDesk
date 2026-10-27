// Copyright 2026 DUO你电脑 contributors. SPDX-License-Identifier: Apache-2.0
import CoreMedia

/// Samples distinct compositor frames against a stable target clock. The deadline advances from
/// its prior position rather than from a late frame, so a faster source is not rounded down to a
/// divisor of its refresh rate. A long gap rebases; it never manufactures frames to catch up.
struct CaptureFramePacer {
    private let interval: CMTime
    private var next: CMTime?
    private var last: CMTime?
    private var resetCandidate: CMTime?
    private var resetCount = 0

    init(fps: Int) {
        precondition((1...240).contains(fps))
        interval = CMTime(value: 1, timescale: CMTimeScale(fps))
    }

    mutating func admit(_ timestamp: CMTime) -> Bool {
        guard timestamp.isNumeric, timestamp.timescale > 0 else { return false }
        if let last, CMTimeCompare(timestamp, last) <= 0 {
            // One stale callback is discarded. A sequence of three increasing timestamps behind
            // the previous epoch means the source clock reset; rebase instead of freezing forever.
            if let resetCandidate, CMTimeCompare(timestamp, resetCandidate) > 0 { resetCount += 1 }
            else { resetCount = 1 }
            resetCandidate = timestamp
            guard resetCount >= 3 else { return false }
            self.last = timestamp; next = CMTimeAdd(timestamp, interval)
            resetCandidate = nil; resetCount = 0
            return true
        }
        resetCandidate = nil; resetCount = 0
        last = timestamp
        guard let deadline = next else {
            next = CMTimeAdd(timestamp, interval)
            return true
        }
        guard CMTimeCompare(timestamp, deadline) >= 0 else { return false }
        let late = CMTimeSubtract(timestamp, deadline)
        next = CMTimeCompare(late, CMTimeMultiply(interval, multiplier: 3)) > 0
            ? CMTimeAdd(timestamp, interval) : CMTimeAdd(deadline, interval)
        return true
    }
}
