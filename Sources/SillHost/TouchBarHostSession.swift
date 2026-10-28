// Copyright 2026 DUO你电脑 contributors. SPDX-License-Identifier: Apache-2.0
import Foundation
import ApplicationServices
import CoreMedia
import CoreVideo
import Network
import QuartzCore
import StreamProtocol

/// A driver that wedges in VideoToolbox creation must not let rapid reconnects create unbounded
/// blocked workers. Its slot remains occupied until the actual creation call returns.
private final class TouchBarEncoderCreationGate: @unchecked Sendable {
    private let lock = NSLock()
    private var busy = false
    func acquire() -> Bool { lock.withLock { if busy { return false }; busy = true; return true } }
    func release() { lock.withLock { busy = false } }
}

/// One callback can be running and one latest frame can wait; a busy main actor cannot accumulate
/// captured IOSurfaces. Tokens fence late callbacks from a stopped or replaced capture source.
private final class TouchBarCaptureIngress: @unchecked Sendable {
    private let lock = NSLock()
    private var token: UUID?
    private var pending: TouchBarCapturedFrame?
    private var scheduled = false
    private let schedule: @Sendable (UUID) -> Void
    init(schedule: @escaping @Sendable (UUID) -> Void) { self.schedule = schedule }
    func reset(_ token: UUID?) { lock.withLock { self.token = token; pending = nil; scheduled = false } }
    func offer(_ frame: TouchBarCapturedFrame, token: UUID) {
        lock.lock()
        guard self.token == token else { lock.unlock(); return }
        pending = frame
        let needsSchedule = !scheduled
        scheduled = true
        if needsSchedule { schedule(token) }
        lock.unlock()
    }
    func take(_ token: UUID) -> TouchBarCapturedFrame? {
        lock.withLock {
            guard self.token == token, scheduled else { return nil }
            let frame = pending; pending = nil; scheduled = false; return frame
        }
    }
}

/// Coordinates a source, a hardware-only independent encoder, paired subscribers and one touch.
/// The factory defaults to no source; the current product does not advertise an unverified DFR API.
/// A queued touch must carry the network subscription's revocable input permit to the main actor.
@MainActor final class TouchBarHostSession {
    private let server: StreamServer
    private let makeSource: () -> (any TouchBarCaptureSource)?
    private let recordingAllowed: () -> Bool
    private let inputAllowed: () -> Bool
    private let authorized: (ClientRoute) -> Bool
    private var subscribers: [ObjectIdentifier: NWConnection] = [:]
    private var source: (any TouchBarCaptureSource)?
    private var token: UUID?
    private var surface: TouchBarSurface?
    private var encoder: HEVCEncoder?
    private var preparingEncoder = false
    private var waitingFrame: TouchBarCapturedFrame?
    private var touch = TouchBarTouchGate<ObjectIdentifier>()
    private var lastRefresh = -Double.infinity
    private var delayedRefresh: Task<Void, Never>?
    private var permissionMonitor: Task<Void, Never>?
    private static let refreshSpacing: TimeInterval = 0.5
    private let encoderCreation = TouchBarEncoderCreationGate()
    private lazy var ingress = TouchBarCaptureIngress { [weak self] token in
        Task { @MainActor [weak self] in self?.consumeFrame(token) }
    }

    init(server: StreamServer, makeSource: @escaping () -> (any TouchBarCaptureSource)? = { nil },
         recordingAllowed: @escaping () -> Bool = { CGPreflightScreenCaptureAccess() },
         inputAllowed: @escaping () -> Bool = { AXIsProcessTrusted() },
         authorized: @escaping (ClientRoute) -> Bool = { _ in false }) {
        self.server = server; self.makeSource = makeSource
        self.recordingAllowed = recordingAllowed; self.inputAllowed = inputAllowed
        self.authorized = authorized
        server.setTouchBarKeyframeNeeded { [weak self] token in
            Task { @MainActor [weak self] in self?.refresh(token) }
        }
    }

