// Copyright 2026 DUO你电脑 contributors. SPDX-License-Identifier: Apache-2.0
// Only an injected runtime and self-created IOSurface; no private system call or actual input.
import AppKit
import CoreMedia
import CoreVideo
import Foundation
import IOSurface
import StreamProtocol

private enum Failure: Error { case invalid(String), timeout(String) }
private final class Switch: @unchecked Sendable {
    private let lock = NSLock()
    private var value = true
    var enabled: Bool { lock.withLock { value } }
    func set(_ value: Bool) { lock.withLock { self.value = value } }
}
private final class FakeRuntime: TouchBarVirtualRuntime, @unchecked Sendable {
    private let lock = NSLock()
    private let firstPostGate: DispatchSemaphore?
    private let postResult: Bool
    private var extent: CGSize?
    private var queue: DispatchQueue?
    private var onSurface: (@Sendable (IOSurfaceRef, CMTime) -> Void)?
    private var onStopped: (@Sendable () -> Void)?
    private var events: [TouchBarVirtualMouseEvent] = []
    private var stops = 0
    init(firstPostGate: DispatchSemaphore? = nil, postResult: Bool = true,
         extent: CGSize? = CGSize(width: 1004, height: 30)) {
        self.firstPostGate = firstPostGate; self.postResult = postResult; self.extent = extent
    }
    func start(queue: DispatchQueue, onSurface: @escaping @Sendable (IOSurfaceRef, CMTime) -> Void,
               onUnavailable: @escaping @Sendable () -> Void, onStopped: @escaping @Sendable () -> Void) throws {
        lock.withLock { self.queue = queue; self.onSurface = onSurface; self.onStopped = onStopped }
    }
    func post(_ event: TouchBarVirtualMouseEvent) -> Bool {
        let first = lock.withLock { events.append(event); return events.count == 1 }
        if first { firstPostGate?.wait() }
        return postResult
    }
    func inputExtent() -> CGSize? { lock.withLock { extent } }
    func setExtent(_ value: CGSize?) { lock.withLock { extent = value } }
    func stop() {
        let callback = lock.withLock { () -> (DispatchQueue, @Sendable () -> Void)? in
            guard stops == 0, let queue, let onStopped else { return nil }
            stops += 1; return (queue, onStopped)
        }
        if let (queue, action) = callback { queue.async(execute: action) }
    }
    func emit(_ surface: IOSurfaceRef) {
        let callback = lock.withLock { () -> (DispatchQueue, @Sendable (IOSurfaceRef, CMTime) -> Void)? in
            guard let queue, let onSurface else { return nil }; return (queue, onSurface)
        }
        if let (queue, action) = callback {
            let box = SurfaceBox(value: surface)
            queue.async { action(box.value, .zero) }
        }
    }
    var snapshot: ([TouchBarVirtualMouseEvent], Int) { lock.withLock { (events, stops) } }
    var started: Bool { lock.withLock { queue != nil } }
}
private struct SurfaceBox: @unchecked Sendable { let value: IOSurfaceRef }
private final class Audit: @unchecked Sendable {
    private let lock = NSLock()
    private var frames = 0, stops = 0
    func frame() { lock.withLock { frames += 1 } }
    func stop() { lock.withLock { stops += 1 } }
    var counts: (Int, Int) { lock.withLock { (frames, stops) } }
}
private func waitFor(_ name: String, _ test: () -> Bool) async throws {
    let deadline = ContinuousClock.now + .seconds(4)
    while !test() {
        guard ContinuousClock.now < deadline else { throw Failure.timeout(name) }
        try await Task.sleep(for: .milliseconds(10))
    }
}
private func surface() throws -> IOSurfaceRef {
    let attributes: [CFString: Any] = [kIOSurfaceWidth: 2008, kIOSurfaceHeight: 60,
        kIOSurfaceBytesPerElement: 4, kIOSurfacePixelFormat: kCVPixelFormatType_32BGRA]
    guard let value = IOSurfaceCreate(attributes as CFDictionary) else { throw Failure.invalid("surface") }
    return value
}
private func touch(_ id: UUID, _ phase: TouchBarPhase, _ x: Double, _ y: Double) -> TouchBarTouch {
    TouchBarTouch(surfaceID: id, phase: phase, x: x, y: y)
}

