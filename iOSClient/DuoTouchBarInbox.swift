// Copyright 2026 DUO你电脑 contributors. SPDX-License-Identifier: Apache-2.0
import Foundation
import Network
import StreamProtocol

/// The network queue may outrun the main actor. Keep at most one status and one independently
/// decodable frame; a newer status invalidates an older frame before either reaches the UI.
final class DuoTouchBarInbox: @unchecked Sendable {
    private struct Status {
        let value: TouchBarStatus
        let connection: NWConnection
        let revision: UInt64
    }
    private struct Frame {
        let packet: TouchBarKeyframe
        let connection: NWConnection
        let revision: UInt64
    }
    private let lock = NSLock()
    private var generation: UInt64 = 0
    private var revision: UInt64 = 0
    private var pendingStatus: Status?
    private var pendingFrame: Frame?
    private var scheduled = false
    private var statusHandler: (@MainActor (TouchBarStatus, NWConnection) -> Void)?
    private var frameHandler: (@MainActor (TouchBarKeyframe, NWConnection) -> Void)?

    @MainActor func attach(status: @escaping @MainActor (TouchBarStatus, NWConnection) -> Void,
                           frame: @escaping @MainActor (TouchBarKeyframe, NWConnection) -> Void) {
        lock.withLock { statusHandler = status; frameHandler = frame }
    }

    func invalidate() {
        lock.withLock { generation &+= 1; revision &+= 1; pendingStatus = nil; pendingFrame = nil; scheduled = false }
    }

    /// Enqueue status before later frames from the same serial network reader. Malformed status
    /// clears any previous surface rather than leaving an old picture eligible for input.
    func receiveStatus(_ data: Data, from connection: NWConnection) {
        let decoded = Wire.decode(TouchBarStatus.self, from: data)
        let status = decoded?.isValid == true ? decoded! : TouchBarStatus(availability: .unavailable)
        lock.lock()
        revision &+= 1
        pendingStatus = Status(value: status, connection: connection, revision: revision)
        pendingFrame = nil
        scheduleLocked()
        lock.unlock()
    }

    func receiveFrame(_ data: Data, keyframe: Bool, from connection: NWConnection) {
        guard keyframe, let packet = TouchBarKeyframe(encoded: data) else { return }
        lock.lock()
        pendingFrame = Frame(packet: packet, connection: connection, revision: revision)
        scheduleLocked()
        lock.unlock()
    }

    private func scheduleLocked() {
        guard !scheduled else { return }
        let current = generation
        scheduled = true
        DispatchQueue.main.async { [weak self] in self?.drain(generation: current) }
    }

    @MainActor private func drain(generation: UInt64) {
        let result = lock.withLock { () -> (Status?, Frame?,
            (@MainActor (TouchBarStatus, NWConnection) -> Void)?,
            (@MainActor (TouchBarKeyframe, NWConnection) -> Void)?)? in
            guard self.generation == generation, scheduled else { return nil }
            let result = (pendingStatus, pendingFrame, statusHandler, frameHandler)
            pendingStatus = nil; pendingFrame = nil; scheduled = false
            return result
        }
        guard let (status, frame, onStatus, onFrame) = result else { return }
        if let status, lock.withLock({ self.generation == generation && revision == status.revision }) {
            onStatus?(status.value, status.connection)
        }
        if let frame, lock.withLock({ self.generation == generation && revision == frame.revision }) {
            onFrame?(frame.packet, frame.connection)
        }
    }
}
