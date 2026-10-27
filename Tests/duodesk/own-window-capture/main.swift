// Copyright 2026 DUO你电脑 contributors. SPDX-License-Identifier: Apache-2.0
// Captures only this process's own AppKit window, using the system's current-process inventory.
// This is not a full-desktop, network, or real-device performance test.
import AppKit
import CoreMedia
import CoreVideo
import Darwin
import ScreenCaptureKit
import StreamProtocol

setbuf(stdout, nil)
let app = NSApplication.shared
app.setActivationPolicy(.regular)
let activity = ProcessInfo.processInfo.beginActivity(options: [.userInitiatedAllowingIdleSystemSleep, .latencyCritical],
                                                     reason: "Native document capture measurement")
let workload = MainActor.assumeIsolated { DocumentWorkload(frameSize: NSSize(width: 1004, height: 714), usesStdin: false) }

final class Frames: @unchecked Sendable {
    let audit: DesktopContentAudit
    private let lock = NSLock()
    private var start = Double.infinity, end = Double.infinity
    private var count = 0, wrongSize = 0
    private var failure: String?
    #if DUO_CAPTURE_DIAGNOSTICS
    private var pendingObservation: (info: WindowCapture.SampleObservation, arrival: UInt64)?
    private var observations: [(time: Double, info: WindowCapture.SampleObservation, arrival: UInt64)] = []
    private var printedDirtyType = false
    func observe(_ info: WindowCapture.SampleObservation) {
        lock.withLock {
            pendingObservation = (info, mach_absolute_time())
            if !printedDirtyType, let type = info.dirtyElementType {
                printedDirtyType = true
                print("SCK DIRTY RECT ELEMENT TYPE: \(type), center=\(String(describing: info.dirtyCenter))")
            }
        }
    }
    #endif
    init(profileAuditLock: Bool = false) throws {
        audit = try DesktopContentAudit(activeOffsetSeconds: 2, profileLockWait: profileAuditLock)
    }
    func begin(seconds: Int) -> Double {
        lock.withLock {
            start = ProcessInfo.processInfo.systemUptime; end = start + Double(seconds)
            return start
        }
    }
    func receive(_ image: CVPixelBuffer) {
        let time = ProcessInfo.processInfo.systemUptime
        let accepted = lock.withLock {
            #if DUO_CAPTURE_DIAGNOSTICS
            let info = pendingObservation; pendingObservation = nil
            #endif
            guard time >= start, time < end else { return false }
            guard CVPixelBufferGetWidth(image) == 2008, CVPixelBufferGetHeight(image) == 1428 else {
                wrongSize += 1; return false
            }
            #if DUO_CAPTURE_DIAGNOSTICS
            if let info { observations.append((time, info.info, info.arrival)) }
            #endif
            count += 1; return true
        }
        if accepted { audit.inspect(image, at: time, onResult: nil) }
    }
    func fail(_ message: String) { lock.withLock { failure = message } }
    func check() throws {
        if let failure = lock.withLock({ failure }) {
            throw NSError(domain: "DuoOwnWindowCapture", code: 1, userInfo: [NSLocalizedDescriptionKey: failure])
        }
    }
    var summary: (Int, Int) { lock.withLock { (count, wrongSize) } }

