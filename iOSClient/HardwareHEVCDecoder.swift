// Copyright 2026 DUO你电脑 contributors. SPDX-License-Identifier: Apache-2.0
import Foundation
import CoreGraphics
import CoreMedia
import CoreVideo
import VideoToolbox
import StreamProtocol

/// The desktop and a Touch Bar have different shape constraints. Both require the encoded
/// dimensions to match exactly before VideoToolbox creates a session; neither accepts downscaling.
enum HardwareVideoRequirement: Equatable {
    case desktop(DuoDesktopResolution)
    case touchBar(width: Int, height: Int)

    func accepts(width: Int, height: Int) -> Bool {
        switch self {
        case .desktop(let size): return size.accepts(width: width, height: height)
        case .touchBar(let w, let h):
            return (1...8192).contains(w) && (1...2048).contains(h)
                && w.isMultiple(of: 2) && h.isMultiple(of: 2) && w >= h
                && w * h <= 4_194_304 && width == w && height == h
        }
    }
}

/// Serializes VideoToolbox session operations. Output is an IOSurface backed image buffer;
/// AVFoundation only presents it. Generation checks discard callbacks from an old connection.
final class HardwareHEVCDecoder: @unchecked Sendable {
    // The simulator reports no HEVC hardware decoder. This opt-in exists only in Debug simulator
    // binaries so UI tests can run; it never changes device/Release hardware requirements.
    static var simulatorSoftwareEnabled: Bool {
        #if DEBUG && targetEnvironment(simulator)
        UserDefaults.standard.bool(forKey: "DuoSimulatorSoftwareDecode")
        #else
        false
        #endif
    }
    let onFormat: (CGSize, UInt64) -> Void
    let onSample: (CMSampleBuffer, UInt64, VideoOutputPermit) -> Void
    let onFailure: (String, UInt64) -> Void
    let onNeedsKeyframe: (UInt64) -> Void
    let onOutputInvalidated: (VideoOutputPermit, UInt64) -> Void
    private let queue = DispatchQueue(label: "duodesk.hardware-decoder", qos: .userInteractive)
    // Only this small admission/generation state crosses the network, UI and VT callback queues.
    private let lock = NSLock()
    private var generation: UInt64 = 0
    // Once retired, this instance cannot admit work even if an old network callback kept it.
    private var retired = false
    private var outputPermit: VideoOutputPermit? = VideoOutputPermit() // guarded by lock
    // Avoid queuing notifications for repeated invalid inputs when this epoch submitted no frame.
    private var outputPermitHasFlight = false // guarded by lock
    // A queued parameter-set operation belongs to the connection/resolution that admitted it.
    // It must not mint a new generation after clear() has already fenced that connection out.
    private var inputEpoch: UInt64 = 0
    private var required: HardwareVideoRequirement?
    private var backlog = VideoDecodeBacklog(maxFrameBytes: StreamMessage.maxFramePayload)
    private var inFlight = 0
    // Compressed bytes submitted to this generation of VideoToolbox but not yet returned.
    // Admission accounts for these together with queued input, without counting a transfer twice.
    private var inFlightBytes = 0
    private static let compressedBytesLimit = StreamMessage.maxFramePayload
    // Under lock: time since the first outstanding frame or most recent completion. New inputs
    // cannot postpone the timeout while none of the outstanding callbacks makes progress.
    private var callbackProgressAt: TimeInterval?
    // An explicit queue checkpoint also detects a blocked reset/invalidation when no frame is
    // counted in flight. Repeated resets coalesce behind one checkpoint and one recheck.
    private var queueCheckpointAt: TimeInterval?
    private var queueCheckpointID: UInt64 = 0
    private var queueCheckpointAgain = false
    private var failed = false
    private let watchdogQueue = DispatchQueue(label: "duodesk.decoder-watchdog", qos: .utility)
    private var watchdog: DispatchSourceTimer?
    // Anchor the first tick too: the app can be suspended before the timer ever fires.
    private var lastWatchdogCheck = ProcessInfo.processInfo.systemUptime // guarded by lock
    private static let stallAfter: TimeInterval = 3
    // The remaining state belongs exclusively to queue.
    private var session: VTDecompressionSession?
    private var description: CMVideoFormatDescription?
    private var parameters: Data?
    private var sessionGeneration: UInt64 = 0
    private var waitingForKeyframe = true
    private var frameIndex: Int64 = 0
    private var measurements: [Double] = []
    private var hardware = true
    private var lastRecoveryRequest = -Double.infinity // guarded by lock
    private let recoveryQueue = DispatchQueue(label: "duodesk.decoder-recovery", qos: .userInitiated)
    private var recoveryTimer: DispatchWorkItem? // guarded by lock
    private var recoveryTimerID: UInt64 = 0      // guarded by lock
    private var latestOutputSequence: Int64 = 0  // guarded by lock
    private static let recoverySpacing: TimeInterval = 0.5

