// Copyright 2026 DUO你电脑 contributors. SPDX-License-Identifier: Apache-2.0
// Captures only this process's own AppKit window, using the system's current-process inventory.
// This is not a full-desktop, public-network, or real-device performance test.
import AppKit
import CoreMedia
import CoreVideo
import Darwin
import ScreenCaptureKit
import StreamProtocol

setbuf(stdout, nil)
let app = NSApplication.shared
app.setActivationPolicy(.regular)
if CommandLine.arguments.contains("--render-correlation") { setenv("DUODESK_RENDER_TRACE", "1", 1) }
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
    private var observations: [(time: Double, info: WindowCapture.SampleObservation, arrival: UInt64, marker: Int?)] = []
    private var printedDirtyType = false
    #if DUO_RENDER_TRACE
    var phaseSampler: RenderPhaseSampler?
    private var phaseLockWait: [UInt64] = []
    #endif
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
        #if DUO_RENDER_TRACE
        let phase = phaseSampler?.inspect(image)
        #endif
        let accepted = lock.withLock {
            #if DUO_CAPTURE_DIAGNOSTICS
            let info = pendingObservation; pendingObservation = nil
            #endif
            guard time >= start, time < end else { return false }
            guard CVPixelBufferGetWidth(image) == 2008, CVPixelBufferGetHeight(image) == 1428 else {
                wrongSize += 1; return false
            }
            #if DUO_CAPTURE_DIAGNOSTICS
            if let info {
                #if DUO_RENDER_TRACE
                observations.append((time, info.info, info.arrival, phase?.sequence))
                if let phase { phaseLockWait.append(phase.lockWaitTicks) }
                #else
                observations.append((time, info.info, info.arrival, nil))
                #endif
            }
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

    #if DUO_RENDER_TRACE
    /// Marker and document-center differences are reported separately. A marker change cannot
    /// turn a stationary document into a counted changing document frame.
    func renderPhaseReport(_ draws: [(Int, UInt64)]) -> String {
        let snapshot = lock.withLock { (start, end, observations, phaseLockWait) }
        let positions = Dictionary(uniqueKeysWithValues: snapshot.2.enumerated().map { ($0.element.time, $0.offset) })
        let times = draws.map(\.1).sorted()
        func upperBound(_ value: UInt64) -> Int {
            var lower = 0, upper = times.count
            while lower < upper {
                let middle = (lower + upper) / 2
                if times[middle] <= value { lower = middle + 1 } else { upper = middle }
            }
            return lower
        }
        var stationarySame = 0, stationaryChanged = 0, motionSame = 0, motionChanged = 0, missing = 0
        var stationaryDraws = [Int](repeating: 0, count: 3), backward = 0, jumps = 0
        let known = Set(draws.map(\.0))
        var knownCurrent = 0, unknownCurrent = 0
        for comparison in audit.comparisonSnapshot() where comparison.time >= snapshot.0 + 2 && comparison.time < snapshot.1 {
            guard let i = positions[comparison.time], i > 0,
                  let previous = snapshot.2[i - 1].marker, let current = snapshot.2[i].marker else { missing += 1; continue }
            if current == 0 || known.contains(current) { knownCurrent += 1 } else { unknownCurrent += 1 }
            let changed = current != previous
            let documentMoved = comparison.center >= 0.12 && comparison.changedPixels >= 500
            if documentMoved {
                if changed { motionChanged += 1 } else { motionSame += 1 }
            } else if changed { stationaryChanged += 1 }
            else {
                stationarySame += 1
                if let a = snapshot.2[i - 1].info.displayTime, let b = snapshot.2[i].info.displayTime, b > a {
                    let count = upperBound(b) - upperBound(a)
                    stationaryDraws[min(count, 2)] += 1
                }
            }
            if changed {
                let difference = (current - previous + 4096) % 4096
                if difference > 2048 { backward += 1 } else if difference > 1 { jumps += 1 }
            }
        }
        var timebase = mach_timebase_info_data_t()
        let validTimebase = mach_timebase_info(&timebase) == KERN_SUCCESS && timebase.denom != 0
        let waits = validTimebase ? snapshot.3.map { Double($0) * Double(timebase.numer) / Double(timebase.denom) / 1_000_000 }.sorted() : []
        let p95 = waits.isEmpty ? -1 : waits[(waits.count * 95 + 99) / 100 - 1]
        let maximum = waits.last ?? -1
        return "RENDER PHASE CORRELATION: stationaryDocument_markerSame=\(stationarySame), stationaryDocument_markerChanged=\(stationaryChanged), movingDocument_markerSame=\(motionSame), movingDocument_markerChanged=\(motionChanged), markerMissing=\(missing), markerKnown=\(knownCurrent), markerUnknown=\(unknownCurrent), markerBackward=\(backward), markerJumps=\(jumps), sourceDraws=\(draws.count), stationarySame_drawsBetweenDisplayTimesZeroOneMultiple=\(stationaryDraws), markerLockWaitP95Ms=\(p95), markerLockWaitMaxMs=\(maximum); marker is diagnostic only, draw timestamps do not prove compositor presentation"
    }

    func compareDisplayFilter(_ other: DisplayFilterTrace) -> String {
        let snapshot = lock.withLock { (start, end, observations) }
        let secondary = other.snapshot()
        let valid = secondary.compactMap { entry -> (UInt64, Int)? in
            guard let time = entry.time, let marker = entry.marker else { return nil }
            return (time, marker)
        }.sorted { $0.0 < $1.0 }
        let byTime = Dictionary(valid, uniquingKeysWith: { _, last in last })
        let secondaryTimes = Set(secondary.compactMap(\.time))
        let positions = Dictionary(uniqueKeysWithValues: snapshot.2.enumerated().map { ($0.element.time, $0.offset) })
        var matched = 0, same = 0, windowNewer = 0, displayNewer = 0, incomparable = 0, missing = 0
        var stationarySame = 0, stationaryDifferent = 0, exactTimeWithoutMarker = 0
        var near: [Double] = [], nearSame = 0, nearDifferent = 0
        var timebase = mach_timebase_info_data_t()
        let validTimebase = mach_timebase_info(&timebase) == KERN_SUCCESS && timebase.denom != 0
        func closest(_ time: UInt64) -> (UInt64, Int)? {
            var lower = 0, upper = valid.count
            while lower < upper {
                let middle = (lower + upper) / 2
                if valid[middle].0 < time { lower = middle + 1 } else { upper = middle }
            }
            let candidates = [lower - 1, lower].filter { valid.indices.contains($0) }
            return candidates.map { valid[$0] }.min { a, b in
                let da = a.0 > time ? a.0 - time : time - a.0
                let db = b.0 > time ? b.0 - time : time - b.0
                return da < db
            }
        }
        for comparison in audit.comparisonSnapshot() where comparison.time >= snapshot.0 + 2 && comparison.time < snapshot.1 {
            guard let i = positions[comparison.time], i > 0, let time = snapshot.2[i].info.displayTime,
                  let windowMarker = snapshot.2[i].marker else { missing += 1; continue }
            if secondaryTimes.contains(time) { exactTimeWithoutMarker += 1 }
            if validTimebase, let nearest = closest(time) {
                let ticks = nearest.0 > time ? nearest.0 - time : time - nearest.0
                let ms = Double(ticks) * Double(timebase.numer) / Double(timebase.denom) / 1_000_000
                near.append(ms)
                if ms <= 1 { if nearest.1 == windowMarker { nearSame += 1 } else { nearDifferent += 1 } }
            }
            guard let displayMarker = byTime[time] else { missing += 1; continue }
            matched += 1
            let difference = (displayMarker - windowMarker + 4096) % 4096
            if difference == 0 { same += 1 }
            else if difference < 2048 { displayNewer += 1 }
            else if difference > 2048 { windowNewer += 1 }
            else { incomparable += 1 }
            if comparison.center < 0.12 || comparison.changedPixels < 500 {
                if difference == 0 { stationarySame += 1 } else { stationaryDifferent += 1 }
            }
        }
        let distances = near.sorted()
        let p50 = distances.isEmpty ? -1 : distances[distances.count / 2]
        let p95 = distances.isEmpty ? -1 : distances[(distances.count * 95 + 99) / 100 - 1]
        return "DISPLAY FILTER CORRELATION: exactDisplayTimeMatches=\(matched), sameMarker=\(same), displayMarkerNewer=\(displayNewer), windowMarkerNewer=\(windowNewer), incomparable=\(incomparable), unmatched=\(missing), stationaryDocument_same=\(stationarySame), stationaryDocument_different=\(stationaryDifferent), secondarySamples=\(secondary.count), secondaryTimePresent=\(secondary.compactMap(\.time).count), secondaryMarkerValid=\(secondary.compactMap(\.marker).count), exactTimeIgnoringMarker=\(exactTimeWithoutMarker), nearestValidP50Ms=\(p50), nearestValidP95Ms=\(p95), within1msSame=\(nearSame), within1msDifferent=\(nearDifferent); near timestamps do not prove the same displayed refresh; simultaneous test may perturb timing"
    }

    func sequenceComparison(_ other: DisplayFilterTrace, draws: [(Int, UInt64)]) -> String {
        let snapshot = lock.withLock { (start, end, observations) }
        let active = snapshot.2.filter { $0.time >= snapshot.0 + 2 && $0.time < snapshot.1 }
        guard let first = active.first?.info.displayTime, let last = active.last?.info.displayTime else {
            return "RENDER SEQUENCE MATCH: valid=false, reason=missing-active-boundary"
        }
        var timebase = mach_timebase_info_data_t()
        guard mach_timebase_info(&timebase) == KERN_SUCCESS, timebase.numer != 0, timebase.denom != 0 else {
            return "RENDER SEQUENCE MATCH: valid=false, reason=missing-timebase"
        }
        let nsPerTick = Double(timebase.numer) / Double(timebase.denom)
        let padding = UInt64((100_000_000 / nsPerTick).rounded(.up))
        guard last > first, last - first > padding * 2 else {
            return "RENDER SEQUENCE MATCH: valid=false, reason=short-overlap"
        }
        let window = active.map { RenderSequenceCorrelation.Sample(displayTime: $0.info.displayTime,
                                                                     arrival: $0.arrival, marker: $0.marker) }
        let display = other.snapshot().map { RenderSequenceCorrelation.Sample(displayTime: $0.time,
                                                                               arrival: $0.arrival, marker: $0.marker) }
        return RenderSequenceCorrelation.compare(draws: draws, primary: window, secondary: display,
                                                 lower: first + padding, upper: last - padding,
                                                 nanosecondsPerTick: nsPerTick).description
    }
    #endif
    #endif
}

