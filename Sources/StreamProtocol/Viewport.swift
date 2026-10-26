import Foundation

/// Duo's upper display in native pixels. HEVC/NV12 dimensions round UP to even pixels; never down.
/// This also specifies the Mac desktop's aspect ratio, independently of its physical panel.
public struct DuoDesktopResolution: Codable, Hashable, Sendable {
    public var width: Int
    public var height: Int
    public init(width: Int, height: Int) { self.width = width; self.height = height }
    public var isValid: Bool { (320...8192).contains(width) && (240...8192).contains(height) }
    public var encodedWidth: Int { isValid ? (width + 1) & ~1 : 0 }
    public var encodedHeight: Int { isValid ? (height + 1) & ~1 : 0 }
    public func accepts(width: Int, height: Int) -> Bool {
        isValid && width == encodedWidth && height == encodedHeight
    }
}

/// Client → host: the size of the client's stream panel in device points and how it wants the
/// Mac window sized to it. Milestone 3's fallback path: rather than a virtual display, the host
/// resizes the real window through Accessibility.
///
/// `scale` is device points per Mac point for text. nil means "leave the Mac window alone"
/// (the default today). 1.0 fits the window to the panel at 1:1 points; 1.5 makes the window a
/// third smaller in Mac points so its content renders a third larger on the device; 0.8 the
/// reverse. Apps have minimum window sizes; the host clamps and streams whatever it actually got.
public struct Viewport: Codable, Hashable {
    public var width: Double
    public var height: Double
    public var scale: Double?
    /// The client draws its own pointer. Kept for compatibility; the host now always leaves the
    /// Mac cursor out of the video and streams its shape separately (`.cursorShape`).
    public var localCursor: Bool?
    /// The rate this device wants the stream at: its panel's ceiling (120 on ProMotion, 60
    /// elsewhere), or 60 while Low Power Mode caps the panel. nil (an older client) means 60.
    /// The host runs the stream at the highest rate among its connected clients and restarts the
    /// pipeline when that changes.
    public var fps: Int?

    /// A strict Duo session: change the Mac desktop to this size/aspect and encode at native pixels.
    /// Optional for old clients. A host must not substitute a lower resolution on slow links.
    public var desktopResolution: DuoDesktopResolution?

    /// Validate external layout numbers before sizing windows or converting them to integers.
    /// Zero-sized panels remain valid for legacy frame-rate-only requests.
    public var isValid: Bool {
        guard width.isFinite, height.isFinite, (0...32768).contains(width),
              (0...32768).contains(height), desktopResolution?.isValid ?? true else { return false }
        if let scale { return scale.isFinite && (0.0625...16).contains(scale) }
        return true
    }

    public init(width: Double, height: Double, scale: Double?, localCursor: Bool? = nil, fps: Int? = nil,
                desktopResolution: DuoDesktopResolution? = nil) {
        self.width = width; self.height = height; self.scale = scale; self.localCursor = localCursor; self.fps = fps
        self.desktopResolution = desktopResolution
    }
}

/// Client → host once a second while connected. Lets the Mac's log show what the device sees,
/// which is how the latency number gets measured without a screenshot of the device.
///
/// A current client measures every frame and several pings a second, and each report covers the
/// second since the one before. The first four fields are the ones every host requires, so they
/// keep carrying the typical value: that second's median, or -1 when the second had no sample
/// (no frame arrived, no pong came back) rather than an older number repeated. The maxima came
/// later as optional fields: an older host ignores them, and nil means an older client, whose
/// frame age and rtt are single samples.
public struct ClientStats: Codable, Hashable {
    public var fps: Int
    public var frameAgeMs: Int      // host encode timestamp → received on the device (clocks assumed synced)
    public var rttMs: Int           // ping round trip
    public var device: String       // model name, so several clients can be told apart
    /// The worst frame age of that second, -1 when no frame arrived. nil from an older client.
    public var frameAgeMaxMs: Int?
    /// The slowest round trip among that second's pongs, -1 when none came back. nil from an older client.
    public var rttMaxMs: Int?

    public init(fps: Int, frameAgeMs: Int, rttMs: Int, device: String,
                frameAgeMaxMs: Int? = nil, rttMaxMs: Int? = nil) {
        self.fps = fps; self.frameAgeMs = frameAgeMs; self.rttMs = rttMs; self.device = device
        self.frameAgeMaxMs = frameAgeMaxMs; self.rttMaxMs = rttMaxMs
    }
}

/// The Mac's current cursor, so the client can draw the same shape (arrow, I-beam, resize, hand…)
/// under its own pointer. hotspot and size are in Mac points; the PNG is the cursor's best
/// representation (usually 2×). Layout: hotX, hotY, width, height as Float32 big-endian, then PNG.
public enum CursorShapeBlob {
    public static func encode(hotspot: CGPoint, size: CGSize, png: Data) -> Data {
        var d = Data(capacity: 16 + png.count)
        for v in [Float(hotspot.x), Float(hotspot.y), Float(size.width), Float(size.height)] {
            d.appendBigEndian(v.bitPattern)
        }
        d.append(png)
        return d
    }
    public static func decode(_ d: Data) -> (hotspot: CGPoint, size: CGSize, png: Data)? {
        guard d.count > 16 else { return nil }
        func f(_ i: Int) -> CGFloat { CGFloat(Float(bitPattern: d.readBigEndian(UInt32.self, at: i * 4))) }
        return (CGPoint(x: f(0), y: f(1)), CGSize(width: f(2), height: f(3)), d.subdata(in: (d.startIndex + 16)..<d.endIndex))
    }
}