    /// VT can report synchronous drops and also finish a callback around the return. One frame
    /// owns exactly one in-flight slot; its completion is claimed under the decoder lock.
    private final class Flight: @unchecked Sendable {
        let generation: UInt64
        let ticket: VideoDecodeBacklog.Ticket
        let sequence: Int64
        let started: TimeInterval
        let compressedBytes: Int
        let outputPermit: VideoOutputPermit
        var completed = false // guarded by the decoder lock
        init(generation: UInt64, ticket: VideoDecodeBacklog.Ticket, sequence: Int64, started: TimeInterval,
             outputPermit: VideoOutputPermit, compressedBytes: Int = 0) {
            self.generation = generation; self.ticket = ticket; self.sequence = sequence; self.started = started
            self.outputPermit = outputPermit; self.compressedBytes = compressedBytes
        }
    }

    init(initialGeneration: UInt64 = 0, onFormat: @escaping (CGSize, UInt64) -> Void,
         onSample: @escaping (CMSampleBuffer, UInt64, VideoOutputPermit) -> Void,
         onFailure: @escaping (String, UInt64) -> Void, onNeedsKeyframe: @escaping (UInt64) -> Void = { _ in },
         onOutputInvalidated: @escaping (VideoOutputPermit, UInt64) -> Void = { _, _ in }) {
        self.generation = initialGeneration
        self.onFormat = onFormat; self.onSample = onSample; self.onFailure = onFailure
        self.onNeedsKeyframe = onNeedsKeyframe; self.onOutputInvalidated = onOutputInvalidated
        let timer = DispatchSource.makeTimerSource(queue: watchdogQueue)
        timer.schedule(deadline: .now() + 0.5, repeating: 0.5, leeway: .milliseconds(100))
        timer.setEventHandler { [weak self] in self?.checkWatchdog() }
        timer.resume()
        watchdog = timer
    }

    deinit {
        watchdog?.cancel()
        outputPermit?.invalidate()
        if let session { DispatchQueue.global(qos: .utility).async { VTDecompressionSessionInvalidate(session) } }
    }

    func isCurrent(_ value: UInt64) -> Bool {
        lock.lock(); defer { lock.unlock() }; return generation == value && !retired
    }

    func canOutput(_ value: UInt64) -> Bool {
        lock.lock(); defer { lock.unlock() }; return generation == value && !failed && !retired
    }

    func admissionPermit(for value: UInt64) -> VideoOutputPermit? {
        lock.lock(); defer { lock.unlock() }
        return generation == value && !failed && !retired ? outputPermit : nil
    }

    /// Under lock. The permit's short admission critical section never calls back into us.
    private func replaceOutputPermitLocked(allow: Bool) {
        outputPermit?.invalidate()
        outputPermit = allow ? VideoOutputPermit() : nil
        outputPermitHasFlight = false
    }

    /// A reset invalidates tickets already admitted in this generation. Revoke their output
    /// permit as well, but retain it when an earlier frame survives a later budget gap.
    private func resetBacklogLocked() -> VideoOutputPermit? {
        let invalidated = outputPermitHasFlight ? outputPermit : nil
        backlog.reset()
        replaceOutputPermitLocked(allow: !failed && !retired)
        return invalidated
    }

    private func advance(ifInputEpoch epoch: UInt64) -> UInt64? {
        lock.lock(); defer { lock.unlock() }
        guard inputEpoch == epoch, !failed, !retired else { return nil }
        replaceOutputPermitLocked(allow: true)
        generation &+= 1; inFlight = 0; inFlightBytes = 0; latestOutputSequence = 0; lastRecoveryRequest = -.infinity
        callbackProgressAt = nil
        cancelRecoveryTimerLocked()
        return generation
    }

    @discardableResult
    func require(_ value: DuoDesktopResolution?) -> UInt64 {
        requireVideo(value.map(HardwareVideoRequirement.desktop))
    }

