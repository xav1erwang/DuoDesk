// Copyright 2026 DUO你电脑 contributors. SPDX-License-Identifier: Apache-2.0

/// Bounded compressed HEVC admission. Delta frames after a discarded frame must wait for a
/// keyframe. The owner serializes admission, generation checks, resets and completions.
public struct VideoDecodeBacklog: Sendable {
    public struct Ticket: Sendable {
        public let epoch: UInt64
        let bytes: Int
    }
    public private(set) var epoch: UInt64 = 0
    public private(set) var frames = 0
    public private(set) var bytes = 0
    public private(set) var waitingForKeyframe = true
    public let frameLimit: Int
    public let byteLimit: Int

    public init(frameLimit: Int = 32, byteLimit: Int = 8 * 1024 * 1024) {
        self.frameLimit = max(1, frameLimit); self.byteLimit = max(1, byteLimit)
    }
    public mutating func reset() {
        epoch &+= 1; waitingForKeyframe = true
        // Old tickets own their slots until their tasks complete.
    }
    public mutating func admit(bytes count: Int, keyframe: Bool) -> Ticket? {
        guard count > 0, count <= byteLimit else { reset(); return nil }
        guard !waitingForKeyframe || keyframe else { return nil }
        guard frames < frameLimit, bytes <= byteLimit - count else { reset(); return nil }
        waitingForKeyframe = false
        frames += 1; bytes += count
        return Ticket(epoch: epoch, bytes: count)
    }
    public func isCurrent(_ ticket: Ticket) -> Bool { ticket.epoch == epoch }
    public mutating func complete(_ ticket: Ticket) { frames -= 1; bytes -= ticket.bytes }
}
