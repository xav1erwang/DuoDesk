import CoreGraphics

/// Compares posted mouse positions with the already sampled system cursor. This is diagnostic
/// only: a different position can also mean an app confines the cursor or the person moved it.
/// No timeout here injects input, warps the cursor, or treats a still desktop as a failed stream.
struct PointerDeliveryCheck {
    enum Observation: Equatable {
        case unconfirmed
        case movedAgain
    }

    private var target: CGPoint?
    private var postedAt = -Double.infinity
    private var observed: CGPoint?
    private var unchangedSince = -Double.infinity
    private var reported = false

    mutating func posted(to point: CGPoint, now: Double) {
        if target == nil { unchangedSince = now }
        target = point
        postedAt = now
    }

    mutating func read(_ point: CGPoint, now: Double) -> Observation? {
        let moved = observed.map { distance($0, point) >= 0.5 } ?? false
        let resumed = reported && moved
        if moved || observed == nil {
            observed = point
            unchangedSince = now
            reported = false
        }
        guard let target else { return nil }
        // No outstanding input, or the last requested point was reached (allow edge rounding).
        if now - postedAt > 0.75 || distance(target, point) <= 2 {
            self.target = nil
            reported = false
            return resumed ? .movedAgain : nil
        }
        if resumed { return .movedAgain }
        guard !reported, now - unchangedSince >= 0.35 else { return nil }
        reported = true
        return .unconfirmed
    }

    private func distance(_ a: CGPoint, _ b: CGPoint) -> Double {
        hypot(a.x - b.x, a.y - b.y)
    }
}