    /// Use only for an independently identified Touch Bar surface, never the desktop.
    @discardableResult
    func requireVideo(_ value: HardwareVideoRequirement?) -> UInt64 {
        lock.lock()
        guard !retired else { let token = generation; lock.unlock(); return token }
        guard required != value else { let token = generation; lock.unlock(); return token }
        replaceOutputPermitLocked(allow: true)
        required = value; inputEpoch &+= 1; generation &+= 1; inFlight = 0; inFlightBytes = 0; backlog.reset()
        callbackProgressAt = nil; failed = false
        latestOutputSequence = 0; lastRecoveryRequest = -.infinity; cancelRecoveryTimerLocked()
        let token = generation
        queue.async { [self] in if isCurrent(token) { invalidate() } }
        lock.unlock()
        return token
    }

    @discardableResult
    func clear() -> UInt64 {
        lock.lock()
        guard !retired else { let token = generation; lock.unlock(); return token }
        replaceOutputPermitLocked(allow: true)
        inputEpoch &+= 1; generation &+= 1; inFlight = 0; inFlightBytes = 0; backlog.reset()
        callbackProgressAt = nil; failed = false
        latestOutputSequence = 0; lastRecoveryRequest = -.infinity; cancelRecoveryTimerLocked()
        let token = generation
        queue.async { [self] in if isCurrent(token) { invalidate() } }
        lock.unlock()
        return token
    }

    /// If a failed queue cannot be replaced because the router's retirement limit is full,
    /// fence the old generation without pretending the same blocked queue became usable.
    func fenceFailed() -> UInt64? {
        lock.lock(); defer { lock.unlock() }
        guard failed, !retired else { return nil }
        replaceOutputPermitLocked(allow: false)
        inputEpoch &+= 1; generation &+= 1; inFlight = 0; inFlightBytes = 0; backlog.reset()
        callbackProgressAt = nil; latestOutputSequence = 0; lastRecoveryRequest = -.infinity
        cancelRecoveryTimerLocked(); cancelQueueCheckpointLocked()
        return generation
    }

    /// Call after a reset that must reuse this queue. The marker runs after that reset and before
    /// subsequent admissions; an already pending marker coalesces later resets into one recheck.
    func watchQueue() {
        lock.lock(); defer { lock.unlock() }
        guard !failed, !retired else { return }
        if queueCheckpointAt != nil { queueCheckpointAgain = true; return }
        startQueueCheckpointLocked(now: ProcessInfo.processInfo.systemUptime)
    }

    private func startQueueCheckpointLocked(now: TimeInterval) {
        queueCheckpointID &+= 1
        let id = queueCheckpointID
        queueCheckpointAt = now
        queue.async { [weak self] in self?.queueCheckpointReached(id) }
    }

    private func queueCheckpointReached(_ id: UInt64) {
        lock.lock(); defer { lock.unlock() }
        guard queueCheckpointID == id, queueCheckpointAt != nil, !failed, !retired else { return }
        if queueCheckpointAgain {
            queueCheckpointAgain = false
            startQueueCheckpointLocked(now: ProcessInfo.processInfo.systemUptime)
        } else { queueCheckpointAt = nil }
    }

    private func cancelQueueCheckpointLocked() {
        queueCheckpointID &+= 1; queueCheckpointAt = nil; queueCheckpointAgain = false
    }

    /// Fence an abandoned instance immediately, then retire its session on its own queue. The
    /// completion is intentionally not called until invalidation returns; a router can bound the
    /// number of old queues retained when a VideoToolbox call never comes back.
    @discardableResult
    func retire(onDrained: @escaping () -> Void) -> UInt64 {
        lock.lock()
        guard !retired else { let token = generation; lock.unlock(); return token }
        replaceOutputPermitLocked(allow: false)
        retired = true; failed = true; inputEpoch &+= 1; generation &+= 1
        inFlight = 0; inFlightBytes = 0; callbackProgressAt = nil; backlog.reset()
        latestOutputSequence = 0; cancelRecoveryTimerLocked(); cancelQueueCheckpointLocked()
        let token = generation
        queue.async { [self] in invalidate(); onDrained() }
        lock.unlock()
        watchdog?.cancel()
        return token
    }

