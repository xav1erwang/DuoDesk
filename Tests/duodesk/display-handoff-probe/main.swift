// Copyright 2026 DUO你电脑 contributors. SPDX-License-Identifier: Apache-2.0
// Real WindowServer experiment, restricted to displays created by this process.
// SPI ABI: current macOS 27 SDK exports CGSConfigureDisplayEnabled; its C declaration
// is also published in https://github.com/jakehilborn/displayplacer/blob/master/src/Header.h.
// No displayplacer implementation is included. Never pass a physical display to this probe.
import AppKit
import CoreGraphics
import Darwin
import Foundation
import StreamProtocol

setbuf(stdout, nil)
let app = NSApplication.shared
app.setActivationPolicy(.regular)

@MainActor
enum OwnedDisplayActivation {
    typealias Configure = @convention(c) (CGDisplayConfigRef?, CGDirectDisplayID, Bool) -> CGError

    static func availableFunction() throws -> Configure {
        guard ProcessInfo.processInfo.operatingSystemVersion.majorVersion == 27,
              let symbol = dlsym(UnsafeMutableRawPointer(bitPattern: -2), "CGSConfigureDisplayEnabled") else {
            throw failure("Display-enable SPI unavailable on the verified OS/ABI")
        }
        return unsafeBitCast(symbol, to: Configure.self)
    }

    static func set(_ display: VirtualDisplay, enabled: Bool, excluding originalIDs: Set<CGDirectDisplayID>) throws {
        guard display.isAlive, display.displayID != 0, !originalIDs.contains(display.displayID) else {
            throw failure("Only a live virtual display owned by this process may be changed")
        }
        let configure = try availableFunction()
        var transaction: CGDisplayConfigRef?
        guard CGBeginDisplayConfiguration(&transaction) == .success, let transaction else {
            throw failure("Could not begin owned-display transaction")
        }
        let result = configure(transaction, display.displayID, enabled)
        guard result == .success else {
            CGCancelDisplayConfiguration(transaction)
            throw failure("Display-enable SPI rejected operation: \(result.rawValue)")
        }
        let committed = CGCompleteDisplayConfiguration(transaction, .forSession)
        guard committed == .success else {
            throw failure("Owned-display transaction failed: \(committed.rawValue)")
        }
    }
}

func failure(_ message: String) -> NSError {
    NSError(domain: "DuoOwnedDisplayHandoff", code: 1, userInfo: [NSLocalizedDescriptionKey: message])
}

struct DisplaySnapshot: Equatable {
    let id: CGDirectDisplayID
    let main: Bool
    let mode: Int32
    let pixels: CGSize
    let points: CGSize
    let hz: Double
    let bounds: CGRect
    let mirror: CGDirectDisplayID

    init?(_ id: CGDirectDisplayID) {
        guard let current = CGDisplayCopyDisplayMode(id) else { return nil }
        self.id = id
        main = CGMainDisplayID() == id
        mode = current.ioDisplayModeID
        pixels = CGSize(width: current.pixelWidth, height: current.pixelHeight)
        points = CGSize(width: current.width, height: current.height)
        hz = current.refreshRate
        bounds = CGDisplayBounds(id)
        mirror = CGDisplayMirrorsDisplay(id)
    }

    var evidence: [String: Any] {
        ["id": id, "main": main, "mode": mode, "pixels": [pixels.width, pixels.height],
         "points": [points.width, points.height], "hz": hz,
         "bounds": [bounds.minX, bounds.minY, bounds.width, bounds.height], "mirror": mirror]
    }
}

func onlineIDs() throws -> [CGDirectDisplayID] {
    var count: UInt32 = 0
    guard CGGetOnlineDisplayList(0, nil, &count) == .success else { throw failure("Display inventory failed") }
    var ids = [CGDirectDisplayID](repeating: 0, count: Int(count))
    guard CGGetOnlineDisplayList(count, &ids, &count) == .success else { throw failure("Display inventory changed") }
    return Array(ids.prefix(Int(count))).sorted()
}

@MainActor
final class FullscreenObserver: NSObject, NSWindowDelegate {
    var entered = false
    func windowDidEnterFullScreen(_ notification: Notification) { entered = true }
    func windowDidExitFullScreen(_ notification: Notification) { entered = false }
}

@MainActor
func waitFor(_ label: String, _ predicate: () -> Bool) async throws {
    for _ in 0..<100 {
        if predicate() { return }
        try await Task.sleep(for: .milliseconds(50))
    }
    throw failure("Timed out: \(label)")
}

@MainActor
func windowBounds(_ window: NSWindow) -> CGRect? {
    let list = CGWindowListCopyWindowInfo([.optionOnScreenOnly, .excludeDesktopElements], kCGNullWindowID) as? [[String: Any]] ?? []
    guard let row = list.first(where: { ($0[kCGWindowNumber as String] as? NSNumber)?.intValue == window.windowNumber }),
          let bounds = row[kCGWindowBounds as String] as? [String: Any] else { return nil }
    return CGRect(dictionaryRepresentation: bounds as CFDictionary)
}

