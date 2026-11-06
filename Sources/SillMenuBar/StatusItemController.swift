// Modified for DUO你电脑, 2026. See NOTICE for upstream attribution.
import AppKit
import SwiftUI
import SillHostCore
import StreamProtocol

/// One line of the status menu, as data. `MenuBuilder` makes the list, the status item turns it
/// into NSMenuItems, and the previews hook prints it to menu.txt, so the three cannot disagree.
struct MenuEntry: Equatable {
    enum Kind: Equatable { case card, item, separator }
    enum Action: Equatable {
        case none
        case allowScreenRecording, allowAccessibility, openPrivacy
        /// These two are absolute, like the radio items: each sets what the item offered when the
        /// menu was built (on when it showed unchecked). A device can change the setting while the
        /// menu is open, which does not rebuild it, and a toggle would then do the opposite of what
        /// the item shows.
        case setVirtualDisplay(Bool)
        case setDirectWireless(Bool)
        case setMaxFPS(Int), setBitrate(Int), setCaptureScale(CGFloat)
        case toggleLaunchAtLogin
        case showLog, showSettings, quit
        /// Settings on one tab (Remote Access…); the plain `showSettings` stays for ⌘,. (Swift
        /// allows no second case named `showSettings`.)
        case showSettingsTab(SettingsTab)
        /// Pair iPhone or iPad…: a pairing window, or the open one brought forward.
        case showPairing
        /// "‹device› Wants to Pair": the window that shows its code brought forward, else one
        /// opened on the Mac, asked by that device.
        case showPairingRequest(name: String, showing: Bool)
        /// DUO你电脑 0.4 Is Available…: the release's page on GitHub, in the browser (UpdateChecker).
        case openUpdate(URL)
    }

    var kind: Kind
    var title = ""
    var subtitle: String?
    var checked = false
    var enabled = true
    /// An orange warning in front: something needs the user.
    var attention = false
    /// ⌘ plus this key.
    var key = ""
    /// An SF Symbol ahead of the title.
    var symbol: String?
    var action: Action = .none
    var children: [MenuEntry] = []

    static let separator = MenuEntry(kind: .separator)
}

/// Launch at login as the menu shows it.
struct LoginState: Equatable {
    var available: Bool
    var on: Bool
    var needsApproval: Bool
    var error: String?
}

/// The status menu, top to bottom. Titles are title case, subtitles sentence case. The controls
/// mirror the Settings window and only ever set the app's settings.
enum MenuBuilder {
    /// `update`: a newer release the update check found, and this DUO你电脑's version: one item right
    /// after the card and anything needing attention. The glyph never changes for it: the attention
    /// glyph means DUO你电脑 needs the person before it can work, and an update needs nothing.
    static func entries(presentation p: StatusPresentation, config: HostConfig, login: LoginState,
                        permissions: PermissionState,
                        update: (offer: UpdatePolicy.Offer, running: SillVersion)? = nil) -> [MenuEntry] {
        var menu: [MenuEntry] = [MenuEntry(kind: .card, title: p.header)]
        for a in p.attention {
            let action: MenuEntry.Action = switch a.action {
            case .allowScreenRecording: .allowScreenRecording
            case .allowAccessibility: .allowAccessibility
            case .showRemoteAccess: .showSettingsTab(.remoteAccess)
            case .showDevices: .showSettingsTab(.devices)
            case .pairingRequest(let name, let showing): .showPairingRequest(name: name, showing: showing)
            case .none: .none
            }
            menu.append(MenuEntry(kind: .item, title: a.title, subtitle: a.subtitle, enabled: action != .none,
                                  attention: true, action: action))
        }
        if let update {
            menu.append(MenuEntry(kind: .item, title: UpdatePolicy.menuTitle(update.offer),
                                  subtitle: UpdatePolicy.menuSubtitle(running: update.running), action: .openUpdate(update.offer.url)))
        }
        menu.append(.separator)

        menu.append(MenuEntry(kind: .item, title: "配对 iPhone 或 iPad…", enabled: p.canPair,
                              symbol: "qrcode", action: .showPairing))
        menu.append(.separator)
        menu.append(MenuEntry(kind: .item, title: "设置…", key: ",", symbol: "gearshape", action: .showSettings))
        menu.append(MenuEntry(kind: .item, title: "显示日志…", symbol: "doc.text", action: .showLog))
        menu.append(.separator)
        menu.append(MenuEntry(kind: .item, title: "退出 DUO你电脑", key: "q", symbol: "power", action: .quit))
        return menu
    }

