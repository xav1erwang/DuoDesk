// Modified for DUO你电脑, 2026. See NOTICE for upstream attribution.
import AppKit
import Combine
import SwiftUI
import SillHostCore
import StreamProtocol

/// One Settings tab: a grouped Form, 520 pt wide. The controls bind straight to
/// `settings.config`, whose didSet is the one path to the host (see HostSettings).
struct SettingsPane: View {
    let tab: SettingsTab
    let model: AppModel
    /// The previews (DebugHooks): General's update section in this state instead of the live one,
    /// so a render does not depend on what an earlier run stored.
    var previewUpdates: UpdatePolicy.Pane?
    /// …and its clipboard section with macOS's answer as given, never read from this Mac.
    var previewClipboardAccess: ClipboardPolicy.MacAccess?

    var body: some View {
        Group {
            switch tab {
            case .general: GeneralPane(model: model, settings: model.settings, previewUpdates: previewUpdates,
                                       previewClipboardAccess: previewClipboardAccess)
            case .devices: LiveDevicesPane(model: model, settings: model.settings)
            case .streaming: StreamingPane(model: model, settings: model.settings)
            case .virtualDisplay: VirtualDisplayPane(model: model, settings: model.settings)
            case .permissions: PermissionsPane(model: model)
            case .remoteAccess: LiveRemoteAccessPane(model: model, settings: model.settings)
            }
        }
        .formStyle(.grouped)
        .frame(width: 520)
        // Permissions and the login item change behind DUO你电脑's back, in System Settings. Re-read
        // them once a second, only while this tab is on screen, and when DUO你电脑 becomes active; an
        // idle DUO你电脑 with Settings closed wakes for nothing. The Devices and Remote Access panes
        // follow the host's status, which is pushed, so they poll nothing.
        .task(id: model.visibleSettingsTab == tab) {
            guard model.visibleSettingsTab == tab, tab != .streaming, tab != .devices, tab != .remoteAccess else { return }
            while !Task.isCancelled {
                model.permissions.refresh()
                model.loginItem.refresh()
                try? await Task.sleep(for: .seconds(1))
            }
        }
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in
            model.permissions.refresh()
            model.loginItem.refresh()
        }
    }
}

/// Footer text the way System Settings sets it: small, secondary, from the leading edge.
struct Footnote: View {
    let text: String
    init(_ text: String) { self.text = text }
    var body: some View {
        Text(text)
            .font(.footnote)
            .foregroundStyle(.secondary)
            .multilineTextAlignment(.leading)
            .frame(maxWidth: .infinity, alignment: .leading)
    }
}

/// An orange problem line with its sign.
struct Warning: View {
    let text: String
    init(_ text: String) { self.text = text }
    var body: some View {
        Label(text, systemImage: "exclamationmark.triangle.fill")
            .foregroundStyle(.orange)
            .fixedSize(horizontal: false, vertical: true)
    }
}

/// A system error message inside a sentence of ours: without its own full stop.
func withoutFullStop(_ text: String) -> String {
    text.hasSuffix(".") ? String(text.dropLast()) : text
}

// MARK: General

private struct GeneralPane: View {
    let model: AppModel
    @Bindable var settings: HostSettings
    var previewUpdates: UpdatePolicy.Pane?
    var previewClipboardAccess: ClipboardPolicy.MacAccess?

    private static let runsFromApplications = Bundle.main.bundlePath.hasPrefix("/Applications/")

