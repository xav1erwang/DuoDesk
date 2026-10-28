// Copyright 2026 DUO你电脑 contributors. SPDX-License-Identifier: Apache-2.0
// Injected runtime only: no private framework, capture permission, screen or system input used.
import CoreMedia
import CoreVideo
import Foundation
import IOSurface
import StreamProtocol

final class FakeRuntime: TouchBarVirtualRuntime, @unchecked Sendable {
    private let lock = NSLock()
    private let blockStart: DispatchSemaphore?
    private var queue: DispatchQueue?
    private var surface: (@Sendable (IOSurfaceRef, CMTime) -> Void)?
    private var unavailable: (@Sendable () -> Void)?
    private var stopped: (@Sendable () -> Void)?
    private var starts = 0, stops = 0
    init(blockStart: DispatchSemaphore? = nil) { self.blockStart = blockStart }
    func start(queue: DispatchQueue, onSurface: @escaping @Sendable (IOSurfaceRef, CMTime) -> Void,
               onUnavailable: @escaping @Sendable () -> Void,
               onStopped: @escaping @Sendable () -> Void) throws {
        lock.withLock { starts += 1; self.queue = queue; surface = onSurface; unavailable = onUnavailable; stopped = onStopped }
        blockStart?.wait()
    }
    func stop() {
        let action = lock.withLock { () -> (DispatchQueue, @Sendable () -> Void)? in
            guard stops == 0, let queue, let stopped else { return nil }
            stops += 1; return (queue, stopped)
        }
        if let (queue, callback) = action { queue.async(execute: callback) }
    }
    func emit(_ value: IOSurfaceRef) {
        let action = lock.withLock { () -> (DispatchQueue, @Sendable (IOSurfaceRef, CMTime) -> Void)? in
            guard let queue, let surface else { return nil }; return (queue, surface)
        }
        if let (queue, callback) = action {
            let box = SurfaceBox(value: value)
            queue.async { callback(box.value, .zero) }
        }
    }
    func blank() {
        let action = lock.withLock { () -> (DispatchQueue, @Sendable () -> Void)? in
            guard let queue, let unavailable else { return nil }; return (queue, unavailable)
        }
        if let (queue, callback) = action { queue.async(execute: callback) }
    }
    var counts: (Int, Int) { lock.withLock { (starts, stops) } }
}
struct SurfaceBox: @unchecked Sendable { let value: IOSurfaceRef }
final class Audit: @unchecked Sendable {
    private let lock = NSLock()
    private var frames = 0, stopped = 0, factories = 0
    func frame(_ frame: TouchBarCapturedFrame) { lock.withLock { frames += 1 } }
    func ended() { lock.withLock { stopped += 1 } }
    func factory() { lock.withLock { factories += 1 } }
    var values: (Int, Int, Int) { lock.withLock { (frames, stopped, factories) } }
}
enum Failure: Error { case check(String), timeout(String) }
@MainActor func waitFor(_ name: String, _ test: () -> Bool) async throws {
    let deadline = ContinuousClock.now + .seconds(4)
    while !test() {
        guard ContinuousClock.now < deadline else { throw Failure.timeout(name) }
        try await Task.sleep(for: .milliseconds(10))
    }
}
func surface() throws -> IOSurfaceRef {
    let properties: [CFString: Any] = [kIOSurfaceWidth: 201, kIOSurfaceHeight: 21,
        kIOSurfaceBytesPerElement: 4, kIOSurfacePixelFormat: kCVPixelFormatType_32BGRA]
    guard let value = IOSurfaceCreate(properties as CFDictionary) else { throw Failure.check("surface") }
    return value
}

