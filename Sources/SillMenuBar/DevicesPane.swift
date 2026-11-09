// Modified for DUO你电脑, 2026. See NOTICE for upstream attribution.
import AppKit
import SwiftUI
import SillHostCore
import StreamProtocol

struct LiveDevicesPane: View {
    let model: AppModel

    var body: some View {
        if model.identityLoading {
            Form {
                HStack(spacing: 12) {
                    ProgressView().controlSize(.small).accessibilityHidden(true)
                    Text("正在载入设备…")
                }
                .accessibilityElement(children: .combine)
                .accessibilityIdentifier("duodesk.identity.loading")
            }
        } else {
            DevicesPane(status: model.coordinator?.status.snapshot.remote ?? RemoteStatus(),
                        actions: DevicesPane.Actions(pair: { model.pairDevice() },
                                                     remove: { model.removeDevice($0) },
                                                     rename: { model.renameDevice($0, to: $1) },
                                                     reopen: { model.permissions.relaunch() }))
        }
    }
}

struct DevicesPane: View {
    struct Actions {
        var pair: () -> Void = {}
        var remove: (String) -> String? = { _ in nil }
        var rename: (String, String) -> Void = { _, _ in }
        var reopen: () -> Void = {}
    }

    let status: RemoteStatus
    let actions: Actions
    var now: Date?

    @State private var removeProblem: String?

    private var unavailable: Bool {
        if status.identityProblem != nil { return true }
        if case .unavailable = status.homeDoor { return true }
        return false
    }

    var body: some View {
        Form {
            Section {
                if unavailable {
                    LabeledContent("无法读取设备") {
                        Button("重新打开 DUO你电脑", action: actions.reopen)
                    }
                } else {
                    if let removeProblem { Warning(removeProblem) }
                    if status.paired.isEmpty {
                        Text("暂无已配对设备").foregroundStyle(.secondary)
                    }
                    ForEach(status.paired) { device in
                        PairedDeviceRow(device: device, now: now,
                                        remove: {
                                            if actions.remove(device.id) != nil {
                                                removeProblem = "未能移除\(device.name)，请重试。"
                                            } else {
                                                removeProblem = nil
                                            }
                                        },
                                        rename: { actions.rename(device.id, $0) })
                    }
                    Button("配对设备…", action: actions.pair)
                }
            }
        }
    }
}

struct PairedDeviceRow: View {
    let device: PairedDeviceSummary
    let now: Date?
    let remove: () -> Void
    let rename: (String) -> Void

    @State private var editing = false
    @State private var text = ""
    @FocusState private var focused: Bool

    private var displayName: String {
        guard let model = device.model else { return device.name }
        let suffix = " (\(model))"
        return device.name.hasSuffix(suffix) ? String(device.name.dropLast(suffix.count)) : device.name
    }

    var body: some View {
        LabeledContent {
            Button("移除", role: .destructive, action: remove)
                .accessibilityLabel("移除\(displayName)")
        } label: {
            if editing {
                TextField("名称", text: $text)
                    .focused($focused)
                    .onSubmit {
                        rename(text)
                        editing = false
                    }
                    .onExitCommand { editing = false }
            } else {
                Text(displayName)
                    .onTapGesture(count: 2) { startEditing() }
                    .contextMenu { Button("重命名") { startEditing() } }
                    .accessibilityAction(named: "重命名") { startEditing() }
            }
            Text(Self.detail(device, now: now ?? Date()))
        }
    }

    private func startEditing() {
        text = displayName
        editing = true
        focused = true
    }

    static func detail(_ device: PairedDeviceSummary, now: Date) -> String {
        guard let seen = device.lastSeen else { return "尚未连接" }
        if now.timeIntervalSince(seen) < 60 { return "刚刚连接" }
        let formatter = RelativeDateTimeFormatter()
        formatter.unitsStyle = .full
        formatter.dateTimeStyle = .named
        return "上次连接：" + formatter.localizedString(for: seen, relativeTo: now)
    }
}
