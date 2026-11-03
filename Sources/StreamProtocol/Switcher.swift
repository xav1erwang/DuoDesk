import Foundation

/// What the host streams. The client decides; the host only ever streams one source.
public enum StreamSource: Codable, Hashable {
    case none
    case window(UInt32)   // CGWindowID, stable for the life of the window
    case desktop          // the one physical display selected for this stream
}

/// One on-screen Mac window, as the client sees it. WindowList order is stable: first seen first.
public struct WindowInfo: Codable, Hashable, Identifiable {
    public var id: UInt32
    public var title: String
    public var appName: String
    public var bundleID: String
    public var width: Int      // points
    public var height: Int

    public init(id: UInt32, title: String, appName: String, bundleID: String, width: Int, height: Int) {
        self.id = id; self.title = title; self.appName = appName; self.bundleID = bundleID
        self.width = width; self.height = height
    }
}

/// An installed app, for the drawer's "All apps" section.
public struct AppInfo: Codable, Hashable, Identifiable {
    public var id: String { bundleID }
    public var name: String
    public var bundleID: String

    public init(name: String, bundleID: String) { self.name = name; self.bundleID = bundleID }
}

public struct WindowList: Codable {
    public var macName: String
    public var windows: [WindowInfo]
    public var active: StreamSource
    /// Random, picked once per launch of the host and the same in every list to every device: two
    /// connections whose lists carry the same one reach the same running host. A name cannot tell
    /// that (two Macs can share one, and mDNS renames neither when they share no link), and a
    /// device moving its session from AWDL to the network must not land on another Mac. Optional:
    /// nil from a host older than 2026-09-24, and an older device ignores the key.
    public var launchID: String?
    /// The host's version: Sill.app's CFBundleShortVersionString ("0.4.0"); nil from SillHost (no
    /// bundle) and from hosts before 2026-09-25. For later devices: which Mac to update, and to what
    /// (docs/update-notice-plan.md §14).
    public var hostVersion: String?
    /// The host's SillProtocol.current; nil from hosts before 2026-09-25, which speak 1. The JSON key
    /// is "protocol".
    public var `protocol`: Int?
    /// Which trackpad gestures this host takes (kind 28, Gesture.swift): 1 is the six of
    /// `TrackpadGesture.names`, each turned into the Mac's own shortcut. Nil from every host before
    /// 2026-09-27, to which a device sends no kind 28. A later generation of gestures says 2 and
    /// goes only to a host that says so.
    public var gestures: Int?
    /// What this host takes and sends of the clipboard (kind 32, Clipboard.swift): 1 is text
    /// (`ClipboardPolicy.generation`). Nil from every host before 2026-10-14, and from one whose Share
    /// clipboard with devices is off: a device sends no kind 32 to either. A later generation
    /// (images) says 2, and a device sends images only to a host that says so. An Int, as `gestures`:
    /// pull request #66's `Bool` (never released) does not decode here and becomes an Int as it
    /// rebases.
    public var clipboard: Int?
    /// Test-only attestation: this host logs input without posting any system event. Omitted
    /// by ordinary hosts; diagnostics must require exactly true before sending dry-run input.
    public var inputDryRun: Bool?

    /// True only when this host can honor an extended-desktop request without mirroring a
    /// physical display. Missing on older hosts; clients must treat nil as unsupported.
    public var extendedDesktop: Bool?
    /// The host validates a mirror request at the client's full render-canvas size rather than
    /// silently substituting a smaller desktop. Missing on older hosts.
    public var renderedNativeDesktop: Bool?
    /// Native mirrors can change between the Duo upper panel and full panel during one session.
    /// Older hosts omit this, so clients keep their established mirror size on those hosts.
    public var resizableMirror: Bool?
    /// A native-mirror failure that leaves the sole capable client connected so it can select an
    /// extension. Missing in ordinary catalogs and on older hosts.
    public var desktopIssue: DuoDesktopIssue?
    /// nil on hosts without display selection. IDs never share the window-thumbnail namespace.
    public var displays: [RemoteDisplayInfo]?
    public var selectedDisplayID: UInt32?
    /// Capture the selected physical display at its existing pixel size. The phone fits that
    /// picture into its viewport; selecting a display never changes the Mac's primary or layout.
    public var existingDisplayCapture: Bool?

