// Copyright 2026 DUO你电脑 contributors. SPDX-License-Identifier: Apache-2.0
import Foundation

/// Versioned separately from the desktop stream: an older host or client simply never subscribes.
/// This is a contract for a real Touch Bar stream; defining it does not advertise an available source.
public enum TouchBarProtocol {
    public static let generation = 1
    /// A Touch Bar picture is small, but a broken peer must not make the receiver hold arbitrary data.
    public static let maximumEncodedBytes = 2 * 1024 * 1024
}

/// Client → host. Subscribe only while the Touch Bar is visible; unsubscribe on hiding or leaving.
public struct TouchBarSubscription: Codable, Equatable, Sendable {
    public var generation: Int
    public var watching: Bool

    public init(watching: Bool) {
        self.generation = TouchBarProtocol.generation
        self.watching = watching
    }

    public var isSupported: Bool { generation == TouchBarProtocol.generation }
}

/// One independently generated real surface. `id` changes whenever the source or encoder restarts.
/// Coordinates describe the top-left anchored content area, never padding on its right or bottom.
public struct TouchBarSurface: Codable, Equatable, Sendable {
    public var id: UUID
    public var pixelWidth: Int
    public var pixelHeight: Int
    public var encodedWidth: Int
    public var encodedHeight: Int
    public var acceptsInput: Bool

    public init(id: UUID, pixelWidth: Int, pixelHeight: Int, encodedWidth: Int, encodedHeight: Int,
                acceptsInput: Bool) {
        self.id = id; self.pixelWidth = pixelWidth; self.pixelHeight = pixelHeight
        self.encodedWidth = encodedWidth; self.encodedHeight = encodedHeight; self.acceptsInput = acceptsInput
    }

    public var isValid: Bool {
        guard (1...8192).contains(pixelWidth), (1...2048).contains(pixelHeight),
              encodedWidth == ((pixelWidth + 1) & ~1), encodedHeight == ((pixelHeight + 1) & ~1),
              (1...8192).contains(encodedWidth), (1...2048).contains(encodedHeight),
              encodedWidth.isMultiple(of: 2), encodedHeight.isMultiple(of: 2) else { return false }
        // The user expects a bar, not a second arbitrary screen. Bounds also limit decode memory.
        return encodedWidth >= encodedHeight && encodedWidth * encodedHeight <= 4_194_304
    }
}

public enum TouchBarAvailability: String, Codable, Sendable {
    case unavailable, starting, live
}

/// Host → client. `live` is meaningful only with a validated descriptor for this session.
public struct TouchBarStatus: Codable, Equatable, Sendable {
    public var availability: TouchBarAvailability
    public var surface: TouchBarSurface?

    public init(availability: TouchBarAvailability, surface: TouchBarSurface? = nil) {
        self.availability = availability; self.surface = surface
    }

    public var isValid: Bool {
        switch availability {
        case .live: return surface?.isValid == true
        case .unavailable, .starting: return surface == nil
        }
    }
}

public enum TouchBarPhase: String, Codable, Sendable { case began, moved, ended, cancelled }

/// Unit coordinates in the visible surface (top-left origin); no control may outlive its surface.
public struct TouchBarTouch: Codable, Equatable, Sendable {
    public var surfaceID: UUID
    public var phase: TouchBarPhase
    public var x: Double
    public var y: Double

    public init(surfaceID: UUID, phase: TouchBarPhase, x: Double, y: Double) {
        self.surfaceID = surfaceID; self.phase = phase; self.x = x; self.y = y
    }

    public var isValid: Bool {
        x.isFinite && y.isFinite && (0...1).contains(x) && (0...1).contains(y)
    }
}

/// A parameter-set or HEVC access-unit payload, fenced by the surface ID. The actual HEVC encode
/// and decode paths must verify hardware acceleration; this envelope never decodes or alters pixels.
public struct TouchBarMedia: Equatable, Sendable {
    public let surfaceID: UUID
    public let bytes: Data

    public init?(surfaceID: UUID, bytes: Data) {
        guard !bytes.isEmpty, bytes.count <= TouchBarProtocol.maximumEncodedBytes else { return nil }
        self.surfaceID = surfaceID; self.bytes = bytes
    }

    public init?(encoded: Data) {
        guard encoded.count > 16, encoded.count <= 16 + TouchBarProtocol.maximumEncodedBytes else { return nil }
        let prefix = Array(encoded.prefix(16))
        let id = UUID(uuid: (prefix[0], prefix[1], prefix[2], prefix[3], prefix[4], prefix[5], prefix[6], prefix[7],
                             prefix[8], prefix[9], prefix[10], prefix[11], prefix[12], prefix[13], prefix[14], prefix[15]))
        self.init(surfaceID: id, bytes: Data(encoded.dropFirst(16)))
    }

    public var encoded: Data {
        var raw = surfaceID.uuid
        var data = withUnsafeBytes(of: &raw) { Data($0) }
        data.append(bytes)
        return data
    }
}

/// One self-contained HEVC keyframe and its parameter sets. A slow client may drop any whole
/// packet without invalidating the next; the producer must actually force and verify keyframes.
/// Layout inside the UUID-fenced media envelope: parameter length (4, BE), parameter sets, NALs.
public struct TouchBarKeyframe {
    public let surfaceID: UUID
    public let parameters: ParameterSets
    public let accessUnit: Data

    public init?(surfaceID: UUID, parameters: ParameterSets, accessUnit: Data) {
        guard parameters.nalUnitHeaderLength == 4, parameters.sets.count == 3,
              parameters.sets.allSatisfy({ !$0.isEmpty && $0.count <= 65_535 }), !accessUnit.isEmpty else { return nil }
        let parameterLength = 2 + parameters.sets.reduce(0) { $0 + 2 + $1.count }
        guard parameterLength + 4 < TouchBarProtocol.maximumEncodedBytes,
              accessUnit.count <= TouchBarProtocol.maximumEncodedBytes - parameterLength - 4 else { return nil }
        self.surfaceID = surfaceID; self.parameters = parameters; self.accessUnit = accessUnit
    }

    public init?(encoded: Data) {
        guard let media = TouchBarMedia(encoded: encoded), media.bytes.count > 4 else { return nil }
        let parameterLength = Int(media.bytes.readBigEndian(UInt32.self, at: 0))
        guard parameterLength > 0, parameterLength < media.bytes.count - 4 else { return nil }
        let start = media.bytes.startIndex + 4
        let parameterData = media.bytes.subdata(in: start..<(start + parameterLength))
        guard let parameters = ParameterSets(encoded: parameterData),
              parameters.nalUnitHeaderLength == 4, parameters.sets.count == 3,
              parameters.sets.allSatisfy({ !$0.isEmpty }), parameters.encoded() == parameterData else { return nil }
        let frame = media.bytes.subdata(in: (start + parameterLength)..<media.bytes.endIndex)
        self.init(surfaceID: media.surfaceID, parameters: parameters, accessUnit: frame)
    }

    public var encoded: Data {
        let parameterData = parameters.encoded()
        var body = Data(capacity: 4 + parameterData.count + accessUnit.count)
        body.appendBigEndian(UInt32(parameterData.count)); body.append(parameterData); body.append(accessUnit)
        return TouchBarMedia(surfaceID: surfaceID, bytes: body)!.encoded
    }
}
