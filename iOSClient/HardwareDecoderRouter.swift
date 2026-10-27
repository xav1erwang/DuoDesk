// Copyright 2026 DUO你电脑 contributors. SPDX-License-Identifier: Apache-2.0
import CoreGraphics
import CoreMedia
import Foundation
import StreamProtocol

/// Owns the current hardware decoder and at most one retiring predecessor. A blocked old VT
/// call cannot occupy the replacement's serial queue; old callbacks carry an earlier generation.
final class HardwareDecoderRouter: @unchecked Sendable {
    private let lock = NSLock()
    private let recoveryQueue = DispatchQueue(label: "duodesk.decoder-router-recovery", qos: .userInitiated)
    private let onFormat: (CGSize, UInt64) -> Void
    private let onSample: (CMSampleBuffer, UInt64, VideoOutputPermit) -> Void
    private let onFailure: (String, UInt64) -> Void
    private let onNeedsKeyframe: (UInt64) -> Void
    private let onReset: (UInt64) -> Void
    private var decoder: HardwareHEVCDecoder?
    private var identity = UUID()
    private var retiring: Set<UUID> = [] // guarded by lock, at most one
    private var required: DuoDesktopResolution?
    private var parameters: ParameterSets?
    private var attemptedRecovery = false
    private var requestAfterFormat: UUID?
    private var unavailableToken: UInt64?
    private var unavailableReported = false

    init(onFormat: @escaping (CGSize, UInt64) -> Void, onSample: @escaping (CMSampleBuffer, UInt64, VideoOutputPermit) -> Void,
         onFailure: @escaping (String, UInt64) -> Void, onNeedsKeyframe: @escaping (UInt64) -> Void = { _ in },
         onReset: @escaping (UInt64) -> Void = { _ in }) {
        self.onFormat = onFormat; self.onSample = onSample; self.onFailure = onFailure
        self.onNeedsKeyframe = onNeedsKeyframe; self.onReset = onReset
        decoder = makeDecoder(initialGeneration: 0, identity: identity)
    }

    private func makeDecoder(initialGeneration: UInt64, identity id: UUID) -> HardwareHEVCDecoder {
        HardwareHEVCDecoder(initialGeneration: initialGeneration, onFormat: { [weak self] size, token in
            self?.format(size, token: token, identity: id)
        }, onSample: { [weak self] image, token in
            self?.sample(image, token: token, identity: id)
        }, onFailure: { [weak self] message, token in
            self?.failed(message, token: token, identity: id)
        }, onNeedsKeyframe: { [weak self] token in
            // enqueue can ask synchronously while the router holds its admission lock.
            self?.recoveryQueue.async { [weak self] in self?.request(token, identity: id) }
        })
    }

    func isCurrent(_ token: UInt64) -> Bool {
        lock.lock(); defer { lock.unlock() }
        return decoder?.isCurrent(token) == true
    }

    /// Unlike failure reporting, input and presentation are disallowed as soon as a decoder fails.
    func canOutput(_ token: UInt64) -> Bool {
        lock.lock(); defer { lock.unlock() }
        return decoder?.canOutput(token) == true
    }

    @discardableResult
    func require(_ resolution: DuoDesktopResolution?) -> UInt64 {
        lock.lock(); defer { lock.unlock() }
        guard required != resolution else { return decoder!.require(resolution) }
        required = resolution
        parameters = nil; requestAfterFormat = nil; attemptedRecovery = false
        if retiring.isEmpty { return replaceLocked().token }
        if let token = decoder!.fenceFailed() {
            unavailableToken = token; unavailableReported = false; return token
        }
        unavailableToken = nil
        let token = decoder!.require(resolution)
        decoder!.watchQueue()
        return token
    }

    /// Reset immediately fences the old generation. When one predecessor is already retiring,
    /// reuse the current queue rather than create an unbounded number of stuck sessions.
    @discardableResult
    func clear() -> UInt64 {
        lock.lock(); defer { lock.unlock() }
        parameters = nil; requestAfterFormat = nil; attemptedRecovery = false
        if retiring.isEmpty { return replaceLocked().token }
        if let token = decoder!.fenceFailed() {
            unavailableToken = token; unavailableReported = false; return token
        }
        unavailableToken = nil
        let token = decoder!.clear()
        decoder!.watchQueue()
        return token
    }

    func apply(_ value: ParameterSets) {
        lock.lock()
        parameters = value
        if let token = unavailableToken {
            let id = identity, notify = !unavailableReported
            unavailableReported = true
            lock.unlock()
            if notify { recoveryQueue.async { [weak self] in self?.reportUnavailable(token, identity: id) } }
            return
        }
        decoder!.apply(value)
        lock.unlock()
    }

    func enqueue(_ data: Data, isKeyframe: Bool) {
        lock.lock(); defer { lock.unlock() }
        decoder!.enqueue(data, isKeyframe: isKeyframe)
    }

    /// Caller holds lock. The retiring queue owns its own session and byte reservations; nothing
    /// it does after retirement can mutate the replacement decoder's accounting or generation.
    private func replaceLocked() -> (decoder: HardwareHEVCDecoder, token: UInt64) {
        let previous = decoder!, oldID = identity
        retiring.insert(oldID)
        let barrier = previous.retire { [weak self] in
            guard let self else { return }
            self.lock.withLock { _ = self.retiring.remove(oldID) }
        }
        let newID = UUID(), next = makeDecoder(initialGeneration: barrier, identity: newID)
        identity = newID; decoder = next; unavailableToken = nil; unavailableReported = false
        return (next, next.require(required))
    }

    private func matchesLocked(_ id: UUID, token: UInt64) -> Bool {
        identity == id && decoder?.isCurrent(token) == true
    }

    private func format(_ size: CGSize, token: UInt64, identity id: UUID) {
        lock.lock()
        guard identity == id, decoder?.canOutput(token) == true else { lock.unlock(); return }
        let request = requestAfterFormat == id
        if request { requestAfterFormat = nil }
        lock.unlock()
        onFormat(size, token)
        if request { self.request(token, identity: id) }
    }

    private func sample(_ image: CMSampleBuffer, token: UInt64, identity id: UUID) {
        lock.lock(); let permit = identity == id ? decoder?.admissionPermit(for: token) : nil; lock.unlock()
        if let permit { onSample(image, token, permit) }
    }

    private func request(_ token: UInt64, identity id: UUID) {
        lock.lock(); let current = identity == id && decoder?.canOutput(token) == true; lock.unlock()
        if current { onNeedsKeyframe(token) }
    }

    private func reportUnavailable(_ token: UInt64, identity id: UUID) {
        lock.lock(); let current = unavailableToken == token && matchesLocked(id, token: token); lock.unlock()
        if current { onFailure("硬件解码器仍在等待旧会话退出。", token) }
    }

    private func failed(_ message: String, token: UInt64, identity id: UUID) {
        lock.lock()
        guard matchesLocked(id, token: token) else { lock.unlock(); return }
        guard !attemptedRecovery, retiring.isEmpty, required != nil, let parameters else {
            lock.unlock(); onFailure(message, token); return
        }
        attemptedRecovery = true
        let replacement = replaceLocked()
        requestAfterFormat = identity
        // Parameter admission is queued before a later network frame can enter this instance.
        replacement.decoder.apply(parameters)
        lock.unlock()
        onReset(replacement.token)
    }
}
