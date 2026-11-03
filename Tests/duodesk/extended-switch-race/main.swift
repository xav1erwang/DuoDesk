// Copyright 2026 DUO你电脑 contributors. SPDX-License-Identifier: Apache-2.0
// Drives the production coordinator and viewport handler with a synthetic host and an unstarted
// connection. --live-virtual also creates and removes one independent virtual display. Neither
// mode starts capture, sends input, opens a listener, accesses a keychain or reads user content.
import Foundation
import Network
import CoreGraphics
import AppKit
import StreamProtocol

struct CheckFailure: Error { let message: String }

struct DisplayState: Equatable {
    let id: CGDirectDisplayID
    let mode: Int32
    let pixelWidth: Int
    let pixelHeight: Int
    let refresh: Double
    let bounds: CGRect
    let mirror: CGDirectDisplayID
    let main: Bool
    static func read(_ id: CGDirectDisplayID) -> DisplayState? {
        guard CGDisplayIsOnline(id) > 0, let mode = CGDisplayCopyDisplayMode(id) else { return nil }
        return DisplayState(id: id, mode: mode.ioDisplayModeID, pixelWidth: mode.pixelWidth,
                            pixelHeight: mode.pixelHeight, refresh: mode.refreshRate,
                            bounds: CGDisplayBounds(id), mirror: CGDisplayMirrorsDisplay(id),
                            main: CGMainDisplayID() == id)
    }
}

final class DisplayMonitor: @unchecked Sendable {
    private let lock = NSLock()
    private let original: [CGDirectDisplayID: DisplayState]
    private var changed = false, modeEvents = 0, afterEvents = 0
    init(_ states: [DisplayState]) { original = Dictionary(uniqueKeysWithValues: states.map { ($0.id, $0) }) }
    func observe(_ id: CGDirectDisplayID, flags: CGDisplayChangeSummaryFlags) {
        guard let before = original[id], !flags.contains(.beginConfigurationFlag) else { return }
        let after = DisplayState.read(id)
        lock.withLock {
            afterEvents += 1
            if flags.contains(.setModeFlag) { modeEvents += 1 }
            if before != after { changed = true }
        }
    }
    func result() -> (changed: Bool, modeEvents: Int, afterEvents: Int) {
        lock.withLock { (changed, modeEvents, afterEvents) }
    }
}

let displayCallback: CGDisplayReconfigurationCallBack = { id, flags, context in
    guard let context else { return }
    Unmanaged<DisplayMonitor>.fromOpaque(context).takeUnretainedValue().observe(id, flags: flags)
}

@main
@MainActor
struct Checks {
    enum Outcome { case kept, cancelled, disconnected, shutdown }
    static func expect(_ condition: @autoclosure () -> Bool, _ message: String) throws {
        guard condition() else { throw CheckFailure(message: message) }
    }

    static func waitFor(_ condition: () -> Bool, message: String) async throws {
        let deadline = ContinuousClock.now + .seconds(3)
        while !condition() {
            guard ContinuousClock.now < deadline else { throw CheckFailure(message: message) }
            try await Task.sleep(for: .milliseconds(10))
        }
    }

