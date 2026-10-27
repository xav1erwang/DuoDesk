// Copyright 2026 DUO你电脑 contributors. SPDX-License-Identifier: Apache-2.0
import Foundation

/// A decoded image may be delayed between its decoder's last check and presentation admission.
/// Invalidation and the short admission operation share one lock, so an old image cannot enter
/// the presentation queue after its generation has been invalidated. Never wait or call back
/// into the decoder inside the admission closure.
public final class VideoOutputPermit: @unchecked Sendable {
    private let lock = NSLock()
    private var valid = true
    public init() { }

    public var isValid: Bool { lock.withLock { valid } }

    public func invalidate() { lock.withLock { valid = false } }

    @discardableResult
    public func admit(_ body: () -> Void) -> Bool {
        lock.lock(); defer { lock.unlock() }
        guard valid else { return false }
        body()
        return true
    }
}

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
    public let maxFrameBytes: Int

    /// Keep the normal queue small, but optionally allow a single larger access unit when it is
    /// the only queued frame. The caller still bounds queued plus in-flight compressed bytes.
    public init(frameLimit: Int = 32, byteLimit: Int = 8 * 1024 * 1024, maxFrameBytes: Int? = nil) {
        self.frameLimit = max(1, frameLimit)
        self.byteLimit = max(1, byteLimit)
        self.maxFrameBytes = max(self.byteLimit, maxFrameBytes ?? self.byteLimit)
    }
    public mutating func reset() {
        epoch &+= 1; waitingForKeyframe = true
        // Old tickets own their slots until their tasks complete.
    }
    /// A later frame was dropped, but already admitted earlier frames are still independently
    /// ordered before that gap and may finish. No later delta may enter until a new keyframe.
    public mutating func waitForKeyframeAfterGap() { waitingForKeyframe = true }
    public mutating func admit(bytes count: Int, keyframe: Bool) -> Ticket? {
        guard count > 0, count <= maxFrameBytes else { reset(); return nil }
        guard !waitingForKeyframe || keyframe else { return nil }
        let queueLimit = max(byteLimit, count)
        guard frames < frameLimit, bytes <= queueLimit - count else {
            // Preserve a large keyframe already being transferred to the hardware. Invalidating
            // it whenever the next delta arrives could starve the only usable recovery picture.
            if bytes > byteLimit { waitForKeyframeAfterGap() } else { reset() }
            return nil
        }
        waitingForKeyframe = false
        frames += 1; bytes += count
        return Ticket(epoch: epoch, bytes: count)
    }
    public func isCurrent(_ ticket: Ticket) -> Bool { ticket.epoch == epoch }
    public mutating func complete(_ ticket: Ticket) { frames -= 1; bytes -= ticket.bytes }
}