@MainActor
func visibleFullscreen(_ window: NSWindow, on display: CGDirectDisplayID, observer: FullscreenObserver) -> Bool {
    guard observer.entered, window.styleMask.contains(.fullScreen), window.isOnActiveSpace,
          let bounds = windowBounds(window) else { return false }
    let intersection = bounds.intersection(CGDisplayBounds(display))
    return !intersection.isNull && intersection.width * intersection.height >= bounds.width * bounds.height * 0.95
}

@MainActor
func describe(_ display: CGDirectDisplayID, window: NSWindow) -> [String: Any] {
    let mode = CGDisplayCopyDisplayMode(display)
    let rect = CGDisplayBounds(display)
    return ["displayID": display, "online": CGDisplayIsOnline(display), "active": CGDisplayIsActive(display),
            "mirror": CGDisplayMirrorsDisplay(display), "pixels": [mode?.pixelWidth ?? 0, mode?.pixelHeight ?? 0],
            "hz": mode?.refreshRate ?? 0, "bounds": [rect.minX, rect.minY, rect.width, rect.height],
            "windowScreen": (window.screen?.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber)?.uint32Value ?? 0,
            "windowFullscreen": window.styleMask.contains(.fullScreen), "windowActive": window.isOnActiveSpace,
            "windowBounds": windowBounds(window).map { [$0.minX, $0.minY, $0.width, $0.height] } ?? []]
}