    static func retireMirrorBeforeExtension() async throws {
        let coordinator = try StreamCoordinator(config: .standard, synthetic: true, appKitLoop: false)
        var monitor: DisplayMonitor?
        var context: UnsafeMutableRawPointer?
        defer {
            coordinator.shutdownForExit()
            if let context { CGDisplayRemoveReconfigurationCallback(displayCallback, context) }
            withExtendedLifetime(monitor) {}
        }
        let mirror = coordinator.mirroredDesktop
        let saved = try mirror.snapshot()
        let main = CGMainDisplayID()
        guard saved.contains(where: { $0.id == main }) else { throw CheckFailure(message: "Main display unavailable") }
        let states = saved.compactMap { DisplayState.read($0.id) }
        guard states.count == saved.count else { throw CheckFailure(message: "Display inventory changed") }
        let liveVirtual = CommandLine.arguments.contains("--live-virtual")
        if liveVirtual {
            print("EXTENDED LAYOUT BASELINE: \(states)")
            let observer = DisplayMonitor(states)
            let pointer = Unmanaged.passUnretained(observer).toOpaque()
            guard CGDisplayRegisterReconfigurationCallback(displayCallback, pointer) == .success else {
                throw CheckFailure(message: "Display monitor unavailable")
            }
            monitor = observer
            context = pointer
        }
        // Simulate an outstanding mirror restoration using a read-only live snapshot. Intercept
        // every configuration attempt: this test must never submit a physical display change.
        mirror.originals = saved
        mirror.originalIdentityCounts = DuoDesktopDisplay.identityCounts(saved.compactMap(\.identity))
        mirror.originalMainID = main
        mirror.originalSystemMainID = main
        mirror.didAttemptDisplayChange = true
        mirror.testInterceptConfiguration = true

        var rejectedStalePreparation = false
        do {
            _ = try await mirror.prepareGraphics(DuoDesktopResolution(width: 320, height: 240), fps: 60,
                                                 requestIsCurrent: { false })
        } catch { rejectedStalePreparation = true }
        try expect(rejectedStalePreparation && mirror.originals.count == saved.count && mirror.testConfigurationAttempts == 0,
                   "A superseded preparation touched the mirror recovery state")

        try await coordinator.setDesktopLayout(extended: true)
        try expect(coordinator.duoDesktop === coordinator.extendedDesktop, "Extension was not selected")
        try expect(mirror.originals.isEmpty && mirror.testConfigurationAttempts == 1,
                   "Entering extension did not restore and retire the mirror session")
        var virtualID: CGDirectDisplayID = 0
        do {
            if liveVirtual {
                virtualID = try await coordinator.extendedDesktop.prepareGraphics(
                    DuoDesktopResolution(width: 2007, height: 2853), fps: 120)
                guard let mode = CGDisplayCopyDisplayMode(virtualID) else { throw CheckFailure(message: "Virtual mode unavailable") }
                try expect(mode.pixelWidth == 2008 && mode.pixelHeight == 2854 && mode.refreshRate == 120
                           && CGDisplayMirrorsDisplay(virtualID) == kCGNullDirectDisplay,
                           "The extension was not an independent native-size display")
                try expect(states.allSatisfy({ DisplayState.read($0.id) == $0 }), "An original display changed during extension")
            }
            try await coordinator.setDesktopLayout(extended: false)
        } catch {
            _ = coordinator.extendedDesktop.restore()
            try? await coordinator.extendedDesktop.waitForRetiredVirtualDisplay()
            if liveVirtual {
                print("EXTENDED LAYOUT FAILURE CLEANUP: originals=\(states.map { DisplayState.read($0.id) as Any }), observations=\(String(describing: monitor?.result()))")
            }
            throw error
        }
        if liveVirtual {
            try expect(CGDisplayIsOnline(virtualID) <= 0, "The extension did not retire before mirror resumed")
            try await Task.sleep(for: .milliseconds(500))
            let observed = monitor?.result()
            try expect(states.allSatisfy({ DisplayState.read($0.id) == $0 }) && observed?.changed == false
                       && observed?.modeEvents == 0 && (observed?.afterEvents ?? 0) > 0,
                       "An original display changed while switching the extension")
            print("EXTENDED LAYOUT LIVE: 2008×2854 @120 Hz independent virtual display added and removed; original displays unchanged, mode events=0")
        }
        try expect(coordinator.duoDesktop === mirror && mirror.originals.isEmpty
                   && mirror.testConfigurationAttempts == 1,
                   "Returning to mirror reused a retired mirror snapshot")

        coordinator.clientExtendedRequests[ObjectIdentifier(coordinator)] = UUID()
        coordinator.discardStaleDesktopAttempt()
        try expect(mirror.originals.isEmpty && mirror.testConfigurationAttempts == 1,
                   "A stale mirror attempt reused the retired physical recovery state")
        coordinator.clientExtendedRequests.removeAll()
        try expect(coordinator.restoreDesktopSession(), "Ending the session did not restore its mirror snapshot")
        try expect(mirror.originals.isEmpty && mirror.testConfigurationAttempts == 1,
                   "Ending the session repeated the retired mirror restoration")
    }

