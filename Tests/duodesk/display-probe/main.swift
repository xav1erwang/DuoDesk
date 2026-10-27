// Default: disposable virtual displays only. --primary also verifies an existing desktop
// window on the real main display. Run that mode on the designated development Mac.
import AppKit
import CoreGraphics
import StreamProtocol

setbuf(stdout, nil)
let app = NSApplication.shared
app.setActivationPolicy(.accessory)
let usesPrimary = CommandLine.arguments.contains("--primary")
let switchesRate = CommandLine.arguments.contains("--rate-switch")
let slowNativeMode = CommandLine.arguments.contains("--slow-native")
let nativePrimary = CommandLine.arguments.contains("--native-primary")
let fullscreen = CommandLine.arguments.contains("--fullscreen")
let inspectsSpaces = CommandLine.arguments.contains("--inspect-spaces")

struct ProbeDisplayState: Equatable, CustomStringConvertible {
    let id: CGDirectDisplayID
    let mode: Int32
    let width: Int, height: Int, pixelWidth: Int, pixelHeight: Int
    let refresh: Double
    let origin: CGPoint
    let mirror: CGDirectDisplayID
    let main: Bool
    var description: String {
        "\(id):mode=\(mode),points=\(width)x\(height),pixels=\(pixelWidth)x\(pixelHeight),hz=\(refresh),origin=\(origin),mirror=\(mirror),main=\(main)"
    }
}

func onlineDisplayStates() -> [ProbeDisplayState]? {
    var count: UInt32 = 0
    guard CGGetOnlineDisplayList(0, nil, &count) == .success, count > 0 else { return nil }
    let expected = count
    var ids = [CGDirectDisplayID](repeating: 0, count: Int(expected))
    guard CGGetOnlineDisplayList(expected, &ids, &count) == .success, count == expected,
          Set(ids).count == ids.count, !ids.contains(kCGNullDirectDisplay) else { return nil }
    var result: [ProbeDisplayState] = []
    for id in ids.sorted() {
        guard CGDisplayIsOnline(id) > 0, let mode = CGDisplayCopyDisplayMode(id), mode.refreshRate.isFinite else { return nil }
        result.append(ProbeDisplayState(id: id, mode: mode.ioDisplayModeID, width: mode.width, height: mode.height,
                                        pixelWidth: mode.pixelWidth, pixelHeight: mode.pixelHeight,
                                        refresh: mode.refreshRate, origin: CGDisplayBounds(id).origin,
                                        mirror: CGDisplayMirrorsDisplay(id), main: CGMainDisplayID() == id))
    }
    return result
}

@MainActor
final class FullscreenObserver: NSObject, NSWindowDelegate {
    var entered = false
    var minimized = false
    func windowDidEnterFullScreen(_ notification: Notification) { entered = true }
    func windowDidExitFullScreen(_ notification: Notification) { entered = false }
    func windowDidMiniaturize(_ notification: Notification) { minimized = true }
    func windowDidDeminiaturize(_ notification: Notification) { minimized = false }
}

@MainActor
func waitForFullscreen(_ window: NSWindow, enabled: Bool, observer: FullscreenObserver) async throws {
    for _ in 0..<100 {
        if observer.entered == enabled, window.styleMask.contains(.fullScreen) == enabled, window.isOnActiveSpace { return }
        try await Task.sleep(for: .milliseconds(50))
    }
    throw DuoDesktopDisplay.Failure.displayUnavailable
}

@MainActor
func waitForMinimized(_ window: NSWindow, enabled: Bool, observer: FullscreenObserver) async throws {
    for _ in 0..<100 {
        if observer.minimized == enabled, window.isMiniaturized == enabled { return }
        try await Task.sleep(for: .milliseconds(50))
    }
    throw DuoDesktopDisplay.Failure.displayUnavailable
}

@MainActor
func ownWindowBounds(_ window: NSWindow) -> CGRect? {
    let windows = CGWindowListCopyWindowInfo([.optionOnScreenOnly, .excludeDesktopElements], kCGNullWindowID) as? [[String: Any]] ?? []
    guard let own = windows.first(where: { ($0[kCGWindowNumber as String] as? NSNumber)?.intValue == window.windowNumber }),
          let bounds = own[kCGWindowBounds as String] as? [String: Any] else { return nil }
    return CGRect(dictionaryRepresentation: bounds as CFDictionary)
}

