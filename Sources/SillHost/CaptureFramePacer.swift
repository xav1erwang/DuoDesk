// Copyright 2026 DUO你电脑 contributors. SPDX-License-Identifier: Apache-2.0
import CoreMedia

/// Samples distinct compositor frames against a stable target clock. The deadline advances from
/// its prior position rather than from a late frame, so a faster source is not rounded down to a
/// divisor of its refresh rate. A long gap rebases; it never manufactures frames to catch up.
struct CaptureFramePacer {
    enum Decision {
        case emit
        case hold(for: TimeInterval)
        case discard
    }
    private let interval: CMTime
    private var next: CMTime?
    private var last: CMTime?
    private var resetCandidate: CMTime?
    private var resetCount = 0

    init(fps: Int) {
        precondition((1...240).contains(fps))
        interval = CMTime(value: 1, timescale: CMTimeScale(fps))
    }

    mutating func consider(_ timestamp: CMTime) -> Decision {
        guard timestamp.isNumeric, timestamp.timescale > 0 else { return .discard }
        if let last, CMTimeCompare(timestamp, last) <= 0 {
            // One stale callback is discarded. A sequence of three increasing timestamps behind
            // the previous epoch means the source clock reset; rebase instead of freezing forever.
            if let resetCandidate, CMTimeCompare(timestamp, resetCandidate) > 0 { resetCount += 1 }
            else { resetCount = 1 }
            resetCandidate = timestamp
            guard resetCount >= 3 else { return .discard }
            self.last = timestamp; next = CMTimeAdd(timestamp, interval)
            resetCandidate = nil; resetCount = 0
            return .emit
        }
        resetCandidate = nil; resetCount = 0
        last = timestamp
        guard let deadline = next else {
            next = CMTimeAdd(timestamp, interval)
            return .emit
        }
        guard CMTimeCompare(timestamp, deadline) >= 0 else {
            let wait = CMTimeGetSeconds(CMTimeSubtract(deadline, timestamp))
            return wait.isFinite && wait > 0 ? .hold(for: wait) : .discard
        }
        let late = CMTimeSubtract(timestamp, deadline)
        next = CMTimeCompare(late, CMTimeMultiply(interval, multiplier: 3)) > 0
            ? CMTimeAdd(timestamp, interval) : CMTimeAdd(deadline, interval)
        return .emit
    }

    /// A held real frame was delivered at the pending deadline. Keep the stable target clock;
    /// the frame's own presentation timestamp remains untouched.
    mutating func deliveredHeldFrame() {
        guard let deadline = next else { return }
        next = CMTimeAdd(deadline, interval)
    }

    /// `wait` was measured from the sample's presentation timestamp, not from its arrival on
    /// the callback queue. When the stream exposes its output clock, subtract the time already
    /// spent in delivery. Unknown, inconsistent or implausibly distant clocks keep the original
    /// conservative wait; never infer a relationship between unrelated clock epochs.
    static func deliveryDelay(wait: TimeInterval, sampleTime: CMTime, clockTime: CMTime?) -> TimeInterval {
        guard wait.isFinite, wait > 0, let clockTime, sampleTime.isNumeric, clockTime.isNumeric,
              sampleTime.timescale > 0, clockTime.timescale > 0, sampleTime.epoch == clockTime.epoch else { return wait }
        let elapsed = CMTimeGetSeconds(CMTimeSubtract(clockTime, sampleTime))
        guard elapsed.isFinite, (0...10).contains(elapsed) else { return wait }
        return max(0, wait - elapsed)
    }
}