    static func failedPreparationPreservesNewerExtension() async throws {
        for allowRestore in [false, true] {
            let probe = DuoDesktopDisplay(layout: .mirrored)
            // Any candidate physical write is rejected by the test gate. The intentionally
            // unsupported size or that gate will fail before changing an actual display.
            probe.testPreventDisplayMutation = true
            probe.testInterceptConfiguration = true
            var failed = false, checked = false
            do {
                _ = try await probe.prepareGraphics(DuoDesktopResolution(width: 8191, height: 8191), fps: 60,
                                                    restoreOnFailure: { checked = true; return allowRestore })
            } catch { failed = true }
            try expect(failed && checked && probe.testConfigurationAttempts == 0,
                       "The preparation failure did not reach its guarded rollback")
            try expect(probe.originals.isEmpty == allowRestore,
                       "The preparation failure discarded the wrong recovery state")
            _ = probe.restore()
        }
    }

    static func scenario(_ outcome: Outcome) async throws {
        let coordinator = try StreamCoordinator(config: .standard, synthetic: true, appKitLoop: false)
        // This is an isolated test fixture: do not use the machine's hardware encoder, connect a
        // socket, start the server/catalog, or permit a real display/input operation.
        coordinator.useSoftwareEncoder = true
        coordinator.extendedDesktopAvailable = true
        let connection = NWConnection(host: "127.0.0.1", port: 9, using: .tcp)
        let id = ObjectIdentifier(connection)
        coordinator.routes[id] = .home(.loopback, peer: nil)
        coordinator.catalog.clientCount = 1
        let mirror = coordinator.mirroredDesktop
        let saved = try mirror.snapshot()
        let main = CGMainDisplayID()
        mirror.originals = saved
        mirror.originalIdentityCounts = DuoDesktopDisplay.identityCounts(saved.compactMap(\.identity))
        mirror.originalMainID = main
        mirror.originalSystemMainID = main
        mirror.didAttemptDisplayChange = true
        mirror.testInterceptConfiguration = true
        defer { coordinator.shutdownForExit() }

        await coordinator.applyViewportToActiveWindow()
        try expect(coordinator.active == .none, "An idle host without an extension should stay idle")
        coordinator.switching = true
        await coordinator.applyViewportToActiveWindow()
        try expect(coordinator.viewportArrivedWhileSwitching,
                   "A deferred viewport arriving during the next switch was lost")
        coordinator.switching = false
        coordinator.viewportArrivedWhileSwitching = false

        // Hold the real capture queue so select(.none) is suspended in its ordinary stop/drain.
        let entered = DispatchSemaphore(value: 0), release = DispatchSemaphore(value: 0)
        coordinator.capture.queue.async { entered.signal(); release.wait() }
        defer { release.signal() }
        try expect(entered.wait(timeout: .now() + 2) == .success, "Could not hold the capture queue")
        let stopping = Task { @MainActor in await coordinator.select(.none) }
        try await waitFor({ coordinator.switching }, message: "The old switch did not start")

        let token = UUID()
        let viewport = Viewport(width: 320, height: 240, scale: nil,
                                desktopResolution: DuoDesktopResolution(width: 320, height: 240),
                                extendedDesktop: true, extendedRequestID: token)
        await coordinator.handle(StreamMessage(kind: .viewport, timestamp: 0, isKeyframe: false,
                                               payload: Wire.encode(viewport)), from: connection)
        try expect(coordinator.clientExtendedRequests[id] == token && coordinator.viewportArrivedWhileSwitching,
                   "The extension request was not deferred by the real viewport handler")
        if outcome == .cancelled {
            let mirror = Viewport(width: 320, height: 240, scale: nil,
                                  desktopResolution: DuoDesktopResolution(width: 320, height: 240))
            await coordinator.handle(StreamMessage(kind: .viewport, timestamp: 0, isKeyframe: false,
                                                   payload: Wire.encode(mirror)), from: connection)
            try expect(coordinator.clientExtendedRequests.isEmpty, "The later cancellation was not recorded")
        } else if outcome == .disconnected {
            coordinator.server.onClientDisconnected?(connection)
            coordinator.server.onClientCountChanged?(0)
            try await waitFor({ coordinator.catalog.clientCount == 0 && coordinator.clientExtendedRequests.isEmpty },
                              message: "The disconnect did not clear the deferred extension")
        } else if outcome == .shutdown {
            coordinator.shutdownForExit()
        }
        release.signal()
        await stopping.value

        if outcome != .kept {
            try await Task.sleep(for: .milliseconds(150))
            try expect(coordinator.active == .none, "An extension restarted after cancellation, disconnect or shutdown")
        } else {
            try await waitFor({ coordinator.active == .desktop },
                              message: "Deferred extension was lost when the preceding switch ended idle")
            try expect(coordinator.clientExtendedRequests[id] == token, "The accepted request was lost")
            try expect(mirror.testConfigurationAttempts == 0 && mirror.originals.count == saved.count,
                       "An earlier stop restored the mirror after the extension request arrived")
        }
        coordinator.clientExtendedRequests.removeAll()
        coordinator.clientDesktopResolutions.removeAll()
        coordinator.catalog.clientCount = 0
        await coordinator.select(.none)
    }