    /// Only a registered paired TLS connection can subscribe. An absent backend or permission
    /// reports unavailable without calling any permission-request API.
    func subscribe(_ request: TouchBarSubscription, from connection: NWConnection, route: ClientRoute) {
        guard request.isSupported, route.encrypted, route.pairedName != nil else { return }
        let id = ObjectIdentifier(connection)
        if !request.watching { unsubscribe(id); return }
        guard authorized(route) else { unsubscribe(id); return }
        guard recordingAllowed() else {
            if source != nil { stop() }
            send(.init(availability: .unavailable), to: connection)
            return
        }
        if source == nil {
            guard let made = makeSource() else { send(.init(availability: .unavailable), to: connection); return }
            subscribers[id] = connection
            let next = UUID()
            token = next; source = made; ingress.reset(next)
            server.beginTouchBarStream(next)
            send(.init(availability: .starting), to: connection)
            let ingress = self.ingress
            do {
                try made.start(onFrame: { frame in ingress.offer(frame, token: next) }, onStopped: { [weak self] in
                    Task { @MainActor [weak self] in self?.sourceStopped(next) }
                })
                monitorPermissions(next)
            } catch { stop() }
            return
        }
        guard subscribers[id] == nil else { return }
        subscribers[id] = connection
        if let surface, let token {
            send(.init(availability: .live, surface: surface), to: connection)
            server.setTouchBarSubscription(token, for: connection)
        } else { send(.init(availability: .starting), to: connection) }
    }

    func clientLeft(_ connection: NWConnection) { unsubscribe(ObjectIdentifier(connection)) }

    private func unsubscribe(_ id: ObjectIdentifier) {
        guard let connection = subscribers.removeValue(forKey: id) else { return }
        if let release = touch.release(for: id) {
            // If the system revoked input permission, stopping the source is the only safe way to
            // discard its held contact; never post through an untrusted process.
            guard inputAllowed(), source?.post(release) == true else { stop(); return }
        }
        server.setTouchBarSubscription(nil, for: connection)
        if subscribers.isEmpty { stop() }
    }

    func receive(_ event: TouchBarTouch, from connection: NWConnection, route: ClientRoute, permit: TouchBarInputPermit) {
        let id = ObjectIdentifier(connection)
        guard route.encrypted, route.pairedName != nil, authorized(route), subscribers[id] != nil,
              let surface, let source, permit.surfaceID == surface.id, permit.connectionID == id,
              permit.isValid else { return }
        guard recordingAllowed() else { stop(); return }
        guard source.supportsInput, inputAllowed() else {
            if touch.release() != nil { stop() }
            else { updateInputCapability(false) }
            return
        }
        // A newly granted input capability is published before any touch can use it.
        guard surface.acceptsInput else { updateInputCapability(true); return }
        var failed = false
        permit.admit {
            guard let accepted = touch.accept(event, from: id, surface: surface, subscribed: true,
                                              paired: true, inputAllowed: true) else { return }
            failed = !source.post(accepted)
        }
        if failed { stop() }
    }

    /// Client refresh requests have the same paired and current-source checks as input. The
    /// actual encoder request is shared and rate-limited with network catch-up requests.
    func requestRefresh(_ request: TouchBarRefresh, from connection: NWConnection, route: ClientRoute) {
        guard route.encrypted, route.pairedName != nil, authorized(route),
              subscribers[ObjectIdentifier(connection)] != nil, request.surfaceID == token else { return }
        refresh(request.surfaceID)
    }

    private func updateInputCapability(_ allowed: Bool) {
        guard var surface, surface.acceptsInput != allowed else { return }
        surface.acceptsInput = allowed; self.surface = surface
        let status = TouchBarStatus(availability: .live, surface: surface)
        for connection in subscribers.values { send(status, to: connection) }
    }

    /// A static bar may have no capture callbacks for a long time. Recheck existing permission
    /// state while subscribed so the last picture and input capability do not outlive revocation.
    /// This never requests permission; the token prevents an old task from affecting a new source.
    private func monitorPermissions(_ token: UUID) {
        permissionMonitor?.cancel()
        permissionMonitor = Task { @MainActor [weak self] in
            while !Task.isCancelled {
                do { try await Task.sleep(for: .seconds(1)) } catch { return }
                guard !Task.isCancelled, let self, self.reconcilePermissions(token) else { return }
            }
        }
    }

    private func reconcilePermissions(_ token: UUID) -> Bool {
        guard self.token == token, let source else { return false }
        guard recordingAllowed() else { stop(); return false }
        guard surface != nil else { return true }
        let acceptsInput = source.supportsInput && inputAllowed()
        if !acceptsInput, touch.release() != nil {
            // No authorized backend remains to send a release; stop it instead.
            stop(); return false
        }
        updateInputCapability(acceptsInput)
        return true
    }

