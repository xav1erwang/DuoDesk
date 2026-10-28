// Copyright 2026 DUO你电脑 contributors. SPDX-License-Identifier: Apache-2.0
import ApplicationServices
import CoreGraphics
import CoreMedia
import Darwin
import Foundation
import IOSurface

/// The runtime's callbacks run on the supplied serial queue. A failed start must have released
/// all resources; after a successful start, stopped is enqueued only once the stream is quiescent.
/// stop is idempotent, including when a stop was requested while start was still returning.
protocol TouchBarVirtualRuntime: AnyObject {
    func start(queue: DispatchQueue, onSurface: @escaping @Sendable (IOSurfaceRef, CMTime) -> Void,
               onUnavailable: @escaping @Sendable () -> Void,
               onStopped: @escaping @Sendable () -> Void) throws
    func stop()
}

private final class VirtualTouchBarStartGate: @unchecked Sendable {
    private let lock = NSLock()
    private var busy = false
    func acquire() -> Bool { lock.withLock { guard !busy else { return false }; busy = true; return true } }
    func release() { lock.withLock { busy = false } }
}

/// Experimental virtual simulator driver. It is deliberately not installed in the product's
/// source factory. A stuck private API occupies one global slot rather than spawning workers on
/// every reconnect. It never requests permission and never posts system input.
final class TouchBarVirtualDriver: TouchBarSurfaceDriver, @unchecked Sendable {
    enum Failure: Error { case recordingUnavailable, busy }
    private static let gate = VirtualTouchBarStartGate()
    private let queue = DispatchQueue(label: "duodesk.touchbar.virtual", qos: .userInitiated)
    private let lock = NSLock()
    private let recordingAllowed: @Sendable () -> Bool
    private let makeRuntime: @Sendable () throws -> any TouchBarVirtualRuntime
    private var active: UUID?
    /// Keep the callback owner alive until a successful stream reports it has actually stopped.
    /// If a private API wedges, the single occupied slot bounds this retained state.
    private var keepAlive: TouchBarVirtualDriver?
    private var running: (UUID, any TouchBarVirtualRuntime)? // only on queue
    /// Used by an isolated diagnostic to wait for a stopped callback without touching the queue.
    var isQuiescent: Bool { lock.withLock { keepAlive == nil } }

    init(recordingAllowed: @escaping @Sendable () -> Bool = { CGPreflightScreenCaptureAccess() },
         makeRuntime: @escaping @Sendable () throws -> any TouchBarVirtualRuntime = { TouchBarDFRRuntime() }) {
        self.recordingAllowed = recordingAllowed; self.makeRuntime = makeRuntime
    }

    func start(onSurface: @escaping @Sendable (IOSurfaceRef, CMTime) -> Void,
               onStopped: @escaping @Sendable () -> Void) throws {
        guard recordingAllowed() else { throw Failure.recordingUnavailable }
        guard Self.gate.acquire() else { throw Failure.busy }
        let token = UUID()
        let accepted = lock.withLock { () -> Bool in
            guard active == nil else { return false }
            active = token; keepAlive = self; return true
        }
        guard accepted else { Self.gate.release(); throw Failure.busy }
        queue.async { [self] in
            guard isActive(token) else { releaseSlot(); return }
            do {
                let runtime = try makeRuntime()
                guard isActive(token) else { runtime.stop(); releaseSlot(); return }
                running = (token, runtime)
                try runtime.start(queue: queue, onSurface: { [weak self] surface, pts in
                    guard self?.isActive(token) == true else { return }
                    onSurface(surface, pts)
                }, onUnavailable: { [weak self] in
                    self?.unavailable(token, onStopped: onStopped)
                }, onStopped: { [weak self] in
                    self?.finished(token, onStopped: onStopped)
                })
                if !isActive(token) { runtime.stop() }
            } catch {
                running = nil
                let notify = takeActive(token)
                releaseSlot()
                if notify { onStopped() }
            }
        }
    }

    func stop() {
        let token = lock.withLock { () -> UUID? in
            let token = active; active = nil; return token
        }
        guard let token else { return }
        queue.async { [self] in
            if running?.0 == token { running?.1.stop() }
        }
    }

    private func isActive(_ token: UUID) -> Bool { lock.withLock { active == token } }
    private func takeActive(_ token: UUID) -> Bool {
        lock.withLock { guard active == token else { return false }; active = nil; return true }
    }
    /// Hide the stale picture immediately, but keep the runtime and its slot until it really stops.
    private func unavailable(_ token: UUID, onStopped: @Sendable () -> Void) {
        guard running?.0 == token else { return }
        if takeActive(token) { onStopped() }
        running?.1.stop()
    }
    /// A stopped callback is the only successful-start path that releases the global slot. If a
    /// private stream never stops, retain it and refuse new starts rather than free live callbacks.
    private func finished(_ token: UUID, onStopped: @Sendable () -> Void) {
        guard running?.0 == token else { return }
        running = nil
        let notify = takeActive(token)
        releaseSlot()
        if notify { onStopped() }
    }

    private func releaseSlot() {
        lock.withLock { keepAlive = nil }
        Self.gate.release()
    }
}

