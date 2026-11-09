// Copyright 2026 DUO你电脑 contributors. SPDX-License-Identifier: Apache-2.0
import AppKit
import CoreText
import SwiftUI

@MainActor
final class AboutPanel: NSObject {
    static let shared = AboutPanel()
    private var window: NSWindow?

    static func show() { shared.show() }

    private func show() {
        if let window { WindowPlacement.bringForward(window); return }
        if let url = Bundle.main.url(forResource: "Montserrat-900", withExtension: "ttf") {
            CTFontManagerRegisterFontsForURL(url as CFURL, .process, nil)
        }
        let panel = NSPanel(contentViewController: NSHostingController(rootView: AboutContent()))
        panel.title = "关于 DUO你电脑"
        panel.styleMask = [.titled, .closable]
        panel.isReleasedWhenClosed = false
        panel.center()
        window = panel
        WindowPlacement.bringForward(panel)
    }

    @objc func open(_ sender: Any?) { show() }
}

struct AboutContent: View {
    var body: some View {
        VStack(spacing: 12) {
            Image(nsImage: NSImage(named: NSImage.applicationIconName) ?? NSImage())
                .resizable().scaledToFit().frame(width: 80, height: 80)
                .accessibilityHidden(true)
            Text("DUO你电脑").font(.title2.bold())
            Text("版本 \(AppModel.version) (\(AppModel.build))")
                .font(.callout).foregroundStyle(.secondary)
            Text(Bundle.main.object(forInfoDictionaryKey: "NSHumanReadableCopyright") as? String ?? "")
                .font(.caption).foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .fixedSize(horizontal: false, vertical: true)
            VisionTecMark(size: 13).padding(.top, 10)
        }
        .padding(28)
        .frame(width: 300)
    }
}
