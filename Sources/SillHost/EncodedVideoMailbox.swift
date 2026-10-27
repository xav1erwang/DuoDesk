// Copyright 2026 DUO你电脑 contributors. SPDX-License-Identifier: Apache-2.0
import Foundation

/// The network queue can be delayed independently of VideoToolbox. Keep at most one serialized
/// frame waiting for it, and remember any lost reference so no dependent delta reaches a client.
/// StreamServer holds its ingress lock around every operation and queues the drain under that lock.
struct EncodedVideoMailbox {
    struct Packet {
        let data: Data
        let parameters: Data?
        let isKeyframe: Bool
        var lostBefore = false
        var lostAfter = false
    }
    struct Offer {
        let schedule: Bool
        let dropped: Bool
        let stale: Bool
    }

    private(set) var token: UUID?
    private(set) var pending: Packet?
    private(set) var scheduled = false

    mutating func reset(to token: UUID?) {
        self.token = token
        pending = nil
        scheduled = false
    }

    mutating func offer(_ incoming: Packet, token: UUID) -> Offer {
        guard self.token == token else { return Offer(schedule: false, dropped: false, stale: true) }
        let needsSchedule = !scheduled
        var dropped = false
        if var old = pending {
            dropped = true
            if incoming.isKeyframe {
                // The newer keyframe is independent of every discarded access unit.
                pending = incoming
            } else if old.isKeyframe {
                // Keep the useful keyframe, but request another after delivering it: this newer
                // delta will never arrive and a still desktop must not remain on the old image.
                old.lostAfter = true
                pending = old
            } else {
                var replacement = incoming
                replacement.lostBefore = true
                pending = replacement
            }
        } else {
            pending = incoming
        }
        scheduled = true
        return Offer(schedule: needsSchedule, dropped: dropped, stale: false)
    }

    mutating func take(token: UUID) -> Packet? {
        // A drain already queued for an older stream must not consume the new stream's frame.
        guard self.token == token, scheduled else { return nil }
        let result = pending
        pending = nil
        scheduled = false
        return result
    }
}
