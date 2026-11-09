import Foundation
import SillHostCore
import StreamProtocol

/// Everything the status item, its card and its menu say, as plain values. Made by
/// `StatusText.present` from the host's snapshot, so the same words appear in the menu, the
/// tooltip, the log's "Status:" lines and the previews.
struct StatusPresentation: Equatable {
    /// A line with a symbol: the stream's source, or one device.
    struct Row: Equatable, Identifiable {
        var id: String
        var symbol: String
        var title: String
        var detail: String?
    }

    /// Something that needs the user, shown in the menu with an orange warning.
    struct Attention: Equatable, Identifiable {
        enum Action: Equatable {
            case allowScreenRecording, allowAccessibility, showRemoteAccess, showDevices
            /// "‹device› Wants to Pair": its window forward while it shows the code (`showing`), else
            /// a window opened on the Mac, asked by that device (its paired-style name).
            case pairingRequest(name: String, showing: Bool)
            case none
        }
        var title: String
        var subtitle: String
        var action: Action
        var id: String { title }
    }

    var glyph: StatusGlyph.State
    var header: String
    var subtitle: String?
    var source: Row?
    var devices: [Row]
    var attention: [Attention]
    /// Under the menu's Virtual Display item.
    var virtualDisplayNote: String
    var tooltip: String
    var accessibilityLabel: String
    /// The name devices see this Mac as, once Bonjour has registered it.
    var advertisedName: String?
    /// Under the menu's Remote Access… item: "Off", "On · Tailscale"… Nil on a host without
    /// remote access (no item then).
    var remoteAccessNote: String?
    /// Pair iPhone or iPad… can open a pairing window (the Mac has an identity).
    var canPair = false
    /// Every connected device is away from home, so the away quality is the target: the menu's
    /// Quality subtitle says so (docs/remote-bundle-plan.md §5.7).
    var away = false
}

/// Whether Sill holds its two permissions, as last read.
struct PermissionState: Equatable {
    var screenRecording: Bool
    var accessibility: Bool
}

/// The status copy. Title case in menus, sentence case in explanations, typographic quotes.
enum StatusText {
    /// How long the menu says an iPhone or iPad needs Sill updated after the home door refused one
    /// of its plain connections (docs/home-pairing-plan.md §6.4).
    static let olderDeviceShownFor: TimeInterval = 600

    /// `now`: the clock the menu's items that last a while are judged by (fixed in the previews).
    static func present(snapshot s: HostStatusSnapshot, permissions: PermissionState,
                        startupError: String?, hasCoordinator: Bool, now: Date = Date()) -> StatusPresentation {
        let (header, subtitle) = headline(s, permissions, startupError, hasCoordinator)

        var attention: [StatusPresentation.Attention] = []
        if !permissions.screenRecording {
            attention.append(.init(title: "允许屏幕录制…", subtitle: "设备查看 Mac 画面需要此权限。",
                                   action: .allowScreenRecording))
        }
        if !permissions.accessibility {
            attention.append(.init(title: "允许辅助功能…", subtitle: "设备可以查看，但不能点击或输入。",
                                   action: .allowAccessibility))
        }
        // Kept to one line no wider than the rest of the menu: a menu item's subtitle does not wrap.
        if s.softwareEncoder, s.hardwareEncoderStuck {
            attention.append(.init(title: "硬件编码器无响应",
                                   subtitle: "当前使用软件编码，最高 60 FPS；可尝试重启 Mac。",
                                   action: .none))
        } else if s.softwareEncoder {
            attention.append(.init(title: "硬件编码器正忙",
                                   subtitle: "释放之前使用软件编码，最高 60 FPS。",
                                   action: .none))
        }
        let remotePortTaken = remotePortInUse(s.remote)
        if let port = remotePortTaken {
            attention.append(.init(title: "远程访问无法启动", subtitle: "端口 \(port) 已被其他应用占用。",
                                   action: .showRemoteAccess))
        }
        // Pairing at home (docs/home-pairing-plan.md §6.4).
        let request = pairingRequest(s.remote, now: now)
        if let request { attention.append(request) }
        if let at = s.remote?.olderDeviceAt, now.timeIntervalSince(at) < olderDeviceShownFor {
            attention.append(.init(title: "iPhone 或 iPad 需要更新应用", subtitle: "设备尝试使用旧版本连接。",
                                   action: .none))
        }
        let homeDoorClosed = homeDoorUnavailable(s.remote)
        if homeDoorClosed {
            attention.append(.init(title: "设备无法连接", subtitle: "应用无法使用钥匙串中的密钥。",
                                   action: .showDevices))
        }

        // The attention glyph means "Sill needs you". The test pattern needs no permission. A device
        // waiting to pair and a closed home door need the user too; an older device is only news.
        let glyph: StatusGlyph.State
        if startupError != nil || isFailed(s.network) || remotePortTaken != nil || request != nil || homeDoorClosed
            || (!s.synthetic && !(permissions.screenRecording && permissions.accessibility)) {
            glyph = .attention
        } else if s.stream != nil {
            glyph = .streaming
        } else if !s.devices.isEmpty {
            glyph = .connected
        } else {
            glyph = .idle
        }

        var name: String?
        if case .advertising(let n) = s.network { name = n }

        return StatusPresentation(glyph: glyph, header: header, subtitle: subtitle,
                                  source: sourceRow(s), devices: s.devices.map(deviceRow), attention: attention,
                                  virtualDisplayNote: virtualDisplayNote(s),
                                  tooltip: "DUO你电脑 — \(header)", accessibilityLabel: "DUO你电脑，\(header)",
                                  advertisedName: name, remoteAccessNote: remoteAccessNote(s.remote),
                                  canPair: s.remote.map { $0.identityProblem == nil } ?? false, away: s.away)
    }