    private func invalidate() {
        if let session { VTDecompressionSessionInvalidate(session) }
        session = nil; description = nil; parameters = nil
        waitingForKeyframe = true; frameIndex = 0; measurements = []
    }

    private func fail(_ status: OSStatus, generation: UInt64, reason: String = "VideoToolbox") {
        lock.lock(); let counts = claimFailureLocked(generation); lock.unlock()
        guard let counts else { return }
        reportFailure(status, generation: generation, reason: reason, counts: counts)
    }

    /// Under lock. Keep the generation for the UI's failure callback, but fence all old queued
    /// inputs and decoded pictures immediately; clear/require starts a fresh generation.
    private func claimFailureLocked(_ token: UInt64) -> (pending: Int, active: Int)? {
        guard generation == token, !failed, !retired else { return nil }
        replaceOutputPermitLocked(allow: false)
        failed = true; inputEpoch &+= 1; backlog.reset(); cancelRecoveryTimerLocked(); cancelQueueCheckpointLocked()
        return (backlog.frames, inFlight)
    }

    private func reportFailure(_ status: OSStatus, generation: UInt64, reason: String,
                               counts: (pending: Int, active: Int)) {
        let (pending, active) = counts
        print("HEVC decode failed: \(status), \(reason), queued=\(pending), inFlight=\(active), generation=\(generation)")
        onFailure("硬件解码不可用（\(status)），请重新连接。", generation)
    }

    /// This queue cannot be blocked behind a VideoToolbox call on the decoder queue. A long gap
    /// between watchdog ticks may be app suspension or scheduler starvation; allow a fresh grace
    /// interval on resumption rather than declaring the session dead based on suspended time.
    private func checkWatchdog() {
        let now = ProcessInfo.processInfo.systemUptime
        lock.lock()
        let gap = now - lastWatchdogCheck
        lastWatchdogCheck = now
        if gap > 2 {
            if callbackProgressAt != nil { callbackProgressAt = now }
            if queueCheckpointAt != nil { queueCheckpointAt = now }
        }
        let token = generation
        let queueStalled = queueCheckpointAt.map { now - $0 >= Self.stallAfter } == true
        let stalled = queueStalled || (inFlight > 0 && callbackProgressAt.map { now - $0 >= Self.stallAfter } == true)
        let counts = stalled ? claimFailureLocked(token) : nil
        lock.unlock()
        if let counts { reportFailure(kVTVideoDecoderNotAvailableNowErr, generation: token,
                                      reason: queueStalled ? "decoder queue stalled" : "decoder callbacks stalled", counts: counts) }
    }

