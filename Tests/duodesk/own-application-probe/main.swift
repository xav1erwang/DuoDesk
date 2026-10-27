// Copyright 2026 DUO你电脑 contributors. SPDX-License-Identifier: Apache-2.0
// Exercises the production own-application lookup using a real AppKit window and system catalog.
import AppKit
import CoreGraphics
import Foundation

setbuf(stdout, nil)
let app = NSApplication.shared
app.setActivationPolicy(.accessory)

@MainActor
final class OwnApplicationProbe: NSObject, NSApplicationDelegate {
    private var statusItem: NSStatusItem?
    private var window: NSWindow?

    func applicationDidFinishLaunching(_ notification: Notification) {
        Task { @MainActor in await run() }
    }

    private func run() async {
        let hasGlobalGrant = CGPreflightScreenCaptureAccess()
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        statusItem?.button?.title = "DUO"
        let hiddenCatalog = WindowCatalog()
        let before = await hiddenCatalog.resolveOwnApplication()
        print("Own app before visible window: \(before?.processID == getpid()); globalRecording=\(hasGlobalGrant)")

        if CommandLine.arguments.contains("--no-window-only") {
            let found = before?.processID == getpid() && before?.bundleIdentifier == Bundle.main.bundleIdentifier
            let cached = await hiddenCatalog.resolveOwnApplication()
            let cacheOK = cached?.processID == getpid()
            if let statusItem { NSStatusBar.system.removeStatusItem(statusItem) }
            print("OWN APP WITHOUT VISIBLE WINDOW: found=\(found), cacheAfterHide=\(cacheOK), globalRecording=\(hasGlobalGrant)")
            guard !hasGlobalGrant, found, cacheOK else { exit(1) }
            app.terminate(nil)
            return
        }

        let window = NSWindow(contentRect: NSRect(x: 40, y: 40, width: 360, height: 120),
                              styleMask: [.titled, .closable], backing: .buffered, defer: false)
        self.window = window
        window.title = "DUO 隐私检查"
        window.contentView = NSTextField(wrappingLabelWithString: "正在检查窗口保护。检查只使用本机窗口。")
        window.center(); window.makeKeyAndOrderFront(nil)
        try? await Task.sleep(for: .milliseconds(350))

        let visibleCatalog = WindowCatalog()
        let found = await visibleCatalog.resolveOwnApplication()
        let expectedBundle = Bundle.main.bundleIdentifier ?? ""
        let correctOwner = found?.processID == getpid() && found?.bundleIdentifier == expectedBundle
        print("Own visible app resolved: \(correctOwner)")
        window.orderOut(nil)
        try? await Task.sleep(for: .milliseconds(150))
        let cached = await visibleCatalog.resolveOwnApplication()
        let cachedCorrectly = cached?.processID == getpid() && cached?.bundleIdentifier == expectedBundle
        print("Own app after hiding window remains usable: \(cachedCorrectly)")
        if let statusItem { NSStatusBar.system.removeStatusItem(statusItem) }
        guard !hasGlobalGrant, correctOwner, cachedCorrectly else {
            print("OWN APPLICATION CHECK FAILED")
            exit(1)
        }
        print("OWN APPLICATION CHECK PASS; scoped inventory only, no screen capture or authorization request")
        app.terminate(nil)
    }
}

let applicationDelegate = MainActor.assumeIsolated { OwnApplicationProbe() }
app.delegate = applicationDelegate
app.run()
