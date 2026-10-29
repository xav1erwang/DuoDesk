// Copyright 2026 DUO你电脑 contributors. SPDX-License-Identifier: Apache-2.0
import ApplicationServices
import CoreGraphics
import CoreMedia
import Darwin
import Foundation
import IOSurface
import StreamProtocol

/// The runtime's callbacks run on the supplied serial queue. A failed start must have released
/// all resources; after a successful start, stopped is enqueued only once the stream is quiescent.
/// stop is idempotent, including when a stop was requested while start was still returning.
protocol TouchBarVirtualRuntime: AnyObject {
    func start(queue: DispatchQueue, onSurface: @escaping @Sendable (IOSurfaceRef, CMTime) -> Void,
               onUnavailable: @escaping @Sendable () -> Void,
               onStopped: @escaping @Sendable () -> Void) throws
    func stop()
    /// Current native input-coordinate extent for this exact runtime, only on its serial queue.
    /// Nil leaves capture available but refuses input. A value is not proof of real compatibility.
    func inputExtent() -> CGSize?
    /// Runs only on the runtime's serial queue. Real input is guarded again by the native runtime.
    func post(_ event: TouchBarVirtualMouseEvent) -> Bool
}

extension TouchBarVirtualRuntime {
    func inputExtent() -> CGSize? { nil }
    func post(_ event: TouchBarVirtualMouseEvent) -> Bool { false }
}

private final class VirtualTouchBarStartGate: @unchecked Sendable {
    private let lock = NSLock()
    private var busy = false
    func acquire() -> Bool { lock.withLock { guard !busy else { return false }; busy = true; return true } }
    func release() { lock.withLock { busy = false } }
}

/// Experimental virtual simulator driver. It is deliberately not installed in the product's
/// source factory. A stuck private API occupies one global slot rather than spawning workers on
/// every reconnect. It never requests permission; its input entry point is diagnostic-only.
final class TouchBarVirtualDriver: TouchBarSurfaceDriver, @unchecked Sendable {
    enum Failure: Error { case recordingUnavailable, busy }
    private static let gate = VirtualTouchBarStartGate()
    private let queue = DispatchQueue(label: "duodesk.touchbar.virtual", qos: .userInitiated)
    private let lock = NSLock()
    private let recordingAllowed: @Sendable () -> Bool
    private let inputAllowed: @Sendable () -> Bool
    private let makeRuntime: @Sendable () throws -> any TouchBarVirtualRuntime
    private var active: UUID?
    private var observedSurface: (width: Int, height: Int, mapping: TouchBarVirtualInputMapping?)? // under lock
    private let input = TouchBarVirtualInputMailbox()
    /// Keep the callback owner alive until a successful stream reports it has actually stopped.
    /// If a private API wedges, the single occupied slot bounds this retained state.
    private var keepAlive: TouchBarVirtualDriver?
    private var running: (UUID, any TouchBarVirtualRuntime, @Sendable () -> Void)? // only on queue
    /// Used by an isolated diagnostic to wait for a stopped callback without touching the queue.
    var isQuiescent: Bool { lock.withLock { keepAlive == nil } }
    /// Diagnostic metadata from the same runtime and latest surface; not a verified native ABI.
    var mappingForExperiment: TouchBarVirtualInputMapping? { lock.withLock { observedSurface?.mapping } }

    init(recordingAllowed: @escaping @Sendable () -> Bool = { CGPreflightScreenCaptureAccess() },
         inputAllowed: @escaping @Sendable () -> Bool = { AXIsProcessTrusted() },
         makeRuntime: @escaping @Sendable () throws -> any TouchBarVirtualRuntime = { TouchBarDFRRuntime() }) {
        self.recordingAllowed = recordingAllowed; self.inputAllowed = inputAllowed; self.makeRuntime = makeRuntime
    }

