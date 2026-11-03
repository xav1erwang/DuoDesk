// Copyright 2026 DUO你电脑 contributors. SPDX-License-Identifier: Apache-2.0
// Creates and removes one independent virtual display. It does not capture pixels, inject input,
// or intentionally configure an existing display. Run only on the authorized development Mac.
import AppKit
import CoreGraphics
import Foundation
import StreamProtocol

struct ExistingDisplay: Equatable {
    let id: CGDirectDisplayID
    let mode: Int32
    let width: Int
    let height: Int
    let pixelWidth: Int
    let pixelHeight: Int
    let refresh: Double
    let origin: CGPoint
    let mirror: CGDirectDisplayID
    let main: Bool

    static func read(_ id: CGDirectDisplayID) -> ExistingDisplay? {
        guard CGDisplayIsOnline(id) > 0, let mode = CGDisplayCopyDisplayMode(id) else { return nil }
        return ExistingDisplay(id: id, mode: mode.ioDisplayModeID, width: mode.width, height: mode.height,
                               pixelWidth: mode.pixelWidth, pixelHeight: mode.pixelHeight, refresh: mode.refreshRate,
                               origin: CGDisplayBounds(id).origin, mirror: CGDisplayMirrorsDisplay(id),
                               main: CGMainDisplayID() == id)
    }
}

func existingDisplays() -> [ExistingDisplay]? {
    var count: UInt32 = 0
    guard CGGetOnlineDisplayList(0, nil, &count) == .success, count > 0 else { return nil }
    let expected = count
    var ids = [CGDirectDisplayID](repeating: 0, count: Int(expected))
    guard CGGetOnlineDisplayList(expected, &ids, &count) == .success, count == expected,
          !ids.contains(kCGNullDirectDisplay), Set(ids).count == ids.count else { return nil }
    let displays = ids.compactMap(ExistingDisplay.read).sorted { $0.id < $1.id }
    return displays.count == ids.count ? displays : nil
}

final class DisplayMonitor: @unchecked Sendable {
    private let lock = NSLock()
    private let baseline: [CGDirectDisplayID: ExistingDisplay]
    private var changed = false
    private var modeEvents = 0
    private var afterEvents = 0
    init(_ displays: [ExistingDisplay]) { baseline = Dictionary(uniqueKeysWithValues: displays.map { ($0.id, $0) }) }
    func observe(_ id: CGDirectDisplayID, _ flags: CGDisplayChangeSummaryFlags) {
        guard let before = baseline[id], !flags.contains(.beginConfigurationFlag) else { return }
        let after = ExistingDisplay.read(id)
        lock.lock()
        afterEvents += 1
        if flags.contains(.setModeFlag) { modeEvents += 1 }
        if after != before { changed = true }
        lock.unlock()
    }
    func result() -> (changed: Bool, modeEvents: Int, afterEvents: Int) {
        lock.lock(); defer { lock.unlock() }
        return (changed, modeEvents, afterEvents)
    }
}

let callback: CGDisplayReconfigurationCallBack = { id, flags, context in
    guard let context else { return }
    Unmanaged<DisplayMonitor>.fromOpaque(context).takeUnretainedValue().observe(id, flags)
}

setbuf(stdout, nil)
let app = NSApplication.shared
app.setActivationPolicy(.prohibited)
let requestedFPS = CommandLine.arguments.contains("--fps=120") ? 120 : 60
Task { @MainActor in
    guard let before = existingDisplays(), before == existingDisplays() else {
        print("EXTENDED PROBE FAIL: existing display inventory is unstable")
        exit(1)
    }
    let monitor = DisplayMonitor(before)
    let context = Unmanaged.passUnretained(monitor).toOpaque()
    guard CGDisplayRegisterReconfigurationCallback(callback, context) == .success else {
        print("EXTENDED PROBE FAIL: could not observe display changes")
        exit(1)
    }
    let desktop = DuoDesktopDisplay(layout: .extended)
    var virtualID: CGDirectDisplayID = 0
    var prepared = false
    do {
        virtualID = try await desktop.prepareGraphics(DuoDesktopResolution(width: 2007, height: 2853), fps: requestedFPS)
        let mode = CGDisplayCopyDisplayMode(virtualID)
        prepared = desktop.isExtendedLayout && desktop.activeModeMatches
            && CGDisplayMirrorsDisplay(virtualID) == kCGNullDirectDisplay
            && mode?.pixelWidth == 2008 && mode?.pixelHeight == 2854 && mode?.refreshRate == Double(requestedFPS)
            && before.allSatisfy { ExistingDisplay.read($0.id) == $0 }
        print("EXTENDED PROBE: created=\(prepared), new display=\(virtualID), pixels=\(mode?.pixelWidth ?? 0)×\(mode?.pixelHeight ?? 0), virtualHz=\(mode?.refreshRate ?? 0)")
    } catch {
        print("EXTENDED PROBE: create failed: \(error.localizedDescription)")
    }
    let removed = desktop.restore()
    for _ in 0..<30 where virtualID != 0 && CGDisplayIsOnline(virtualID) > 0 {
        try? await Task.sleep(for: .milliseconds(100))
    }
    // Allow the event-processing loop to deliver the final post-reconfiguration callbacks.
    try? await Task.sleep(for: .milliseconds(500))
    let after = existingDisplays()
    let observations = monitor.result()
    CGDisplayRemoveReconfigurationCallback(callback, context)
    let restored = after == before && (virtualID == 0 || CGDisplayIsOnline(virtualID) <= 0)
    print("EXTENDED PROBE: removed=\(removed), original displays unchanged=\(restored), physical mode events=\(observations.modeEvents), observed post events=\(observations.afterEvents), observed drift=\(observations.changed)")
    guard prepared && removed && restored && !observations.changed && observations.modeEvents == 0 && observations.afterEvents > 0 else {
        print("EXTENDED PROBE FAIL")
        exit(1)
    }
    print("EXTENDED PROBE PASS: one independent virtual display; no capture, input or physical mode writes")
    exit(0)
}
app.run()
