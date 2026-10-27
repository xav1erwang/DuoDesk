// Copyright 2026 DUO你电脑 contributors. SPDX-License-Identifier: Apache-2.0
// A temporary secondary display for the owned-window sampling diagnostic only.
import AppKit

@MainActor
final class VirtualWindowDisplay {
    private let before: [[String: Double]]
    private var virtual: VirtualDisplay?
    private var displayID: CGDirectDisplayID = 0

    private static func snapshot() throws -> [[String: Double]] {
        var count: UInt32 = 0
        guard CGGetOnlineDisplayList(0, nil, &count) == .success, count > 0 else {
            throw failure("online display inventory unavailable")
        }
        var ids = [CGDirectDisplayID](repeating: 0, count: Int(count))
        guard CGGetOnlineDisplayList(count, &ids, &count) == .success,
              Int(count) == ids.count else { throw failure("display inventory changed") }
        return try ids.sorted().map { id in
            guard let mode = CGDisplayCopyDisplayMode(id), mode.refreshRate.isFinite else {
                throw failure("display mode unavailable")
            }
            let bounds = CGDisplayBounds(id)
            return ["id": Double(id), "main": id == CGMainDisplayID() ? 1 : 0,
                    "mode": Double(mode.ioDisplayModeID), "width": Double(mode.width), "height": Double(mode.height),
                    "pixelWidth": Double(mode.pixelWidth), "pixelHeight": Double(mode.pixelHeight), "hz": mode.refreshRate,
                    "x": bounds.origin.x, "y": bounds.origin.y, "boundsWidth": bounds.width, "boundsHeight": bounds.height,
                    "mirror": Double(CGDisplayMirrorsDisplay(id))]
        }
    }

    private static func failure(_ message: String) -> NSError {
        NSError(domain: "DuoVirtualWindowDiagnostic", code: 1, userInfo: [NSLocalizedDescriptionKey: message])
    }

    private static func printSnapshot(_ label: String, _ snapshot: [[String: Double]]) {
        if let data = try? JSONSerialization.data(withJSONObject: snapshot, options: [.sortedKeys]),
           let json = String(data: data, encoding: .utf8) { print("\(label): \(json)") }
    }

    init() throws {
        before = try Self.snapshot()
        Self.printSnapshot("VIRTUAL_WINDOW_DISPLAY_BEFORE", before)
    }

    func prepare(window: NSWindow) async throws {
        try await Task.sleep(for: .seconds(1))
        guard try Self.snapshot() == before else { throw Self.failure("display inventory changed before creation") }
        // Leave room for the title bar and menu area so the entire 1004×714 pt window
        // remains visible. The captured window, not this diagnostic display, is 2008×1428 px.
        let display = try VirtualDisplay(name: "DUO Own Window Diagnostic", widthPt: 1100, heightPt: 800,
                                         scale: 2, refreshHz: 120, vendorID: 0x4455,
                                         productID: 0x4f06, serialNum: 1)
        virtual = display
        displayID = display.displayID
        guard !before.contains(where: { $0["id"] == Double(displayID) }) else {
            throw Self.failure("temporary display reused an existing identifier")
        }
        guard await display.waitUntilOnline(), display.hasRequestedMode else {
            throw Self.failure("temporary virtual mode unavailable")
        }
        try checkOriginalDisplays()
        var target: NSScreen?
        for _ in 0..<30 {
            target = NSScreen.screens.first {
                ($0.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber)?.uint32Value == displayID
            }
            if target != nil { break }
            try await Task.sleep(for: .milliseconds(100))
        }
        guard let target else { throw Self.failure("temporary virtual NSScreen unavailable") }
        let visible = target.visibleFrame
        guard visible.width >= window.frame.width && visible.height >= window.frame.height else {
            throw Self.failure("temporary display cannot fit the full owned window")
        }
        window.setFrameOrigin(NSPoint(x: visible.midX - window.frame.width / 2,
                                      y: visible.midY - window.frame.height / 2))
        try await Task.sleep(for: .milliseconds(300))
        try checkOwnedWindow(window)
        print("VIRTUAL WINDOW READY: display=\(displayID), frame=\(target.frame), visible=\(visible), window=\(window.frame), screenFPS=\(target.maximumFramesPerSecond), requestedMode=\(display.hasRequestedMode)")
    }

    func checkOriginalDisplays() throws {
        let all = try Self.snapshot()
        guard displayID != 0, all.contains(where: { $0["id"] == Double(displayID) && $0["mirror"] == 0 }),
              virtual?.hasRequestedMode == true else {
            throw Self.failure("temporary display went offline, changed mode, or entered a mirror group")
        }
        let current = all.filter { $0["id"] != Double(displayID) }
        guard current == before else {
            Self.printSnapshot("VIRTUAL_WINDOW_DISPLAY_CHANGED", current)
            throw Self.failure("original display inventory changed; ending diagnostic")
        }
    }

    func checkOwnedWindow(_ window: NSWindow) throws {
        try checkOriginalDisplays()
        let actual = (window.screen?.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber)?.uint32Value
        guard actual == displayID else { throw Self.failure("owned window left the temporary display") }
    }

    func cleanup() async -> Bool {
        virtual?.destroy()
        virtual = nil
        var after: [[String: Double]] = []
        for _ in 0..<30 {
            after = (try? Self.snapshot()) ?? []
            if after == before && !after.contains(where: { $0["id"] == Double(displayID) }) { break }
            try? await Task.sleep(for: .milliseconds(100))
        }
        Self.printSnapshot("VIRTUAL_WINDOW_DISPLAY_AFTER", after)
        let restored = after == before && !after.contains(where: { $0["id"] == Double(displayID) })
        print("VIRTUAL_WINDOW_DISPLAY_EXACT_RESTORE: \(restored)")
        return restored
    }
}