    public init(macName: String, windows: [WindowInfo], active: StreamSource, launchID: String? = nil,
                hostVersion: String? = nil, protocol: Int? = nil, gestures: Int? = nil, clipboard: Int? = nil,
                inputDryRun: Bool? = nil, extendedDesktop: Bool? = nil, desktopIssue: DuoDesktopIssue? = nil,
                renderedNativeDesktop: Bool? = nil, resizableMirror: Bool? = nil,
                displays: [RemoteDisplayInfo]? = nil, selectedDisplayID: UInt32? = nil,
                existingDisplayCapture: Bool? = nil) {
        self.macName = macName; self.windows = windows; self.active = active; self.launchID = launchID
        self.hostVersion = hostVersion; self.protocol = `protocol`; self.gestures = gestures
        self.clipboard = clipboard
        self.inputDryRun = inputDryRun
        self.extendedDesktop = extendedDesktop
        self.desktopIssue = desktopIssue
        self.renderedNativeDesktop = renderedNativeDesktop
        self.resizableMirror = resizableMirror
        self.displays = displays
        self.selectedDisplayID = selectedDisplayID
        self.existingDisplayCapture = existingDisplayCapture
    }
}

public struct LaunchApp: Codable {
    public var bundleID: String
    public init(bundleID: String) { self.bundleID = bundleID }
}

/// Client → host: what the bar's long-press menu asks of a window, the three traffic lights.
public struct WindowCommand: Codable {
    public enum Action: String, Codable { case close, minimize, fullScreen }
    public var id: UInt32
    public var action: Action
    public init(id: UInt32, action: Action) { self.id = id; self.action = action }
}

/// A recoverable native-mirror failure. The connection is still live; this is never a video frame
/// or an assertion that a lower-resolution desktop is acceptable.
public struct DuoDesktopIssue: Codable, Hashable, Sendable {
    public var resolution: DuoDesktopResolution
    public var message: String
    /// The current full physical display, when it has at least the requested pixels. Its aspect
    /// can differ from the Duo panel; selecting it preserves the Mac mode and can leave borders.
    public var physicalFallback: DuoDesktopResolution?
    public init(resolution: DuoDesktopResolution, message: String, physicalFallback: DuoDesktopResolution? = nil) {
        self.resolution = resolution
        self.message = message
        self.physicalFallback = physicalFallback
    }
}

/// JSON payloads. Everything here is small and infrequent; frames never go through JSON.
public enum Wire {
    public static func encode<T: Encodable>(_ value: T) -> Data {
        (try? JSONEncoder().encode(value)) ?? Data()
    }
    public static func decode<T: Decodable>(_ type: T.Type, from data: Data) -> T? {
        try? JSONDecoder().decode(type, from: data)
    }
}

/// Binary image payloads: a key, then the image bytes.
public enum ImageBlob {
    /// windowID(4, BE) + JPEG
    public static func encodeThumbnail(windowID: UInt32, jpeg: Data) -> Data {
        var d = Data(capacity: 4 + jpeg.count)
        d.appendBigEndian(windowID)
        d.append(jpeg)
        return d
    }
    public static func decodeThumbnail(_ d: Data) -> (windowID: UInt32, jpeg: Data)? {
        guard d.count > 4 else { return nil }
        return (d.readBigEndian(UInt32.self, at: 0), d.subdata(in: (d.startIndex + 4)..<d.endIndex))
    }

    /// bundleIDLength(2, BE) + bundleID UTF-8 + PNG
    public static func encodeIcon(bundleID: String, png: Data) -> Data {
        let id = Data(bundleID.utf8)
        var d = Data(capacity: 2 + id.count + png.count)
        d.appendBigEndian(UInt16(id.count))
        d.append(id)
        d.append(png)
        return d
    }
    public static func decodeIcon(_ d: Data) -> (bundleID: String, png: Data)? {
        guard d.count > 2 else { return nil }
        let len = Int(d.readBigEndian(UInt16.self, at: 0))
        guard d.count > 2 + len else { return nil }
        let idStart = d.startIndex + 2
        guard let id = String(data: d.subdata(in: idStart..<(idStart + len)), encoding: .utf8) else { return nil }
        return (id, d.subdata(in: (idStart + len)..<d.endIndex))
    }
}