    /// Exercise the real selection and startup-failure path with a synthetic stream. In
    /// particular, no client-side automatic desktop retry is sent to rescue the host.
    static func startupFailureResumesMirror() async throws {
        let coordinator = try StreamCoordinator(config: .standard, synthetic: true, appKitLoop: false)
        coordinator.useSoftwareEncoder = true
        coordinator.extendedDesktopAvailable = true
        let connection = NWConnection(host: "127.0.0.1", port: 9, using: .tcp)
        let id = ObjectIdentifier(connection)
        coordinator.routes[id] = .home(.loopback, peer: nil)
        coordinator.catalog.clientCount = 1
        let mirror = DuoDesktopResolution(width: 320, height: 240)
        let full = DuoDesktopResolution(width: 320, height: 480)
        coordinator.clientDesktopResolutions[id] = full
        coordinator.mirrorResolutionBeforeExtension[id] = mirror
        coordinator.clientExtendedRequests[id] = UUID()
        coordinator.testFailExtendedStart = true
        coordinator.active = .desktop
        defer { coordinator.shutdownForExit() }

        await coordinator.select(.desktop)
        try expect(coordinator.clientExtendedRequests[id] == nil
                   && coordinator.clientDesktopResolutions[id] == mirror,
                   "A failed extension did not restore the mirror request")
        try await waitFor({ coordinator.active == .desktop && !coordinator.switching },
                          message: "A failed extension left the mirror idle without a client retry")
        try expect(coordinator.encoderWidth == mirror.encodedWidth && coordinator.encoderHeight == mirror.encodedHeight,
                   "The restarted stream did not use the retained mirror dimensions")
        coordinator.clientDesktopResolutions.removeAll()
        coordinator.catalog.clientCount = 0
        await coordinator.select(.none)
    }

