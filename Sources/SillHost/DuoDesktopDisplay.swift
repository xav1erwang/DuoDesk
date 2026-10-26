// Copyright 2026 DUO你电脑 contributors. SPDX-License-Identifier: Apache-2.0
import Foundation
import CoreGraphics
import ScreenCaptureKit
import StreamProtocol

/// A transaction on the Mac desktop. A native physical mode is preferred. Otherwise a precisely
/// sized HiDPI display becomes the mirror master of the existing main desktop; it is not an empty
/// second workspace. Capture and input both use that same desktop's global coordinate rectangle.
/// Original modes, origins and mirror relationships are restored when the temporary display ends.
@MainActor
final class DuoDesktopDisplay {
    // Independent primary is a CLI-only experiment until existing full-screen Spaces migrate.
    enum Layout { case mirrored, nativePrimary }
    struct Prepared {
        let display: SCDisplay
        let bounds: CGRect
        let mirrored: Bool
    }
    enum Failure: LocalizedError {
        case invalidResolution, invalidFrameRate, screenPermission, noDisplay, modeRejected, displayUnavailable
        var errorDescription: String? {
            switch self {
            case .invalidResolution: return "Duo 上屏原生分辨率无效。"
            case .invalidFrameRate: return "Duo 请求的帧率无效。"
            case .screenPermission: return "请先在 Mac 系统设置中允许 DUO你电脑录制屏幕，再重新连接。"
            case .noDisplay: return "找不到可匹配 Duo 的 Mac 主显示器。"
            case .modeRejected: return "macOS 未能应用 Duo 的原生桌面尺寸和刷新率；本次连接不会降低分辨率。"
            case .displayUnavailable: return "无法捕获匹配 Duo 的桌面，请重新连接。"
            }
        }
    }
    private struct Original {
        let id: CGDirectDisplayID
        let mode: CGDisplayMode
        let origin: CGPoint
        let mirror: CGDirectDisplayID
    }
    private var originals: [Original] = []
    private var temporary: VirtualDisplay?
    private var capturedID: CGDirectDisplayID = 0
    private var originalMainID: CGDirectDisplayID = 0
    private var originalSystemMainID: CGDirectDisplayID = 0
    private var primaryOrigins: [CGDirectDisplayID: CGPoint] = [:]
    private let mainDisplay: () -> CGDirectDisplayID
    private let layout: Layout
    init(mainDisplay: @escaping () -> CGDirectDisplayID = { CGMainDisplayID() }, layout: Layout = .mirrored) {
        self.mainDisplay = mainDisplay
        self.layout = layout
    }
    private(set) var resolution: DuoDesktopResolution?
    private var requestedFPS: Int?
    var captureBounds: CGRect? { capturedID == 0 ? nil : CGDisplayBounds(capturedID) }
    /// SCK may follow an exact native clock on both the mirrored product desktop and the
    /// independent diagnostic desktop. A second 1/fps limiter is unnecessary in either case.
    /// This only changes sampling: never uncap a display running above the negotiated rate.
    var followsNativeCadence: Bool {
        guard activeModeMatches, let requestedFPS,
              let mode = CGDisplayCopyDisplayMode(capturedID) else { return false }
        return abs(mode.refreshRate - Double(requestedFPS)) < 0.5
    }
    /// Keep the diagnostic filter choice separate from the capture interval policy.
    var usesIndependentCaptureFilter: Bool { layout == .nativePrimary && followsNativeCadence }
    var activeModeMatches: Bool {
        guard let resolution, let requestedFPS, let mode = CGDisplayCopyDisplayMode(capturedID),
              mode.refreshRate >= Double(requestedFPS) - 0.5 else { return false }
        if temporary != nil {
            guard abs(mode.refreshRate - Double(requestedFPS)) < 0.5 else { return false }
            switch layout {
            case .mirrored:
                guard CGDisplayMirrorsDisplay(originalMainID) == capturedID else { return false }
            case .nativePrimary:
                guard CGDisplayMirrorsDisplay(capturedID) == kCGNullDirectDisplay,
                      CGDisplayMirrorsDisplay(originalMainID) != capturedID else { return false }
                if originalMainID == originalSystemMainID, CGMainDisplayID() != capturedID { return false }
                for old in originals where primaryOrigins[old.id] != nil {
                    guard CGDisplayBounds(old.id).origin == primaryOrigins[old.id],
                          CGDisplayMirrorsDisplay(old.id) == old.mirror,
                          Self.sameMode(CGDisplayCopyDisplayMode(old.id), old.mode) else { return false }
                }
            }
        }
        return resolution.accepts(width: mode.pixelWidth, height: mode.pixelHeight)
    }