    /// "iPad Wants to Pair", for 5 minutes after a device's ask (the host ends it sooner: when the
    /// window showing its code closes, and when that device pairs): "A code is showing." while that
    /// window is up, "Click to show a code." when the ask limits kept one from opening, the unlock
    /// line when this Mac was locked. Sentences with a full stop, as every attention subtitle is.
    /// Never for an ask from this Mac itself (the host sets none).
    private static func pairingRequest(_ r: RemoteStatus?, now: Date) -> StatusPresentation.Attention? {
        guard let request = r?.pairingRequest, now.timeIntervalSince(request.at) < RemoteStatus.PairingRequest.shownFor else { return nil }
        let short = shortName(request.name)
        let subtitle: String
        switch request.reason {
        case "showing": subtitle = "配对码正在显示。"
        case "locked": subtitle = "请解锁此 Mac，然后在 \(short) 上重新点按。"
        default: subtitle = "点击显示配对码。"
        }
        return .init(title: "\(short) 请求配对", subtitle: subtitle,
                     action: .pairingRequest(name: request.name, showing: request.reason == "showing"))
    }

    /// The home door has no listener: the identity (its key, the trust list) could not be used.
    private static func homeDoorUnavailable(_ r: RemoteStatus?) -> Bool {
        if case .unavailable? = r?.homeDoor { return true }
        return false
    }

    /// The remote door's port while Remote Access is on and another app holds that port.
    private static func remotePortInUse(_ r: RemoteStatus?) -> Int? {
        guard let r, r.remoteAccess, r.identityProblem == nil, case .portInUse(let port) = r.listener else { return nil }
        return port
    }

    /// The Remote Access… item's subtitle: "Off", "On · Tailscale", "On · Tailscale and the
    /// internet", "On · no VPN on this Mac", "Port 7455 is in use" or "Unavailable: the keychain
    /// couldn’t be used".
    static func remoteAccessNote(_ r: RemoteStatus?) -> String? {
        guard let r else { return nil }
        if r.identityProblem != nil { return "不可用：无法使用钥匙串" }
        guard r.remoteAccess else { return "已关闭" }
        switch r.listener {
        case .portInUse(let port): return "端口 \(port) 已被占用"
        case .failed: return "无法启动，正在重试"
        case .off, .listening: break
        }
        var ways: [String] = []
        for a in r.addresses where a.kind == MacAddress.vpn && !ways.contains(a.via) { ways.append(a.via) }
        if r.internetAccess { ways.append("公网") }
        guard !ways.isEmpty else { return "已开启 · 此 Mac 未连接 VPN" }
        return "已开启 · " + ways.joined(separator: "、")
    }

