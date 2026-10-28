// Copyright 2026 DUO你电脑 contributors. SPDX-License-Identifier: Apache-2.0
import Foundation
import AppKit
import CoreGraphics
import ScreenCaptureKit
import StreamProtocol

/// The pipeline target is independent of the source display's negotiated clock.
enum StreamSamplingPolicy {
    nonisolated static func target(maximum: Int, highestRequested: Int?, softwareEncoder: Bool,
                                   sourceClockCeiling: Int?) -> Int {
        let wanted = min(maximum, max(24, highestRequested ?? 60))
        let codecTarget = softwareEncoder ? min(wanted, 60) : wanted
        return sourceClockCeiling.map { min(codecTarget, $0) } ?? codecTarget
    }
}

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
        case invalidResolution, invalidFrameRate, screenPermission, noDisplay, modeRejected, displayUnavailable, restorePending, topologyChanging, recoveryUnavailable, samplingClockTooSlow
        var errorDescription: String? {
            switch self {
            case .invalidResolution: return "Duo 上屏原生分辨率无效。"
            case .invalidFrameRate: return "Duo 请求的帧率无效。"
            case .screenPermission: return "请先在 Mac 系统设置中允许 DUO你电脑录制屏幕，再重新连接。"
            case .noDisplay: return "找不到可匹配 Duo 的 Mac 主显示器。"
            case .modeRejected: return "macOS 未能应用 Duo 的原生桌面尺寸和刷新率；本次连接不会降低分辨率。"
            case .displayUnavailable: return "无法捕获匹配 Duo 的桌面，请重新连接。"
            case .restorePending: return "此前的 Mac 显示配置仍待恢复，原显示器可能已离线、配置已变化或系统拒绝恢复。"
            case .topologyChanging: return "Mac 显示器配置正在变化，无法安全记录原始状态；未启动新的原生桌面。"
            case .recoveryUnavailable: return "无法安全保存 Mac 显示配置；未启动新的原生桌面。"
            case .samplingClockTooSlow: return "当前桌面时钟低于请求的采样率；更高目标可在下次连接时尝试。"
            }
        }
    }
    private struct Original {
        let id: CGDirectDisplayID
        let mode: CGDisplayMode
        let origin: CGPoint
        let mirror: CGDirectDisplayID
        let identity: DisplayRestoreIdentity?
        init(id: CGDirectDisplayID, mode: CGDisplayMode, origin: CGPoint, mirror: CGDirectDisplayID,
             identity: DisplayRestoreIdentity? = nil) {
            self.id = id; self.mode = mode; self.origin = origin; self.mirror = mirror; self.identity = identity
        }
    }
    private var originals: [Original] = []
    /// Keep counts from the full original inventory even after unrelated restored screens are released.
    private var originalIdentityCounts: [DisplayRestoreIdentity: Int] = [:]
    /// An ID observed offline or with different identity must be reidentified before any write.
    private var observedOffline: Set<CGDirectDisplayID> = []
    private var temporary: VirtualDisplay?
    private var pendingMirror = false
    private var capturedID: CGDirectDisplayID = 0
    private var originalMainID: CGDirectDisplayID = 0
    private var originalSystemMainID: CGDirectDisplayID = 0
    private var primaryOrigins: [CGDirectDisplayID: CGPoint] = [:]
    private let recoveryDirectory: URL?
    private var recoveryStore: DisplayRecoveryStore?
    private var recoveryToken: UUID?
    private var didAttemptDisplayChange = false
    #if DUO_DISPLAY_RESTORE_TESTING
    private var testInventory: (() -> [CGDirectDisplayID: DisplayRestoreIdentity]?)?
    private var testInterceptConfiguration = false
    private var testConfigurationAttempts = 0
    private var testPreventDisplayMutation = false
    private var testRecoveryModes: [CGDisplayMode]?
    private var testRecoveryRead: (() throws -> DisplayRecoveryRecord)?
    private var testAfterRecoveryConfiguration: (() -> Void)?
    private var testVirtualSampling = false
    private var testSnapshotReads = 0
    #endif
    private let mainDisplay: @MainActor () -> CGDirectDisplayID
    private let layout: Layout
    init(mainDisplay: @escaping @MainActor () -> CGDirectDisplayID = { DuoDesktopDisplay.availableMainDisplayID() },
         layout: Layout = .mirrored, recoveryDirectory: URL? = nil) {
        self.mainDisplay = mainDisplay
        self.layout = layout
        self.recoveryDirectory = recoveryDirectory
    }
    /// A Screen Sharing display handover can leave CGMainDisplayID pointing at a removed
    /// display. AppKit already knows the replacement. Only accept an unambiguous, online
    /// desktop; never move an arbitrary secondary display when the main display is unknown.
    private static func availableMainDisplayID() -> CGDirectDisplayID {
        let main = CGMainDisplayID()
        if isDisplayOnline(main) { return main }
        let live = NSScreen.screens.compactMap { screen -> CGDirectDisplayID? in
            guard let number = screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber else { return nil }
            let id = number.uint32Value
            return isDisplayOnline(id) ? id : nil
        }
        let atOrigin = live.filter { CGDisplayBounds($0).origin == .zero && CGDisplayMirrorsDisplay($0) == 0 }
        if atOrigin.count == 1 { return atOrigin[0] }
        return live.count == 1 ? live[0] : main
    }
    /// CoreGraphics returns -1 for an unknown display ID on macOS 27; it is not online.
    nonisolated static func isDisplayOnline(_ id: CGDirectDisplayID) -> Bool {
        CGDisplayIsOnline(id) > 0
    }
    /// Keep a stable identity for each source desktop, rather than sharing serial 1 with
    /// every source and virtual-display utility. A Screen Sharing handover can retain the
    /// previous source's identity after its display has left the online list.
    private static func virtualDesktopSerial(source: CGDirectDisplayID) -> UInt32 {
        let words: [UInt32] = [0x44554F32, CGDisplayVendorNumber(source),
                               CGDisplayModelNumber(source), CGDisplaySerialNumber(source)]
        var hash: UInt32 = 2_166_136_261
        for word in words {
            for shift in stride(from: 0, to: 32, by: 8) {
                hash = (hash ^ ((word >> shift) & 0xFF)) &* 16_777_619
            }
        }
        return hash > 1 ? hash : 0x44554F32
    }
    private(set) var resolution: DuoDesktopResolution?
    private var requestedFPS: Int?
    /// Set once when a virtual desktop is created. Sampling changes never change this clock.
    private var virtualDesktopClockFPS: Int?
    var captureBounds: CGRect? { capturedID == 0 ? nil : CGDisplayBounds(capturedID) }
    /// SCK may follow an exact native clock on both the mirrored product desktop and the
    /// independent diagnostic desktop. A second 1/fps limiter is unnecessary in either case.
    /// This only changes sampling: never uncap a display running above the negotiated rate.
    var followsNativeCadence: Bool {
        guard activeModeMatches, let requestedFPS,
              let mode = CGDisplayCopyDisplayMode(capturedID) else { return false }
        return abs(mode.refreshRate - Double(requestedFPS)) < 0.5
    }
    /// Only a faster, known clock needs software-side frame selection after an unthrottled SCK
    /// sample. This includes a virtual desktop whose sampling target is below its fixed clock.
    var needsCadenceResampling: Bool {
        guard activeModeMatches, let requestedFPS,
              let mode = CGDisplayCopyDisplayMode(capturedID) else { return false }
        return mode.refreshRate > Double(requestedFPS) + 0.5
    }
    /// Keep the diagnostic filter choice separate from the capture interval policy.
    var usesIndependentCaptureFilter: Bool { layout == .nativePrimary && activeModeMatches }
    /// A physical resolution may change, but its reported refresh must stay exactly as it was.
    /// Unknown or slower physical clocks use the virtual desktop instead of a different mode.
    nonisolated static func permitsPhysicalMode(currentHz: Double, candidateHz: Double, fps: Int) -> Bool {
        currentHz.isFinite && candidateHz.isFinite && currentHz > 0 && (1...240).contains(fps)
            && candidateHz == currentHz && candidateHz >= Double(fps) - 0.5
    }
    /// Treat near-integer clocks such as 59.94 Hz as the corresponding target; this is only a
    /// sampling/encoder ceiling, not a claim about delivered frames. Unknown clocks do not cap.
    nonisolated static func samplingCeiling(refreshHz: Double) -> Int? {
        guard refreshHz.isFinite, refreshHz >= 1, refreshHz <= 1000 else { return nil }
        return min(240, Int((refreshHz + 0.5).rounded(.down)))
    }
    /// Only an already established and verified desktop has a clock that can cap a later request.
    var currentSamplingCeiling: Int? {
        guard activeModeMatches, let mode = CGDisplayCopyDisplayMode(capturedID) else { return nil }
        return Self.samplingCeiling(refreshHz: mode.refreshRate)
    }
    private var isVirtualDesktop: Bool {
        #if DUO_DISPLAY_RESTORE_TESTING
        if testVirtualSampling { return true }
        #endif
        return temporary != nil
    }
    var activeModeMatches: Bool {
        guard !pendingMirror, let resolution, let requestedFPS, let mode = CGDisplayCopyDisplayMode(capturedID),
              mode.refreshRate >= Double(requestedFPS) - 0.5,
              physicalRefreshMatchesOriginal else { return false }
        if isVirtualDesktop {
            guard let virtualDesktopClockFPS,
                  abs(mode.refreshRate - Double(virtualDesktopClockFPS)) < 0.5 else { return false }
            #if DUO_DISPLAY_RESTORE_TESTING
            if testVirtualSampling { return resolution.accepts(width: mode.pixelWidth, height: mode.pixelHeight) }
            #endif
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
        } else {
            guard let original = originals.first(where: { $0.id == originalMainID }),
                  mode.refreshRate == original.mode.refreshRate else { return false }
        }
        return resolution.accepts(width: mode.pixelWidth, height: mode.pixelHeight)
    }

    /// WindowServer can itself choose a different physical clock while changing a mirror graph.
    /// Reject that graph and restore the snapshot instead of silently changing panel refresh.
    private var physicalRefreshMatchesOriginal: Bool {
        !originals.isEmpty && originals.allSatisfy { original in
            guard Self.isDisplayOnline(original.id), let mode = CGDisplayCopyDisplayMode(original.id) else { return false }
            return mode.refreshRate == original.mode.refreshRate
        }
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
    func prepareGraphics(_ wanted: DuoDesktopResolution, fps: Int, deferMirror: Bool = false) async throws -> CGDirectDisplayID {
        guard wanted.isValid else { throw Failure.invalidResolution }
        guard (1...240).contains(fps) else { throw Failure.invalidFrameRate }
        guard !deferMirror || layout == .mirrored else { throw Failure.invalidResolution }
        if resolution == wanted, activeModeMatches {
            guard let ceiling = currentSamplingCeiling, fps <= ceiling else { throw Failure.samplingClockTooSlow }
            guard requestedFPS != fps else { return capturedID }
            let previous = requestedFPS
            requestedFPS = fps
            guard activeModeMatches else { requestedFPS = previous; throw Failure.modeRejected }
            print("Duo desktop: sampling target updated to \(fps) fps; desktop clock unchanged")
            return capturedID
        }
        guard restore() else { throw Failure.restorePending }
        let store: DisplayRecoveryStore?
        do { store = try recoveryDirectory.map { try DisplayRecoveryStore(directory: $0) } }
        catch { print("Duo display recovery storage unavailable: \(error)"); throw Failure.recoveryUnavailable }
        var main = mainDisplay()
        var systemMain = CGMainDisplayID()
        var sampled = try snapshot()
        guard main == mainDisplay(), systemMain == CGMainDisplayID() else { throw Failure.topologyChanging }
        let recoveryRecord: DisplayRecoveryRecord?
        if let store {
            var record = try Self.recoveryRecord(sampled, systemMain: systemMain)
            do {
                if let prior = try store.load() {
                    if !prior.alreadyRestored(as: record) {
                        guard let intent = try store.loadIntent(for: prior),
                              try recoverSingleDisplay(prior, intent: intent, current: record) else { throw Failure.restorePending }
                        main = mainDisplay(); systemMain = CGMainDisplayID(); sampled = try snapshot()
                        guard main == mainDisplay(), systemMain == CGMainDisplayID() else { throw Failure.topologyChanging }
                        record = try Self.recoveryRecord(sampled, systemMain: systemMain)
                        guard prior.alreadyRestored(as: record) else { throw Failure.restorePending }
                        print("Duo desktop: interrupted single-display mode restored")
                    }
                    try store.remove(token: prior.token)
                    print("Duo desktop: interrupted session was already restored; recovery record cleared")
                }
            } catch let error as Failure { throw error }
            catch { print("Duo display recovery record unavailable: \(error)"); throw Failure.restorePending }
            recoveryRecord = record
        } else { recoveryRecord = nil }
        guard let home = sampled.first(where: { $0.id == main }) else { throw Failure.noDisplay }
        recoveryStore = store
        originals = sampled
        originalIdentityCounts = Self.identityCounts(originals.compactMap(\.identity))
        observedOffline.removeAll()
        originalMainID = main
        originalSystemMainID = systemMain
        didAttemptDisplayChange = false
        do {
            let options = [kCGDisplayShowDuplicateLowResolutionModes: true] as CFDictionary
            let modes = (CGDisplayCopyAllDisplayModes(main, options) as? [CGDisplayMode]) ?? []
            let matchingModes = modes.filter {
                wanted.accepts(width: $0.pixelWidth, height: $0.pixelHeight)
                    && Self.permitsPhysicalMode(currentHz: home.mode.refreshRate, candidateHz: $0.refreshRate, fps: fps)
            }
            let native = matchingModes.first { Self.sameMode($0, home.mode) }
                ?? matchingModes.min { $0.width < $1.width }
            if let native {
                if !Self.sameMode(native, home.mode) {
                    try persistRecovery(recoveryRecord)
                    if let recoveryRecord, let intent = Self.singleDisplayIntent(original: recoveryRecord, mode: native) {
                        do { try recoveryStore?.saveIntent(intent, for: recoveryRecord) }
                        catch { throw Failure.recoveryUnavailable }
                        // The intent is durable; check the complete state again before mutation.
                        let latestMain = CGMainDisplayID()
                        let latest = try Self.recoveryRecord(snapshot(), systemMain: latestMain)
                        guard latestMain == CGMainDisplayID(), main == mainDisplay(),
                              recoveryRecord.sameState(as: latest) else { throw Failure.topologyChanging }
                    }
                    #if DUO_DISPLAY_RESTORE_TESTING
                    if testPreventDisplayMutation { throw Failure.modeRejected }
                    #endif
                    didAttemptDisplayChange = true
                    try configure { config in
                        CGConfigureDisplayWithDisplayMode(config, main, native, nil)
                    }
                }
                capturedID = main
            } else {
                try persistRecovery(recoveryRecord)
                #if DUO_DISPLAY_RESTORE_TESTING
                if testPreventDisplayMutation { throw Failure.modeRejected }
                #endif
                didAttemptDisplayChange = true
                let display = try VirtualDisplay(name: "DUO你电脑 · 原生桌面",
                                                 widthPt: wanted.encodedWidth / 2,
                                                 heightPt: wanted.encodedHeight / 2,
                                                 scale: 2, refreshHz: Double(fps),
                                                 vendorID: 0x4455, productID: 0x4F01,
                                                 serialNum: Self.virtualDesktopSerial(source: main))
                temporary = display
                virtualDesktopClockFPS = fps
                guard await display.waitUntilOnline(),
                      wanted.accepts(width: display.pixelSize.width, height: display.pixelSize.height) else {
                    throw Failure.modeRejected
                }
                capturedID = display.displayID
                if deferMirror {
                    // Keep the current desktop stable while the system picker is on screen.
                    // The selected filter continues to identify this same display after attach.
                    pendingMirror = true
                } else {
                    try attachMirror(display, home: home)
                }
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
            guard pendingMirror || activeModeMatches else { throw Failure.modeRejected }
            let kind = temporary == nil ? "physical mode" : layout == .mirrored ? "mirrored HiDPI mode" : "independent native primary"
            print("Duo desktop: \(wanted.width)×\(wanted.height) native; canvas \(wanted.encodedWidth)×\(wanted.encodedHeight) pixels; \(pendingMirror ? "awaiting desktop attachment" : kind)")
            return capturedID
        } catch {
            _ = restore()
            throw error
        }
    }

    func attachPreparedMirror() throws {
        guard pendingMirror else { return }
        do {
            guard let display = temporary, let home = originals.first(where: { $0.id == originalMainID }),
                  Self.isDisplayOnline(home.id), Self.isDisplayOnline(display.displayID) else {
                throw Failure.displayUnavailable
            }
            try attachMirror(display, home: home)
            pendingMirror = false
            guard activeModeMatches else { throw Failure.modeRejected }
        } catch {
            _ = restore()
            throw error
        }
    }

    private func attachMirror(_ display: VirtualDisplay, home: Original) throws {
        // The virtual desktop supplies the negotiated clock. Do not select a new panel mode.
        try configure { config in
            let origin = CGConfigureDisplayOrigin(config, display.displayID, Int32(home.origin.x), Int32(home.origin.y))
            guard origin == .success else { return origin }
            return CGConfigureDisplayMirrorOfDisplay(config, home.id, display.displayID)
        }
        guard CGDisplayMirrorsDisplay(home.id) == display.displayID else { throw Failure.modeRejected }
        guard physicalRefreshMatchesOriginal else {
            print("Duo mirror rejected: WindowServer changed a physical display's reported refresh rate.")
            throw Failure.modeRejected
        }
        print("Duo mirror timing: desktop \(display.refreshHz) Hz; source \(CGDisplayCopyDisplayMode(home.id)?.refreshRate ?? 0) Hz")
    }

    /// Synchronous for the app's Quit/signal path. Never writes persistent display preferences.
    @discardableResult
    func restore() -> Bool {
        guard !originals.isEmpty || temporary != nil else { return finishRecovery() }
        // If recording the journal failed, no display API has been called yet. Do not change a
        // user's display just to clean up a transaction that never started.
        if !didAttemptDisplayChange {
            originals = []; originalIdentityCounts.removeAll(); observedOffline.removeAll()
            capturedID = 0; originalMainID = 0; originalSystemMainID = 0; primaryOrigins = [:]
            resolution = nil; requestedFPS = nil; virtualDesktopClockFPS = nil
            return finishRecovery()
        }
        var success = true
        var live: [Original] = [], unavailable: [Original] = []
        // Reidentification needs a stable, complete online inventory. A changed ID is not silently
        // remapped; mode and mirror relationships still refer to the original CoreGraphics IDs.
        let inventory = onlineIdentitySnapshot()
        let onlineCounts = inventory.map { Self.identityCounts(Array($0.values)) }
        for original in originals {
            // An unstable read is not proof that a monitor disconnected, but it also must not
            // authorize any display write. Keep the snapshot for a later stable observation.
            guard let inventory else { unavailable.append(original); continue }
            guard let current = inventory[original.id], let expected = original.identity else {
                observedOffline.insert(original.id); unavailable.append(original); continue
            }
            let trusted = expected.permitsRestore(current: current, wasOffline: observedOffline.contains(original.id),
                                                   originalMatches: originalIdentityCounts[expected, default: 0],
                                                   onlineMatches: onlineCounts?[expected, default: 0] ?? 0)
            if trusted { live.append(original) }
            else { observedOffline.insert(original.id); unavailable.append(original) }
        }
        let trustedIDs = Set(live.map(\.id))
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
        pendingMirror = false
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
                        if !Self.sameRestoredMode(CGDisplayCopyDisplayMode(old.id), old.mode) {
                            let mode = CGConfigureDisplayWithDisplayMode(config, old.id, old.mode, nil)
                            if mode != .success { return mode }
                        }
                        if CGDisplayBounds(old.id).origin != old.origin {
                            let origin = CGConfigureDisplayOrigin(config, old.id, Int32(old.origin.x), Int32(old.origin.y))
                            if origin != .success { return origin }
                        }
                    }
                    for old in live where old.mirror != kCGNullDirectDisplay && trustedIDs.contains(old.mirror) && CGDisplayMirrorsDisplay(old.id) != old.mirror {
                        let result = CGConfigureDisplayMirrorOfDisplay(config, old.id, old.mirror)
                        if result != .success { return result }
                    }
                    return .success
                }
            } catch { success = false; print("Duo desktop restore failed: \(error.localizedDescription)") }
        }
        capturedID = 0
        originalMainID = 0
        primaryOrigins = [:]
        resolution = nil
        requestedFPS = nil
        virtualDesktopClockFPS = nil
        if success {
            var pending = unavailable
            let verifiedIdentities = onlineIdentitySnapshot()
            for old in live {
                // A replacement or disconnect during the configuration must not be reported as
                // success. An unstable inventory remains pending without guessing what happened.
                guard let verifiedIdentities else { pending.append(old); continue }
                guard verifiedIdentities[old.id] == old.identity else {
                    observedOffline.insert(old.id); pending.append(old); continue
                }
                if !Self.isDisplayOnline(old.id) || !Self.sameRestoredMode(CGDisplayCopyDisplayMode(old.id), old.mode)
                    || CGDisplayMirrorsDisplay(old.id) != old.mirror || CGDisplayBounds(old.id).origin != old.origin {
                    pending.append(old)
                }
            }
            // Equal modes/origins do not by themselves prove the original system main display was
            // restored, especially with a mirror group. Ignore a stale ID that was not in snapshot.
            if let main = Self.unrestoredSystemMain(originals, expected: originalSystemMainID, current: CGMainDisplayID()),
               !pending.contains(where: { $0.id == main.id }) {
                pending.append(main)
            }
            // A pending mirror may change its master when it returns. Keep that whole original
            // mirror group until it can be verified together, but release unrelated restored screens.
            originals = Self.retainPendingMirrorGroups(originals, pending: pending)
            observedOffline.formIntersection(Set(originals.map(\.id)))
            success = pending.isEmpty
            if success {
                originalSystemMainID = 0; originalIdentityCounts.removeAll(); didAttemptDisplayChange = false
                success = finishRecovery()
                if success { print("Duo desktop: original Mac display configuration restored") }
                else { print("Duo desktop: display configuration restored, but recovery record cleanup is pending") }
            } else {
                print("Duo desktop: \(pending.count) original display(s) still need restoration; snapshot retained")
            }
        } else if !unavailable.isEmpty {
            print("Duo desktop: \(unavailable.count) original display(s) unavailable; restoration snapshot retained")
        }
        // Preserve the snapshot on failure: the next stop/reconnect/exit can retry restoration.
        return success
    }

    private static func recoveryRecord(_ originals: [Original], systemMain: CGDirectDisplayID) throws -> DisplayRecoveryRecord {
        let saved = try originals.map { original -> DisplayRecoveryRecord.Display in
            guard let identity = original.identity,
                  let x = Int32(exactly: original.origin.x), let y = Int32(exactly: original.origin.y) else {
                throw Failure.topologyChanging
            }
            return DisplayRecoveryRecord.Display(id: original.id, identity: identity, modeID: original.mode.ioDisplayModeID,
                width: original.mode.width, height: original.mode.height,
                pixelWidth: original.mode.pixelWidth, pixelHeight: original.mode.pixelHeight,
                refresh: original.mode.refreshRate, originX: x, originY: y, mirror: original.mirror)
        }
        let record = DisplayRecoveryRecord(version: 1, token: UUID(), main: systemMain, displays: saved)
        guard record.isValid else { throw Failure.topologyChanging }
        return record
    }

    /// This narrowly scoped intent is known before a single physical-mode change. In all other
    /// topologies the journal remains a conservative record and is never replayed automatically.
    private static func singleDisplayIntent(original: DisplayRecoveryRecord, mode: CGDisplayMode) -> DisplayRecoveryIntent? {
        guard original.displays.count == 1 else { return nil }
        let saved = original.displays[0]
        let target = DisplayRecoveryRecord.Display(id: saved.id, identity: saved.identity, modeID: mode.ioDisplayModeID,
            width: mode.width, height: mode.height, pixelWidth: mode.pixelWidth, pixelHeight: mode.pixelHeight,
            refresh: mode.refreshRate, originX: saved.originX, originY: saved.originY, mirror: saved.mirror)
        let expected = DisplayRecoveryRecord(version: original.version, token: original.token, main: original.main, displays: [target])
        let intent = DisplayRecoveryIntent(version: 1, expected: expected)
        return intent.isValid(for: original) ? intent : nil
    }

    /// After a crash, undo only a matching, identifiable single-display change. Find the exact
    /// old mode again; mode IDs or dimensions alone are not sufficient. The final state is checked
    /// before clearing the journal. No refresh-rate change is requested.
    private func recoverSingleDisplay(_ original: DisplayRecoveryRecord, intent: DisplayRecoveryIntent,
                                      current: DisplayRecoveryRecord) throws -> Bool {
        guard intent.permitsReplay(original: original, current: current) else { return false }
        let saved = original.displays[0]
        let options = [kCGDisplayShowDuplicateLowResolutionModes: true] as CFDictionary
        let modes: [CGDisplayMode]
        #if DUO_DISPLAY_RESTORE_TESTING
        if let testRecoveryModes { modes = testRecoveryModes }
        else { modes = (CGDisplayCopyAllDisplayModes(saved.id, options) as? [CGDisplayMode]) ?? [] }
        #else
        modes = (CGDisplayCopyAllDisplayModes(saved.id, options) as? [CGDisplayMode]) ?? []
        #endif
        let matches = modes.filter {
            $0.ioDisplayModeID == saved.modeID && $0.width == saved.width && $0.height == saved.height
                && $0.pixelWidth == saved.pixelWidth && $0.pixelHeight == saved.pixelHeight && $0.refreshRate == saved.refresh
        }
        guard matches.count == 1, let mode = matches.first else { return false }
        let latest = try currentRecoveryRecord()
        guard intent.permitsReplay(original: original, current: latest) else { return false }
        try configure { config in CGConfigureDisplayWithDisplayMode(config, saved.id, mode, nil) }
        #if DUO_DISPLAY_RESTORE_TESTING
        testAfterRecoveryConfiguration?()
        #endif
        return original.alreadyRestored(as: try currentRecoveryRecord())
    }

    private func currentRecoveryRecord() throws -> DisplayRecoveryRecord {
        #if DUO_DISPLAY_RESTORE_TESTING
        if let testRecoveryRead { return try testRecoveryRead() }
        #endif
        let main = CGMainDisplayID()
        let record = try Self.recoveryRecord(snapshot(), systemMain: main)
        guard main == CGMainDisplayID() else { throw Failure.topologyChanging }
        return record
    }

    private func persistRecovery(_ record: DisplayRecoveryRecord?) throws {
        guard let store = recoveryStore, let record else { return }
        // Remember the token before writing: even an error after publication must clean up only
        // our own record, and only after the display state has been safely handled.
        recoveryToken = record.token
        do { try store.save(record) }
        catch { print("Duo display recovery journal could not be saved: \(error)"); throw Failure.recoveryUnavailable }
        let main = CGMainDisplayID()
        let latest = try Self.recoveryRecord(snapshot(), systemMain: main)
        guard CGMainDisplayID() == main, record.sameState(as: latest) else { throw Failure.topologyChanging }
    }

    private func finishRecovery() -> Bool {
        do {
            if let recoveryStore, let recoveryToken { try recoveryStore.remove(token: recoveryToken) }
            recoveryToken = nil
            recoveryStore = nil
            return true
        } catch {
            print("Duo display recovery journal could not be cleared: \(error)")
            return false
        }
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
        #if DUO_DISPLAY_RESTORE_TESTING
        testSnapshotReads += 1
        #endif
        let main = CGMainDisplayID()
        let captured = try Self.stableSnapshot {
            var count: UInt32 = 0
            guard CGGetOnlineDisplayList(0, nil, &count) == .success, count > 0 else {
                throw Failure.topologyChanging
            }
            let expected = count
            var ids = [CGDirectDisplayID](repeating: 0, count: Int(expected))
            guard CGGetOnlineDisplayList(expected, &ids, &count) == .success, count == expected else {
                throw Failure.topologyChanging
            }
            return try ids.map { id in
                guard Self.isDisplayOnline(id), let mode = CGDisplayCopyDisplayMode(id),
                      mode.width > 0, mode.height > 0, mode.pixelWidth > 0, mode.pixelHeight > 0,
                      mode.refreshRate.isFinite else { throw Failure.topologyChanging }
                let origin = CGDisplayBounds(id).origin
                guard Int32(exactly: origin.x) != nil, Int32(exactly: origin.y) != nil else {
                    throw Failure.topologyChanging
                }
                return Original(id: id, mode: mode, origin: origin, mirror: CGDisplayMirrorsDisplay(id),
                                identity: Self.displayIdentity(id))
            }
        }
        guard CGMainDisplayID() == main else { throw Failure.topologyChanging }
        return captured
    }

    /// Reject partial or changing inventories before a display configuration can begin.
    private static func stableSnapshot(_ read: () throws -> [Original]) throws -> [Original] {
        func checkedRead() throws -> [Original] {
            let result = try read().sorted { $0.id < $1.id }
            let ids = result.map(\.id)
            guard !ids.isEmpty, !ids.contains(kCGNullDirectDisplay), Set(ids).count == ids.count else {
                throw Failure.topologyChanging
            }
            return result
        }
        let first = try checkedRead(), second = try checkedRead()
        guard first.count == second.count, zip(first, second).allSatisfy({ before, after in
            before.id == after.id && sameMode(before.mode, after.mode)
                && before.mode.refreshRate == after.mode.refreshRate
                && before.origin == after.origin && before.mirror == after.mirror && before.identity == after.identity
        }) else { throw Failure.topologyChanging }
        return second
    }

    private static func sameMode(_ a: CGDisplayMode?, _ b: CGDisplayMode) -> Bool {
        guard let a else { return false }
        return a.ioDisplayModeID == b.ioDisplayModeID && a.width == b.width && a.height == b.height
            && a.pixelWidth == b.pixelWidth && a.pixelHeight == b.pixelHeight
            && abs(a.refreshRate - b.refreshRate) < 0.5
    }

    private static func sameRestoredMode(_ a: CGDisplayMode?, _ b: CGDisplayMode) -> Bool {
        guard let a else { return false }
        return sameMode(a, b) && DisplayRestoreIdentity.exactRefreshRestored(current: a.refreshRate, original: b.refreshRate)
    }

    private static func displayIdentity(_ id: CGDirectDisplayID) -> DisplayRestoreIdentity {
        DisplayRestoreIdentity(vendor: CGDisplayVendorNumber(id), model: CGDisplayModelNumber(id),
                               serial: CGDisplaySerialNumber(id), builtIn: CGDisplayIsBuiltin(id) > 0)
    }

    private static func identityCounts(_ identities: [DisplayRestoreIdentity]) -> [DisplayRestoreIdentity: Int] {
        identities.reduce(into: [:]) { $0[$1, default: 0] += 1 }
    }

    private struct OnlineIdentity: Equatable {
        let id: CGDirectDisplayID
        let identity: DisplayRestoreIdentity
    }

    /// Two complete reads prevent a partial or changing inventory from proving uniqueness.
    private static func stableOnlineIdentities() -> [CGDirectDisplayID: DisplayRestoreIdentity]? {
        func read() -> [OnlineIdentity]? {
            var count: UInt32 = 0
            guard CGGetOnlineDisplayList(0, nil, &count) == .success, count > 0 else { return nil }
            let expected = count
            var ids = [CGDirectDisplayID](repeating: 0, count: Int(expected))
            guard CGGetOnlineDisplayList(expected, &ids, &count) == .success, count == expected,
                  !ids.contains(kCGNullDirectDisplay), Set(ids).count == ids.count,
                  ids.allSatisfy(isDisplayOnline) else { return nil }
            return ids.sorted().map { OnlineIdentity(id: $0, identity: displayIdentity($0)) }
        }
        guard let first = read(), let second = read(), first == second else { return nil }
        return Dictionary(uniqueKeysWithValues: second.map { ($0.id, $0.identity) })
    }

    private static func stableOnlineIdentityCounts() -> [DisplayRestoreIdentity: Int]? {
        stableOnlineIdentities().map { identityCounts(Array($0.values)) }
    }

    private func onlineIdentitySnapshot() -> [CGDirectDisplayID: DisplayRestoreIdentity]? {
        #if DUO_DISPLAY_RESTORE_TESTING
        if let testInventory { return testInventory() }
        #endif
        return Self.stableOnlineIdentities()
    }

    private static func retainPendingMirrorGroups(_ originals: [Original], pending: [Original]) -> [Original] {
        var retained = Set(pending.map(\.id))
        var changed = true
        while changed {
            changed = false
            for old in originals where old.mirror != kCGNullDirectDisplay {
                if retained.contains(old.id) || retained.contains(old.mirror) {
                    if retained.insert(old.id).inserted { changed = true }
                    if retained.insert(old.mirror).inserted { changed = true }
                }
            }
        }
        return originals.filter { retained.contains($0.id) }
    }

    private static func unrestoredSystemMain(_ originals: [Original], expected: CGDirectDisplayID,
                                              current: CGDirectDisplayID) -> Original? {
        guard expected != current else { return nil }
        return originals.first { $0.id == expected }
    }

    private func configure(_ body: (CGDisplayConfigRef) -> CGError) throws {
        #if DUO_DISPLAY_RESTORE_TESTING
        if testInterceptConfiguration { testConfigurationAttempts += 1; return }
        #endif
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

    #if DUO_DISPLAY_RESTORE_TESTING
    /// Uses the current main mode as a read-only stand-in for a virtual desktop. No display is
    /// created, configured, captured or mirrored. Any attempted configuration is intercepted.
    static func inspectSamplingSwitchForTesting() async -> [Bool]? {
        do {
            let desktop = DuoDesktopDisplay()
            let original = try desktop.snapshot()
            let id = CGMainDisplayID()
            guard let main = original.first(where: { $0.id == id }),
                  let ceiling = samplingCeiling(refreshHz: main.mode.refreshRate), ceiling >= 120, ceiling < 240 else { return nil }
            let native = DuoDesktopResolution(width: main.mode.pixelWidth, height: main.mode.pixelHeight)
            guard native.isValid, native.accepts(width: main.mode.pixelWidth, height: main.mode.pixelHeight) else { return nil }
            desktop.originals = original
            desktop.originalMainID = id; desktop.originalSystemMainID = id; desktop.capturedID = id
            desktop.resolution = native; desktop.requestedFPS = 120
            desktop.virtualDesktopClockFPS = ceiling
            desktop.testVirtualSampling = true
            desktop.testPreventDisplayMutation = true; desktop.testInterceptConfiguration = true
            desktop.testSnapshotReads = 0
            let virtualReady = desktop.activeModeMatches && desktop.currentSamplingCeiling == ceiling
            let down = try await desktop.prepareGraphics(native, fps: 60)
            let downOnlySampled = down == id && desktop.requestedFPS == 60 && desktop.virtualDesktopClockFPS == ceiling
                && desktop.activeModeMatches && desktop.needsCadenceResampling && desktop.testSnapshotReads == 0
                && desktop.testConfigurationAttempts == 0
            let up = try await desktop.prepareGraphics(native, fps: 120)
            let upOnlySampled = up == id && desktop.requestedFPS == 120 && desktop.virtualDesktopClockFPS == ceiling
                && desktop.activeModeMatches && desktop.testSnapshotReads == 0 && desktop.testConfigurationAttempts == 0
            var rejectedTooFast = false
            do { _ = try await desktop.prepareGraphics(native, fps: ceiling + 1) }
            catch Failure.samplingClockTooSlow { rejectedTooFast = true }
            let rejectedWithoutReconfiguration = rejectedTooFast && desktop.requestedFPS == 120
                && desktop.activeModeMatches && desktop.testSnapshotReads == 0 && desktop.testConfigurationAttempts == 0
            desktop.testVirtualSampling = false; desktop.virtualDesktopClockFPS = nil
            let physical = try await desktop.prepareGraphics(native, fps: 60)
            let physicalOnlySampled = physical == id && desktop.requestedFPS == 60 && desktop.activeModeMatches
                && desktop.testSnapshotReads == 0 && desktop.testConfigurationAttempts == 0
            return [virtualReady, downOnlySampled, upOnlySampled, rejectedWithoutReconfiguration, physicalOnlySampled]
        } catch { return nil }
    }

    /// Exercise the production replay sequence with synthetic records and intercepted writes.
    /// The live mode object is read only to stand in for an available original mode.
    static func inspectSingleDisplayReplayForTesting() -> [Bool]? {
        let id = CGMainDisplayID()
        guard isDisplayOnline(id), let mode = CGDisplayCopyDisplayMode(id), mode.refreshRate > 0 else { return nil }
        let identity = DisplayRestoreIdentity(vendor: 42, model: 7, serial: 1234, builtIn: false)
        func display(identity: DisplayRestoreIdentity, modeID: Int32, x: Int32 = 0) -> DisplayRecoveryRecord.Display {
            .init(id: id, identity: identity, modeID: modeID, width: mode.width, height: mode.height,
                  pixelWidth: mode.pixelWidth, pixelHeight: mode.pixelHeight, refresh: mode.refreshRate,
                  originX: x, originY: 0, mirror: 0)
        }
        let token = UUID()
        let saved = display(identity: identity, modeID: mode.ioDisplayModeID)
        let original = DisplayRecoveryRecord(version: 1, token: token, main: id, displays: [saved])
        let changedID = mode.ioDisplayModeID == Int32.max ? mode.ioDisplayModeID - 1 : mode.ioDisplayModeID + 1
        let expected = DisplayRecoveryRecord(version: 1, token: token, main: id,
                                             displays: [display(identity: identity, modeID: changedID)])
        let intent = DisplayRecoveryIntent(version: 1, expected: expected)
        let moved = DisplayRecoveryRecord(version: 1, token: token, main: id,
                                          displays: [display(identity: identity, modeID: changedID, x: 1)])
        let replacement = DisplayRestoreIdentity(vendor: 42, model: 7, serial: 9876, builtIn: false)
        let replaced = DisplayRecoveryRecord(version: 1, token: token, main: id,
                                             displays: [display(identity: replacement, modeID: changedID)])
        func run(current: DisplayRecoveryRecord, latest: DisplayRecoveryRecord, final: DisplayRecoveryRecord,
                 available: [CGDisplayMode]) -> (Bool, Int) {
            let desktop = DuoDesktopDisplay()
            desktop.testInterceptConfiguration = true
            desktop.testRecoveryModes = available
            var state = latest
            desktop.testRecoveryRead = { state }
            desktop.testAfterRecoveryConfiguration = { state = final }
            let result = (try? desktop.recoverSingleDisplay(original, intent: intent, current: current)) ?? false
            return (result, desktop.testConfigurationAttempts)
        }
        let accepted = run(current: expected, latest: expected, final: original, available: [mode])
        let initialDrift = run(current: moved, latest: expected, final: original, available: [mode])
        let laterDrift = run(current: expected, latest: moved, final: original, available: [mode])
        let laterReplacement = run(current: expected, latest: replaced, final: original, available: [mode])
        let missingMode = run(current: expected, latest: expected, final: original, available: [])
        let ambiguousMode = run(current: expected, latest: expected, final: original, available: [mode, mode])
        let notRestored = run(current: expected, latest: expected, final: expected, available: [mode])
        return [accepted.0 && accepted.1 == 1, !initialDrift.0 && initialDrift.1 == 0,
                !laterDrift.0 && laterDrift.1 == 0, !laterReplacement.0 && laterReplacement.1 == 0,
                !missingMode.0 && missingMode.1 == 0, !ambiguousMode.0 && ambiguousMode.1 == 0,
                !notRestored.0 && notRestored.1 == 1]
    }

    /// Exercise the real restore path with an unavailable ID; no live display is configured.
    static func inspectOfflineRestoreForTesting() -> (Bool, Bool, Bool, Bool)? {
        let missing = CGDirectDisplayID.max
        guard !isDisplayOnline(missing), let mode = CGDisplayCopyDisplayMode(CGMainDisplayID()) else { return nil }
        let desktop = DuoDesktopDisplay()
        desktop.originals = [Original(id: missing, mode: mode, origin: .zero, mirror: kCGNullDirectDisplay)]
        desktop.didAttemptDisplayChange = true
        let first = desktop.restore()
        let keptAfterFirst = !desktop.originals.isEmpty
        let second = desktop.restore()
        return (first, keptAfterFirst, second, !desktop.originals.isEmpty)
    }

    static func inspectPendingMirrorGroupsForTesting() -> [[CGDirectDisplayID]]? {
        guard let mode = CGDisplayCopyDisplayMode(CGMainDisplayID()) else { return nil }
        let main = Original(id: 101, mode: mode, origin: .zero, mirror: kCGNullDirectDisplay)
        let slave = Original(id: 102, mode: mode, origin: .zero, mirror: 101)
        let unrelated = Original(id: 103, mode: mode, origin: .zero, mirror: kCGNullDirectDisplay)
        let originals = [main, slave, unrelated]
        return [[slave], [main], [unrelated]].map { pending in
            retainPendingMirrorGroups(originals, pending: pending).map(\.id)
        }
    }

    static func inspectSnapshotStabilityForTesting() -> [Bool]? {
        guard let mode = CGDisplayCopyDisplayMode(CGMainDisplayID()) else { return nil }
        let first = Original(id: 101, mode: mode, origin: .zero, mirror: kCGNullDirectDisplay)
        let second = Original(id: 102, mode: mode, origin: CGPoint(x: 100, y: 0), mirror: kCGNullDirectDisplay)
        let moved = Original(id: 102, mode: mode, origin: CGPoint(x: 101, y: 0), mirror: kCGNullDirectDisplay)
        let mirrored = Original(id: 102, mode: mode, origin: CGPoint(x: 100, y: 0), mirror: 101)
        let invalid = Original(id: kCGNullDirectDisplay, mode: mode, origin: .zero, mirror: kCGNullDirectDisplay)
        let oneIdentity = DisplayRestoreIdentity(vendor: 1, model: 2, serial: 3, builtIn: false)
        let otherIdentity = DisplayRestoreIdentity(vendor: 1, model: 2, serial: 4, builtIn: false)
        let identified = Original(id: 101, mode: mode, origin: .zero, mirror: kCGNullDirectDisplay, identity: oneIdentity)
        let replaced = Original(id: 101, mode: mode, origin: .zero, mirror: kCGNullDirectDisplay, identity: otherIdentity)
        func accepts(_ before: [Original], _ after: [Original]) -> Bool {
            var calls = 0
            return (try? stableSnapshot {
                calls += 1
                return calls == 1 ? before : after
            }) != nil
        }
        return [accepts([first, second], [second, first]),
                !accepts([first, second], [first]),
                !accepts([first], [first, second]),
                !accepts([first, second], [first, moved]),
                !accepts([first, second], [first, mirrored]),
                !accepts([first, first], [first, first]),
                !accepts([invalid], [invalid]),
                !accepts([], []),
                (try? stableSnapshot { throw Failure.topologyChanging }) == nil,
                !accepts([identified], [replaced])]
    }

    static func inspectLiveSnapshotForTesting() -> Bool {
        guard let originals = try? DuoDesktopDisplay().snapshot() else { return false }
        let main = availableMainDisplayID()
        let savedCounts = identityCounts(originals.compactMap(\.identity))
        return originals.contains { $0.id == main && isDisplayOnline($0.id) }
            && originals.allSatisfy { $0.identity != nil }
            && stableOnlineIdentityCounts() == savedCounts
    }

    static func inspectSystemMainVerificationForTesting() -> Bool? {
        guard let mode = CGDisplayCopyDisplayMode(CGMainDisplayID()) else { return nil }
        let original = Original(id: 101, mode: mode, origin: .zero, mirror: kCGNullDirectDisplay)
        return unrestoredSystemMain([original], expected: 101, current: 102)?.id == 101
            && unrestoredSystemMain([original], expected: 101, current: 101) == nil
            && unrestoredSystemMain([original], expected: 999, current: 101) == nil
    }

    /// Drive the real restore classifier against synthetic inventories. Any configuration attempt
    /// is intercepted before CoreGraphics, so even an incorrect result cannot alter a display.
    static func inspectRestoreIdentityGuardForTesting() -> [Bool]? {
        let id = CGMainDisplayID()
        guard isDisplayOnline(id), let mode = CGDisplayCopyDisplayMode(id) else { return nil }
        let origin = CGDisplayBounds(id).origin, mirror = CGDisplayMirrorsDisplay(id)
        let identified = DisplayRestoreIdentity(vendor: 42, model: 7, serial: 1234, builtIn: false)
        let unidentifiable = DisplayRestoreIdentity(vendor: 42, model: 7, serial: 0, builtIn: false)
        let other = DisplayRestoreIdentity(vendor: 42, model: 7, serial: 9876, builtIn: false)
        let secondID: CGDirectDisplayID = id == 9_999 ? 9_998 : 9_999
        func run(expected: DisplayRestoreIdentity, inventory: [CGDirectDisplayID: DisplayRestoreIdentity]?,
                 wasOffline: Bool, originalCount: Int) -> (Bool, Bool, Bool, Int) {
            let desktop = DuoDesktopDisplay()
            desktop.originals = [Original(id: id, mode: mode, origin: origin, mirror: mirror, identity: expected)]
            desktop.didAttemptDisplayChange = true
            desktop.originalIdentityCounts = [expected: originalCount]
            if wasOffline { desktop.observedOffline.insert(id) }
            desktop.testInventory = { inventory }
            desktop.testInterceptConfiguration = true
            let result = desktop.restore()
            return (result, !desktop.originals.isEmpty, desktop.observedOffline.contains(id), desktop.testConfigurationAttempts)
        }
        let changed = run(expected: identified, inventory: [id: other], wasOffline: false, originalCount: 1)
        let missingSerial = run(expected: unidentifiable, inventory: [id: unidentifiable], wasOffline: true, originalCount: 1)
        let duplicate = run(expected: identified, inventory: [id: identified, secondID: identified], wasOffline: true, originalCount: 1)
        let unstable = run(expected: identified, inventory: nil, wasOffline: false, originalCount: 1)
        let unique = run(expected: identified, inventory: [id: identified], wasOffline: true, originalCount: 1)
        let changing = DuoDesktopDisplay()
        changing.originals = [Original(id: id, mode: mode, origin: origin, mirror: mirror, identity: identified)]
        changing.didAttemptDisplayChange = true
        changing.originalIdentityCounts = [identified: 1]
        var reads = 0
        changing.testInventory = { reads += 1; return [id: reads == 1 ? identified : other] }
        changing.testInterceptConfiguration = true
        let changedDuringRestore = changing.restore()
        return [!changed.0 && changed.1 && changed.2 && changed.3 == 0,
                !missingSerial.0 && missingSerial.1 && missingSerial.2 && missingSerial.3 == 0,
                !duplicate.0 && duplicate.1 && duplicate.2 && duplicate.3 == 0,
                !unstable.0 && unstable.1 && !unstable.2 && unstable.3 == 0,
                unique.0 && !unique.1 && unique.3 == 1,
                !changedDuringRestore && !changing.originals.isEmpty && changing.observedOffline.contains(id)
                    && changing.testConfigurationAttempts == 1]
    }

    static func inspectBlockedPrepareForTesting() async -> Bool? {
        let missing = CGDirectDisplayID.max
        guard !isDisplayOnline(missing), let mode = CGDisplayCopyDisplayMode(CGMainDisplayID()) else { return nil }
        let desktop = DuoDesktopDisplay()
        desktop.originals = [Original(id: missing, mode: mode, origin: .zero, mirror: kCGNullDirectDisplay)]
        desktop.didAttemptDisplayChange = true
        do {
            _ = try await desktop.prepareGraphics(DuoDesktopResolution(width: 2007, height: 1427), fps: 120)
            return false
        } catch Failure.restorePending {
            return desktop.originals.count == 1 && desktop.originals[0].id == missing
        } catch { return false }
    }

    /// A stale, mismatched journal must block the production preparation path without any display
    /// change. The final mutation gate is independently intercepted, even if the guard regresses.
    static func inspectPersistedRecoveryGuardForTesting(directory: URL) async -> Bool {
        do {
            let probe = DuoDesktopDisplay(recoveryDirectory: directory)
            probe.testPreventDisplayMutation = true
            probe.testInterceptConfiguration = true
            let originals = try probe.snapshot()
            let current = try recoveryRecord(originals, systemMain: CGMainDisplayID())
            guard let first = current.displays.first else { return false }
            let changed = DisplayRecoveryRecord.Display(id: first.id, identity: first.identity, modeID: first.modeID,
                width: first.width, height: first.height, pixelWidth: first.pixelWidth, pixelHeight: first.pixelHeight,
                refresh: first.refresh, originX: first.originX == 0 ? 1 : 0, originY: first.originY, mirror: first.mirror)
            let prior = DisplayRecoveryRecord(version: 1, token: UUID(), main: current.main,
                                              displays: [changed] + current.displays.dropFirst())
            do { let store = try DisplayRecoveryStore(directory: directory); try store.save(prior) }
            do {
                _ = try await probe.prepareGraphics(DuoDesktopResolution(width: 2007, height: 1427), fps: 120)
                return false
            } catch Failure.restorePending { }
            let store = try DisplayRecoveryStore(directory: directory)
            return try store.load() == prior && probe.testConfigurationAttempts == 0
        } catch { return false }
    }

    /// Neither failed publication nor a changed inventory may lead to a configuration write;
    /// failed journal cleanup stays retryable without reconfiguring already-restored displays.
    static func inspectRecoveryCleanupForTesting(directory: URL) -> [Bool]? {
        do {
            let desktop = DuoDesktopDisplay(recoveryDirectory: directory)
            desktop.testInterceptConfiguration = true
            let originals = try desktop.snapshot()
            let current = try recoveryRecord(originals, systemMain: CGMainDisplayID())
            guard let first = current.displays.first else { return nil }
            let changed = DisplayRecoveryRecord.Display(id: first.id, identity: first.identity, modeID: first.modeID,
                width: first.width, height: first.height, pixelWidth: first.pixelWidth, pixelHeight: first.pixelHeight,
                refresh: first.refresh, originX: first.originX == 0 ? 1 : 0, originY: first.originY, mirror: first.mirror)
            let mismatched = DisplayRecoveryRecord(version: 1, token: UUID(), main: current.main,
                                                   displays: [changed] + current.displays.dropFirst())
            desktop.originals = originals
            desktop.recoveryStore = try DisplayRecoveryStore(directory: directory)
            let mismatchRejected: Bool
            do { try desktop.persistRecovery(mismatched); mismatchRejected = false }
            catch Failure.topologyChanging { mismatchRejected = true }
            let mismatchCleared = desktop.restore() && desktop.testConfigurationAttempts == 0
            let firstCheck = mismatchRejected && mismatchCleared

            desktop.originals = originals
            let store = try DisplayRecoveryStore(directory: directory)
            desktop.recoveryStore = store
            try store.save(current)
            desktop.recoveryToken = current.token
            let path = directory.appendingPathComponent("pending-display.json").path
            try FileManager.default.setAttributes([.posixPermissions: 0o644], ofItemAtPath: path)
            let blocked = !desktop.restore() && FileManager.default.fileExists(atPath: path)
                && desktop.testConfigurationAttempts == 0
            try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: path)
            let retried = desktop.restore() && !FileManager.default.fileExists(atPath: path)
                && desktop.testConfigurationAttempts == 0
            return [firstCheck, blocked, retried]
        } catch { return nil }
    }
    #endif
}
