import AppKit
import SwiftUI
import SillHostCore
import StreamProtocol

/// Settings › Devices, live: Require pairing, which the model keeps in the identity store beside
/// the trust list (never in UserDefaults), and the paired devices from the host's status (pushed,
/// so nothing polls), with the model's actions.
struct LiveDevicesPane: View {
    let model: AppModel
    @Bindable var settings: HostSettings

    var body: some View {
        if model.identityLoading {
            Form {
                HStack(spacing: 12) {
                    ProgressView().controlSize(.small).accessibilityHidden(true)
                    Text("正在读取已保存的配对信息…")
                }
                .accessibilityElement(children: .combine)
                .accessibilityIdentifier("duodesk.identity.loading")
            }
        } else {
            DevicesPane(status: model.coordinator?.status.snapshot.remote ?? RemoteStatus(),
                        requirePairing: Binding(get: { settings.config.requirePairing }, set: { model.setRequirePairing($0) }),
                        requirePairingProblem: model.requirePairingProblem,
                        actions: DevicesPane.Actions(pair: { model.pairDevice() },
                                                     remove: { model.removeDevice($0) },
                                                     rename: { model.renameDevice($0, to: $1) }))
        }
    }
}

/// The Devices pane (docs/home-pairing-plan.md §6.1): Require pairing, and the devices paired with
/// this Mac at home and from afar (one trust list), each with how it paired and how it last
/// connected, Remove, rename and Pair iPhone or iPad…. Values in, actions out, so the previews can
/// draw every state. Errors show inline, never in alerts.
struct DevicesPane: View {
    struct Actions {
        var pair: () -> Void = {}
        /// Nil when the device was removed; otherwise why it is still paired.
        var remove: (String) -> String? = { _ in nil }
        var rename: (String, String) -> Void = { _, _ in }
    }

    let status: RemoteStatus
    @Binding var requirePairing: Bool
    /// The last Require pairing change the identity store did not keep.
    var requirePairingProblem: AppModel.RequirePairingProblem?
    let actions: Actions
    /// "Last connected 2 minutes ago" counts from here (fixed in the previews).
    var now: Date?

    @State private var removedName: String?
    /// A Remove the keychain did not keep: the device's name and why.
    @State private var removeProblem: (name: String, reason: String)?

    /// Why devices can't connect at all: the identity (the key, the trust list) could not be used,
    /// so the home door has no listener. Nil when it works.
    private var unavailable: String? {
        if let problem = status.identityProblem { return problem }
        if case .unavailable(let why) = status.homeDoor { return why }
        return nil
    }

