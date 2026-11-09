// Modified for DUO你电脑, 2026. See NOTICE for upstream attribution.
import AppKit
import Combine
import SwiftUI
import SillHostCore
import StreamProtocol

/// One Settings tab: a compact grouped Form. The controls bind straight to
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
            case .devices: LiveDevicesPane(model: model)
            case .permissions: PermissionsPane(model: model)
            case .remoteAccess: LiveRemoteAccessPane(model: model, settings: model.settings)
            }
        }
        .formStyle(.grouped)
        .controlSize(.small)
        .frame(width: 440)
        // Refresh system permissions only while their state is visible. Connection and device
        // changes are pushed by the host.
        .task(id: model.visibleSettingsTab == tab) {
            guard model.visibleSettingsTab == tab, tab == .general || tab == .permissions else { return }
            while !Task.isCancelled {
                model.permissions.refresh()
                model.bootService.refresh()
                try? await Task.sleep(for: .seconds(1))
            }
        }
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in
            model.permissions.refresh()
            model.bootService.refresh()
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

    var body: some View {
        Form {
            Section {
                PictureQualityPicker(title: "画质", bitrate: $settings.pictureQuality)
            }
            ClipboardSection(shareClipboard: $settings.config.shareClipboard,
                             access: previewClipboardAccess ?? model.permissions.clipboardAccess,
                             allow: { model.permissions.allowClipboard() })
            Section {
                Toggle("空闲时保持唤醒", isOn: $settings.keepAvailable)
            } footer: {
                Footnote("打开这个开关后，这台电脑将不会自动休眠，但即使不打开，DUO你电脑也会在你希望连接到这台电脑时，尽力唤醒它。")
            }
            DiagnosticSettingsSection()
            if let preview = previewUpdates {
                UpdatesSection(pane: preview, automatic: .constant(true))
            } else if Bundle.main.bundleIdentifier != "com.duodesk.host" {
                UpdatesSection(pane: model.updates.pane, automatic: $settings.updateCheck,
                               actions: UpdatesSection.Actions(checkNow: { model.updates.checkNow() },
                                                               openRelease: { NSWorkspace.shared.open($0) }))
            }
            Section {
                Button("关于 DUO你电脑") { AboutPanel.show() }
            } footer: {
                Footnote("DUO你电脑 \(AppModel.version) · 基于 Sill（Apache-2.0）")
            }
        }
    }
}

// MARK: Clipboard

/// Clipboard sharing, with an action only when macOS still needs permission.
struct ClipboardSection: View {
    @Binding var shareClipboard: Bool
    let access: ClipboardPolicy.MacAccess
    var allow: () -> Void = {}

    var body: some View {
        Section {
            Toggle("共享剪贴板", isOn: $shareClipboard)
            if shareClipboard, access != .allowed {
                Button("允许读取剪贴板…", action: allow)
            }
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

// MARK: Permissions

private struct PermissionsPane: View {
    let model: AppModel

    var body: some View {
        let permissions = model.permissions
        Form {
            Section {
                PermissionRow(id: "screen-recording", title: "屏幕录制", allowed: permissions.screenRecording,
                              explanation: "查看 Mac 画面。",
                              button: model.settings.askedScreenRecording ? "打开系统设置…" : "允许…") {
                    permissions.requestScreenRecording()
                }
                PermissionRow(id: "accessibility", title: "辅助功能", allowed: permissions.accessibility,
                              explanation: "使用鼠标和键盘。",
                              button: model.settings.askedAccessibility ? "打开系统设置…" : "允许…") {
                    permissions.requestAccessibility()
                }
            }
            if permissions.relaunchSuggested, !permissions.screenRecording {
                Section {
                    Button("重新打开以完成授权") { permissions.relaunch() }
                }
            }
            if model.bootService.needsApproval {
                Section {
                    LabeledContent("开机服务") {
                        Button("完成授权…") { model.bootService.openSystemSettings() }
                    }
                }
            } else if let error = model.bootService.error {
                Section {
                    LabeledContent("开机服务未能启动") {
                        Button("重试") { model.bootService.retry() }
                            .disabled(model.bootService.busy)
                    }
                    .help(error)
                }
            }
            if case .failed = model.coordinator?.status.snapshot.network {
                Section {
                    LabeledContent("本地网络") {
                        Button("检查权限…") { permissions.openPrivacyPane("Privacy_LocalNetwork") }
                    }
                }
            }
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
        LabeledContent {
            if allowed {
                Label("已允许", systemImage: "checkmark.circle.fill")
                    .foregroundStyle(.green)
            } else {
                Button(action: action) { Text(button) }
                    .accessibilityLabel(Text("\(Text(title)): \(Text(button))"))
                    .accessibilityIdentifier("duodesk.permission.\(id)")
            }
        } label: {
            Text(title)
            if !allowed { Text(explanation) }
        }
        .accessibilityElement(children: .contain)
    }
}