    /// The live menu for `model` as it would open now (the status item's rebuild, and
    /// -SillPrintMenuAfter): its presentation, settings, login item, permissions and any update the
    /// check found.
    @MainActor
    static func entries(for model: AppModel) -> [MenuEntry] {
        let login = LoginState(available: model.loginItem.available, on: model.loginItem.isOn,
                               needsApproval: model.loginItem.needsApproval, error: model.loginItem.error)
        let permissions = PermissionState(screenRecording: model.permissions.screenRecording,
                                          accessibility: model.permissions.accessibility)
        let update = model.updates.offer.flatMap { offer in model.updates.runningVersion.map { (offer: offer, running: $0) } }
        return entries(presentation: model.presentation, config: model.settings.config, login: login, permissions: permissions,
                       update: update)
    }

    /// The menu as text, for the previews: "✓" checked, "⚠" attention, "(off)" disabled.
    static func dump(_ entries: [MenuEntry], card: StatusPresentation? = nil, indent: String = "") -> String {
        var out = ""
        for e in entries {
            switch e.kind {
            case .separator:
                out += indent + "────────\n"
            case .card:
                guard let p = card else { out += indent + "[card]\n"; continue }
                out += indent + "[card] \(p.header)\n"
                if let s = p.subtitle { out += indent + "       \(s)\n" }
                for row in [p.source].compactMap({ $0 }) + p.devices {
                    out += indent + "       · \(row.title)\(row.detail.map { " — \($0)" } ?? "")\n"
                }
            case .item:
                let mark = e.attention ? "⚠ " : (e.checked ? "✓ " : "  ")
                var line = indent + mark + e.title
                if !e.key.isEmpty { line += "  ⌘" + e.key.uppercased() }
                if !e.enabled { line += "  (off)" }
                if let s = e.subtitle { line += "  — \(s)" }
                out += line + (e.children.isEmpty ? "\n" : " ▸\n")
                if !e.children.isEmpty { out += dump(e.children, indent: indent + "    ") }
            }
        }
        return out
    }
}

/// The menu bar item and its menu. The menu is rebuilt each time it opens (permissions and the
/// login item re-read first), and the status card inside it follows the host live while it is
/// open. Every control only sets `model.settings.config`, the one path to the coordinator.
///
/// Its actions are AppKit target/action, the one safe place to start what may run a modal loop
/// (NSApp.terminate): see AppDelegate.
@MainActor
final class StatusItemController: NSObject {
    private let item: NSStatusItem
    private let panel = NSPopover()
    private let model: AppModel
    private var glyph: StatusGlyph.State?

    init(model: AppModel) {
        self.model = model
        item = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        super.init()
        item.autosaveName = "SillStatusItem"
        panel.behavior = .transient
        panel.animates = true
        if let button = item.button {
            button.target = self
            button.action = #selector(togglePanel)
        }
        show(model.presentation)
    }

    /// The glyph, tooltip and accessibility label for a new presentation.
    func show(_ p: StatusPresentation) {
        guard let button = item.button else { return }
        if glyph != p.glyph {
            glyph = p.glyph
            button.image = StatusGlyph.image(p.glyph)
        }
        button.toolTip = p.tooltip
        button.setAccessibilityLabel(p.accessibilityLabel)
    }

    // MARK: The panel

    @objc private func togglePanel() {
        if panel.isShown {
            panel.performClose(nil)
            return
        }
        model.permissions.refresh()
        model.loginItem.refresh()
        showPanel()
    }

    private func showPanel() {
        guard let button = item.button else { return }
        let root = StatusPanel(presentation: model.presentation,
                               entries: MenuBuilder.entries(for: model),
                               action: { [weak self] action in self?.perform(action) },
                               dismiss: { [weak self] in self?.panel.performClose(nil) })
        let host = NSHostingController(rootView: root)
        host.sizingOptions = [.preferredContentSize]
        panel.contentViewController = host
        panel.contentSize = host.view.fittingSize
        panel.show(relativeTo: button.bounds, of: button, preferredEdge: .minY)
        NSApp.activate()
    }

    private func perform(_ action: MenuEntry.Action) {
        switch action {
        case .none: break
        case .allowScreenRecording: model.permissions.requestScreenRecording()
        case .allowAccessibility: model.permissions.requestAccessibility()
        case .openPrivacy: model.permissions.openPrivacyPane()
        case .setVirtualDisplay(let on): model.settings.config.virtualDisplay = on
        case .setDirectWireless(let on): model.settings.config.directWireless = on
        case .setMaxFPS(let fps): model.settings.config.maxFPS = fps
        case .setBitrate(let bitrate): model.settings.config.bitrate = bitrate
        case .setCaptureScale(let scale): model.settings.config.captureScale = scale
        case .toggleLaunchAtLogin: model.loginItem.set(!model.loginItem.isOn)
        case .showLog: model.showLog?()
        case .showSettings: model.showSettings?(nil)
        case .showSettingsTab(let tab): model.showSettings?(tab)
        case .showPairing: model.pairDevice()
        case .showPairingRequest(let name, let showing): model.showPairingRequest(name: name, showing: showing)
        case .openUpdate(let url): NSWorkspace.shared.open(url)   // the browser; no modal loop
        case .quit: NSApp.terminate(nil)
        }
    }
}