    var body: some View {
        Form {
            Section {
                Toggle("要求配对", isOn: $requirePairing)
                    .disabled(unavailable != nil)
                if let problem = unavailable {
                    Warning("设备无法连接：DUO你电脑 无法使用钥匙串中的密钥（\(withoutFullStop(problem))）。请重新打开应用；若钥匙串询问，请选择始终允许。")
                } else if let p = requirePairingProblem {
                    let reason = withoutFullStop(p.reason)
                    Warning(p.wanted
                            ? "退出应用前仍要求配对：无法更新钥匙串（\(reason)）。请重试。"
                            : "仍然要求配对：无法更新钥匙串（\(reason)）。请重试。")
                }
            } footer: {
                if requirePairing {
                    Footnote("每台 iPhone 或 iPad 只需配对一次：可通过 USB 连接，或在 Wi-Fi 下输入 Mac 显示的配对码。设备收发的内容均经过加密。")
                } else {
                    Label("网络中的设备、开启无线直连后附近的设备，以及此 Mac 上的应用，都可无需配对查看和控制此 Mac。连接仍会加密。",
                          systemImage: "exclamationmark.triangle.fill")
                        .font(.footnote)
                        .foregroundStyle(.orange)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            pairedDevices
        }
    }

    private var pairedDevices: some View {
        Section {
            if let removedName {
                Text("\(removedName) 已无法连接；如需再次使用，请重新配对。")
            }
            if let removeProblem {
                Warning("\(removeProblem.name) 仍处于配对状态：无法更新钥匙串（\(withoutFullStop(removeProblem.reason))）。请重试。")
            }
            if unavailable != nil {
                // The trust list lives with the key: unread, not empty.
                Text("应用恢复使用密钥后，将在此显示已配对设备。").foregroundStyle(.secondary)
            } else if status.paired.isEmpty {
                Text("尚无已配对设备。").foregroundStyle(.secondary)
            }
            ForEach(status.paired) { device in
                PairedDeviceRow(device: device, now: now,
                                remove: {
                                    // Said only once the keychain kept it: otherwise the device
                                    // would be trusted again at the next launch.
                                    if let reason = actions.remove(device.id) {
                                        removedName = nil
                                        removeProblem = (device.name, reason)
                                    } else {
                                        removedName = device.name
                                        removeProblem = nil
                                    }
                                },
                                rename: { actions.rename(device.id, $0) })
            }
            Button("配对 iPhone 或 iPad…") { actions.pair() }
                .disabled(unavailable != nil)
        } header: {
            Text("已配对设备")
        } footer: {
            Footnote("已配对设备可在本地网络或附近查看和控制此 Mac；开启远程访问后也可从外网连接。设备丢失时可在此移除。")
        }
    }
}

/// One paired device: its name (double-click to rename: Return saves, Esc cancels), how it paired,
/// when and how it last connected (at home or from away), and Remove, with no confirmation since
/// it only takes access away.
struct PairedDeviceRow: View {
    let device: PairedDeviceSummary
    let now: Date?
    let remove: () -> Void
    let rename: (String) -> Void

    @State private var editing = false
    @State private var text = ""
    @FocusState private var focused: Bool

    var body: some View {
        LabeledContent {
            Button("移除", action: remove)
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
                Text(device.name)
                    .onTapGesture(count: 2) { startEditing() }
                    .accessibilityAction(named: "重命名") { startEditing() }
            }
            Text(Self.detail(device, now: now ?? Date()))
        }
    }

    private func startEditing() {
        text = device.name
        editing = true
        focused = true
    }

    /// "Paired Sep 25 over the USB cable · last connected 2 minutes ago over Wi‑Fi", "Paired Sep 24
    /// with the QR code · last connected yesterday through Tailscale".
    static func detail(_ device: PairedDeviceSummary, now: Date) -> String {
        var out = "配对于 \(day(device.pairedAt, now: now))"
        if let method = device.displayMethod { out += " · \(translatedRoute(method))" }
        if let seen = device.lastSeen {
            let formatter = RelativeDateTimeFormatter()
            formatter.locale = Locale(identifier: "zh_Hans_CN")
            formatter.unitsStyle = .full
            formatter.dateTimeStyle = .named
            let when = now.timeIntervalSince(seen) < 60 ? "刚刚" : formatter.localizedString(for: seen, relativeTo: now)
            out += " · 上次连接：\(when)"
            if let route = device.lastRoute { out += " · \(translatedRoute(route))" }
        }
        return out
    }

    private static func translatedRoute(_ value: String) -> String {
        switch value {
        case "over the USB cable": return "通过 USB 线缆"
        case "over Wi-Fi", "over Wi‑Fi": return "通过 Wi-Fi"
        case "with the QR code": return "通过二维码"
        case "with a code": return "通过配对码"
        default:
            if value.hasPrefix("through ") { return "通过 " + String(value.dropFirst("through ".count)) }
            return value
        }
    }

    static func day(_ date: Date, now: Date) -> String {
        let sameYear = Calendar.current.component(.year, from: date) == Calendar.current.component(.year, from: now)
        return sameYear ? date.formatted(.dateTime.month(.abbreviated).day()) : date.formatted(.dateTime.month(.abbreviated).day().year())
    }
}