    private func consumeFrame(_ token: UUID) {
        guard self.token == token, source != nil, !subscribers.isEmpty,
              let frame = ingress.take(token) else { return }
        guard recordingAllowed() else { stop(); return }
        let width = CVPixelBufferGetWidth(frame.pixels), height = CVPixelBufferGetHeight(frame.pixels)
        let candidate = TouchBarSurface(id: token, pixelWidth: frame.contentWidth, pixelHeight: frame.contentHeight,
                                        encodedWidth: width, encodedHeight: height,
                                        acceptsInput: inputAllowed() && source?.supportsInput == true)
        guard candidate.isValid else { stop(); return }
        if let existing = surface {
            guard existing.pixelWidth == candidate.pixelWidth, existing.pixelHeight == candidate.pixelHeight,
                  existing.encodedWidth == width, existing.encodedHeight == height else { stop(); return }
            if existing.acceptsInput != candidate.acceptsInput {
                if !candidate.acceptsInput, touch.release() != nil { stop(); return }
                updateInputCapability(candidate.acceptsInput)
            }
            encoder?.encode(frame.pixels, pts: frame.pts)
            return
        }
        waitingFrame = frame
        guard !preparingEncoder else { return }
        guard encoderCreation.acquire() else { stop(); return }
        preparingEncoder = true
        // Session creation can block; keep the desktop and main actor responsive while preparing.
        let creation = encoderCreation
        DispatchQueue.global(qos: .userInitiated).async { [weak self, creation] in
            defer { creation.release() }
            let made = try? HEVCEncoder(width: width, height: height, fps: 30, bitrate: 3_000_000,
                                        prioritizeSpeed: true, software: false, quiet: true, independentFrames: true)
            Task { @MainActor [weak self] in self?.encoderReady(made, surface: candidate, token: token) }
        }
    }

    private func encoderReady(_ made: HEVCEncoder?, surface: TouchBarSurface, token: UUID) {
        guard self.token == token, source != nil, !subscribers.isEmpty, recordingAllowed(), let made else {
            _ = made?.abandon()
            if self.token == token { stop() }
            return
        }
        var surface = surface
        surface.acceptsInput = inputAllowed() && source?.supportsInput == true
        preparingEncoder = false; encoder = made; self.surface = surface
        made.onEncoded = { [weak server] bytes, keyframe, parameters in
            server?.broadcastTouchBarFrame(bytes, keyframe: keyframe, parameters: parameters,
                                           timestamp: Date().timeIntervalSince1970, token: token)
        }
        made.onHung = { [weak self] in Task { @MainActor [weak self] in self?.sourceStopped(token) } }
        for connection in subscribers.values {
            send(.init(availability: .live, surface: surface), to: connection)
            server.setTouchBarSubscription(token, for: connection)
        }
        if let frame = waitingFrame {
            waitingFrame = nil
            guard frame.contentWidth == surface.pixelWidth, frame.contentHeight == surface.pixelHeight,
                  CVPixelBufferGetWidth(frame.pixels) == surface.encodedWidth,
                  CVPixelBufferGetHeight(frame.pixels) == surface.encodedHeight else { stop(); return }
            made.encode(frame.pixels, pts: frame.pts)
        }
    }

    /// Keyframe requests are coalesced across subscribers. A stale timer cannot revive a stopped
    /// source, and an unchanged Touch Bar can use the encoder's retained last frame.
    private func refresh(_ token: UUID) {
        guard self.token == token, !subscribers.isEmpty, let encoder else { return }
        guard recordingAllowed() else { stop(); return }
        let wait = Self.refreshSpacing - (CACurrentMediaTime() - lastRefresh)
        if wait <= 0 {
            delayedRefresh?.cancel(); delayedRefresh = nil
            lastRefresh = CACurrentMediaTime(); encoder.requestKeyframe()
        } else if delayedRefresh == nil {
            delayedRefresh = Task { @MainActor [weak self] in
                try? await Task.sleep(for: .seconds(wait))
                guard !Task.isCancelled, let self else { return }
                self.delayedRefresh = nil; self.refresh(token)
            }
        }
    }

    private func sourceStopped(_ token: UUID) { if self.token == token { stop() } }

    func stop() {
        let clients = Array(subscribers.values)
        subscribers.removeAll()
        if let release = touch.release(), inputAllowed() { _ = source?.post(release) }
        let old = source; source = nil; token = nil; surface = nil
        ingress.reset(nil); waitingFrame = nil; preparingEncoder = false
        permissionMonitor?.cancel(); permissionMonitor = nil
        delayedRefresh?.cancel(); delayedRefresh = nil; lastRefresh = -Double.infinity
        _ = encoder?.abandon(); encoder = nil
        for connection in clients {
            server.setTouchBarSubscription(nil, for: connection)
            send(.init(availability: .unavailable), to: connection)
        }
        server.beginTouchBarStream(nil)
        old?.stop()
    }

    private func send(_ status: TouchBarStatus, to connection: NWConnection) {
        server.send(StreamMessage(kind: .touchBarStatus, timestamp: Date().timeIntervalSince1970,
                                  isKeyframe: false, payload: Wire.encode(status)), to: connection)
    }
}