    var body: some View {
        Form {
            Section {
                Toggle("登录时启动", isOn: Binding(get: { model.loginItem.isOn }, set: { model.loginItem.set($0) }))
                    .disabled(!model.loginItem.available)
                if !model.loginItem.available {
                    Footnote("从应用程序包运行 DUO你电脑 时可用。")
                } else if model.loginItem.needsApproval {
                    LabeledContent("等待系统设置确认") {
                        Button("打开系统设置…") { model.loginItem.openSystemSettings() }
                    }
                }
                if let error = model.loginItem.error {
                    Text(error).font(.callout).foregroundStyle(.red)
                }
            }
            Section {
                LabeledContent("运行位置") {
                    Text(Bundle.main.bundlePath)
                        .lineLimit(1)
                        .truncationMode(.middle)
                        .textSelection(.enabled)
                }
                if !Self.runsFromApplications {
                    Label("登录项和权限与此应用副本绑定。请在“应用程序”中保留一个副本。",
                          systemImage: "exclamationmark.triangle.fill")
                        .foregroundStyle(.orange)
                }
            }
            Section {
                LabeledContent("网络中显示为") { Text(networkName) }
            } footer: {
                HStack(spacing: 4) {
                    Text("这是此 Mac 的名称。")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                    Button("在共享设置中更改…") {
                        if let url = URL(string: "x-apple.systempreferences:com.apple.Sharing-Settings.extension") {
                            NSWorkspace.shared.open(url)
                        }
                    }
                    .buttonStyle(.link)
                    .font(.footnote)
                    Spacer(minLength: 0)
                }
            }
            // How devices reach this Mac, so beside its name on the network. Applies at once without
            // restarting the stream (the listener is replaced); enabled in test pattern mode too,
            // where it is saved and changes only the listener.
            Section {
                Toggle("无线直连", isOn: $settings.config.directWireless)
            } footer: {
                Footnote("附近的 iPhone 和 iPad 无需接入同一 Wi-Fi 即可连接，方式类似隔空投送。开启后 Wi-Fi 串流可能卡顿。附近的 DUO你电脑 可以发现此 Mac；开启配对要求时只有已配对设备可以连接。")
            }
            // The clipboard both ways (HostClipboard): at once, no restart. Each device has its own
            // switch too. macOS's answer is read with the permissions (once a second while this pane
            // shows, and when DUO你电脑 becomes active), never in a preview.
            ClipboardSection(shareClipboard: $settings.config.shareClipboard,
                             access: previewClipboardAccess ?? model.permissions.clipboardAccess,
                             allow: { model.permissions.allowClipboard() })
            if let preview = previewUpdates {
                UpdatesSection(pane: preview, automatic: .constant(true))
            } else if Bundle.main.bundleIdentifier != "com.duodesk.host" {
                UpdatesSection(pane: model.updates.pane, automatic: $settings.updateCheck,
                               actions: UpdatesSection.Actions(checkNow: { model.updates.checkNow() },
                                                               openRelease: { NSWorkspace.shared.open($0) }))
            }
            Section {
                HStack {
                    Button("显示日志…") { model.showLog?() }
                    Button("在访达中显示日志文件") {
                        if let url = HostLog.shared.fileURL { NSWorkspace.shared.activateFileViewerSelecting([url]) }
                    }
                    .disabled(HostLog.shared.fileURL == nil)
                }
            }
            Section {
                // A way out when the status item is hidden (a crowded menu bar, the notch).
                Button("退出 DUO你电脑") { NSApp.terminate(nil) }
            } footer: {
                Footnote("DUO你电脑 \(AppModel.version)（\(AppModel.build)），基于 Apache-2.0 许可的 Sill 开发。")
            }
        }
    }

    private var networkName: String {
        let snapshot = model.coordinator?.status.snapshot ?? HostStatusSnapshot()
        switch snapshot.network {
        case .advertising(let name): return "“\(name)”"
        case .notAdvertised: return "未广播（测试图模式）"
        case .failed: return "不可见（监听失败）"
        case .waiting: return "等待网络"
        case .starting, .registering: return "正在注册…"
        }
    }
}

// MARK: Clipboard

/// Share clipboard with devices (HostClipboard, docs/clipboard-plan.md): the switch and its footnote,
/// and while the switch is on and macOS does not allow every read DUO你电脑 makes on its own
/// (ClipboardPolicy.MacAccess), why what is copied here stays on this Mac and the way to allow it.
/// Drawn alone in the previews in each of macOS's answers (DebugHooks).
struct ClipboardSection: View {
    @Binding var shareClipboard: Bool
    let access: ClipboardPolicy.MacAccess
    var allow: () -> Void = {}

    var body: some View {
        Section {
            Toggle("与设备共享剪贴板", isOn: $shareClipboard)
            if shareClipboard, access != .allowed {
                VStack(alignment: .leading, spacing: 6) {
                    Warning(access == .denied
                            ? "macOS 不允许应用读取剪贴板，此 Mac 复制的内容不会发往设备。"
                            : "macOS 会在读取剪贴板前询问，此 Mac 复制的内容暂时不会发往设备。")
                    Text(access == .notAsked
                         ? "在系统设置中允许“从其他 App 粘贴”；设备发来的文本仍可接收。"
                         : "请在“隐私与安全性”中将“从其他 App 粘贴”设为允许；设备发来的文本仍可接收。")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                    Button("在系统设置中允许…", action: allow)
                }
            }
        } footer: {
            Footnote("在此 Mac 上复制的文字可粘贴到已连接的 iPhone 或 iPad；设备发来的文字会写入 Mac 剪贴板。密码管理器标记为隐藏的内容会留在此 Mac。")
        }
    }
}

// MARK: Updates

/// Settings › General's update check: the automatic switch, the line (what the last check found, or
/// why DUO你电脑 cannot check), Open Release Page… while a newer release is offered, and Check Now. Plain
/// values in, so the previews draw every state. Errors show here and in the log, never in an alert.
struct UpdatesSection: View {
    struct Actions {
        var checkNow: () -> Void = {}
        var openRelease: (URL) -> Void = { _ in }
    }