    /// The header and its explanation; the first match wins.
    private static func headline(_ s: HostStatusSnapshot, _ permissions: PermissionState, _ startupError: String?,
                                 _ hasCoordinator: Bool) -> (String, String?) {
        if let startupError { return ("DUO你电脑 无法启动", startupError) }
        if !hasCoordinator { return ("正在启动…", nil) }
        // No listener at all (fail closed): no device can find or reach this Mac.
        if homeDoorUnavailable(s.remote) {
            return ("网络中不可见",
                    "应用无法使用钥匙串中的密钥。请重新打开应用；若钥匙串询问，请选择始终允许。")
        }
        switch s.network {
        case .starting:
            return ("正在启动…", nil)
        case .failed(let error):
            return ("网络中不可见", "\(error)。请重新打开应用后重试。")
        case .waiting:
            return ("等待网络连接",
                    "Mac 接入 Wi-Fi 或以太网并允许本地网络访问后，设备即可发现它。")
        case .notAdvertised(let port):
            return ("测试图模式", "不广播；测试客户端连接端口 \(port)。")
        case .registering, .advertising:
            break
        }
        if !permissions.screenRecording {
            return ("屏幕录制未开启", "设备可以连接，但无法查看窗口。")
        }
        let count = s.devices.count
        if count > 0 {
            let who = count == 1 ? (s.devices[0].name.map(shortName) ?? "设备") : "\(count) 台设备"
            if s.stream != nil { return ("正在串流到 \(who)", nil) }
            let connected = count == 1 ? (s.devices[0].name.map(shortName) ?? "设备") : "\(count) 台设备"
            return ("\(connected) 已连接", "在设备上选择窗口以开始串流。")
        }
        if case .advertising(let name) = s.network {
            return ("等待设备连接", "在 iPhone 或 iPad 的 DUO你电脑 中选择“\(name)”。")
        }
        return ("等待设备连接", "正在本地网络注册…")
    }

    private static func isFailed(_ n: HostStatusSnapshot.Network) -> Bool {
        if case .failed = n { return true }
        return false
    }

    /// "iPad" from "iPad (iPad14,1)".
    static func shortName(_ device: String) -> String {
        let name = device.components(separatedBy: " (").first ?? device
        return name.isEmpty ? device : name
    }

    /// What streams: "Safari — Apple Developer" over "3024×1898 · 118 of 120 fps · 30 Mbps" (a still
    /// picture: "120 fps, still"), and with one device, how it is connected: "… · 30 Mbps · Wi-Fi".
    /// With two or more, each device's own row says it.
    private static func sourceRow(_ s: HostStatusSnapshot) -> StatusPresentation.Row? {
        guard let stream = s.stream else { return nil }
        let title: String, symbol: String
        switch stream.kind {
        case .window: title = middleTruncated(stream.title, to: 44); symbol = "macwindow"
        case .desktop: title = "完整桌面"; symbol = "menubar.dock.rectangle"
        case .testPattern: title = "测试图"; symbol = "checkerboard.rectangle"
        }
        // The encoder only produces a frame when the picture changed (ScreenCaptureKit delivers
        // frames on repaint), so 0 means a still window, not a stalled stream. "120 fps, still" is
        // about as wide as a one-digit count ("5 of 120 fps"), so a row wraps the same still as
        // changing, unless the count's own digits tip it: the open menu resizes the card on every
        // change, and "nothing changing" with the route word made it jump a line each time a
        // window stopped or started changing.
        let rate = s.encodedFPS > 0 ? "\(min(s.encodedFPS, stream.fps))/\(stream.fps) FPS" : "\(stream.fps) FPS，画面静止"
        var detail = "\(stream.width)×\(stream.height) · \(rate) · \(stream.mbps) Mbps"
        if s.devices.count == 1, let route = routeWord(s.devices[0]) { detail += " · \(route)" }
        if stream.onVirtualDisplay {
            detail += " · 虚拟显示器"
        } else if s.virtualDisplayOn, stream.kind == .window {
            detail += " · 原窗口（虚拟显示器：\(s.lastStageFailure ?? s.virtualDisplayProblem ?? "不可用")）"
        }
        if stream.softwareEncoder { detail += " · 软件编码" }
        return StatusPresentation.Row(id: "source", symbol: symbol, title: title, detail: detail)
    }