    #if DUO_CAPTURE_DIAGNOSTICS
    func metadataReport() -> String {
        struct Tally {
            var total = 0, sameDisplayTime = 0, changedDisplayTime = 0, unknownDisplayTime = 0
            var noDirtyRects = 0, hasDirtyRects = 0, unknownDirtyRects = 0
            var centerDirty = 0, centerClean = 0, centerUnknown = 0
            var sameSurface = 0, changedSurface = 0, unknownSurface = 0
            mutating func add(_ current: WindowCapture.SampleObservation, _ previous: WindowCapture.SampleObservation) {
                total += 1
                if let a = current.displayTime, let b = previous.displayTime {
                    if a == b { sameDisplayTime += 1 } else { changedDisplayTime += 1 }
                } else { unknownDisplayTime += 1 }
                if let count = current.dirtyRectCount {
                    if count == 0 { noDirtyRects += 1 } else { hasDirtyRects += 1 }
                } else { unknownDirtyRects += 1 }
                if let dirty = current.dirtyCenter {
                    if dirty { centerDirty += 1 } else { centerClean += 1 }
                } else { centerUnknown += 1 }
                if let a = current.surfaceID, let b = previous.surfaceID {
                    if a == b { sameSurface += 1 } else { changedSurface += 1 }
                } else { unknownSurface += 1 }
            }
            var description: String {
                "n=\(total),displaySame=\(sameDisplayTime),displayChanged=\(changedDisplayTime),displayUnknown=\(unknownDisplayTime),dirtyEmpty=\(noDirtyRects),dirtyPresent=\(hasDirtyRects),dirtyUnknown=\(unknownDirtyRects),centerDirty=\(centerDirty),centerClean=\(centerClean),centerUnknown=\(centerUnknown),surfaceSame=\(sameSurface),surfaceChanged=\(changedSurface),surfaceUnknown=\(unknownSurface)"
            }
        }
        let snapshot = lock.withLock { (start, end, observations) }
        let index = Dictionary(uniqueKeysWithValues: snapshot.2.enumerated().map { ($0.element.time, $0.offset) })
        var unchanged = Tally(), changed = Tally(), unmatched = 0
        for item in audit.comparisonSnapshot() where item.time >= snapshot.0 + 2 && item.time < snapshot.1 {
            guard let position = index[item.time], position > 0 else { unmatched += 1; continue }
            let current = snapshot.2[position].info, previous = snapshot.2[position - 1].info
            if item.full == 0 { unchanged.add(current, previous) } else { changed.add(current, previous) }
        }
        return "SCK METADATA CORRELATION: lumaDeltaBelowThree={\(unchanged.description)}; lumaDeltaPresent={\(changed.description)}; unmatched=\(unmatched)"
    }

    /// Compare completed scroll calls with WindowServer display timestamps; this does not
    /// establish which scroll produced a particular image or identify a single bottleneck.
    func scrollTimingReport(_ scrollTimes: [UInt64]) -> String {
        struct Tally {
            var zero = 0, one = 0, multiple = 0
            mutating func add(_ count: Int) {
                if count == 0 { zero += 1 } else if count == 1 { one += 1 } else { multiple += 1 }
            }
            var description: String { "zero=\(zero),one=\(one),multiple=\(multiple)" }
        }
        var timebase = mach_timebase_info_data_t()
        guard mach_timebase_info(&timebase) == KERN_SUCCESS, timebase.numer != 0, timebase.denom != 0 else {
            return "SCROLL TIMING: mach timebase unavailable"
        }
        let ticksPerNanosecond = Double(timebase.denom) / Double(timebase.numer)
        let offsets = [0.0, 8_333_333.0, 16_666_667.0].map { UInt64(($0 * ticksPerNanosecond).rounded()) }
        let sorted = scrollTimes.sorted()
        func upperBound(_ value: UInt64) -> Int {
            var lower = 0, upper = sorted.count
            while lower < upper {
                let middle = (lower + upper) / 2
                if sorted[middle] <= value { lower = middle + 1 } else { upper = middle }
            }
            return lower
        }
        let snapshot = lock.withLock { (start, end, observations) }
        let index = Dictionary(uniqueKeysWithValues: snapshot.2.enumerated().map { ($0.element.time, $0.offset) })
        var unchanged = [Tally](repeating: Tally(), count: offsets.count)
        var changed = [Tally](repeating: Tally(), count: offsets.count)
        var missing = 0, arrivalBeforeDisplay = 0
        var callbackLagMS: [Double] = []
        for item in audit.comparisonSnapshot() where item.time >= snapshot.0 + 2 && item.time < snapshot.1 {
            guard let position = index[item.time], position > 0,
                  let current = snapshot.2[position].info.displayTime,
                  let previous = snapshot.2[position - 1].info.displayTime,
                  current > previous, previous >= (offsets.last ?? 0) else { missing += 1; continue }
            let arrival = snapshot.2[position].arrival
            if arrival >= current {
                callbackLagMS.append(Double(arrival - current) / ticksPerNanosecond / 1_000_000)
            } else { arrivalBeforeDisplay += 1 }
            for (i, offset) in offsets.enumerated() {
                let count = upperBound(current - offset) - upperBound(previous - offset)
                if item.full == 0 { unchanged[i].add(count) } else { changed[i].add(count) }
            }
        }
        let lags = callbackLagMS.sorted()
        let p50 = lags.isEmpty ? 0 : lags[lags.count / 2]
        let p95 = lags.isEmpty ? 0 : lags[(lags.count * 95 + 99) / 100 - 1]
        return "SCROLL TIMING: sourceCalls=\(sorted.count), offsetsMs=[0,8.333,16.667], lumaBelowThree=\(unchanged.map(\.description)), lumaPresent=\(changed.map(\.description)), missing=\(missing), arrivalBeforeDisplay=\(arrivalBeforeDisplay), displayToCallbackMsP50=\(p50), p95=\(p95); interval counts only, not frame attribution"
    }
    #endif
}