    func apply(_ ps: ParameterSets) {
        lock.lock()
        guard !failed, !retired else { lock.unlock(); return }
        let epoch = inputEpoch
        queue.async { [self] in
            lock.lock(); let current = inputEpoch == epoch && !failed; lock.unlock()
            guard current else { return }
            guard ps.sets.count == 3, ps.sets.allSatisfy({ !$0.isEmpty && $0.count <= 65_535 }),
                  ps.nalUnitHeaderLength == 4 else {
                guard let token = advance(ifInputEpoch: epoch) else { return }
                invalidate()
                fail(kVTVideoDecoderBadDataErr, generation: token); return
            }
            let encoded = ps.encoded()
            if encoded == parameters, session != nil, isCurrent(sessionGeneration) { return }
            guard let token = advance(ifInputEpoch: epoch) else { return }
            invalidate()
            var format: CMVideoFormatDescription?
            let buffers = ps.sets.map { data -> UnsafeMutablePointer<UInt8> in
                let p = UnsafeMutablePointer<UInt8>.allocate(capacity: data.count)
                data.copyBytes(to: p, count: data.count); return p
            }
            defer { buffers.forEach { $0.deallocate() } }
            let pointers = buffers.map { UnsafePointer($0) }, sizes = ps.sets.map(\.count)
            let status = CMVideoFormatDescriptionCreateFromHEVCParameterSets(allocator: nil, parameterSetCount: 3,
                parameterSetPointers: pointers, parameterSetSizes: sizes, nalUnitHeaderLength: 4,
                extensions: nil, formatDescriptionOut: &format)
            guard status == noErr, let format else { fail(status, generation: token); return }
            let dimensions = CMVideoFormatDescriptionGetDimensions(format)
            lock.lock(); let target = required; lock.unlock()
            guard let target, target.accepts(width: Int(dimensions.width), height: Int(dimensions.height)) else { return }
            var made: VTDecompressionSession?
            let simulatorTest = Self.simulatorSoftwareEnabled
            let spec = simulatorTest
                ? [kVTVideoDecoderSpecification_EnableHardwareAcceleratedVideoDecoder: false] as CFDictionary
                : [kVTVideoDecoderSpecification_RequireHardwareAcceleratedVideoDecoder: true] as CFDictionary
            let attrs: [CFString: Any] = [kCVPixelBufferPixelFormatTypeKey: kCVPixelFormatType_420YpCbCr8BiPlanarFullRange,
                         kCVPixelBufferIOSurfacePropertiesKey: [:], kCVPixelBufferMetalCompatibilityKey: true]
            let creation = VTDecompressionSessionCreate(allocator: nil, formatDescription: format, decoderSpecification: spec,
                imageBufferAttributes: attrs as CFDictionary, outputCallback: nil, decompressionSessionOut: &made)
            guard creation == noErr, let made else { fail(creation, generation: token); return }
            var actual: Unmanaged<CFTypeRef>?
            let query = VTSessionCopyProperty(made, key: kVTDecompressionPropertyKey_UsingHardwareAcceleratedVideoDecoder,
                                             allocator: nil, valueOut: &actual)
            let realtime = VTSessionSetProperty(made, key: kVTDecompressionPropertyKey_RealTime, value: kCFBooleanTrue)
            let usingHardware = (actual?.takeRetainedValue() as? NSNumber)?.boolValue == true
            guard ((query == noErr && usingHardware) || simulatorTest), realtime == noErr, isCurrent(token) else {
                VTDecompressionSessionInvalidate(made)
                fail(query != noErr ? query : kVTVideoDecoderNotAvailableNowErr, generation: token); return
            }
            session = made; description = format; parameters = encoded; sessionGeneration = token
            hardware = usingHardware
            print("\(usingHardware ? "Hardware" : "SIMULATOR TEST ONLY software") HEVC decoder verified: \(dimensions.width)×\(dimensions.height), realtime, IOSurface")
            onFormat(CGSize(width: Int(dimensions.width), height: Int(dimensions.height)), token)
        }
        lock.unlock()
    }