    func prepare(_ wanted: DuoDesktopResolution, fps: Int) async throws -> Prepared {
        guard CGPreflightScreenCaptureAccess() else { throw Failure.screenPermission }
        let id = try await prepareGraphics(wanted, fps: fps)
        do {
            let display = try await findDisplay(id)
            return Prepared(display: display, bounds: CGDisplayBounds(id), mirrored: temporary != nil && layout == .mirrored)
        } catch {
            _ = restore()
            throw error
        }
    }

    /// Separated for a graphics-only test whose injected main display is itself disposable.
    /// The production entry point above always requires Screen Recording before changing a mode.
    func prepareGraphics(_ wanted: DuoDesktopResolution, fps: Int) async throws -> CGDirectDisplayID {
        guard wanted.isValid else { throw Failure.invalidResolution }
        guard (1...240).contains(fps) else { throw Failure.invalidFrameRate }
        if resolution == wanted, requestedFPS == fps, activeModeMatches { return capturedID }
        if resolution == wanted, activeModeMatches, let temporary {
            do {
                try await temporary.updateRefreshRate(Double(fps))
                requestedFPS = fps
                guard activeModeMatches else { throw Failure.modeRejected }
                print("Duo desktop: existing native desktop clock updated to \(fps) Hz")
                return capturedID
            } catch {
                _ = restore()
                throw error
            }
        }
        guard restore() else { throw Failure.modeRejected }
        let main = mainDisplay()
        originals = try snapshot()
        guard let home = originals.first(where: { $0.id == main }) else { originals = []; throw Failure.noDisplay }
        originalMainID = main
        originalSystemMainID = CGMainDisplayID()
        do {
            let options = [kCGDisplayShowDuplicateLowResolutionModes: true] as CFDictionary
            let modes = (CGDisplayCopyAllDisplayModes(main, options) as? [CGDisplayMode]) ?? []
            let native = modes.filter {
                wanted.accepts(width: $0.pixelWidth, height: $0.pixelHeight) && $0.refreshRate >= Double(fps) - 0.5
            }
                .sorted { a, b in
                    let aExact = abs(a.refreshRate - Double(fps)) < 0.5
                    let bExact = abs(b.refreshRate - Double(fps)) < 0.5
                    if aExact != bExact { return aExact }
                    return a.width == b.width ? a.refreshRate > b.refreshRate : a.width < b.width
                }.first
            if let native {
                try configure { config in
                    CGConfigureDisplayWithDisplayMode(config, main, native, nil)
                }
                capturedID = main
            } else {
                let display = try VirtualDisplay(name: "DUO你电脑 · 原生桌面",
                                                 widthPt: wanted.encodedWidth / 2,
                                                 heightPt: wanted.encodedHeight / 2,
                                                 scale: 2, refreshHz: Double(fps),
                                                 vendorID: 0x4455, productID: 0x4F01, serialNum: 1)
                temporary = display
                guard await display.waitUntilOnline(),
                      wanted.accepts(width: display.pixelSize.width, height: display.pixelSize.height) else {
                    throw Failure.modeRejected
                }
                // The virtual desktop supplies the negotiated clock; preserve the physical
                // panel's timing rather than adding an unrelated mode change.
                try configure { config in
                    let origin = CGConfigureDisplayOrigin(config, display.displayID, Int32(home.origin.x), Int32(home.origin.y))
                    guard origin == .success else { return origin }
                    return CGConfigureDisplayMirrorOfDisplay(config, main, display.displayID)
                }
                guard CGDisplayMirrorsDisplay(main) == display.displayID else { throw Failure.modeRejected }
                capturedID = display.displayID
                print("Duo mirror timing: desktop \(fps) Hz; panel \(CGDisplayCopyDisplayMode(main)?.refreshRate ?? 0) Hz")
                if layout == .nativePrimary {
                    try configure { config in
                        guard let nx = Int32(exactly: home.origin.x), let ny = Int32(exactly: home.origin.y) else { return .illegalArgument }
                        return CGConfigureDisplayOrigin(config, display.displayID, nx, ny)
                    }
                    // Let WindowServer finish moving the existing main workspace before detaching.
                    // Combining these stages can also pull a secondary display's windows onto it.
                    try await Task.sleep(for: .milliseconds(350))
                    try makeIndependentPrimary(display, home: home)
                }
            }
            resolution = wanted
            requestedFPS = fps
            guard activeModeMatches else { throw Failure.modeRejected }
            let kind = temporary == nil ? "physical mode" : layout == .mirrored ? "mirrored HiDPI mode" : "independent native primary"
            print("Duo desktop: \(wanted.width)×\(wanted.height) native; Mac renders \(wanted.encodedWidth)×\(wanted.encodedHeight) pixels; \(kind)")
            return capturedID
        } catch {
            _ = restore()
            throw error
        }
    }