    /// "iPad (iPad14,1)" over "118 fps · frame age 9 ms · RTT 7 ms · Wi-Fi" (from away: "… · through
    /// Tailscale"); the address until the device's first report (within a second; a remote device
    /// shows its paired name), and until then the route alone. A second without a sample reads
    /// "–", as in the host's log line and the device's HUD: a still window sends no frames
    /// (ScreenCaptureKit delivers only repaints), and a second can pass without a pong. While its
    /// link does not keep up (docs/remote-bundle-plan.md §6.6) the numbers give way to it, the frame
    /// age dropping out to keep the row short: "3 fps, the link can’t carry Pro · RTT 531 ms ·
    /// through Tailscale", or "Nothing is getting through · through Tailscale".
    private static func deviceRow(_ d: HostStatusSnapshot.Device) -> StatusPresentation.Row {
        let name = d.name ?? d.endpoint
        let symbol = name.localizedCaseInsensitiveContains("iphone") ? "iphone" : "ipad"
        var parts: [String] = []
        if let link = d.link {
            parts.append(linkWords(link, fps: d.fps, rttMs: d.rttMs))
        } else if let fps = d.fps, let age = d.frameAgeMs, let rtt = d.rttMs {
            parts.append("\(fps) FPS · 帧延迟 \(ms(age)) · 往返 \(ms(rtt))")
        }
        if let route = routeWord(d) { parts.append(route) }
        return StatusPresentation.Row(id: String(describing: d.id), symbol: symbol, title: name,
                                      detail: parts.isEmpty ? nil : parts.joined(separator: " · "))
    }

    /// A device's link that does not keep up, as its row says it: behind, "3 fps, the link can’t carry
    /// Pro · RTT 531 ms" (the fps and the round trip when its stats have come); stalled, "Nothing is
    /// getting through".
    static func linkWords(_ link: HostStatusSnapshot.LinkStatus, fps: Int?, rttMs: Int?) -> String {
        switch link.state {
        case .stalled:
            return "连接暂时没有数据通过"
        case .behind:
            let quality = QualityPreset.name(forBitrate: link.bitrate).replacingOccurrences(of: " ", with: "\u{00A0}")
            var words = (fps.map { "\($0) FPS，" } ?? "") + "连接无法承载 \(quality) 画质"
            if let rtt = rttMs { words += " · 往返 \(ms(rtt))" }
            return words
        }
    }

    /// How a device reaches this Mac, the one place the card decides it (the device's row, and the
    /// source row while it is the only device). A remote session says how it came ("through
    /// Tailscale", "over the internet"; RemoteServer's label), which always wins: its link from
    /// this Mac's side would read "Wi-Fi" for a session over the internet. A home device gets its
    /// link from this Mac's side of its connection (ClientLink.route), in the words the device's
    /// connect screen and Settings panel use; nil when neither says (loopback, an interface of no
    /// known kind). Either is kept whole when a detail wraps: a remote label's spaces are no-break
    /// ones (the source row wrapped "through" and "Tailscale" onto two lines), as Wi-Fi's hyphen is.
    private static func routeWord(_ d: HostStatusSnapshot.Device) -> String? {
        if let remote = d.remoteRoute { return remote.replacingOccurrences(of: " ", with: "\u{00A0}") }
        return d.route.map(word)
    }

    /// A home device's link as the card words it. "Wi-Fi" has a non-breaking hyphen, so a wrapped
    /// detail never splits it.
    private static func word(_ route: ClientLink.Route) -> String {
        switch route {
        case .wired: return "有线"
        case .wifi: return "局域网"
        case .direct: return "就近连接"
        }
    }

    /// One of a device's reported times. Negative is the client's "no sample this second" (-1),
    /// never a time.
    private static func ms(_ v: Int) -> String { v < 0 ? "–" : "\(v) ms" }

    private static func virtualDisplayNote(_ s: HostStatusSnapshot) -> String {
        if let problem = s.virtualDisplayProblem { return "不可用：\(problem)" }
        if s.virtualDisplayOn, s.stream?.onVirtualDisplay == true { return "串流窗口位于虚拟显示器" }
        return "串流期间所选窗口会离开此屏幕"
    }

    /// "Safari — A very long window title that goes on" → "Safari — A very long…that goes on".
    static func middleTruncated(_ text: String, to limit: Int) -> String {
        guard text.count > limit, limit > 1 else { return text }
        let keep = limit - 1
        return String(text.prefix((keep + 1) / 2)) + "…" + String(text.suffix(keep / 2))
    }
}
