// Copyright 2026 DUO你电脑 contributors. SPDX-License-Identifier: Apache-2.0
import Foundation
import CoreGraphics
import CoreMedia
import CoreVideo
import VideoToolbox
import StreamProtocol

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
    let onSample: (CMSampleBuffer, UInt64) -> Void
    let onFailure: (String, UInt64) -> Void
    let onNeedsKeyframe: (UInt64) -> Void
    private let queue = DispatchQueue(label: "duodesk.hardware-decoder", qos: .userInteractive)
    // Only this small admission/generation state crosses the network, UI and VT callback queues.
    private let lock = NSLock()
    private var generation: UInt64 = 0
    // A queued parameter-set operation belongs to the connection/resolution that admitted it.
    // It must not mint a new generation after clear() has already fenced that connection out.
    private var inputEpoch: UInt64 = 0
    private var required: DuoDesktopResolution?
    private var backlog = VideoDecodeBacklog()
    private var inFlight = 0
    // The remaining state belongs exclusively to queue.
    private var session: VTDecompressionSession?
    private var description: CMVideoFormatDescription?
    private var parameters: Data?
    private var sessionGeneration: UInt64 = 0
    private var waitingForKeyframe = true
    private var failed = false
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
        var completed = false // guarded by the decoder lock
        init(generation: UInt64, ticket: VideoDecodeBacklog.Ticket, sequence: Int64, started: TimeInterval) {
            self.generation = generation; self.ticket = ticket; self.sequence = sequence; self.started = started
        }
    }

    init(onFormat: @escaping (CGSize, UInt64) -> Void, onSample: @escaping (CMSampleBuffer, UInt64) -> Void,
         onFailure: @escaping (String, UInt64) -> Void, onNeedsKeyframe: @escaping (UInt64) -> Void = { _ in }) {
        self.onFormat = onFormat; self.onSample = onSample; self.onFailure = onFailure
        self.onNeedsKeyframe = onNeedsKeyframe
    }

    deinit {
        if let session { DispatchQueue.global(qos: .utility).async { VTDecompressionSessionInvalidate(session) } }
    }

    func isCurrent(_ value: UInt64) -> Bool {
        lock.lock(); defer { lock.unlock() }; return generation == value
    }

    private func advance(ifInputEpoch epoch: UInt64) -> UInt64? {
        lock.lock(); defer { lock.unlock() }
        guard inputEpoch == epoch else { return nil }
        generation &+= 1; inFlight = 0; latestOutputSequence = 0; lastRecoveryRequest = -.infinity
        cancelRecoveryTimerLocked()
        return generation
    }

    @discardableResult
    func require(_ value: DuoDesktopResolution?) -> UInt64 {
        lock.lock()
        guard required != value else { let token = generation; lock.unlock(); return token }
        required = value; inputEpoch &+= 1; generation &+= 1; inFlight = 0; backlog.reset()
        latestOutputSequence = 0; lastRecoveryRequest = -.infinity; cancelRecoveryTimerLocked()
        let token = generation
        queue.async { [self] in if isCurrent(token) { invalidate() } }
        lock.unlock()
        return token
    }

    @discardableResult
    func clear() -> UInt64 {
        lock.lock()
        inputEpoch &+= 1; generation &+= 1; inFlight = 0; backlog.reset()
        latestOutputSequence = 0; lastRecoveryRequest = -.infinity; cancelRecoveryTimerLocked()
        let token = generation
        queue.async { [self] in if isCurrent(token) { invalidate() } }
        lock.unlock()
        return token
    }

    private func invalidate() {
        if let session { VTDecompressionSessionInvalidate(session) }
        session = nil; description = nil; parameters = nil; failed = false
        waitingForKeyframe = true; frameIndex = 0; measurements = []
    }

    private func fail(_ status: OSStatus, generation: UInt64, reason: String = "VideoToolbox") {
        guard !failed, isCurrent(generation) else { return }
        failed = true
        lock.lock(); let pending = backlog.frames, active = inFlight; lock.unlock()
        print("HEVC decode failed: \(status), \(reason), queued=\(pending), inFlight=\(active), generation=\(generation)")
        onFailure("硬件解码不可用（\(status)），请重新连接。", generation)
    }

    func apply(_ ps: ParameterSets) {
        lock.lock()
        let epoch = inputEpoch
        queue.async { [self] in
            lock.lock(); let current = inputEpoch == epoch; lock.unlock()
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
        // Even an empty or oversized access unit is a gap in the reference chain. Let the
        // bounded admission state fence old work and request recovery instead of silently
        // returning before it can observe the discarded frame.
        let ticket = backlog.admit(bytes: data.count, keyframe: isKeyframe)
        guard let ticket else {
            let request = requestRecoveryLocked(now: ProcessInfo.processInfo.systemUptime)
            lock.unlock()
            if let request { print("Video backlog: waiting for a fresh keyframe"); onNeedsKeyframe(request) }
            return
        }
        if isKeyframe, recoveryTimer != nil { cancelRecoveryTimerLocked() }
        let epoch = inputEpoch
        queue.async { [self] in
            defer { lock.lock(); backlog.complete(ticket); lock.unlock() }
            lock.lock(); let current = inputEpoch == epoch && backlog.isCurrent(ticket); lock.unlock()
            guard current else { return }
            guard !failed, let session, let description, isCurrent(sessionGeneration) else { return }
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
            lock.lock(); let available = generation == token && inFlight < 32
            if available { inFlight += 1 }; lock.unlock()
            guard available else { fail(kVTVideoDecoderNotAvailableNowErr, generation: token, reason: "decoder callbacks stalled"); return }
            let started = ProcessInfo.processInfo.systemUptime
            let flight = Flight(generation: token, ticket: ticket, sequence: frameIndex, started: started)
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
            decoded(nil, status: status, flags: flags, flight: flight, pts: .invalid, onDecoderQueue: true)
        }
    }

    private func decoded(_ image: CVImageBuffer?, status: OSStatus, flags: VTDecodeInfoFlags, flight: Flight,
                         pts: CMTime, onDecoderQueue: Bool = false) {
        lock.lock()
        guard !flight.completed else { lock.unlock(); return }
        flight.completed = true
        let token = flight.generation
        guard generation == token else { lock.unlock(); return }
        inFlight -= 1
        let current = backlog.isCurrent(flight.ticket)
        lock.unlock()
        guard current else { return }
        guard status == noErr else {
            if onDecoderQueue { fail(status, generation: token) }
            else { queue.async { [self] in fail(status, generation: token) } }
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
        let newer = generation == token && backlog.isCurrent(flight.ticket) && flight.sequence > latestOutputSequence
        if newer { latestOutputSequence = flight.sequence }
        lock.unlock()
        guard newer else { return }
        // The presenter fences generations too. Call outside the state lock so a callback may
        // clear/disconnect without deadlocking, and a late old image can never replace a new one.
        if isCurrent(token) { onSample(sample, token) }
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
        guard generation == flight.generation, backlog.isCurrent(flight.ticket), flight.sequence > latestOutputSequence else {
            lock.unlock(); return
        }
        backlog.reset()
        let request = requestRecoveryLocked(now: ProcessInfo.processInfo.systemUptime)
        lock.unlock()
        if let request { onNeedsKeyframe(request) }
    }

    /// Under `lock`. A request suppressed by the rate limit still needs a timer: if the desktop
    /// becomes static, there may be no later incoming frame to trigger another request.
    private func requestRecoveryLocked(now: TimeInterval) -> UInt64? {
        guard backlog.waitingForKeyframe else { return nil }
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