    /// Synchronous for the app's Quit/signal path. Never writes persistent display preferences.
    @discardableResult
    func restore() -> Bool {
        guard !originals.isEmpty || temporary != nil else { return true }
        var success = true
        let live = originals.filter { CGDisplayIsOnline($0.id) != 0 }
        // Detach first. Removing a mirror master after restoring a slave's mode can otherwise
        // make WindowServer reapply the slave's pre-mirror timing after this method returns.
        if temporary != nil, !live.isEmpty {
            do {
                try configure { config in
                    for old in live where CGDisplayMirrorsDisplay(old.id) != old.mirror {
                        let result = CGConfigureDisplayMirrorOfDisplay(config, old.id, kCGNullDirectDisplay)
                        if result != .success { return result }
                    }
                    return .success
                }
            } catch { success = false; print("Duo desktop detach failed: \(error.localizedDescription)") }
        }
        temporary?.destroy()
        temporary = nil
        if !live.isEmpty {
            do {
                try configure { config in
                    for old in live {
                        if CGDisplayMirrorsDisplay(old.id) != old.mirror {
                            let result = CGConfigureDisplayMirrorOfDisplay(config, old.id, kCGNullDirectDisplay)
                            if result != .success { return result }
                        }
                    }
                    for old in live {
                        if !Self.sameMode(CGDisplayCopyDisplayMode(old.id), old.mode) {
                            let mode = CGConfigureDisplayWithDisplayMode(config, old.id, old.mode, nil)
                            if mode != .success { return mode }
                        }
                        if CGDisplayBounds(old.id).origin != old.origin {
                            let origin = CGConfigureDisplayOrigin(config, old.id, Int32(old.origin.x), Int32(old.origin.y))
                            if origin != .success { return origin }
                        }
                    }
                    for old in live where old.mirror != kCGNullDirectDisplay && CGDisplayIsOnline(old.mirror) != 0 && CGDisplayMirrorsDisplay(old.id) != old.mirror {
                        let result = CGConfigureDisplayMirrorOfDisplay(config, old.id, old.mirror)
                        if result != .success { return result }
                    }
                    return .success
                }
            } catch { success = false; print("Duo desktop restore failed: \(error.localizedDescription)") }
        }
        capturedID = 0
        originalMainID = 0
        originalSystemMainID = 0
        primaryOrigins = [:]
        resolution = nil
        requestedFPS = nil
        if success {
            for old in live {
                guard Self.sameMode(CGDisplayCopyDisplayMode(old.id), old.mode),
                      CGDisplayMirrorsDisplay(old.id) == old.mirror,
                      CGDisplayBounds(old.id).origin == old.origin else { success = false; continue }
            }
        }
        if success {
            originals = []
            print("Duo desktop: original Mac display configuration restored")
        }
        // Preserve the snapshot on failure: the next stop/reconnect/exit can retry restoration.
        return success
    }