    func enqueue(_ data: Data, isKeyframe: Bool) {
        lock.lock()
        guard !failed, !retired else { lock.unlock(); return }
        // Even an empty or oversized access unit is a gap in the reference chain. Let the
        // bounded admission state fence old work and request recovery instead of silently
        // returning before it can observe the discarded frame. The queue and this generation's
        // in-flight compressed data share one wire-sized budget.
        let count = data.count, limit = Self.compressedBytesLimit
        guard count > 0, count <= limit else {
            let invalidated = resetBacklogLocked(), token = generation
            let request = requestRecoveryLocked(now: ProcessInfo.processInfo.systemUptime)
            lock.unlock()
            if let invalidated { onOutputInvalidated(invalidated, token) }
            if let request { print("Video backlog: waiting for a fresh keyframe"); onNeedsKeyframe(request) }
            return
        }
        guard inFlightBytes <= limit - count, backlog.bytes <= limit - count - inFlightBytes else {
            // The frame that did not fit is later than all existing tickets. Preserve those
            // earlier outputs (especially a large recovery keyframe), but reject future deltas.
            backlog.waitForKeyframeAfterGap()
            let request = requestRecoveryLocked(now: ProcessInfo.processInfo.systemUptime)
            lock.unlock()
            if let request { print("Video backlog: waiting for a fresh keyframe"); onNeedsKeyframe(request) }
            return
        }
        let previousEpoch = backlog.epoch
        let ticket = backlog.admit(bytes: data.count, keyframe: isKeyframe)
        let invalidated = backlog.epoch != previousEpoch && outputPermitHasFlight ? outputPermit : nil
        if backlog.epoch != previousEpoch { replaceOutputPermitLocked(allow: true) }
        guard let ticket else {
            let token = generation
            let request = requestRecoveryLocked(now: ProcessInfo.processInfo.systemUptime)
            lock.unlock()
            if let invalidated { onOutputInvalidated(invalidated, token) }
            if let request { print("Video backlog: waiting for a fresh keyframe"); onNeedsKeyframe(request) }
            return
        }
        if isKeyframe, recoveryTimer != nil { cancelRecoveryTimerLocked() }
        let epoch = inputEpoch
        queue.async { [self] in
            var queued = true
            defer { if queued { lock.lock(); backlog.complete(ticket); lock.unlock() } }
            lock.lock(); let current = inputEpoch == epoch && !failed && backlog.isCurrent(ticket); lock.unlock()
            guard current else { return }
            guard let session, let description, canOutput(sessionGeneration) else { return }
            if waitingForKeyframe { guard isKeyframe else { return }; waitingForKeyframe = false }
            var block: CMBlockBuffer?
            guard CMBlockBufferCreateWithMemoryBlock(allocator: nil, memoryBlock: nil, blockLength: data.count,
                blockAllocator: nil, customBlockSource: nil, offsetToData: 0, dataLength: data.count,
                flags: 0, blockBufferOut: &block) == noErr, let block,
                  CMBlockBufferAssureBlockMemory(block) == noErr else { return }
            let replaced = data.withUnsafeBytes { bytes in
                CMBlockBufferReplaceDataBytes(with: bytes.baseAddress!, blockBuffer: block, offsetIntoDestination: 0, dataLength: data.count)
            }
            guard replaced == noErr else { fail(replaced, generation: sessionGeneration); return }
            frameIndex += 1
            var timing = CMSampleTimingInfo(duration: CMTime(value: 1, timescale: 120),
                presentationTimeStamp: CMTime(value: frameIndex, timescale: 120), decodeTimeStamp: .invalid)
            var size = data.count; var sample: CMSampleBuffer?
            let ready = CMSampleBufferCreateReady(allocator: nil, dataBuffer: block, formatDescription: description,
                sampleCount: 1, sampleTimingEntryCount: 1, sampleTimingArray: &timing,
                sampleSizeEntryCount: 1, sampleSizeArray: &size, sampleBufferOut: &sample)
            guard ready == noErr, let sample else { fail(ready, generation: sessionGeneration); return }
            let token = sessionGeneration
            lock.lock()
            let readyForSession = generation == token && !failed && backlog.isCurrent(ticket)
            let permit = outputPermit
            let available = readyForSession && permit != nil && inFlight < 32 && inFlightBytes <= Self.compressedBytesLimit - data.count
            if available {
                // Move the reservation to VT under the same lock; an arriving frame sees it
                // exactly once, and an older fenced ticket cannot enter the decoder.
                if inFlight == 0 { callbackProgressAt = ProcessInfo.processInfo.systemUptime }
                inFlight += 1; inFlightBytes += data.count
                outputPermitHasFlight = true
                backlog.complete(ticket); queued = false
            }
            lock.unlock()
            guard readyForSession else { return }
            guard available, let permit else { fail(kVTVideoDecoderNotAvailableNowErr, generation: token, reason: "decoder callbacks stalled"); return }
            let started = ProcessInfo.processInfo.systemUptime
            let flight = Flight(generation: token, ticket: ticket, sequence: frameIndex, started: started,
                                outputPermit: permit, compressedBytes: data.count)
            var info: VTDecodeInfoFlags = []
            let decoded = VTDecompressionSessionDecodeFrame(session, sampleBuffer: sample,
                flags: [._EnableAsynchronousDecompression], infoFlagsOut: &info) { [weak self] status, flags, image, pts, _ in
                    self?.decoded(image, status: status, flags: flags, flight: flight, pts: pts)
                }
            completeSubmission(decoded, flags: info, flight: flight)
        }
        lock.unlock()
    }

    /// Called on the decoder queue after VT returns; a callback may already have claimed flight.
    private func completeSubmission(_ status: OSStatus, flags: VTDecodeInfoFlags, flight: Flight) {
        if status != noErr || flags.contains(.frameDropped) {
            decoded(nil, status: status, flags: flags, flight: flight, pts: .invalid)
        }
    }