@main struct Check {
    @MainActor static func run() async throws {
        let audit = Audit(), fake = FakeRuntime()
        let denied = TouchBarVirtualDriver(recordingAllowed: { false }, makeRuntime: { audit.factory(); return fake })
        do { try denied.start(onSurface: { _, _ in }, onStopped: {}); throw Failure.check("permission denial") }
        catch TouchBarVirtualDriver.Failure.recordingUnavailable { }
        guard audit.values.2 == 0 else { throw Failure.check("loaded runtime without permission") }

        let driver = TouchBarVirtualDriver(recordingAllowed: { true }, makeRuntime: { audit.factory(); return fake })
        let source = TouchBarReadOnlySource(driver: driver, recordingAllowed: { true })
        let frame: @Sendable (TouchBarCapturedFrame) -> Void = { audit.frame($0) }
        let stopped: @Sendable () -> Void = { audit.ended() }
        guard driver.isQuiescent else { throw Failure.check("idle driver") }
        try source.start(onFrame: frame, onStopped: stopped)
        guard !driver.isQuiescent else { throw Failure.check("active driver") }
        try await waitFor("fake runtime start") { fake.counts.0 == 1 }
        let duplicate = TouchBarReadOnlySource(driver: driver, recordingAllowed: { true })
        do { try duplicate.start(onFrame: frame, onStopped: stopped); throw Failure.check("duplicate source") }
        catch TouchBarVirtualDriver.Failure.busy { }
        guard fake.counts.1 == 0 else { throw Failure.check("failed start stopped another source") }
        let image = try surface()
        fake.emit(image)
        try await waitFor("fake borrowed surface") { audit.values.0 == 1 }
        source.stop()
        try await waitFor("fake runtime stop") { fake.counts.1 == 1 }
        try await waitFor("fake runtime quiescent") { driver.isQuiescent }
        fake.emit(image)
        try await Task.sleep(for: .milliseconds(100))
        guard audit.values.0 == 1, audit.values.1 == 0 else { throw Failure.check("late fake callback") }

        let interrupted = FakeRuntime()
        let interruptedDriver = TouchBarVirtualDriver(recordingAllowed: { true }, makeRuntime: { interrupted })
        let interruptedSource = TouchBarReadOnlySource(driver: interruptedDriver, recordingAllowed: { true })
        try await waitFor("first slot released") {
            do { try interruptedSource.start(onFrame: frame, onStopped: stopped); return true }
            catch TouchBarVirtualDriver.Failure.busy { return false }
            catch { return false }
        }
        try await waitFor("interrupted runtime starts") { interrupted.counts.0 == 1 }
        interrupted.stop()
        try await waitFor("spontaneous stop delivered") { audit.values.1 == 1 }

        let blank = FakeRuntime()
        let blankDriver = TouchBarVirtualDriver(recordingAllowed: { true }, makeRuntime: { blank })
        let blankSource = TouchBarReadOnlySource(driver: blankDriver, recordingAllowed: { true })
        try await waitFor("interrupted slot released") {
            do { try blankSource.start(onFrame: frame, onStopped: stopped); return true }
            catch TouchBarVirtualDriver.Failure.busy { return false }
            catch { return false }
        }
        try await waitFor("blank runtime starts") { blank.counts.0 == 1 }
        blank.blank()
        try await waitFor("blank hides source and stops runtime") { audit.values.1 == 2 && blank.counts.1 == 1 }

        // Simulate a private creation call that wedges: stop returns, and another driver is
        // refused until the original call actually returns and reports its stopped callback.
        let release = DispatchSemaphore(value: 0), stalled = FakeRuntime(blockStart: release)
        let first = TouchBarVirtualDriver(recordingAllowed: { true }, makeRuntime: { stalled })
        let next = FakeRuntime()
        let second = TouchBarVirtualDriver(recordingAllowed: { true }, makeRuntime: { next })
        try await waitFor("previous slot released") {
            do { try first.start(onSurface: { _, _ in }, onStopped: {}); return true }
            catch TouchBarVirtualDriver.Failure.busy { return false }
            catch { return false }
        }
        try await waitFor("stalled fake creation") { stalled.counts.0 == 1 }
        do { try second.start(onSurface: { _, _ in }, onStopped: {}); throw Failure.check("unbounded workers") }
        catch TouchBarVirtualDriver.Failure.busy { }
        first.stop()
        guard !first.isQuiescent else { throw Failure.check("wedged driver released early") }
        release.signal()
        try await waitFor("stalled runtime stops") { stalled.counts.1 == 1 }
        try await waitFor("stalled driver quiescent") { first.isQuiescent }
        try await waitFor("stalled slot released") {
            do { try second.start(onSurface: { _, _ in }, onStopped: {}); return true }
            catch TouchBarVirtualDriver.Failure.busy { return false }
            catch { return false }
        }
        try await waitFor("next runtime starts") { next.counts.0 == 1 }
        second.stop()
        try await waitFor("next runtime stops") { next.counts.1 == 1 }
        let abandoned = FakeRuntime()
        let abandonedDriver = TouchBarVirtualDriver(recordingAllowed: { true }, makeRuntime: { abandoned })
        var abandonedSource: TouchBarReadOnlySource? = TouchBarReadOnlySource(driver: abandonedDriver, recordingAllowed: { true })
        try await waitFor("next slot released") {
            do { try abandonedSource?.start(onFrame: frame, onStopped: stopped); return true }
            catch TouchBarVirtualDriver.Failure.busy { return false }
            catch { return false }
        }
        try await waitFor("abandoned runtime starts") { abandoned.counts.0 == 1 }
        abandonedSource = nil
        try await waitFor("deinit stops runtime") { abandoned.counts.1 == 1 }
        abandoned.emit(image)
        try await Task.sleep(for: .milliseconds(100))
        guard audit.values.0 == 1 else { throw Failure.check("deinit admitted a late frame") }
        print("TOUCH BAR VIRTUAL DRIVER PASS: fake permission gate, synthetic callback, stop fence and single blocked-start slot")
        print("SCOPE: injected fake runtime; private DFR was not loaded or invoked; no real Touch Bar, capture, input, Duo or FPS acceptance")
    }
    static func main() async {
        do { try await run() }
        catch { print("TOUCH BAR VIRTUAL DRIVER FAIL: \(error)"); exit(1) }
    }
}