    static func startupFailureKeepsNewerChoices() throws {
        for scenario in 0..<4 {
            let coordinator = try StreamCoordinator(config: .standard, synthetic: true, appKitLoop: false)
            defer { coordinator.shutdownForExit() }
            let connection = NWConnection(host: "127.0.0.1", port: 9, using: .tcp)
            let id = ObjectIdentifier(connection), request = UUID()
            let mirror = DuoDesktopResolution(width: 320, height: 240)
            coordinator.catalog.clientCount = scenario == 2 ? 0 : 1
            coordinator.clientDesktopResolutions[id] = DuoDesktopResolution(width: 320, height: 480)
            coordinator.clientExtendedRequests[id] = request
            if scenario != 3 { coordinator.mirrorResolutionBeforeExtension[id] = mirror }
            if scenario == 0 { coordinator.pickArrivedWhileSwitching = .some(.none) }
            coordinator.failExtendedStartup(id, requestID: scenario == 1 ? UUID() : request, message: "test")
            switch scenario {
            case 0:
                try expect(coordinator.pickArrivedWhileSwitching == .some(.none),
                           "A failure replaced a newer stop choice")
            case 1:
                try expect(coordinator.clientExtendedRequests[id] == request && coordinator.pickArrivedWhileSwitching == nil,
                           "A stale failure changed the current extension")
            case 2:
                try expect(coordinator.pickArrivedWhileSwitching == nil,
                           "A failure queued a mirror after the last client left")
            default:
                try expect(coordinator.pickArrivedWhileSwitching == nil,
                           "A failure invented a mirror without a retained size")
            }
        }
    }

    /// The launched window appears while a selection is suspended in capture stop. This uses a
    /// synthetic host and a fake catalog entry; no actual application is launched or activated.
    static func launchedWindowDuringSwitch(disconnect: Bool) async throws {
        let coordinator = try StreamCoordinator(config: .standard, synthetic: true, appKitLoop: false)
        coordinator.useSoftwareEncoder = true
        coordinator.catalog.clientCount = 1
        let fake = WindowInfo(id: 4242, title: "fixture", appName: "fixture",
                              bundleID: "org.duodesk.fixture.launch", width: 320, height: 240)
        coordinator.catalog.infos = [fake]
        coordinator.clientDesktopResolutions[ObjectIdentifier(coordinator)] = DuoDesktopResolution(width: 320, height: 240)
        defer { coordinator.shutdownForExit() }

        let entered = DispatchSemaphore(value: 0), release = DispatchSemaphore(value: 0)
        coordinator.capture.queue.async { entered.signal(); release.wait() }
        defer { release.signal() }
        try expect(entered.wait(timeout: .now() + 2) == .success, "Could not hold the capture queue")
        let starting = Task { @MainActor in await coordinator.select(.desktop) }
        try await waitFor({ coordinator.switching }, message: "The selection did not start")
        coordinator.pendingLaunch = fake.bundleID
        await coordinator.windowsChanged([fake])
        try expect(coordinator.pendingLaunch == fake.bundleID,
                   "A launched window was discarded while the desktop was switching")
        if disconnect {
            coordinator.server.onClientCountChanged?(0)
            try await waitFor({ coordinator.catalog.clientCount == 0 && coordinator.pendingLaunch == nil },
                              message: "A disconnected session kept its pending launch")
        }
        release.signal()
        await starting.value
        if disconnect {
            try await waitFor({ coordinator.active == .none && !coordinator.switching },
                              message: "A disconnected client left a stream running")
        } else {
            try await waitFor({ coordinator.pendingLaunch == nil && coordinator.active == .desktop && !coordinator.switching },
                              message: "The launched window was not revisited after the switch")
        }
        coordinator.clientDesktopResolutions.removeAll()
        coordinator.catalog.clientCount = 0
        await coordinator.select(.none)
    }