/// Historical DFR simulator interfaces are private and their ABI/semantics are not a platform
/// guarantee. This runtime has not been validated against a real stream on the Air; the shipping
/// factory does not instantiate it. It describes a virtual bar, not proof of a physical one.
private final class TouchBarDFRRuntime: TouchBarVirtualRuntime, @unchecked Sendable {
    private typealias MakeSimulator = @convention(c) (Int32, UnsafeRawPointer?, Int32) -> UnsafeMutableRawPointer?
    private typealias GetBar = @convention(c) (UnsafeMutableRawPointer?) -> UnsafeMutableRawPointer?
    private typealias FrameBlock = @convention(block) (CGDisplayStreamFrameStatus, UInt64, IOSurfaceRef?, CGDisplayStreamUpdate?) -> Void
    private typealias MakeStream = @convention(c) (UnsafeMutableRawPointer?, Int32, DispatchQueue, FrameBlock) -> Unmanaged<CGDisplayStream>?
    private typealias StreamControl = @convention(c) (CGDisplayStream) -> CGError
    private typealias Invalidate = @convention(c) (UnsafeMutableRawPointer?) -> Void
    private struct API {
        let library: UnsafeMutableRawPointer
        let makeSimulator: MakeSimulator
        let getBar: GetBar
        let makeStream: MakeStream
        let start: StreamControl
        let stop: StreamControl
        let invalidate: Invalidate
    }
    private enum Failure: Error { case recordingUnavailable, symbols, simulator, bar, stream, start }
    private var api: API?
    private var simulator: AnyObject?
    private var stream: CGDisplayStream?
    private var stopping = false
    private var invalidated = false

    func start(queue: DispatchQueue, onSurface: @escaping @Sendable (IOSurfaceRef, CMTime) -> Void,
               onUnavailable: @escaping @Sendable () -> Void,
               onStopped: @escaping @Sendable () -> Void) throws {
        // This independent preflight prevents a test-injected driver gate from authorizing a
        // real runtime. There is intentionally no request API or TCC database access.
        guard CGPreflightScreenCaptureAccess() else { throw Failure.recordingUnavailable }
        let loaded = try Self.load()
        api = loaded
        guard let raw = loaded.makeSimulator(3, nil, 3) else { cleanup(); throw Failure.simulator }
        simulator = Unmanaged<AnyObject>.fromOpaque(raw).takeUnretainedValue()
        guard let bar = loaded.getBar(raw) else { cleanup(); throw Failure.bar }
        let callback: FrameBlock = { [weak self] status, time, surface, _ in
            guard let self else { return }
            if status == .stopped {
                self.invalidated = true
                // Leave the private framework's callback stack before unloading it.
                queue.async { [weak self] in self?.cleanup(); onStopped() }
            } else if status == .frameComplete, !self.invalidated, let surface {
                // The receiver must copy before this callback returns; it cannot retain a borrowed
                // IOSurface for asynchronous use without the documented use-count contract.
                onSurface(surface, CMClockMakeHostTimeFromSystemUnits(time))
            } else if status == .frameBlank, !self.invalidated {
                // A blank is not a still frame: stop publishing the previous image immediately.
                self.invalidated = true
                queue.async { onUnavailable() }
            }
        }
        guard let made = loaded.makeStream(bar, 0, queue, callback)?.takeRetainedValue() else {
            cleanup(); throw Failure.stream
        }
        stream = made
        guard loaded.start(made) == .success else { cleanup(); throw Failure.start }
    }

    func stop() {
        guard !stopping, let api, let stream else { return }
        stopping = true
        // If stop fails or never delivers its stopped callback, deliberately retain all objects.
        // The driver's occupied slot prevents unbounded retries or use-after-free.
        _ = api.stop(stream)
    }

    private func cleanup() {
        stream = nil
        if let simulator, let api { api.invalidate(Unmanaged.passUnretained(simulator).toOpaque()) }
        simulator = nil
        if let api { dlclose(api.library) }
        api = nil
    }

    private static func load() throws -> API {
        guard let library = dlopen("/System/Library/PrivateFrameworks/DFRFoundation.framework/DFRFoundation", RTLD_NOW | RTLD_LOCAL) else {
            throw Failure.symbols
        }
        func loadSymbol<T>(_ handle: UnsafeMutableRawPointer, _ name: String, _: T.Type) -> T? {
            guard let pointer = dlsym(handle, name) else { return nil }
            return unsafeBitCast(pointer, to: T.self)
        }
        // Darwin's RTLD_DEFAULT macro is ((void *) -2); Swift does not import that macro.
        let defaultSymbols = UnsafeMutableRawPointer(bitPattern: -2)!
        guard let make = loadSymbol(library, "DFRTouchBarSimulatorCreate", MakeSimulator.self),
              let get = loadSymbol(library, "DFRTouchBarSimulatorGetTouchBar", GetBar.self),
              let create = loadSymbol(library, "DFRTouchBarCreateDisplayStream", MakeStream.self),
              let invalidate = loadSymbol(library, "DFRTouchBarSimulatorInvalidate", Invalidate.self),
              let start = loadSymbol(defaultSymbols, "CGDisplayStreamStart", StreamControl.self),
              let stop = loadSymbol(defaultSymbols, "CGDisplayStreamStop", StreamControl.self) else {
            dlclose(library); throw Failure.symbols
        }
        return API(library: library, makeSimulator: make, getBar: get, makeStream: create,
                   start: start, stop: stop, invalidate: invalidate)
    }
}
