// Copyright 2026 DUO你电脑 contributors. SPDX-License-Identifier: Apache-2.0
import ApplicationServices
import CoreMedia
import Foundation
import IOSurface
import StreamProtocol

/// A future native driver must deliver each borrowed surface inside its callback, return promptly
/// from start/stop and leave any existing run untouched if start throws. Nothing here requests access.
protocol TouchBarSurfaceDriver: AnyObject, Sendable {
    func start(onSurface: @escaping @Sendable (IOSurfaceRef, CMTime) -> Void,
               onStopped: @escaping @Sendable () -> Void) throws
    func stop()
}

private final class TouchBarSourceGate: @unchecked Sendable {
    private let lock = NSLock()
    private var active: UUID?
    func begin(_ token: UUID) { lock.withLock { active = token } }
    func contains(_ token: UUID) -> Bool { lock.withLock { active == token } }
    func admit(_ token: UUID, _ deliver: () -> Void) {
        lock.withLock { if active == token { deliver() } }
    }
    func end(_ token: UUID) -> Bool {
        lock.withLock { guard active == token else { return false }; active = nil; return true }
    }
}

/// Capture-only adapter. It copies borrowed pixels before the callback returns, fences late
/// callbacks and never posts a touch. Without existing recording permission it fails without a
/// prompt. The system screenshot driver's physical Touch Bar compatibility remains unverified.
@MainActor final class TouchBarReadOnlySource: TouchBarCaptureSource {
    enum Failure: Error { case alreadyRunning, recordingUnavailable }
    let supportsInput = false
    private let driver: any TouchBarSurfaceDriver
    private let recordingAllowed: () -> Bool
    private let gate = TouchBarSourceGate()
    private var token: UUID?
    private var onStopped: (@Sendable () -> Void)?

    init(driver: any TouchBarSurfaceDriver, recordingAllowed: @escaping () -> Bool = { CGPreflightScreenCaptureAccess() }) {
        self.driver = driver; self.recordingAllowed = recordingAllowed
    }

    deinit {
        if let token { _ = gate.end(token); driver.stop() }
    }

    func start(onFrame: @escaping @Sendable (TouchBarCapturedFrame) -> Void,
               onStopped: @escaping @Sendable () -> Void) throws {
        guard token == nil else { throw Failure.alreadyRunning }
        guard recordingAllowed() else { throw Failure.recordingUnavailable }
        let next = UUID(), gate = self.gate
        token = next; self.onStopped = onStopped; gate.begin(next)
        do {
            try driver.start(onSurface: { [weak self] surface, pts in
                guard gate.contains(next) else { return }
                guard let frame = TouchBarSurfaceCopier.copy(surface, pts: pts) else {
                    if gate.end(next) { Task { @MainActor [weak self] in self?.finish(next) } }
                    return
                }
                // Admission and stop share this short lock. The session's ingress callback must
                // return promptly and must not synchronously wait for the main actor.
                gate.admit(next) { onFrame(frame) }
            }, onStopped: { [weak self] in
                if gate.end(next) { Task { @MainActor [weak self] in self?.finish(next) } }
            })
        } catch {
            _ = gate.end(next); token = nil; self.onStopped = nil
            throw error
        }
    }

    func post(_ touch: TouchBarTouch) -> Bool { false }

    func stop() {
        guard let token else { return }
        self.token = nil; onStopped = nil; _ = gate.end(token)
        driver.stop()
    }

    private func finish(_ token: UUID) {
        guard self.token == token else { return }
        self.token = nil
        let callback = onStopped; onStopped = nil
        driver.stop()
        callback?()
    }
}