Task { @MainActor in
    let output = URL(fileURLWithPath: ProcessInfo.processInfo.environment["DUODESK_HANDOFF_REPORT"]
                     ?? "Temp/AirAcceptance-20261026/display-handoff.json")
    var report: [String: Any] = ["experiment": "suspend-owned-mirror-source",
                                "captureOrInputPermissionRequested": false, "nativePixels": [2008, 1428],
                                "performanceAcceptance": false, "sourceSuspensionAttempted": false]
    var source: VirtualDisplay?
    var desktop: DuoDesktopDisplay?
    var window: NSWindow?
    var sourceMayBeDisabled = false
    var originalIDs: Set<CGDirectDisplayID> = []
    var originals: [DisplaySnapshot] = []
    var problem: String?
    let observer = FullscreenObserver()
    do {
        _ = try OwnedDisplayActivation.availableFunction()
        let ids = try onlineIDs()
        originalIDs = Set(ids)
        originals = ids.compactMap(DisplaySnapshot.init)
        guard originals.count == ids.count else { throw failure("Incomplete baseline") }
        report["originalDisplays"] = originals.map(\.evidence)
        let fake = try VirtualDisplay(name: "DUO owned handoff source", widthPt: 1280, heightPt: 800,
                                      scale: 2, refreshHz: 60, vendorID: 0x4455, productID: 0x4F04, serialNum: 0x20261026)
        source = fake
        guard await fake.waitUntilOnline(), !originalIDs.contains(fake.displayID) else { throw failure("Owned source unavailable") }
        let x = originals.map(\.bounds.maxX).max() ?? 0
        guard let origin = Int32(exactly: x + 256) else { throw failure("Invalid fixture origin") }
        var placement: CGDisplayConfigRef?
        guard CGBeginDisplayConfiguration(&placement) == .success, let placement else { throw failure("Fixture placement failed") }
        let positioned = CGConfigureDisplayOrigin(placement, fake.displayID, origin, 0)
        guard positioned == .success else { CGCancelDisplayConfiguration(placement); throw failure("Fixture origin rejected") }
        guard CGCompleteDisplayConfiguration(placement, .forSession) == .success else { throw failure("Fixture placement not committed") }
        try await waitFor("owned screen in AppKit") {
            NSScreen.screens.contains { ($0.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber)?.uint32Value == fake.displayID }
        }
        guard let screen = NSScreen.screens.first(where: {
            ($0.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber)?.uint32Value == fake.displayID
        }) else { throw failure("Owned screen missing") }
        let fixture = NSWindow(contentRect: CGRect(x: screen.frame.minX + 80, y: screen.frame.minY + 80, width: 500, height: 300),
                               styleMask: [.titled, .resizable, .closable], backing: .buffered, defer: false, screen: screen)
        window = fixture
        fixture.isReleasedWhenClosed = false
        fixture.isRestorable = false
        fixture.title = "DUO owned full-screen handoff fixture"
        fixture.backgroundColor = .systemTeal
        fixture.delegate = observer
        fixture.collectionBehavior = [.fullScreenPrimary]
        fixture.makeKeyAndOrderFront(nil)
        app.activate()
        try await waitFor("fixture on owned source") {
            (fixture.screen?.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber)?.uint32Value == fake.displayID
        }
        fixture.toggleFullScreen(nil)
        try await waitFor("initial full-screen completion") { visibleFullscreen(fixture, on: fake.displayID, observer: observer) }
        report["initial"] = describe(fake.displayID, window: fixture)
        let session = DuoDesktopDisplay(mainDisplay: { fake.displayID })
        desktop = session
        let master = try await session.prepareGraphics(DuoDesktopResolution(width: 2007, height: 1427), fps: 120)
        guard !originalIDs.contains(master), master != fake.displayID, session.activeModeMatches else { throw failure("Native mirror not established") }
        report["mirroredSource"] = describe(fake.displayID, window: fixture)
        report["mirroredMaster"] = describe(master, window: fixture)
        // A secondary display's full-screen Space need not move on mirroring. The experiment
        // is whether suspending that source hands it to the master, so record this intermediate
        // state instead of requiring the outcome before exercising the handoff.
        report["fullscreenVisibleBeforeSuspension"] = visibleFullscreen(fixture, on: master, observer: observer)
        guard originals == originalIDs.sorted().compactMap(DisplaySnapshot.init) else {
            throw failure("Real display topology or configuration changed; source suspension not attempted")
        }
        sourceMayBeDisabled = true
        report["sourceSuspensionAttempted"] = true
        try OwnedDisplayActivation.set(fake, enabled: false, excluding: originalIDs)
        report["immediatelySuspendedSource"] = describe(fake.displayID, window: fixture)
        report["immediatelySuspendedMaster"] = describe(master, window: fixture)
        try await waitFor("native master after source suspension") {
            CGDisplayIsOnline(master) != 0 && visibleFullscreen(fixture, on: master, observer: observer)
        }
        guard let mode = CGDisplayCopyDisplayMode(master), mode.pixelWidth == 2008, mode.pixelHeight == 1428,
              abs(mode.refreshRate - 120) < 0.5 else { throw failure("Native canvas or clock changed") }
        report["suspendedSource"] = describe(fake.displayID, window: fixture)
        report["suspendedMaster"] = describe(master, window: fixture)
        guard originals == originalIDs.sorted().compactMap(DisplaySnapshot.init) else { throw failure("A real display changed") }
        report["handoffObserved"] = true
        // Public window lifecycle/geometry is observed; private Space IDs are not asserted.
        report["spaceIDIdentityVerified"] = false
        print("Owned-display handoff: native full-screen window remains active after source suspension")
    } catch {
        problem = error.localizedDescription
        report["handoffObserved"] = false
        if let window, let source { report["failedSource"] = describe(source.displayID, window: window) }
        let atFailure = originalIDs.sorted().compactMap(DisplaySnapshot.init)
        report["originalDisplaysAtFailure"] = atFailure.map(\.evidence)
        report["originalDisplaysDifferedAtFailure"] = originals != atFailure
    }

    if let source, sourceMayBeDisabled {
        do { try OwnedDisplayActivation.set(source, enabled: true, excluding: originalIDs) }
        catch { problem = [problem, "Source re-enable: \(error.localizedDescription)"].compactMap { $0 }.joined(separator: "; ") }
    }
    if let desktop, !desktop.restore() { problem = [problem, "Mirror restoration failed"].compactMap { $0 }.joined(separator: "; ") }
    if let window, let source, observer.entered {
        do {
            try await waitFor("restored owned full-screen window") { visibleFullscreen(window, on: source.displayID, observer: observer) }
            report["restoredWindow"] = describe(source.displayID, window: window)
        } catch { problem = [problem, error.localizedDescription].compactMap { $0 }.joined(separator: "; ") }
        window.toggleFullScreen(nil)
        do { try await waitFor("full-screen exit") { !observer.entered && !window.styleMask.contains(.fullScreen) } }
        catch { problem = [problem, error.localizedDescription].compactMap { $0 }.joined(separator: "; ") }
    }
    window?.close()
    source?.destroy()
    do {
        try await waitFor("owned displays removed and real displays restored") {
            (try? onlineIDs()) == originalIDs.sorted() && originals == originalIDs.sorted().compactMap(DisplaySnapshot.init)
        }
        report["originalDisplaysRestored"] = true
    } catch {
        report["originalDisplaysRestored"] = false
        problem = [problem, error.localizedDescription].compactMap { $0 }.joined(separator: "; ")
    }
    let finalIDs = (try? onlineIDs()) ?? []
    let finalOriginals = originalIDs.sorted().compactMap(DisplaySnapshot.init)
    report["finalDisplays"] = finalIDs.compactMap(DisplaySnapshot.init).map(\.evidence)
    report["originalDisplayIDsNoLongerOnline"] = originalIDs.subtracting(finalIDs).sorted()
    report["unexpectedDisplayIDs"] = Set(finalIDs).subtracting(originalIDs).sorted()
    report["originalDisplaysChangedAfterCleanup"] = originals != finalOriginals
    report["passed"] = problem == nil
    report["error"] = problem ?? ""
    do {
        let data = try JSONSerialization.data(withJSONObject: report, options: [.prettyPrinted, .sortedKeys])
        try FileManager.default.createDirectory(at: output.deletingLastPathComponent(), withIntermediateDirectories: true)
        try data.write(to: output, options: .atomic)
    } catch { print("Could not save handoff evidence: \(error.localizedDescription)"); exit(2) }
    print("Owned-display handoff result: \(problem ?? "passed"), report \(output.path)")
    exit(problem == nil ? 0 : 1)
}
app.run()