final class RecoveryBox: @unchecked Sendable {
    private let lock = NSLock()
    private weak var channel: LoopbackVideo?
    func set(_ value: LoopbackVideo?) { lock.withLock { channel = value } }
    func request() { lock.withLock { channel }?.requestKeyframe() }
}

func currentProcessContent() async -> SCShareableContent? {
    final class Once: @unchecked Sendable {
        private let lock = NSLock(); private var done = false
        func first() -> Bool { lock.withLock { if done { return false }; done = true; return true } }
    }
    let once = Once()
    return await withCheckedContinuation { (continuation: CheckedContinuation<SCShareableContent?, Never>) in
        SCShareableContent.getCurrentProcessShareableContent { content, _ in
            if once.first() { continuation.resume(returning: content) }
        }
        DispatchQueue.global().asyncAfter(deadline: .now() + 3) {
            if once.first() { continuation.resume(returning: nil) }
        }
    }
}

@MainActor
func run() async {
    let capture = WindowCapture()
    var encoder: HEVCEncoder?
    var decoder: HardwareHEVCDecoder?
    var loopback: LoopbackVideo?
    var temporaryDisplay: VirtualWindowDisplay?
    var scrollTimes: [UInt64] = []
    if CommandLine.arguments.contains("--scroll-correlation") {
        workload.onScrollSample = { scrollTimes.append($0) }
    }
    var passed = false
    let initialGrant = CGPreflightScreenCaptureAccess()
    print("OWN WINDOW START: globalRecording=\(initialGrant); completeDesktop=false; no physical display mode writes")
    do {
        guard !initialGrant, let window = workload.window else { throw PixelMotionAudit.Failure.unavailable }
        try await Task.sleep(for: .milliseconds(400))
        if let requested = ProcessInfo.processInfo.environment["DUODESK_WORKLOAD_SCREEN_ID"].flatMap(UInt32.init) {
            let actual = (window.screen?.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber)?.uint32Value
            guard actual == requested else { throw PixelMotionAudit.Failure.unavailable }
        }
        let virtualSecondary = CommandLine.arguments.contains("--virtual-secondary")
        if virtualSecondary {
            let display = try VirtualWindowDisplay()
            temporaryDisplay = display
            try await display.prepare(window: window)
        }
        guard let content = await currentProcessContent(),
              let owned = content.windows.first(where: {
                  $0.windowID == UInt32(window.windowNumber) && $0.owningApplication?.processID == getpid()
              }) else { throw PixelMotionAudit.Failure.unavailable }
        let filter = SCContentFilter(desktopIndependentWindow: owned)
        let width = Int((filter.contentRect.width * CGFloat(filter.pointPixelScale)).rounded())
        let height = Int((filter.contentRect.height * CGFloat(filter.pointPixelScale)).rounded())
        print("OWN WINDOW FILTER: owner=\(owned.owningApplication?.processID ?? 0), ownPID=\(getpid()), frame=\(filter.contentRect), scale=\(filter.pointPixelScale), nativePixels=\(width)×\(height)")
        guard width == 2008, height == 1428 else { throw PixelMotionAudit.Failure.invalidFrames }
        let diagnostic = CommandLine.arguments.contains("--diagnose")
        let captureOnly = CommandLine.arguments.contains("--capture-only")
        let profileAuditLock = CommandLine.arguments.contains("--audit-lock-profile")
        guard !captureOnly || (diagnostic && !CommandLine.arguments.contains("--quic-loopback")
                               && !CommandLine.arguments.contains("--request-keyframe")) else {
            throw PixelMotionAudit.Failure.unavailable
        }
        guard !profileAuditLock || captureOnly else { throw PixelMotionAudit.Failure.unavailable }
        let captured = try Frames(profileAuditLock: profileAuditLock)
        var decoded: Frames?
        if !captureOnly {
            let frames = try Frames()
            let recovery = RecoveryBox()
            let received = HardwareHEVCDecoder(onFormat: { size, _ in
                if size != CGSize(width: 2008, height: 1428) { frames.fail("unexpected hardware-decoder dimensions") }
            }, onSample: { sample, _ in
                if let image = CMSampleBufferGetImageBuffer(sample) { frames.receive(image) }
            }, onFailure: { message, _ in frames.fail(message) }, onNeedsKeyframe: { _ in recovery.request() })
            received.require(DuoDesktopResolution(width: 2007, height: 1427))
            let compressor = try HEVCEncoder(width: 2008, height: 1428, fps: 120, bitrate: 80_000_000,
                                             prioritizeSpeed: true, software: false)
            if CommandLine.arguments.contains("--quic-loopback") {
                let channel = try await LoopbackVideo.connect(decoder: received, encoder: compressor)
                recovery.set(channel)
                compressor.onEncoded = { bytes, keyframe, parameters in
                    channel.sendEncoded(bytes, keyframe: keyframe, parameters: parameters)
                }
                loopback = channel
            } else {
                compressor.onEncoded = { bytes, keyframe, parameters in
                    if let parameters { received.apply(parameters) }
                    received.enqueue(bytes, isKeyframe: keyframe)
                }
            }
            compressor.onHung = { frames.fail("hardware encoder stalled") }
            capture.onFrame = { image, pts in captured.receive(image); compressor.encode(image, pts: pts) }
            encoder = compressor; decoder = received; decoded = frames
        } else {
            capture.onFrame = { image, _ in captured.receive(image) }
            print("OWN WINDOW CAPTURE-ONLY DIAGNOSTIC: no encoder, decoder, network or desktop acceptance")
        }
        #if DUO_CAPTURE_DIAGNOSTICS
        capture.onSampleObservation = { info in captured.observe(info) }
        #endif
        capture.onStopped = { stop in captured.fail(stop.error.localizedDescription) }
        let resampled = CommandLine.arguments.contains("--resampled")
        guard !virtualSecondary || !resampled else { throw PixelMotionAudit.Failure.unavailable }
        try await capture.start(filter: filter, width: 2008, height: 1428, fps: 120, showsCursor: false,
                                nativeCadence: virtualSecondary, resampleCadence: resampled)
        try await Task.sleep(for: .seconds(2))
        if CommandLine.arguments.contains("--request-keyframe"), loopback == nil { throw LoopbackVideo.Failure.configuration }
        // One second stationary, one second scrolling warmup, then a fixed active interval.
        let duration = diagnostic ? 12 : 32
        let capturedStart = captured.begin(seconds: duration), decodedStart = decoded?.begin(seconds: duration)
        var keyframeRequest: (before: Int, deadline: Double)?
        for step in 0..<(duration * 2) {
            try await Task.sleep(for: .milliseconds(500))
            if step == 1 { workload.startScrolling() }
            if step == 6, CommandLine.arguments.contains("--request-keyframe"), let loopback {
                keyframeRequest = (loopback.counters.keyframes, ProcessInfo.processInfo.systemUptime + 1.5)
                loopback.requestKeyframe()
                print("OWN LOOPBACK QUIC: requested a new keyframe")
            }
            if let request = keyframeRequest, ProcessInfo.processInfo.systemUptime >= request.deadline {
                guard let loopback, loopback.counters.keyframes > request.before else {
                    throw NSError(domain: "DuoLoopback", code: 4, userInfo: [NSLocalizedDescriptionKey: "keyframe recovery deadline exceeded"])
                }
                keyframeRequest = nil
                print("OWN LOOPBACK QUIC: requested keyframe received within 1.5 seconds")
            }
            try captured.check(); try decoded?.check()
            try loopback?.check()
            try temporaryDisplay?.checkOwnedWindow(window)
        }
        await capture.stop(); capture.onFrame = nil
        try await Task.sleep(for: .milliseconds(250))
        let (samples, wrong) = captured.summary
        print("OWN WINDOW CAPTURE: samples=\(samples), wrongDimensions=\(wrong)")
        print(await captured.audit.report(from: capturedStart, seconds: duration))
        if profileAuditLock { print(captured.audit.lockWaitReport()) }
        #if DUO_CAPTURE_DIAGNOSTICS
        print(captured.metadataReport())
        if CommandLine.arguments.contains("--scroll-correlation") { print(captured.scrollTimingReport(scrollTimes)) }
        #endif
        if let decoded, let decodedStart {
            let (outputs, badOutputs) = decoded.summary
            print("OWN WINDOW HARDWARE DECODE: outputs=\(outputs), wrongDimensions=\(badOutputs)")
            print(await decoded.audit.report(from: decodedStart, seconds: duration))
        }
        if let loopback {
            let counters = loopback.counters
            print("OWN LOOPBACK QUIC COUNTERS: frames=\(counters.frames), keyframes=\(counters.keyframes), parameterSets=\(counters.parameters), resets=\(counters.resets)")
            print(loopback.latencyReport)
            Stats.shared.dump()
        }
        try captured.audit.validate(); try decoded?.audit.validate()
        passed = !diagnostic && !captureOnly && wrong == 0 && decoded?.summary.1 == 0
            && (captured.audit.changedFramesPerSecond ?? 0) >= 120 && (decoded?.audit.changedFramesPerSecond ?? 0) >= 120
        print("OWN WINDOW RESULT: target120=\(passed); diagnosticOnly=\(diagnostic); captureOnly=\(captureOnly); virtualSecondary=\(virtualSecondary); resampled=\(resampled); loopbackQUIC=\(loopback != nil); completeDesktop=false; publicNetwork=false; realDuo=false")
    } catch {
        print("OWN WINDOW CHECK FAILED: \(error)")
    }
    await capture.stop(); capture.onFrame = nil
    _ = encoder?.abandon(); loopback?.close(); decoder?.clear()
    workload.stopScrolling()
    workload.onScrollSample = nil
    workload.window?.close()
    if let temporaryDisplay, !(await temporaryDisplay.cleanup()) { passed = false }
    ProcessInfo.processInfo.endActivity(activity)
    print("OWN WINDOW END: globalRecording=\(CGPreflightScreenCaptureAccess()); no screen capture or permission prompt was requested for another process")
    exit(passed ? 0 : 1)
}

MainActor.assumeIsolated { workload.onReady = { Task { @MainActor in await run() } } }
app.delegate = workload
app.run()
