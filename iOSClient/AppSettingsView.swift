// Copyright 2026 DUO你电脑 contributors. SPDX-License-Identifier: Apache-2.0
import SwiftUI
import StreamProtocol

/// The app's own settings, reached from the connect screen's toolbar. What lives
/// here is what belongs to
/// this device rather than to a connection: the switches that change how it drives
/// the Mac, where to get the Mac's side, and the two addresses App Review asks for.
///
/// A connection's own settings stay in the stream screen's panel (HostSettingsPanel),
/// because they are the Mac's and change with it.
struct AppSettingsView: View {
    @Environment(\.dismiss) private var dismiss
    @Environment(\.colorScheme) private var scheme

    @AppStorage(StreamClient.gesturesKey) private var gesturesOn = true
    @AppStorage(StreamClient.largerPictureKey) private var largerPicture = false
    @AppStorage(StreamClient.clipboardKey) private var clipboardOn = true
    /// What this device asks the Mac for; the Mac's own cap still applies.
    @AppStorage(DuoStreamPolicy.preferredFPSKey) private var preferredFPS = DuoStreamPolicy.defaultFPS

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 18) {
                    group("连接") {
                        HStack {
                            Text("首选帧率")
                                .foregroundStyle(Palette.text)
                            Spacer(minLength: 8)
                            Picker("首选帧率", selection: $preferredFPS) {
                                Text("60").tag(60)
                                Text("120").tag(120)
                            }
                            .pickerStyle(.segmented)
                            .labelsHidden()
                            .frame(width: 132)
                        }
                        .font(.system(size: 15))
                        .padding(.horizontal, 14)
                        .padding(.vertical, 9)
                        divider
                        row {
                            Toggle("三指手势", isOn: $gesturesOn)
                        }
                        divider
                        row {
                            Toggle("更宽视野", isOn: $largerPicture)
                        }
                        divider
                        row {
                            Toggle("共享剪贴板", isOn: $clipboardOn)
                        }
                        divider
                        note("这些偏好跟随这台设备，换一台 Mac 也生效。画质与分辨率属于 Mac，在串流页的设置面板里调。")
                    }

                    if SillLinks.download != nil {
                        group("Mac 服务端") {
                            link("下载 Mac 服务端", to: SillLinks.download)
                            divider
                            note("Mac 上运行服务端并配对后，这台设备才能连接。")
                        }
                    }

                    group("关于") {
                        if let support = SillLinks.support {
                            link("支持", to: support)
                            divider
                        }
                        if let privacy = SillLinks.privacy {
                            link("隐私政策", to: privacy)
                            divider
                        }
                        HStack {
                            Text("版本")
                                .foregroundStyle(Palette.text)
                            Spacer(minLength: 8)
                            Text(Self.version)
                                .foregroundStyle(Palette.muted)
                                .monospacedDigit()
                        }
                        .font(.system(size: 15))
                        .padding(.horizontal, 14)
                        .padding(.vertical, 12)
                    }
                }
                .padding(16)
            }
            .background(PageBackground())
            .navigationTitle("设置")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    PanelCloseButton(label: "关闭") { dismiss() }
                }
            }
        }
        .readsAppearance()
    }

    // MARK: Pieces

    private func group<Content: View>(_ title: String,
                                      @ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(title)
                .font(.system(size: 11, weight: .semibold))
                .tracking(0.8)
                .textCase(.uppercase)
                .foregroundStyle(Palette.muted)
                .padding(.leading, 4)
            VStack(spacing: 0) { content() }
                .background {
                    RoundedRectangle(cornerRadius: 16, style: .continuous)
                        .fill(Palette.group)
                        .overlay {
                            RoundedRectangle(cornerRadius: 16, style: .continuous)
                                .strokeBorder(Palette.strokeSoft, lineWidth: 1)
                        }
                }
                .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
        }
    }

    private func row<Content: View>(@ViewBuilder content: () -> Content) -> some View {
        content()
            .font(.system(size: 15))
            .foregroundStyle(Palette.text)
            .padding(.horizontal, 14)
            .padding(.vertical, 11)
    }

    private var divider: some View {
        Rectangle().fill(Palette.divider).frame(height: 0.5).padding(.leading, 14)
    }

    private func note(_ text: String) -> some View {
        Text(text)
            .font(.system(size: 12))
            .foregroundStyle(Palette.muted)
            .fixedSize(horizontal: false, vertical: true)
            .padding(.horizontal, 14)
            .padding(.vertical, 10)
    }

    private func link(_ title: String, to url: URL?) -> some View {
        Link(destination: url ?? SillLinks.repository ?? URL(string: "https://example.invalid")!) {
            HStack {
                Text(title).foregroundStyle(Palette.accent)
                Spacer(minLength: 8)
                Image(systemName: "arrow.up.right")
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(Palette.muted)
            }
            .font(.system(size: 15))
            .padding(.horizontal, 14)
            .padding(.vertical, 12)
            .contentShape(Rectangle())
        }
    }

    /// "0.1.0 (2026110503)": the version a support request needs.
    private static var version: String {
        let info = Bundle.main.infoDictionary
        let short = info?["CFBundleShortVersionString"] as? String ?? "—"
        let build = info?["CFBundleVersion"] as? String
        return build.map { "\(short) (\($0))" } ?? short
    }
}