@main private struct Check {
    static func run() async throws {
        let audit = Audit(), inputAllowed = Switch(), release = DispatchSemaphore(value: 0)
        let fake = FakeRuntime(firstPostGate: release)
        let driver = TouchBarVirtualDriver(recordingAllowed: { true }, inputAllowed: { inputAllowed.enabled }, makeRuntime: { fake })
        let id = UUID()
        let mapping = TouchBarVirtualInputMapping(imageWidth: 2008, imageHeight: 60, pointWidth: 1004, pointHeight: 30)
        let wrong = TouchBarVirtualInputMapping(imageWidth: 2006, imageHeight: 60, pointWidth: 1003, pointHeight: 30)
        let wrongExtent = TouchBarVirtualInputMapping(imageWidth: 2008, imageHeight: 60, pointWidth: 502, pointHeight: 30)
        try driver.start(onSurface: { _, _ in audit.frame() }, onStopped: { audit.stop() })
        guard !driver.postForExperiment(touch(id, .began, 0, 0), mapping: mapping) else { throw Failure.invalid("input before frame") }
        try await waitFor("runtime started") { fake.started }
        fake.emit(try surface())
        try await waitFor("surface callback") { audit.counts.0 == 1 }
        guard driver.mappingForExperiment == mapping else { throw Failure.invalid("source-provided input extent") }
        guard !driver.postForExperiment(touch(id, .began, 0, 0), mapping: wrong) else { throw Failure.invalid("wrong source geometry") }
        guard !driver.postForExperiment(touch(id, .began, 0, 0), mapping: wrongExtent) else {
            release.signal(); throw Failure.invalid("incorrect runtime input extent accepted")
        }
        inputAllowed.set(false)
        guard !driver.postForExperiment(touch(id, .began, 0, 0), mapping: mapping) else { throw Failure.invalid("denied input") }
        inputAllowed.set(true)
        guard driver.postForExperiment(touch(id, .began, 0, 0), mapping: mapping) else { throw Failure.invalid("down") }
        try await waitFor("blocked native post") { fake.snapshot.0.count == 1 }
        guard driver.postForExperiment(touch(id, .moved, 0.1, 0.25), mapping: mapping),
              driver.postForExperiment(touch(id, .moved, 0.7, 0.25), mapping: mapping),
              driver.postForExperiment(touch(id, .ended, 1, 1), mapping: mapping),
              !driver.postForExperiment(touch(id, .began, 0.5, 0.5), mapping: mapping) else {
            release.signal(); throw Failure.invalid("bounded contact sequence")
        }
        release.signal()
        try await waitFor("coalesced drag and release") { fake.snapshot.0.count == 3 }
        let events = fake.snapshot.0
        guard events.map(\.phase) == [.began, .moved, .ended],
              events.map(\.type) == [.leftMouseDown, .leftMouseDragged, .leftMouseUp],
              events[0].point.x == 0, events[0].point.y < 30, events[0].point.y > 29.9,
              abs(events[1].point.x - 702.8) < 0.001, abs(events[1].point.y - 22.5) < 0.001,
              events[2].point.x < 1004, events[2].point.x > 1003.9, events[2].point.y == 0 else {
            throw Failure.invalid("mapped system event ordering")
        }
        driver.stop()
        try await waitFor("runtime stopped") { fake.snapshot.1 == 1 && driver.isQuiescent }
        guard !driver.postForExperiment(touch(id, .began, 0.5, 0.5), mapping: mapping), audit.counts.1 == 0 else {
            throw Failure.invalid("input after stop")
        }

        // If permission disappears while one fake call is in flight, later queued events never
        // reach the runtime and the source is invalidated. The in-flight call cannot be recalled.
        let gate = DispatchSemaphore(value: 0), blocked = FakeRuntime(firstPostGate: gate), permission = Switch()
        let later = TouchBarVirtualDriver(recordingAllowed: { true }, inputAllowed: { permission.enabled }, makeRuntime: { blocked })
        try later.start(onSurface: { _, _ in audit.frame() }, onStopped: { audit.stop() })
        try await waitFor("second runtime started") { blocked.started }
        blocked.emit(try surface())
        try await waitFor("second surface") { audit.counts.0 == 2 }
        guard later.postForExperiment(touch(id, .began, 0.1, 0.1), mapping: mapping) else { throw Failure.invalid("second down") }
        try await waitFor("second post blocked") { blocked.snapshot.0.count == 1 }
        guard later.postForExperiment(touch(id, .moved, 0.2, 0.2), mapping: mapping) else { gate.signal(); throw Failure.invalid("queued move") }
        permission.set(false); gate.signal()
        try await waitFor("revoked permission stops source") { blocked.snapshot.1 == 1 && later.isQuiescent && audit.counts.1 == 1 }
        guard blocked.snapshot.0.count == 1 else { throw Failure.invalid("late input after permission denial") }

        // A stopped source fences waiting input even when a previous fake native call is stuck.
        let stopGate = DispatchSemaphore(value: 0), stopping = FakeRuntime(firstPostGate: stopGate)
        let third = TouchBarVirtualDriver(recordingAllowed: { true }, inputAllowed: { true }, makeRuntime: { stopping })
        try third.start(onSurface: { _, _ in audit.frame() }, onStopped: { audit.stop() })
        try await waitFor("third runtime started") { stopping.started }
        stopping.emit(try surface())
        try await waitFor("third surface") { audit.counts.0 == 3 }
        guard third.postForExperiment(touch(id, .began, 0.3, 0.3), mapping: mapping) else { throw Failure.invalid("third down") }
        try await waitFor("third post blocked") { stopping.snapshot.0.count == 1 }
        guard third.postForExperiment(touch(id, .moved, 0.4, 0.4), mapping: mapping) else { stopGate.signal(); throw Failure.invalid("third move") }
        third.stop(); stopGate.signal()
        try await waitFor("blocked source stopped") { stopping.snapshot.1 == 1 && third.isQuiescent }
        guard stopping.snapshot.0.count == 1, audit.counts.1 == 1 else { throw Failure.invalid("queued input survived stop") }

        let failing = FakeRuntime(postResult: false)
        let fourth = TouchBarVirtualDriver(recordingAllowed: { true }, inputAllowed: { true }, makeRuntime: { failing })
        try fourth.start(onSurface: { _, _ in audit.frame() }, onStopped: { audit.stop() })
        try await waitFor("fourth runtime started") { failing.started }
        failing.emit(try surface())
        try await waitFor("fourth surface") { audit.counts.0 == 4 }
        guard fourth.postForExperiment(touch(id, .began, 0.5, 0.5), mapping: mapping) else { throw Failure.invalid("fourth down") }
        try await waitFor("failed post stopped source") { failing.snapshot.1 == 1 && fourth.isQuiescent && audit.counts.1 == 2 }

        // An unavailable or malformed native extent does not suppress capture, but it must never
        // authorize input. A later valid frame replaces that metadata on the same fake runtime.
        let noExtent = FakeRuntime(extent: nil)
        let fifth = TouchBarVirtualDriver(recordingAllowed: { true }, inputAllowed: { true }, makeRuntime: { noExtent })
        try fifth.start(onSurface: { _, _ in audit.frame() }, onStopped: { audit.stop() })
        try await waitFor("fifth runtime started") { noExtent.started }
        noExtent.emit(try surface())
        try await waitFor("fifth surface without extent") { audit.counts.0 == 5 }
        guard fifth.mappingForExperiment == nil,
              !fifth.postForExperiment(touch(id, .began, 0.2, 0.2), mapping: mapping) else {
            throw Failure.invalid("input without runtime extent")
        }
        noExtent.setExtent(CGSize(width: CGFloat.nan, height: 30)); noExtent.emit(try surface())
        try await waitFor("fifth surface with malformed extent") { audit.counts.0 == 6 }
        guard fifth.mappingForExperiment == nil,
              !fifth.postForExperiment(touch(id, .began, 0.2, 0.2), mapping: mapping) else {
            throw Failure.invalid("input with malformed runtime extent")
        }
        noExtent.setExtent(CGSize(width: 1004, height: 30)); noExtent.emit(try surface())
        try await waitFor("fifth surface with valid extent") { audit.counts.0 == 7 }
        guard fifth.mappingForExperiment == mapping,
              fifth.postForExperiment(touch(id, .began, 0.2, 0.2), mapping: mapping) else {
            throw Failure.invalid("input after runtime extent became valid")
        }
        try await waitFor("fifth down delivered") { noExtent.snapshot.0.count == 1 }
        fifth.stop()
        try await waitFor("fifth runtime stopped") { noExtent.snapshot.1 == 1 && fifth.isQuiescent }

        // The bar may change size after the last picture while a native call is blocked. Waiting
        // input must be rejected by the current runtime extent, not just the captured metadata.
        let sizeGate = DispatchSemaphore(value: 0), changed = FakeRuntime(firstPostGate: sizeGate)
        let sixth = TouchBarVirtualDriver(recordingAllowed: { true }, inputAllowed: { true }, makeRuntime: { changed })
        try sixth.start(onSurface: { _, _ in audit.frame() }, onStopped: { audit.stop() })
        try await waitFor("sixth runtime started") { changed.started }
        changed.emit(try surface())
        try await waitFor("sixth surface") { audit.counts.0 == 8 }
        guard sixth.postForExperiment(touch(id, .began, 0.2, 0.2), mapping: mapping) else { throw Failure.invalid("sixth down") }
        try await waitFor("sixth post blocked") { changed.snapshot.0.count == 1 }
        guard sixth.postForExperiment(touch(id, .moved, 0.8, 0.2), mapping: mapping) else {
            sizeGate.signal(); throw Failure.invalid("sixth queued move")
        }
        changed.setExtent(CGSize(width: 502, height: 30)); sizeGate.signal()
        try await waitFor("changed extent stops source") { changed.snapshot.1 == 1 && sixth.isQuiescent && audit.counts.1 == 3 }
        guard changed.snapshot.0.count == 1 else { throw Failure.invalid("stale extent reached runtime") }

        print("VIRTUAL TOUCH BAR INTERACTION PASS: same injected runtime/surface, runtime extent, changed extent, bounded movement and permission gates")
        print("SCOPE: fake runtime and permissions, generated surface; no private system call, actual input, real Touch Bar, Duo, WAN or FPS acceptance")
    }
    static func main() async {
        do { try await run() }
        catch { print("VIRTUAL TOUCH BAR INTERACTION FAIL: \(error)"); exit(1) }
    }
}