    func start(onSurface: @escaping @Sendable (IOSurfaceRef, CMTime) -> Void,
               onStopped: @escaping @Sendable () -> Void) throws {
        guard recordingAllowed() else { throw Failure.recordingUnavailable }
        guard Self.gate.acquire() else { throw Failure.busy }
        let token = UUID()
        let accepted = lock.withLock { () -> Bool in
            guard active == nil else { return false }
            active = token; observedSurface = nil; keepAlive = self; return true
        }
        guard accepted else { Self.gate.release(); throw Failure.busy }
        input.reset(to: token)
        queue.async { [self] in
            guard isActive(token) else { releaseSlot(); return }
            do {
                let runtime = try makeRuntime()
                guard isActive(token) else { runtime.stop(); releaseSlot(); return }
                running = (token, runtime, onStopped)
                try runtime.start(queue: queue, onSurface: { [weak self, weak runtime] surface, pts in
                    guard let self, let runtime, self.isActive(token),
                          self.observe(surface, extent: runtime.inputExtent(), token: token) else { return }
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
            let token = active; active = nil; observedSurface = nil; return token
        }
        guard let token else { return }
        input.reset(to: nil)
        queue.async { [self] in
            if running?.0 == token { running?.1.stop() }
        }
    }

    /// Experimental same-instance input, intentionally not wired to TouchBarCaptureSource or the
    /// product factory. `mapping` must equal the observed extent for this exact runtime and
    /// surface. A true result means the queue accepted the contact, not that the system acted.
    /// A future product adapter must additionally carry the revocable paired-session permit to
    /// the actual native post, and validate coordinates/orientation on a real system.
    func postForExperiment(_ touch: TouchBarTouch, mapping: TouchBarVirtualInputMapping) -> Bool {
        guard recordingAllowed(), inputAllowed(), let event = mapping.event(touch) else { return false }
        let token = lock.withLock { () -> UUID? in
            guard let active, let observedSurface,
                  observedSurface.width == mapping.imageWidth, observedSurface.height == mapping.imageHeight,
                  observedSurface.mapping == mapping else { return nil }
            return active
        }
        guard let token else { return false }
        let offer = input.offer(event, token: token)
        if offer.schedule { queue.async { [self] in drainInput(token) } }
        return offer.accepted
    }

    private func observe(_ surface: IOSurfaceRef, extent: CGSize?, token: UUID) -> Bool {
        lock.withLock {
            guard active == token else { return false }
            let width = IOSurfaceGetWidth(surface), height = IOSurfaceGetHeight(surface)
            observedSurface = (width, height, .observed(imageWidth: width, imageHeight: height, extent: extent))
            return true
        }
    }

    private func drainInput(_ token: UUID) {
        while let event = input.take(token: token) {
            guard let running, running.0 == token else { input.reset(to: nil); return }
            let geometryMatches = lock.withLock {
                active == token && observedSurface?.width == event.mapping.imageWidth
                    && observedSurface?.height == event.mapping.imageHeight
                    && observedSurface?.mapping == event.mapping
            }
            guard geometryMatches, recordingAllowed(), inputAllowed(),
                  event.mapping.matches(extent: running.1.inputExtent()), running.1.post(event) else {
                input.reset(to: nil)
                unavailable(token, onStopped: running.2)
                return
            }
            input.completed(event, token: token)
        }
    }

    private func isActive(_ token: UUID) -> Bool { lock.withLock { active == token } }
    private func takeActive(_ token: UUID) -> Bool {
        lock.withLock { guard active == token else { return false }; active = nil; observedSurface = nil; return true }
    }
    /// Hide the stale picture immediately, but keep the runtime and its slot until it really stops.
    private func unavailable(_ token: UUID, onStopped: @Sendable () -> Void) {
        guard running?.0 == token else { return }
        input.reset(to: nil)
        if takeActive(token) { onStopped() }
        running?.1.stop()
    }
    /// A stopped callback is the only successful-start path that releases the global slot. If a
    /// private stream never stops, retain it and refuse new starts rather than free live callbacks.
    private func finished(_ token: UUID, onStopped: @Sendable () -> Void) {
        guard running?.0 == token else { return }
        input.reset(to: nil)
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
    private typealias GetScreenSize = @convention(c) (UnsafeMutableRawPointer?) -> CGSize
    private typealias FrameBlock = @convention(block) (CGDisplayStreamFrameStatus, UInt64, IOSurfaceRef?, CGDisplayStreamUpdate?) -> Void
    private typealias MakeStream = @convention(c) (UnsafeMutableRawPointer?, Int32, DispatchQueue, FrameBlock) -> Unmanaged<CGDisplayStream>?
    private typealias StreamControl = @convention(c) (CGDisplayStream) -> CGError
    private typealias Invalidate = @convention(c) (UnsafeMutableRawPointer?) -> Void
    // Historical declarations disagree about the result, and macOS 27's wrapper does not
    // preserve the internal post's return value. Treat a returned call only as an attempt.
    private typealias PostMouse = @convention(c) (UnsafeMutableRawPointer?, UInt, CGPoint) -> Void
    private struct API {
        let library: UnsafeMutableRawPointer
        let makeSimulator: MakeSimulator
        let getBar: GetBar
        let screenSize: GetScreenSize?
        let makeStream: MakeStream
        let start: StreamControl
        let stop: StreamControl
        let invalidate: Invalidate
        let postMouse: PostMouse?
    }
    private enum Failure: Error { case recordingUnavailable, symbols, simulator, bar, stream, start }
    private var api: API?
    private var simulator: AnyObject?
    private var bar: AnyObject?
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
        guard let rawBar = loaded.getBar(raw) else { cleanup(); throw Failure.bar }
        bar = Unmanaged<AnyObject>.fromOpaque(rawBar).takeUnretainedValue()
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
        guard let made = loaded.makeStream(rawBar, 0, queue, callback)?.takeRetainedValue() else {
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

    /// Candidate metadata from the same simulator bar used to make the stream. The getter's
    /// current signature is inferred from system code, not a documented ABI or hardware proof.
    func inputExtent() -> CGSize? {
        guard !stopping, !invalidated, CGPreflightScreenCaptureAccess(),
              let size = api?.screenSize, let bar else { return nil }
        let extent = size(Unmanaged.passUnretained(bar).toOpaque())
        guard extent.width.isFinite, extent.height.isFinite, extent.width > 0, extent.height > 0 else { return nil }
        return extent
    }

    /// The private event targets the very simulator that owns this stream. Test-injected outer
    /// permission gates cannot authorize a real post: both process grants are independently
    /// checked immediately before the call. No permission is requested and no entitlement is set.
    func post(_ event: TouchBarVirtualMouseEvent) -> Bool {
        guard !stopping, !invalidated, CGPreflightScreenCaptureAccess(), AXIsProcessTrusted(),
              let api, let postMouse = api.postMouse, let simulator,
              event.mapping.matches(extent: inputExtent()) else { return false }
        postMouse(Unmanaged.passUnretained(simulator).toOpaque(), event.type.rawValue, event.point)
        return true // The private call returned; this does not prove the system accepted the touch.
    }

    private func cleanup() {
        stream = nil
        bar = nil
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
        return API(library: library, makeSimulator: make, getBar: get,
                   screenSize: loadSymbol(library, "DFRTouchBarGetScreenSize", GetScreenSize.self), makeStream: create,
                   start: start, stop: stop, invalidate: invalidate,
                   postMouse: loadSymbol(library, "DFRTouchBarSimulatorPostEventWithMouseActivity", PostMouse.self))
    }
}
