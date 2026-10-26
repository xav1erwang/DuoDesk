import Foundation

/// An ordered video restart, independent of whether two encoders produce identical parameter
/// sets. Replayed markers at a keyframe or connection hand-over must not clear a newer picture.
public struct VideoStreamEpoch: Sendable {
    public private(set) var lastValue: UInt64?

    public init() {}

    public mutating func nextReset() -> Data {
        var next = (lastValue ?? 0) &+ 1
        if next == 0 { next = 1 }
        lastValue = next
        return Data(stride(from: 56, through: 0, by: -8).map { UInt8(truncatingIfNeeded: next >> $0) })
    }

    public mutating func acceptReset(_ payload: Data) -> Bool {
        guard payload.count == 8 else { return false }
        let next = payload.reduce(UInt64(0)) { ($0 << 8) | UInt64($1) }
        guard next != 0 else { return false }
        if let lastValue {
            let distance = next &- lastValue
            guard distance > 0, distance < UInt64(1) << 63 else { return false }
        }
        lastValue = next
        return true
    }

    public mutating func reset() { lastValue = nil }

    /// A native input must name the video still active when the host acts on it. A client-side
    /// decoder fence alone cannot reject an old input already travelling towards the host.
    public func acceptsControl(_ control: VideoControlPayload?) -> Bool {
        guard let lastValue, let control else { return false }
        return control.epoch == lastValue
    }
}

/// Optional prefix for kinds 8 and 28: `DUOC`, a nonzero 8-byte big-endian video epoch, then the
/// existing JSON payload. Old plain input remains unchanged for hosts without restart markers.
public struct VideoControlPayload: Sendable {
    private static let marker = Data([0x44, 0x55, 0x4F, 0x43])
    public let epoch: UInt64
    public let payload: Data

    public init?(epoch: UInt64, payload: Data) {
        guard epoch != 0, !payload.isEmpty else { return nil }
        self.epoch = epoch
        self.payload = payload
    }

    public init?(encoded: Data) {
        guard encoded.count > 12, encoded.starts(with: Self.marker) else { return nil }
        let epoch = encoded.dropFirst(4).prefix(8).reduce(UInt64(0)) { ($0 << 8) | UInt64($1) }
        self.init(epoch: epoch, payload: Data(encoded.dropFirst(12)))
    }

    public var encoded: Data {
        var result = Self.marker
        result.append(contentsOf: stride(from: 56, through: 0, by: -8).map { UInt8(truncatingIfNeeded: epoch >> $0) })
        result.append(payload)
        return result
    }
}