    /// First mirror the existing desktop so its windows join the native main workspace. Then
    /// detach the physical displays; a mirrored compositor can otherwise limit capture to 60 Hz.
    /// Move only display groups that overlap the native desktop or another displaced group.
    /// Keep existing side screens in place where possible; moving a side screen across the main
    /// display on restoration can cause WindowServer to relocate its windows onto the main one.
    private func makeIndependentPrimary(_ display: VirtualDisplay, home: Original) throws {
        // An injected disposable target must never rearrange unrelated physical displays.
        let displaced = originalMainID == originalSystemMainID ? originals : originals.filter { $0.id == originalMainID }
        let byID = Dictionary(uniqueKeysWithValues: displaced.map { ($0.id, $0) })
        var groups: [CGDirectDisplayID: [Original]] = [:]
        for old in displaced {
            var root = old.id
            var seen: Set<CGDirectDisplayID> = []
            while let next = byID[root], next.mirror != kCGNullDirectDisplay {
                guard seen.insert(root).inserted, byID[next.mirror] != nil else { throw Failure.modeRejected }
                root = next.mirror
            }
            groups[root, default: []].append(old)
        }
        let mainRoot = groups.first(where: { $0.value.contains { $0.id == originalMainID } })?.key
        let ordered = groups.keys.sorted { a, b in
            if a == b { return false }
            if a == mainRoot { return true }
            if b == mainRoot { return false }
            return a < b
        }
        let nativeBounds = CGDisplayBounds(display.displayID)
        var occupied = [nativeBounds]
        var origins: [CGDirectDisplayID: CGPoint] = [:]
        for root in ordered {
            guard let master = byID[root], master.mode.width > 0, master.mode.height > 0 else { throw Failure.modeRejected }
            var frame = CGRect(origin: master.origin, size: CGSize(width: master.mode.width, height: master.mode.height))
            if occupied.contains(where: {
                let overlap = $0.intersection(frame)
                return !overlap.isNull && overlap.width > 0 && overlap.height > 0
            }) { frame.origin = CGPoint(x: occupied.map(\.maxX).max() ?? nativeBounds.maxX, y: home.origin.y) }
            guard Int32(exactly: frame.minX) != nil, Int32(exactly: frame.minY) != nil,
                  frame.maxX.isFinite, frame.maxY.isFinite else { throw Failure.modeRejected }
            for old in groups[root] ?? [] { origins[old.id] = frame.origin }
            occupied.append(frame)
        }
        try configure { config in
            for old in displaced where CGDisplayMirrorsDisplay(old.id) != kCGNullDirectDisplay {
                let result = CGConfigureDisplayMirrorOfDisplay(config, old.id, kCGNullDirectDisplay)
                if result != .success { return result }
            }
            for old in displaced {
                if !Self.sameMode(CGDisplayCopyDisplayMode(old.id), old.mode) {
                    let result = CGConfigureDisplayWithDisplayMode(config, old.id, old.mode, nil)
                    if result != .success { return result }
                }
                guard let point = origins[old.id], let px = Int32(exactly: point.x), let py = Int32(exactly: point.y) else { return .illegalArgument }
                let result = CGConfigureDisplayOrigin(config, old.id, px, py)
                if result != .success { return result }
            }
            for old in displaced where old.mirror != kCGNullDirectDisplay {
                let result = CGConfigureDisplayMirrorOfDisplay(config, old.id, old.mirror)
                if result != .success { return result }
            }
            guard let nx = Int32(exactly: home.origin.x), let ny = Int32(exactly: home.origin.y) else { return .illegalArgument }
            // Explicitly assign the native origin last: detaching a mirror can make WindowServer
            // choose the physical display as main again even when the virtual one was at (0,0).
            return CGConfigureDisplayOrigin(config, display.displayID, nx, ny)
        }
        primaryOrigins = origins
        print("Duo native primary: main=\(CGMainDisplayID()), target=\(display.displayID), physical display groups=\(ordered.count)")
        print("Duo primary bounds: \(CGDisplayBounds(display.displayID))")
        for old in displaced {
            let mode = CGDisplayCopyDisplayMode(old.id)
            print("Duo displaced display \(old.id): origin \(CGDisplayBounds(old.id).origin), planned \(String(describing: origins[old.id])), mirror \(CGDisplayMirrorsDisplay(old.id))/\(old.mirror), mode \(mode?.ioDisplayModeID ?? 0)/\(old.mode.ioDisplayModeID), \(mode?.width ?? 0)×\(mode?.height ?? 0) @\(mode?.refreshRate ?? 0)")
        }
    }

    private func snapshot() throws -> [Original] {
        var count: UInt32 = 0
        guard CGGetOnlineDisplayList(0, nil, &count) == .success else { throw Failure.noDisplay }
        var ids = [CGDirectDisplayID](repeating: 0, count: Int(count))
        guard CGGetOnlineDisplayList(count, &ids, &count) == .success else { throw Failure.noDisplay }
        return ids.compactMap { id in
            guard let mode = CGDisplayCopyDisplayMode(id) else { return nil }
            return Original(id: id, mode: mode, origin: CGDisplayBounds(id).origin, mirror: CGDisplayMirrorsDisplay(id))
        }
    }

    private static func sameMode(_ a: CGDisplayMode?, _ b: CGDisplayMode) -> Bool {
        guard let a else { return false }
        return a.ioDisplayModeID == b.ioDisplayModeID && a.width == b.width && a.height == b.height
            && a.pixelWidth == b.pixelWidth && a.pixelHeight == b.pixelHeight
            && abs(a.refreshRate - b.refreshRate) < 0.5
    }

    private func configure(_ body: (CGDisplayConfigRef) -> CGError) throws {
        var config: CGDisplayConfigRef?
        guard CGBeginDisplayConfiguration(&config) == .success, let config else { throw Failure.modeRejected }
        let result = body(config)
        guard result == .success else {
            print("Duo display configuration body rejected: \(result.rawValue)")
            CGCancelDisplayConfiguration(config); throw Failure.modeRejected
        }
        let committed = CGCompleteDisplayConfiguration(config, .forSession)
        guard committed == .success else {
            print("Duo display configuration commit rejected: \(committed.rawValue)")
            throw Failure.modeRejected
        }
    }

    private func findDisplay(_ id: CGDirectDisplayID) async throws -> SCDisplay {
        for _ in 0..<20 {
            let content = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: true)
            if let display = content.displays.first(where: { $0.displayID == id }) { return display }
            try await Task.sleep(for: .milliseconds(100))
        }
        throw Failure.displayUnavailable
    }
}
