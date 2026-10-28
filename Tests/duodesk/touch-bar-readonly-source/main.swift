// Copyright 2026 DUO你电脑 contributors. SPDX-License-Identifier: Apache-2.0
// Synthetic borrowed surfaces and fake permission state; no screen or system input access.
import CoreMedia
import CoreVideo
import Foundation
import IOSurface
import StreamProtocol

final class FakeDriver: TouchBarSurfaceDriver, @unchecked Sendable {
    private let lock = NSLock()
    private var onSurface: (@Sendable (IOSurfaceRef, CMTime) -> Void)?
    private var lateSurface: (@Sendable (IOSurfaceRef, CMTime) -> Void)?
    private var onStopped: (@Sendable () -> Void)?
    private var starts = 0, stops = 0
    func start(onSurface: @escaping @Sendable (IOSurfaceRef, CMTime) -> Void,
               onStopped: @escaping @Sendable () -> Void) throws {
        lock.withLock { starts += 1; self.onSurface = onSurface; self.onStopped = onStopped }
    }
    func stop() { lock.withLock { stops += 1; lateSurface = onSurface; onSurface = nil; onStopped = nil } }
    func emit(_ surface: IOSurfaceRef) { let f = lock.withLock { onSurface }; f?(surface, .zero) }
    func emitLate(_ surface: IOSurfaceRef) { let f = lock.withLock { lateSurface }; f?(surface, .zero) }
    var counts: (Int, Int) { lock.withLock { (starts, stops) } }
}
final class Results: @unchecked Sendable {
    private let lock = NSLock()
    private var frames: [TouchBarCapturedFrame] = []
    private var stops = 0
    func frame(_ value: TouchBarCapturedFrame) { lock.withLock { frames.append(value) } }
    func stopped() { lock.withLock { stops += 1 } }
    var state: ([TouchBarCapturedFrame], Int) { lock.withLock { (frames, stops) } }
}
struct SurfaceBox: @unchecked Sendable { let value: IOSurfaceRef }
enum Failure: Error { case check(String) }
func makeSurface(_ format: OSType) throws -> IOSurfaceRef {
    let properties: [CFString: Any] = [kIOSurfaceWidth: 201, kIOSurfaceHeight: 21,
        kIOSurfaceBytesPerElement: 4, kIOSurfacePixelFormat: format]
    guard let value = IOSurfaceCreate(properties as CFDictionary) else { throw Failure.check("surface") }
    return value
}
@main struct Check {
    @MainActor static func run() async throws {
        let driver = FakeDriver(), results = Results()
        let gotFrame: @Sendable (TouchBarCapturedFrame) -> Void = { results.frame($0) }
        let stopped: @Sendable () -> Void = { results.stopped() }
        let denied = TouchBarReadOnlySource(driver: driver, recordingAllowed: { false })
        do { try denied.start(onFrame: gotFrame, onStopped: stopped); throw Failure.check("denied start") }
        catch TouchBarReadOnlySource.Failure.recordingUnavailable { }
        guard driver.counts.0 == 0 else { throw Failure.check("driver started without permission") }
        let source = TouchBarReadOnlySource(driver: driver, recordingAllowed: { true })
        try source.start(onFrame: gotFrame, onStopped: stopped)
        guard !source.supportsInput, !source.post(TouchBarTouch(surfaceID: UUID(), phase: .began, x: 0.5, y: 0.5)) else {
            throw Failure.check("read-only input")
        }
        let good = try makeSurface(kCVPixelFormatType_32BGRA)
        driver.emit(good)
        guard let first = results.state.0.first, first.contentWidth == 201, first.contentHeight == 21,
              CVPixelBufferGetWidth(first.pixels) == 202, CVPixelBufferGetHeight(first.pixels) == 22 else {
            throw Failure.check("copied callback")
        }
        source.stop()
        driver.emitLate(good)
        guard results.state.0.count == 1, driver.counts == (1, 1) else { throw Failure.check("late callback") }

        try source.start(onFrame: gotFrame, onStopped: stopped)
        let bad = try makeSurface(kCVPixelFormatType_32ARGB)
        driver.emit(bad); driver.emit(bad)
        try await Task.sleep(for: .milliseconds(100))
        guard results.state.1 == 1, driver.counts == (2, 2), results.state.0.count == 1 else {
            throw Failure.check("unsupported format stopped once")
        }
        // Force a callback to pause inside final admission while stop races it. The deliberately
        // held callback is test-only; real session ingress must return promptly.
        let entered = DispatchSemaphore(value: 0), release = DispatchSemaphore(value: 0)
        let held: @Sendable (TouchBarCapturedFrame) -> Void = { frame in
            entered.signal(); release.wait(); results.frame(frame)
        }
        try source.start(onFrame: held, onStopped: stopped)
        let box = SurfaceBox(value: good)
        DispatchQueue.global().async { driver.emit(box.value) }
        let ready = await withCheckedContinuation { continuation in
            DispatchQueue.global().async { continuation.resume(returning: entered.wait(timeout: .now() + 3) == .success) }
        }
        guard ready else { throw Failure.check("admission setup") }
        DispatchQueue.global().asyncAfter(deadline: .now() + .milliseconds(50)) { release.signal() }
        source.stop()
        driver.emitLate(good)
        guard results.state.0.count == 2, driver.counts == (3, 3) else { throw Failure.check("stop/admission race") }
        print("TOUCH BAR READ-ONLY SOURCE PASS: fake permission gate, independent copied surface, late-callback fence, unsupported format stop and input refusal")
        print("SCOPE: injected driver and in-memory surfaces only; no real Touch Bar, TCC access, capture or input")
    }
    static func main() async {
        do { try await run() }
        catch { print("TOUCH BAR READ-ONLY SOURCE FAIL: \(error)"); exit(1) }
    }
}