    let pane: UpdatePolicy.Pane
    @Binding var automatic: Bool
    var actions = Actions()

    var body: some View {
        Section {
            Toggle("自动检查更新", isOn: $automatic)
            LabeledContent {
                HStack(spacing: 8) {
                    if let url = pane.releasePage {
                        Button("打开发行页面…") { actions.openRelease(url) }
                    }
                    Button("立即检查") { actions.checkNow() }
                        .disabled(!pane.canCheck)
                }
            } label: {
                Text(pane.line)
                    .foregroundStyle(pane.failed ? Color.orange : Color.primary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            // VoiceOver hears Check Now's result, which arrives after the click.
            .onChange(of: pane.resultID) { _, _ in
                AccessibilityNotification.Announcement(pane.line).post()
            }
        } footer: {
            Footnote(UpdatePolicy.footnote)
        }
    }
}

// MARK: Streaming

private struct StreamingPane: View {
    let model: AppModel
    @Bindable var settings: HostSettings

    var body: some View {
        Form {
            Section {
                Picker("帧率上限", selection: $settings.config.maxFPS) {
                    Text("60 FPS").tag(60)
                    Text("120 FPS").tag(120)
                }
                .pickerStyle(.segmented)
                Picker("画质", selection: $settings.config.bitrate) {
                    ForEach(QualityPreset.allCases) { Text(DuoQualityLabels.title(forBitrate: $0.rawValue)).tag($0.rawValue) }
                    if QualityPreset(rawValue: settings.config.bitrate) == nil {
                        Text(DuoQualityLabels.title(forBitrate: settings.config.bitrate)).tag(settings.config.bitrate)
                    }
                }
                Picker("常规画面分辨率", selection: $settings.config.captureScale) {
                    Text("Retina").tag(CGFloat(2))
                    Text("标准").tag(CGFloat(1))
                }
            } footer: {
                Footnote("设备请求的帧率不会超过此上限；实际帧率还取决于桌面更新和连接。码率以 60 FPS 为基准，120 FPS 时加倍。超清和极致需要 USB 或高速 Wi-Fi。更改后画面可能短暂停顿。Duo 原生桌面保持原生尺寸并使用硬件编码，不受常规画面分辨率选项影响。")
            }
            // Away from home (docs/remote-bundle-plan.md §5): its own quality, which a device away
            // sets too; the menu's Quality and Resolution stay the home ones.
            Section {
                Picker("画质", selection: $settings.config.awayBitrate) {
                    ForEach(QualityPreset.allCases) { Text(DuoQualityLabels.title(forBitrate: $0.rawValue)).tag($0.rawValue) }
                    if QualityPreset(rawValue: settings.config.awayBitrate) == nil {
                        Text(DuoQualityLabels.title(forBitrate: settings.config.awayBitrate)).tag(settings.config.awayBitrate)
                    }
                }
                Picker("常规画面分辨率", selection: $settings.config.awayCaptureScale) {
                    Text("Retina").tag(CGFloat(2))
                    Text("标准").tag(CGFloat(1))
                }
            } header: {
                Text("远程连接")
            } footer: {
                Footnote("当所有已连接设备都通过公网或 VPN 远程连接时，使用这里的设置；远程设备更改的是这一组设置。"
                         + (model.coordinator?.status.snapshot.away == true ? " 当前正在使用远程设置。" : ""))
            }
            Section {
                Toggle("优先编码速度", isOn: $settings.config.prioritizeSpeed)
            } footer: {
                Footnote("Mac 繁忙时可降低延迟，画面可能略柔和。")
            }
            if let snapshot = model.coordinator?.status.snapshot, snapshot.softwareEncoder {
                Section {
                    Label("当前为软件编码测试状态；Duo 原生桌面需要硬件编码，不能以此状态验收。",
                          systemImage: "exclamationmark.triangle.fill")
                        .foregroundStyle(.orange)
                }
            }
        }
    }
}

// MARK: Virtual Display

private struct VirtualDisplayPane: View {
    let model: AppModel
    @Bindable var settings: HostSettings
    @State private var retrying = false

    var body: some View {
        let snapshot = model.coordinator?.status.snapshot ?? HostStatusSnapshot()
        Form {
            Section {
                Toggle("从虚拟显示器串流", isOn: $settings.config.virtualDisplay)
            } footer: {
                Footnote("将所选窗口移到为设备创建的虚拟显示器，窗口被遮挡时仍可更新，并按设备比例绘制文字。停止串流或退出 DUO你电脑 后，窗口会返回原处。")
            }
            Section {
                LabeledContent("状态") {
                    HStack(spacing: 8) {
                        Text(statusText(snapshot))
                            .multilineTextAlignment(.trailing)
                        if canRetry(snapshot) {
                            Button("重试") {
                                retrying = true
                                Task { @MainActor in
                                    await model.coordinator?.retryVirtualDisplay()
                                    retrying = false
                                }
                            }
                            .disabled(retrying || model.coordinator == nil)
                        }
                    }
                }
                if settings.config.virtualDisplay, let failure = snapshot.lastStageFailure {
                    LabeledContent("上一个窗口") {
                        Text("已在原位置串流：\(failure)").multilineTextAlignment(.trailing)
                    }
                }
            } footer: {
                Footnote("使用 macOS 的 CGVirtualDisplay 接口。如果系统更新导致接口不可用，将在窗口原位置串流。")
            }
        }
    }

    private func statusText(_ s: HostStatusSnapshot) -> String {
        let sr = model.permissions.screenRecording, ax = model.permissions.accessibility
        if s.virtualDisplayAPIMissing, let problem = s.virtualDisplayProblem {
            return "此 macOS 版本不可用：\(problem)"
        }
        if !sr && !ax { return "需要屏幕录制和辅助功能权限" }
        if !ax { return "需要辅助功能权限" }
        if !sr { return "需要屏幕录制权限" }
        if let problem = s.virtualDisplayProblem { return "本次会话已关闭：\(problem)" }
        return "可用"
    }

    /// A run-level disable (the system removed the display too often) can be retried; a missing
    /// API or permission cannot.
    private func canRetry(_ s: HostStatusSnapshot) -> Bool {
        s.virtualDisplayProblem != nil && !s.virtualDisplayAPIMissing && model.permissions.allGranted
    }
}

// MARK: Permissions

private struct PermissionsPane: View {
    let model: AppModel

    var body: some View {
        let permissions = model.permissions
        let network = model.coordinator?.status.snapshot.network
        Form {
            Section {
                PermissionRow(id: "screen-recording", title: "屏幕录制", allowed: permissions.screenRecording,
                              explanation: "允许 iPhone Duo 查看完整的 Mac 桌面。",
                              button: model.settings.askedScreenRecording ? "打开系统设置…" : "允许…") {
                    permissions.requestScreenRecording()
                }
                PermissionRow(id: "accessibility", title: "辅助功能", allowed: permissions.accessibility,
                              explanation: "允许 iPhone Duo 在此 Mac 上点击、滚动和输入。",
                              button: model.settings.askedAccessibility ? "打开系统设置…" : "允许…") {
                    permissions.requestAccessibility()
                }
            } footer: {
                Footnote("请在系统设置中为 DUO你电脑 开启这两项权限。")
            }
            if permissions.relaunchSuggested, !permissions.screenRecording {
                Section {
                    LabeledContent("重新打开 DUO你电脑 后，屏幕录制权限才会生效。") {
                        Button(permissions.canRelaunch ? "重新打开 DUO你电脑" : "退出 DUO你电脑") { permissions.relaunch() }
                    }
                }
            }
            if Self.networkNeedsHelp(network) {
                Section {
                    LabeledContent {
                        Button("打开本地网络设置…") { permissions.openPrivacyPane("Privacy_LocalNetwork") }
                    } label: {
                        Text("本地网络")
                        Text("如果 iPhone 或 iPad 找不到此 Mac，请在“隐私与安全性 › 本地网络”中允许 DUO你电脑。")
                    }
                }
            }
            if permissions.allGranted {
                Section {
                    Label("已准备就绪，请在 iPhone 或 iPad 上打开 DUO你电脑。", systemImage: "checkmark.seal.fill")
                }
            }
        }
    }

    private static func networkNeedsHelp(_ network: HostStatusSnapshot.Network?) -> Bool {
        switch network {
        case .waiting, .failed: return true
        default: return false
        }
    }
}

private struct PermissionRow: View {
    let id: String
    let title: LocalizedStringResource
    let allowed: Bool
    let explanation: LocalizedStringResource
    let button: LocalizedStringResource
    let action: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Text(title)
                Spacer()
                if allowed {
                    Label("已允许", systemImage: "checkmark.circle.fill")
                        .foregroundStyle(.green)
                } else {
                    HStack(spacing: 6) {
                        Image(systemName: "exclamationmark.triangle.fill")
                            .foregroundStyle(.orange)
                            .accessibilityHidden(true)
                        Button(action: action) { Text(button) }
                            .accessibilityLabel(Text("\(Text(title)): \(Text(button))"))
                            .accessibilityIdentifier("duodesk.permission.\(id)")
                    }
                }
            }
            Text(explanation)
                .font(.callout)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .accessibilityElement(children: .contain)
    }
}