#if DUO_RENDER_TRACE && DUO_CAPTURE_DIAGNOSTICS
final class DisplayFilterTrace: @unchecked Sendable {
    struct Entry { let time: UInt64?; let arrival: UInt64; let marker: Int? }
    private let lock = NSLock()
    private let sampler: RenderPhaseSampler
    private var pending: (time: UInt64?, arrival: UInt64)?
    private var entries: [Entry] = []
    init(sampler: RenderPhaseSampler) { self.sampler = sampler }
    func observe(_ info: WindowCapture.SampleObservation) { lock.withLock { pending = (info.displayTime, mach_absolute_time()) } }
    func receive(_ image: CVPixelBuffer) {
        let marker = sampler.inspect(image).sequence
        lock.withLock {
            let observation = pending
            entries.append(Entry(time: observation?.time, arrival: observation?.arrival ?? 0, marker: marker))
            pending = nil
        }
    }
    func snapshot() -> [Entry] { lock.withLock { entries } }
}
#endif

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
    let flow = CommandLine.arguments.contains("--stage-counts") ? FlowStageCounts() : nil
    #if DUO_RENDER_TRACE
    var displayCapture: WindowCapture?
    var displayTrace: DisplayFilterTrace?
    #endif
    var encoder: HEVCEncoder?
    var decoder: HardwareHEVCDecoder?
    var loopback: LoopbackVideo?
    var temporaryDisplay: VirtualWindowDisplay?
    var scrollTimes: [UInt64] = []
    #if DUO_RENDER_TRACE
    var phaseDraws: [(Int, UInt64)] = []
    let renderCorrelation = CommandLine.arguments.contains("--render-correlation")
    let compareDisplay = CommandLine.arguments.contains("--compare-display-filter")
    if renderCorrelation { workload.onRenderPhaseDraw = { sequence, time in phaseDraws.append((sequence, time)) } }
    #endif
    if CommandLine.arguments.contains("--scroll-correlation") {
        workload.onScrollSample = { scrollTimes.append($0) }
    }
    var passed = false
    let initialGrant = CGPreflightScreenCaptureAccess()
    print("OWN WINDOW START: globalRecording=\(initialGrant); completeDesktop=false; no physical display mode writes")
    do {
        guard let window = workload.window else { throw PixelMotionAudit.Failure.unavailable }
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
        guard flow == nil || (!captureOnly && CommandLine.arguments.contains("--quic-loopback")) else {
            throw PixelMotionAudit.Failure.unavailable
        }
        guard !profileAuditLock || captureOnly else { throw PixelMotionAudit.Failure.unavailable }
        let captured = try Frames(profileAuditLock: profileAuditLock)
        #if DUO_RENDER_TRACE
        if renderCorrelation {
            guard diagnostic, captureOnly, virtualSecondary, let rect = workload.renderMarkerRectInWindow else {
                throw PixelMotionAudit.Failure.unavailable
            }
            captured.phaseSampler = RenderPhaseSampler(markerRect: rect, windowHeight: window.frame.height, scale: CGFloat(filter.pointPixelScale))
            print("RENDER PHASE MARKER: own diagnostic window, outside document center, rect=\(rect), scale=\(filter.pointPixelScale)")
            if compareDisplay {
                // This uses a display-style filter containing only our own window. It excludes
                // desktop, Dock and menu bar and never enumerates or captures another app.
                guard initialGrant,
                      let id = (window.screen?.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber)?.uint32Value,
                      let display = content.displays.first(where: { $0.displayID == id }) else { throw PixelMotionAudit.Failure.unavailable }
                let displayFilter = SCContentFilter(display: display, including: [owned])
                displayFilter.includeMenuBar = false
                guard displayFilter.includedWindows.count == 1, displayFilter.includedWindows.first?.windowID == owned.windowID,
                      !displayFilter.includeMenuBar else { throw PixelMotionAudit.Failure.unavailable }
                let crop = owned.frame.offsetBy(dx: -display.frame.minX, dy: -display.frame.minY)
                guard crop.width == 1004, crop.height == 714, crop.minX >= 0, crop.minY >= 0,
                      crop.maxX <= display.frame.width, crop.maxY <= display.frame.height else { throw PixelMotionAudit.Failure.unavailable }
                let trace = DisplayFilterTrace(sampler: RenderPhaseSampler(markerRect: rect, windowHeight: window.frame.height,
                                                                           scale: CGFloat(filter.pointPixelScale)))
                let second = WindowCapture()
                second.onSampleObservation = { trace.observe($0) }
                second.onFrame = { image, _ in trace.receive(image) }
                second.onStopped = { stop in captured.fail(stop.error.localizedDescription) }
                displayCapture = second; displayTrace = trace
                try await second.start(filter: displayFilter, width: 2008, height: 1428, fps: 120, showsCursor: false,
                                       sourceRect: crop, nativeCadence: true)
                print("DISPLAY FILTER COMPARISON: own window only, menuBar=false, crop=\(crop), no other applications")
            }
        } else if compareDisplay {
            throw PixelMotionAudit.Failure.unavailable
        }
        #endif
        var decoded: Frames?
        if !captureOnly {
            let frames = try Frames()
            let recovery = RecoveryBox()
            let received = HardwareHEVCDecoder(onFormat: { size, _ in
                if size != CGSize(width: 2008, height: 1428) { frames.fail("unexpected hardware-decoder dimensions") }
            }, onSample: { sample, _, _ in
                if let image = CMSampleBufferGetImageBuffer(sample) { flow?.record(.decode); frames.receive(image) }
            }, onFailure: { message, _ in frames.fail(message) }, onNeedsKeyframe: { _ in recovery.request() })
            received.require(DuoDesktopResolution(width: 2007, height: 1427))
            let compressor = try HEVCEncoder(width: 2008, height: 1428, fps: 120, bitrate: 80_000_000,
                                             prioritizeSpeed: true, software: false)
            if CommandLine.arguments.contains("--quic-loopback") {
                let receivedFrame: (@Sendable () -> Void)?
                if let flow { receivedFrame = { flow.record(.receive) } } else { receivedFrame = nil }
                let channel = try await LoopbackVideo.connect(decoder: received, encoder: compressor,
                                                              onFrameReceived: receivedFrame)
                recovery.set(channel)
                compressor.onEncoded = { bytes, keyframe, parameters in
                    flow?.record(.encode)
                    channel.sendEncoded(bytes, keyframe: keyframe, parameters: parameters)
                }
                loopback = channel
            } else {
                compressor.onEncoded = { bytes, keyframe, parameters in
                    flow?.record(.encode)
                    if let parameters { received.apply(parameters) }
                    received.enqueue(bytes, isKeyframe: keyframe)
                }
            }
            compressor.onHung = { frames.fail("hardware encoder stalled") }
            capture.onFrame = { image, pts in flow?.record(.capture); captured.receive(image); compressor.encode(image, pts: pts) }
            encoder = compressor; decoder = received; decoded = frames
        } else {
            capture.onFrame = { image, _ in flow?.record(.capture); captured.receive(image) }
            print("OWN WINDOW CAPTURE-ONLY DIAGNOSTIC: no encoder, decoder, network or desktop acceptance")
        }
        #if DUO_CAPTURE_DIAGNOSTICS
        capture.onSampleObservation = { info in captured.observe(info) }
        #endif
        capture.onStopped = { stop in captured.fail(stop.error.localizedDescription) }
        let resampled = CommandLine.arguments.contains("--resampled")
        guard !virtualSecondary || !resampled else { throw PixelMotionAudit.Failure.unavailable }
        let phaseRequested = CommandLine.arguments.contains("--phase-study")
        guard !phaseRequested || (diagnostic && captureOnly && resampled && !virtualSecondary) else {
            throw PixelMotionAudit.Failure.unavailable
        }
        let phaseStudy = phaseRequested ? try SamplePhaseStudy() : nil
        #if DUO_CAPTURE_DIAGNOSTICS
        if let phaseStudy {
            capture.onUnpacedSample = { image, pts, arrival in phaseStudy.inspect(image, pts: pts, arrived: arrival) }
            capture.onFrame = { image, pts in
                let now = CMClockGetTime(CMClockGetHostTimeClock())
                phaseStudy.emitted(pts: pts, at: now)
                captured.receive(image)
            }
        }
        #endif
        try await capture.start(filter: filter, width: 2008, height: 1428, fps: 120, showsCursor: false,
                                nativeCadence: virtualSecondary, resampleCadence: resampled)
        try await Task.sleep(for: .seconds(2))
        if CommandLine.arguments.contains("--request-keyframe"), loopback == nil { throw LoopbackVideo.Failure.configuration }
        // One second stationary, one second scrolling warmup, then a fixed active interval.
        #if DUO_RENDER_TRACE
        let duration = phaseRequested || renderCorrelation ? 7 : diagnostic ? 12 : 32
        #else
        let duration = phaseRequested ? 7 : diagnostic ? 12 : 32
        #endif
        let capturedStart = captured.begin(seconds: duration), decodedStart = decoded?.begin(seconds: duration)
        flow?.begin(at: capturedStart + 2, seconds: duration - 2)
        if let phaseStudy {
            let hostNow = CMTimeGetSeconds(CMClockGetTime(CMClockGetHostTimeClock()))
            let uptimeNow = ProcessInfo.processInfo.systemUptime
            phaseStudy.begin(at: capturedStart + hostNow - uptimeNow, seconds: duration)
        }
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
        #if DUO_RENDER_TRACE
        await displayCapture?.stop(); displayCapture?.onFrame = nil
        #endif
        try await Task.sleep(for: .milliseconds(250))
        let (samples, wrong) = captured.summary
        print("OWN WINDOW CAPTURE: samples=\(samples), wrongDimensions=\(wrong)")
        print(await captured.audit.report(from: capturedStart, seconds: duration))
        if let phaseStudy { print(await phaseStudy.report(fullPixelFPS: captured.audit.changedFramesPerSecond)) }
        if profileAuditLock { print(captured.audit.lockWaitReport()) }
        #if DUO_CAPTURE_DIAGNOSTICS
        print(captured.metadataReport())
        if CommandLine.arguments.contains("--scroll-correlation") { print(captured.scrollTimingReport(scrollTimes)) }
        #if DUO_RENDER_TRACE
        if renderCorrelation { print(captured.renderPhaseReport(phaseDraws)) }
        if let displayTrace {
            print(captured.compareDisplayFilter(displayTrace))
            print(captured.sequenceComparison(displayTrace, draws: phaseDraws))
        }
        #endif
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
        if let flow { print(flow.report()) }
        try captured.audit.validate(); try decoded?.audit.validate()
        passed = !diagnostic && !captureOnly && wrong == 0 && decoded?.summary.1 == 0
            && (captured.audit.changedFramesPerSecond ?? 0) >= 120 && (decoded?.audit.changedFramesPerSecond ?? 0) >= 120
        print("OWN WINDOW RESULT: target120=\(passed); diagnosticOnly=\(diagnostic); captureOnly=\(captureOnly); virtualSecondary=\(virtualSecondary); resampled=\(resampled); loopbackQUIC=\(loopback != nil); completeDesktop=false; publicNetwork=false; realDuo=false")
    } catch {
        print("OWN WINDOW CHECK FAILED: \(error)")
    }
    await capture.stop(); capture.onFrame = nil
    #if DUO_RENDER_TRACE
    await displayCapture?.stop(); displayCapture?.onFrame = nil
    #endif
    #if DUO_CAPTURE_DIAGNOSTICS
    capture.onUnpacedSample = nil
    #endif
    _ = encoder?.abandon(); loopback?.close(); decoder?.clear()
    workload.stopScrolling()
    workload.onScrollSample = nil
    #if DUO_RENDER_TRACE
    workload.onRenderPhaseDraw = nil
    #endif
    workload.window?.close()
    if let temporaryDisplay, !(await temporaryDisplay.cleanup()) { passed = false }
    ProcessInfo.processInfo.endActivity(activity)
    print("OWN WINDOW END: globalRecording=\(CGPreflightScreenCaptureAccess()); no screen capture or permission prompt was requested for another process")
    exit(passed ? 0 : 1)
}

MainActor.assumeIsolated { workload.onReady = { Task { @MainActor in await run() } } }
app.delegate = workload
app.run()
