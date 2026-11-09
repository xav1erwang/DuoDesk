// Modified for DUO你电脑, 2026. See NOTICE for upstream attribution.
import AppKit
import SwiftUI
import SillHostCore
import StreamProtocol

struct LiveRemoteAccessPane: View {
    let model: AppModel
    @Bindable var settings: HostSettings

    var body: some View {
        RemoteAccessPane(status: model.coordinator?.status.snapshot.remote ?? RemoteStatus(),
                         internetAccess: $settings.config.internetAccess,
                         directWireless: $settings.config.directWireless,
                         port: settings.config.remotePort,
                         addressName: settings.remoteAddressName,
                         actions: RemoteAccessPane.Actions(
                             setPort: { settings.config.remotePort = $0 },
                             setAddressName: { settings.remoteAddressName = $0 },
                             reopen: { model.permissions.relaunch() }))
    }
}

struct RemoteAccessPane: View {
    struct Actions {
        var setPort: (Int) -> Void = { _ in }
        var setAddressName: (String) -> Void = { _ in }
        var reopen: () -> Void = {}
    }

    let status: RemoteStatus
    @Binding var internetAccess: Bool
    @Binding var directWireless: Bool
    let port: Int
    let addressName: String
    let actions: Actions

    var body: some View {
        Form {
            Section {
                Toggle("允许就近连接", isOn: $directWireless)
            } footer: {
                Footnote("当设备在附近时 尝试直接连接")
            }
            Section {
                Toggle("允许使用互联网建立连接", isOn: $internetAccess)
                    .disabled(status.identityProblem != nil)
            } footer: {
                Footnote("允许已配对设备通过互联网连接，需要设置路由器端口转发。")
            }
            if status.identityProblem != nil {
                Section {
                    LabeledContent("连接暂时不可用") {
                        Button("重新打开 DUO你电脑", action: actions.reopen)
                    }
                }
            } else {
                ConnectionAddressesSection(status: status, port: port, setPort: actions.setPort,
                                           showsPort: !internetAccess)
                if internetAccess {
                    PublicConnectionSection(status: status, port: port, addressName: addressName,
                                            setPort: actions.setPort, setAddressName: actions.setAddressName)
                }
            }
        }
    }
}

private struct ConnectionAddressesSection: View {
    let status: RemoteStatus
    let port: Int
    let setPort: (Int) -> Void
    let showsPort: Bool

    private var vpnAddresses: [MacAddress] {
        var seen = Set<String>()
        return status.addresses.filter { $0.kind == MacAddress.vpn && seen.insert($0.via).inserted }
    }

    var body: some View {
        if !vpnAddresses.isEmpty || listenerFailed {
            Section {
                ForEach(vpnAddresses, id: \.via) { address in
                    LabeledContent(address.via) {
                        HStack(spacing: 8) {
                            Text(address.host).textSelection(.enabled)
                            CopyButton(text: address.host, spoken: "复制连接地址")
                        }
                    }
                }
                switch status.listener {
                case .portInUse(let port):
                    Warning("端口\(port)被占用，请更换端口。")
                    if showsPort { ConnectionPortRow(port: self.port, save: setPort) }
                case .failed:
                    Warning("连接服务暂时不可用，正在重试。")
                case .off, .listening:
                    EmptyView()
                }
            }
        }
    }

    private var listenerFailed: Bool {
        switch status.listener {
        case .portInUse, .failed: true
        case .off, .listening: false
        }
    }
}

private struct PublicConnectionSection: View {
    let status: RemoteStatus
    let port: Int
    let addressName: String
    let setPort: (Int) -> Void
    let setAddressName: (String) -> Void

    @State private var draft: String?
    @State private var problem: String?

    var body: some View {
        Section {
            ConnectionPortRow(port: port, save: setPort)
            LabeledContent("地址或域名") {
                HStack(spacing: 8) {
                    TextField("公网地址", text: Binding(get: { draft ?? addressName },
                                                      set: { draft = $0; problem = nil }),
                              prompt: Text(automaticAddress))
                        .labelsHidden()
                        .multilineTextAlignment(.trailing)
                        .onSubmit { saveAddress() }
                    if let draft, draft != addressName {
                        Button("保存") { saveAddress() }
                    }
                }
            }
            if let problem { Warning(problem) }
            if case .carrierNAT = status.router {
                Warning("此网络不支持端口转发，请使用 VPN。")
            } else if case .doubleNAT = status.router {
                Warning("需要在两台路由器上设置端口转发。")
            }
        } footer: {
            if let lan = status.lanAddress {
                Footnote("在路由器中将 TCP 端口 \(String(port)) 转发到 \(lan)。")
            }
        }
    }

    private var automaticAddress: String {
        if case .address(let address) = status.router { return address }
        return "自动获取"
    }

    private func saveAddress() {
        let value = (draft ?? addressName).trimmingCharacters(in: .whitespacesAndNewlines)
        if !value.isEmpty, case .failure = AddressParser.parse(value) {
            problem = "请输入有效的 IP 地址或域名。"
            return
        }
        setAddressName(value)
        draft = nil
        problem = nil
    }
}

private struct ConnectionPortRow: View {
    let port: Int
    let save: (Int) -> Void

    @State private var draft: String?
    @State private var problem: String?

    var body: some View {
        LabeledContent("端口") {
            HStack(spacing: 8) {
                TextField("端口", text: Binding(get: { draft ?? String(port) },
                                              set: { draft = $0; problem = nil }))
                    .labelsHidden()
                    .frame(width: 72)
                    .multilineTextAlignment(.trailing)
                    .monospacedDigit()
                    .onSubmit { savePort() }
                if let draft, draft != String(port) {
                    Button("保存") { savePort() }
                }
            }
        }
        if let problem { Warning(problem) }
    }

    private func savePort() {
        let value = (draft ?? String(port)).trimmingCharacters(in: .whitespacesAndNewlines)
        guard let number = Int(value), (1024...65535).contains(number) else {
            problem = "请输入 1024–65535 之间未被占用的端口。"
            return
        }
        save(number)
        draft = nil
        problem = nil
    }
}

private struct CopyButton: View {
    let text: String
    let spoken: String
    @State private var copied = false

    var body: some View {
        Button(copied ? "已复制" : "复制") {
            NSPasteboard.general.clearContents()
            NSPasteboard.general.setString(text, forType: .string)
            copied = true
            Task { @MainActor in
                try? await Task.sleep(for: .seconds(1.5))
                copied = false
            }
        }
        .accessibilityLabel(copied ? "已复制" : spoken)
    }
}