Task { @MainActor in
    var fakeMac: VirtualDisplay?
    var session: DuoDesktopDisplay?
    var fixture: NSWindow?
    var minimized: NSWindow?
    var newWindow: NSWindow?
    var secondaryWindow: NSWindow?
    var secondaryID: CGDirectDisplayID?
    var secondaryBounds: CGRect?
    var originalFixtureBounds: CGRect?
    var spaceAudit: DisplaySpaceAudit?
    let fullscreenObserver = FullscreenObserver()
    let physical = CGMainDisplayID()
    let physicalMode = CGDisplayCopyDisplayMode(physical)
    let physicalOrigin = CGDisplayBounds(physical).origin
    let beforeDisplays = onlineDisplayStates()
    do {
        guard let physicalMode, let beforeDisplays else { throw DuoDesktopDisplay.Failure.noDisplay }
        print("DISPLAY PROBE INVENTORY BEFORE: \(beforeDisplays)")
        guard !usesPrimary || !slowNativeMode else { throw DuoDesktopDisplay.Failure.invalidResolution }
        guard !fullscreen || usesPrimary else { throw DuoDesktopDisplay.Failure.invalidResolution }
        guard !inspectsSpaces || (fullscreen && usesPrimary && nativePrimary) else { throw DuoDesktopDisplay.Failure.invalidResolution }
        if inspectsSpaces { spaceAudit = try DisplaySpaceAudit() }
        print("Graphics baseline: main=\(physical), pixels=\(physicalMode.pixelWidth)×\(physicalMode.pixelHeight), origin=\(physicalOrigin), primaryTest=\(usesPrimary)")
        let target: CGDirectDisplayID
        if usesPrimary {
            target = physical
            guard let screen = NSScreen.screens.first(where: { ($0.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber)?.uint32Value == physical }) else {
                throw DuoDesktopDisplay.Failure.noDisplay
            }
            let window = NSWindow(contentRect: CGRect(x: screen.frame.minX + 80, y: screen.frame.minY + 80, width: 320, height: 200),
                                  styleMask: fullscreen ? [.titled, .resizable, .closable, .miniaturizable] : [.borderless], backing: .buffered, defer: false)
            fixture = window
            window.isReleasedWhenClosed = false
            window.title = "DUO disposable desktop fixture"
            window.backgroundColor = .systemBlue
            window.orderFrontRegardless()
            if fullscreen {
                app.setActivationPolicy(.regular)
                window.delegate = fullscreenObserver
                window.collectionBehavior = [.fullScreenPrimary]
                window.makeKeyAndOrderFront(nil)
                app.activate()
                window.toggleFullScreen(nil)
                try await waitForFullscreen(window, enabled: true, observer: fullscreenObserver)
                print("Fullscreen fixture: entered the original main display's full-screen Space")
            }
            if nativePrimary, !fullscreen {
                let mini = NSWindow(contentRect: CGRect(x: screen.frame.minX + 430, y: screen.frame.minY + 100, width: 260, height: 180),
                                    styleMask: [.titled, .miniaturizable, .closable], backing: .buffered, defer: false)
                minimized = mini; mini.isReleasedWhenClosed = false; mini.isRestorable = false
                mini.delegate = fullscreenObserver
                mini.title = "DUO minimized window continuity fixture"; mini.orderFrontRegardless(); mini.miniaturize(nil)
                try await waitForMinimized(mini, enabled: true, observer: fullscreenObserver)
                if let other = NSScreen.screens.first(where: {
                    let id = ($0.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber)?.uint32Value ?? 0
                    return id != physical && CGDisplayMirrorsDisplay(id) == kCGNullDirectDisplay
                }), let id = (other.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber)?.uint32Value {
                    let side = NSWindow(contentRect: CGRect(x: other.frame.minX + 90, y: other.frame.minY + 90, width: 260, height: 160),
                                        styleMask: [.borderless], backing: .buffered, defer: false)
                    secondaryWindow = side; secondaryID = id; side.isReleasedWhenClosed = false; side.isRestorable = false
                    side.title = "DUO secondary display continuity fixture"; side.orderFrontRegardless()
                }
            }
        } else {
            let fake = try VirtualDisplay(name: "DUO graphics test only", widthPt: slowNativeMode ? 1004 : 1280,
                                          heightPt: slowNativeMode ? 714 : 800,
                                          scale: 2, refreshHz: slowNativeMode ? 60 : 120,
                                          vendorID: 0x4455, productID: 0x4F02, serialNum: 1)
            fakeMac = fake
            guard await fake.waitUntilOnline() else { throw DuoDesktopDisplay.Failure.modeRejected }
            var config: CGDisplayConfigRef?
            guard CGBeginDisplayConfiguration(&config) == .success, let config else { throw DuoDesktopDisplay.Failure.modeRejected }
            CGConfigureDisplayOrigin(config, fake.displayID, 10000, 0)
            guard CGCompleteDisplayConfiguration(config, .forSession) == .success else { throw DuoDesktopDisplay.Failure.modeRejected }
            target = fake.displayID
        }
        try await Task.sleep(for: .milliseconds(100))
        if let minimized, !minimized.isMiniaturized { throw DuoDesktopDisplay.Failure.displayUnavailable }
        if let fixture {
            for _ in 0..<40 {
                if let bounds = ownWindowBounds(fixture) { originalFixtureBounds = bounds; break }
                try await Task.sleep(for: .milliseconds(50))
            }
            // A missing initial frame must fail setup, never skip the restoration assertions.
            guard originalFixtureBounds != nil else { throw DuoDesktopDisplay.Failure.displayUnavailable }
        }
        if let secondaryWindow { secondaryBounds = ownWindowBounds(secondaryWindow) }
        let baseline = CGDisplayCopyDisplayMode(target)
        if let fixture { try spaceAudit?.record("before", window: fixture, expectedDisplay: target) }
        let test = DuoDesktopDisplay(mainDisplay: { target }, layout: nativePrimary ? .nativePrimary : .mirrored)
        session = test
        guard !test.followsNativeCadence else { throw DuoDesktopDisplay.Failure.modeRejected }
        let native = DuoDesktopResolution(width: 2007, height: 1427)
        var master = try await test.prepareGraphics(native, fps: switchesRate ? 60 : 120)
        let correctRole = nativePrimary ? CGDisplayMirrorsDisplay(target) == kCGNullDirectDisplay : CGDisplayMirrorsDisplay(target) == master
        guard test.activeModeMatches, master == target || correctRole else { throw DuoDesktopDisplay.Failure.modeRejected }
        guard test.followsNativeCadence,
              test.usesIndependentCaptureFilter == nativePrimary else { throw DuoDesktopDisplay.Failure.modeRejected }
        print("Native sampling: exact negotiated desktop clock; no additional 1/fps interval; filter choice unchanged")
        if let window = fixture {
            var visible = false
            for _ in 0..<20 {
                if let bounds = ownWindowBounds(window) {
                    let intersection = bounds.intersection(CGDisplayBounds(master))
                    visible = window.isVisible && !intersection.isNull && intersection.width * intersection.height >= bounds.width * bounds.height * 0.95
                    if visible { break }
                }
                try await Task.sleep(for: .milliseconds(50))
            }
            print("Graphics fixture: own window \(String(describing: ownWindowBounds(window))), native master \(CGDisplayBounds(master)), main=\(CGMainDisplayID())")
            if let spaceAudit {
                let ownership = try spaceAudit.record("prepared", window: window, expectedDisplay: master)
                guard ownership.spaces == spaceAudit.originalSpaces else {
                    throw DisplaySpaceAudit.Failure(message: "The original full-screen Space ID changed")
                }
                guard ownership.ownsExpectedDisplay else {
                    throw DisplaySpaceAudit.Failure(message: "Original full-screen Space remains on another display; activation cannot migrate it")
                }
                if !window.isOnActiveSpace {
                    // Only activate this process's window if its original Space already belongs
                    // to the native target. Never substitute a new fullscreen Space or change
                    // another process's windows with private Space mutation APIs.
                    window.makeKeyAndOrderFront(nil)
                    app.activate()
                    try await waitForFullscreen(window, enabled: true, observer: fullscreenObserver)
                    try spaceAudit.record("activated", window: window, expectedDisplay: master)
                    if let bounds = ownWindowBounds(window) {
                        let intersection = bounds.intersection(CGDisplayBounds(master))
                        visible = !intersection.isNull && intersection.width * intersection.height >= bounds.width * bounds.height * 0.95
                    }
                }
            }
            guard visible, CGMainDisplayID() == master else { throw DuoDesktopDisplay.Failure.displayUnavailable }
            if fullscreen {
                guard window.styleMask.contains(.fullScreen), window.isOnActiveSpace else { throw DuoDesktopDisplay.Failure.displayUnavailable }
                let restoredSpace = try spaceAudit?.record("restored", window: window, expectedDisplay: physical)
                if let restoredSpace {
                    guard restoredSpace.spaces == spaceAudit?.originalSpaces, restoredSpace.ownsExpectedDisplay else {
                        throw DisplaySpaceAudit.Failure(message: "Original full-screen Space identity or owner did not restore")
                    }
                }
                print("Fullscreen continuity: existing full-screen Space remains active on the native main desktop")
            }
        }
        if let side = secondaryWindow, let id = secondaryID {
            // AppKit learns each display move asynchronously; a synchronous CG transaction alone
            // does not mean every NSWindow has processed its screen-change notification yet.
            for _ in 0..<20 {
                if let bounds = ownWindowBounds(side), CGDisplayBounds(id).intersection(bounds).size == bounds.size { break }
                try await Task.sleep(for: .milliseconds(50))
            }
            let screen = (side.screen?.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber)?.uint32Value
            print("Secondary fixture: expected=\(id), screen=\(screen ?? 0), window=\(String(describing: ownWindowBounds(side))), display=\(CGDisplayBounds(id))")
            guard side.isVisible, screen == id, let bounds = ownWindowBounds(side),
                  CGDisplayBounds(id).intersection(bounds).size == bounds.size else { throw DuoDesktopDisplay.Failure.displayUnavailable }
            print("Secondary continuity: existing window stayed on its original display \(id)")
        }
        if nativePrimary, usesPrimary, !fullscreen {
            // A window created after connection and an old minimized window must both be usable
            // on the native main desktop, rather than quietly opening on a physical side screen.
            let fresh = NSWindow(contentRect: CGRect(x: 440, y: 70, width: 260, height: 180),
                                 styleMask: [.titled, .closable], backing: .buffered, defer: false)
            fresh.isReleasedWhenClosed = false; fresh.isRestorable = false
            fresh.title = "DUO window created after connection"; fresh.orderFrontRegardless(); newWindow = fresh
            minimized?.deminiaturize(nil)
            if let minimized { try await waitForMinimized(minimized, enabled: false, observer: fullscreenObserver) }
            for window in [fresh, minimized].compactMap({ $0 }) {
                let screen = (window.screen?.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber)?.uint32Value
                print("Native window continuity: \(window.title), screen=\(screen ?? 0), bounds=\(String(describing: ownWindowBounds(window)))")
                guard window.isVisible, screen == master, let bounds = ownWindowBounds(window),
                      CGDisplayBounds(master).intersection(bounds).size == bounds.size else { throw DuoDesktopDisplay.Failure.displayUnavailable }
            }
        }
        if slowNativeMode {
            let rate = CGDisplayCopyDisplayMode(master)?.refreshRate ?? 0
            print("Native-size slow display: original=60 Hz, prepared=\(rate) Hz, master=\(master), target=\(target)")
            guard rate >= 119.5, master != target else { throw DuoDesktopDisplay.Failure.modeRejected }
        }
        if switchesRate {
            for rate in [120, 60, 120] {
                let previous = master
                master = try await test.prepareGraphics(native, fps: rate)
                let actual = CGDisplayCopyDisplayMode(master)?.refreshRate ?? 0
                print("Graphics rate switch: requested=\(rate), actual=\(actual), master=\(master)")
                guard abs(actual - Double(rate)) < 0.5 else { throw DuoDesktopDisplay.Failure.modeRejected }
                guard test.followsNativeCadence else { throw DuoDesktopDisplay.Failure.modeRejected }
                if previous != target, master != previous { throw DuoDesktopDisplay.Failure.modeRejected }
            }
        }
        let same = try await test.prepareGraphics(native, fps: 120)
        guard same == master else { throw DuoDesktopDisplay.Failure.modeRejected }
        guard test.restore(), test.restore(), CGDisplayMirrorsDisplay(target) == kCGNullDirectDisplay,
              let restored = CGDisplayCopyDisplayMode(target),
              restored.pixelWidth == baseline?.pixelWidth, restored.pixelHeight == baseline?.pixelHeight else {
            throw DuoDesktopDisplay.Failure.modeRejected
        }
        guard !test.followsNativeCadence else { throw DuoDesktopDisplay.Failure.modeRejected }
        // Virtual-master removal and WindowServer notifications must not later undo restoration.
        try await Task.sleep(for: .seconds(1.5))
        if usesPrimary, let window = fixture, let before = originalFixtureBounds {
            let screen = (window.screen?.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber)?.uint32Value
            print("Desktop restore fixture: screen=\(screen ?? 0), visible=\(window.isVisible), fullScreen=\(window.styleMask.contains(.fullScreen)), activeSpace=\(window.isOnActiveSpace), before=\(before), after=\(String(describing: ownWindowBounds(window)))")
            guard screen == physical, let after = ownWindowBounds(window),
                  abs(after.minX - before.minX) < 2, abs(after.minY - before.minY) < 2,
                  after.size == before.size else { throw DuoDesktopDisplay.Failure.displayUnavailable }
            print("Desktop restore: original window returned to its original screen and frame")
            if fullscreen {
                guard window.styleMask.contains(.fullScreen), window.isOnActiveSpace else { throw DuoDesktopDisplay.Failure.displayUnavailable }
                print("Fullscreen restore: original full-screen Space and frame restored")
                window.toggleFullScreen(nil)
                try await waitForFullscreen(window, enabled: false, observer: fullscreenObserver)
            }
            for other in [minimized, newWindow].compactMap({ $0 }) {
                let restoredScreen = (other.screen?.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber)?.uint32Value
                print("Other window restore: \(other.title), screen=\(restoredScreen ?? 0), visible=\(other.isVisible), miniaturized=\(other.isMiniaturized), bounds=\(String(describing: ownWindowBounds(other)))")
                guard other.isVisible, restoredScreen == physical else { throw DuoDesktopDisplay.Failure.displayUnavailable }
            }
        }
        if let side = secondaryWindow, let id = secondaryID, let before = secondaryBounds {
            let screen = (side.screen?.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber)?.uint32Value
            print("Secondary restore fixture: expected=\(id), screen=\(screen ?? 0), before=\(before), after=\(String(describing: ownWindowBounds(side)))")
            guard side.isVisible, screen == id, let after = ownWindowBounds(side),
                  abs(after.minX - before.minX) < 2, abs(after.minY - before.minY) < 2, after.size == before.size else {
                throw DuoDesktopDisplay.Failure.displayUnavailable
            }
            print("Secondary restore: original screen and exact window frame restored")
        }
        fixture?.close()
        minimized?.close(); newWindow?.close()
        secondaryWindow?.close()
        fakeMac?.destroy()
        var afterDisplays: [ProbeDisplayState]?
        for _ in 0..<30 {
            afterDisplays = onlineDisplayStates()
            if afterDisplays == beforeDisplays { break }
            try await Task.sleep(for: .milliseconds(100))
        }
        print("DISPLAY PROBE INVENTORY AFTER: \(String(describing: afterDisplays))")
        guard let current = CGDisplayCopyDisplayMode(physical),
              current.ioDisplayModeID == physicalMode.ioDisplayModeID,
              current.pixelWidth == physicalMode.pixelWidth, current.pixelHeight == physicalMode.pixelHeight,
              current.refreshRate == physicalMode.refreshRate, afterDisplays == beforeDisplays,
              CGDisplayBounds(physical).origin == physicalOrigin, CGMainDisplayID() == physical else { throw DuoDesktopDisplay.Failure.modeRejected }
        print("DUO graphics PASS: exact native pixels, repeated prepare, original display restored; existing primary window \(usesPrimary ? "verified" : "not tested in disposable mode")")
        try spaceAudit?.finish(passed: true, cleanupRestored: true)
        exit(0)
    } catch {
        let restored = session?.restore() ?? true
        if let fixture, fixture.styleMask.contains(.fullScreen) {
            if let spaceAudit {
                try? await waitForFullscreen(fixture, enabled: true, observer: fullscreenObserver)
                _ = try? spaceAudit.record("failure-restored", window: fixture, expectedDisplay: physical)
            }
            fixture.toggleFullScreen(nil)
            try? await waitForFullscreen(fixture, enabled: false, observer: fullscreenObserver)
        }
        fixture?.close()
        minimized?.close(); newWindow?.close()
        secondaryWindow?.close()
        fakeMac?.destroy()
        let restoredMode = CGDisplayCopyDisplayMode(physical)
        let exact = restored && restoredMode?.ioDisplayModeID == physicalMode?.ioDisplayModeID
            && restoredMode?.refreshRate == physicalMode?.refreshRate
            && CGDisplayBounds(physical).origin == physicalOrigin && CGMainDisplayID() == physical
            && onlineDisplayStates() == beforeDisplays
        try? spaceAudit?.finish(passed: false, cleanupRestored: exact, error: error.localizedDescription)
        print("DUO graphics FAILED: \(error.localizedDescription); cleanup restored=\(restored)")
        exit(1)
    }
}
app.run()