    private func decoded(_ image: CVImageBuffer?, status: OSStatus, flags: VTDecodeInfoFlags, flight: Flight,
                         pts: CMTime) {
        lock.lock()
        guard !flight.completed else { lock.unlock(); return }
        flight.completed = true
        let token = flight.generation
        guard generation == token else { lock.unlock(); return }
        inFlight -= 1; inFlightBytes -= flight.compressedBytes
        callbackProgressAt = inFlight == 0 ? nil : ProcessInfo.processInfo.systemUptime
        let current = !failed && backlog.isCurrent(flight.ticket)
        lock.unlock()
        guard current else { return }
        guard status == noErr else {
            // The decoder queue itself may be stuck in VideoToolbox. Failure claiming is
            // lock-protected, so report directly from either the callback or submission path.
            fail(status, generation: token)
            return
        }
        // No image or a drop flag can leave the last desktop update unseen forever. Requiring a
        // keyframe also fences dependent work. An older callback cannot undo a newer good image.
        guard !flags.contains(.frameDropped), let image else { recoverMissingOutput(flight); return }
        var format: CMVideoFormatDescription?
        guard CMVideoFormatDescriptionCreateForImageBuffer(allocator: nil, imageBuffer: image, formatDescriptionOut: &format) == noErr,
              let format else { recoverMissingOutput(flight); return }
        // Sequence belongs to the submitted sample even if VT's optional output PTS is invalid.
        var timing = CMSampleTimingInfo(duration: .invalid,
            presentationTimeStamp: CMTime(value: flight.sequence, timescale: 120), decodeTimeStamp: .invalid)
        var sample: CMSampleBuffer?
        guard CMSampleBufferCreateReadyWithImageBuffer(allocator: nil, imageBuffer: image, formatDescription: format,
                sampleTiming: &timing, sampleBufferOut: &sample) == noErr, let sample else { recoverMissingOutput(flight); return }
        lock.lock()
        let newer = generation == token && !failed && backlog.isCurrent(flight.ticket) && flight.sequence > latestOutputSequence
        if newer { latestOutputSequence = flight.sequence }
        lock.unlock()
        guard newer else { return }
        // Carry the permit captured with this ticket. Re-reading the current permit here would
        // let an old image cross an intervening backlog reset in the same generation.
        if canOutput(token) { onSample(sample, token, flight.outputPermit) }
        let ms = (ProcessInfo.processInfo.systemUptime - flight.started) * 1000
        queue.async { [self] in
            guard isCurrent(token) else { return }
            measurements.append(ms)
            if measurements.count == 120 {
                let sorted = measurements.sorted()
                let mode = hardware ? "Hardware" : "SIMULATOR TEST software"
                print(String(format: "\(mode) decode: 120 frames, mean %.2f ms, p95 %.2f ms, max %.2f ms, pts=\(pts.value)/\(pts.timescale)", measurements.reduce(0, +) / 120, sorted[113], sorted[119]))
                measurements.removeAll(keepingCapacity: true)
            }
        }
    }

    private func recoverMissingOutput(_ flight: Flight) {
        lock.lock()
        guard generation == flight.generation, !failed, backlog.isCurrent(flight.ticket), flight.sequence > latestOutputSequence else {
            lock.unlock(); return
        }
        let invalidated = resetBacklogLocked()
        let request = requestRecoveryLocked(now: ProcessInfo.processInfo.systemUptime)
        lock.unlock()
        if let invalidated { onOutputInvalidated(invalidated, flight.generation) }
        if let request { onNeedsKeyframe(request) }
    }

    /// Under `lock`. A request suppressed by the rate limit still needs a timer: if the desktop
    /// becomes static, there may be no later incoming frame to trigger another request.
    private func requestRecoveryLocked(now: TimeInterval) -> UInt64? {
        guard !failed, backlog.waitingForKeyframe else { return nil }
        let remaining = Self.recoverySpacing - (now - lastRecoveryRequest)
        if remaining <= 0 {
            cancelRecoveryTimerLocked()
            lastRecoveryRequest = now
            return generation
        }
        if recoveryTimer == nil {
            recoveryTimerID &+= 1
            let token = generation, timerID = recoveryTimerID
            let work = DispatchWorkItem { [weak self] in self?.retryRecovery(token: token, timerID: timerID) }
            recoveryTimer = work
            recoveryQueue.asyncAfter(deadline: .now() + remaining, execute: work)
        }
        return nil
    }

    private func cancelRecoveryTimerLocked() {
        recoveryTimer?.cancel(); recoveryTimer = nil; recoveryTimerID &+= 1
    }

    private func retryRecovery(token: UInt64, timerID: UInt64) {
        lock.lock()
        guard generation == token, recoveryTimerID == timerID else { lock.unlock(); return }
        recoveryTimer = nil
        let request = requestRecoveryLocked(now: ProcessInfo.processInfo.systemUptime)
        lock.unlock()
        if let request { onNeedsKeyframe(request) }
    }
}
