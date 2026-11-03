// Separate UI process: the host's own windows are excluded from production desktop capture.
import AppKit
import CoreGraphics
import Darwin
import Foundation

let app = NSApplication.shared
let target = UInt32(ProcessInfo.processInfo.environment["DUO_FIXTURE_DISPLAY"] ?? "3")!
let path = URL(fileURLWithPath: ProcessInfo.processInfo.environment["DUO_FIXTURE_STATE"]!)
let otherTarget = UInt32(ProcessInfo.processInfo.environment["DUO_FIXTURE_OTHER"] ?? "0")
let full = ProcessInfo.processInfo.environment["DUO_FIXTURE_FULLSCREEN"] == "1"
app.setActivationPolicy(full ? .regular : .accessory)

@MainActor func bounds(_ window: NSWindow) -> [Double]? {
    let rows = CGWindowListCopyWindowInfo(.optionOnScreenOnly, 0) as? [[String: Any]] ?? []
    guard let row = rows.first(where: { ($0[kCGWindowNumber as String] as? NSNumber)?.intValue == window.windowNumber }),
          let data = row[kCGWindowBounds as String] as? [String: Any], let rect = CGRect(dictionaryRepresentation: data as CFDictionary) else { return nil }
    return [rect.minX, rect.minY, rect.width, rect.height]
}

@MainActor final class Fixture: NSObject, NSWindowDelegate {
    var windows: [String: NSWindow] = [:]
    var entered = false
    var timer: Timer?
    func windowDidEnterFullScreen(_ notification: Notification) { entered = true; report() }
    func windowDidExitFullScreen(_ notification: Notification) { entered = false; report() }
    func report() {
        var state: [String: Any] = ["ready": !full || entered, "pid": ProcessInfo.processInfo.processIdentifier]
        for (key, window) in windows {
            state[key] = ["id": window.windowNumber,
                          "screen": (window.screen?.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber)?.uint32Value ?? 0,
                          "frame": bounds(window) as Any? ?? NSNull(),
                          "active": window.isOnActiveSpace, "fullscreen": window.styleMask.contains(.fullScreen)]
        }
        if let data = try? JSONSerialization.data(withJSONObject: state) { try? data.write(to: path, options: .atomic) }
    }
    func start() {
        for screen in NSScreen.screens {
            guard let id = (screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber)?.uint32Value,
                  id == target || id == (otherTarget == 0 ? CGMainDisplayID() : otherTarget) else { continue }
            let selected = id == target
            let window = NSWindow(contentRect: CGRect(x: screen.frame.minX + 80, y: screen.frame.minY + 80, width: 320, height: 200),
                                  styleMask: selected && full ? [.titled, .resizable, .closable] : [.borderless],
                                  backing: .buffered, defer: false, screen: screen)
            window.isReleasedWhenClosed = false; window.isRestorable = false; window.hasShadow = false
            window.backgroundColor = selected ? .systemBlue : .systemOrange
            window.title = selected ? "DUO selected desktop fixture" : "DUO other desktop fixture"
            window.setFrameOrigin(CGPoint(x: screen.frame.minX + 80, y: screen.frame.minY + 80))
            window.orderFrontRegardless()
            windows[selected ? "selected" : "other"] = window
        }
        if full, let window = windows["selected"] {
            window.delegate = self; window.collectionBehavior = [.fullScreenPrimary]
            window.makeKeyAndOrderFront(nil); app.activate(); window.toggleFullScreen(nil)
        }
        timer = Timer.scheduledTimer(withTimeInterval: 0.05, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.report() }
        }
        report()
    }
}
MainActor.assumeIsolated {
    let fixture = Fixture()
    fixture.start()
    withExtendedLifetime(fixture) { app.run() }
}