    /// A released virtual display can remain in WindowServer's online list for a while. Use an
    /// existing display ID solely as a read-only stand-in; no real display is created or changed.
    static func waitBeforeReplacingRetiringExtension() async throws {
        let display = DuoDesktopDisplay(layout: .extended)
        let online = CGMainDisplayID()
        try expect(DuoDesktopDisplay.isDisplayOnline(online), "No online display for the retirement fixture")
        display.testPreventDisplayMutation = true
        display.testInterceptConfiguration = true
        var reachedRestore = false
        display.testAfterDisplayRestore = { [weak display] in
            reachedRestore = true
            display?.retiringVirtualDisplayID = online
        }
        defer { display.retiringVirtualDisplayID = nil; _ = display.restore() }
        var refusal: DuoDesktopDisplay.Failure?
        do {
            _ = try await display.prepareGraphics(DuoDesktopResolution(width: 320, height: 480), fps: 60)
        } catch { refusal = error as? DuoDesktopDisplay.Failure }
        guard case .restorePending? = refusal else {
            throw CheckFailure(message: "Replacement did not wait for an online retiring display")
        }
        try expect(reachedRestore && display.retiringVirtualDisplayID == online
                   && display.testSnapshotReads == 0 && display.testConfigurationAttempts == 0 && display.temporary == nil,
                   "The retirement guard changed a display or lost its pending ID")
    }

    /// A newer request can arrive while retirement is being resolved. It wins before any new
    /// display inventory or mutation, even if the retiring ID has already gone offline.
    static func staleRequestAfterRetirement() async throws {
        let display = DuoDesktopDisplay(layout: .extended)
        let offline = CGDirectDisplayID.max
        try expect(!DuoDesktopDisplay.isDisplayOnline(offline), "Retirement fixture ID is already in use")
        display.testPreventDisplayMutation = true
        display.testInterceptConfiguration = true
        var current = true
        display.testAfterDisplayRestore = { [weak display] in
            current = false
            display?.retiringVirtualDisplayID = offline
        }
        defer { display.retiringVirtualDisplayID = nil; _ = display.restore() }
        var refusal: DuoDesktopDisplay.Failure?
        do {
            _ = try await display.prepareGraphics(DuoDesktopResolution(width: 320, height: 480), fps: 60,
                                                   requestIsCurrent: { current })
        } catch { refusal = error as? DuoDesktopDisplay.Failure }
        guard case .topologyChanging? = refusal else {
            throw CheckFailure(message: "A superseded request continued after display retirement")
        }
        try expect(display.testSnapshotReads == 0 && display.testConfigurationAttempts == 0 && display.temporary == nil,
                   "A superseded request read or changed the replacement topology")
    }

    static func main() {
        let app = NSApplication.shared
        app.setActivationPolicy(.prohibited)
        Task { @MainActor in
            do {
                if CommandLine.arguments.contains("--retire-only") {
                    try await waitBeforeReplacingRetiringExtension()
                    try await staleRequestAfterRetirement()
                    print("EXTENSION RETIREMENT PASS: wait for retirement and reject stale requests; no display created or modified")
                    exit(0)
                }
                if CommandLine.arguments.contains("--launch-only") {
                    try await launchedWindowDuringSwitch(disconnect: false)
                    try await launchedWindowDuringSwitch(disconnect: true)
                    print("PENDING LAUNCH PASS: selection resumes after switching and is cleared on disconnect; no real app, screen capture or input")
                    exit(0)
                }
                if !CommandLine.arguments.contains("--failure-only") {
                    try await retireMirrorBeforeExtension()
                    try await failedPreparationPreservesNewerExtension()
                    try await scenario(.kept)
                    try await scenario(.cancelled)
                    try await scenario(.disconnected)
                    try await scenario(.shutdown)
                }
                try await startupFailureResumesMirror()
                try startupFailureKeepsNewerChoices()
                print("EXTENDED STARTUP FAILURE PASS: mirror resumes; newer choices, stale failures and disconnect are respected; no display writes")
                exit(0)
            } catch {
                print("EXTENDED SWITCH RACE FAIL: \(error)")
                exit(1)
            }
        }
        app.run()
    }
}
