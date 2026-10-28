// Copyright 2026 DUO你电脑 contributors. SPDX-License-Identifier: Apache-2.0
// Diagnostic only: compares this fixture's captured samples in memory; never stores image pixels.
import CoreMedia
import CoreVideo
import Foundation
import IOSurface

final class FullFrameCaptureStudy: @unchecked Sendable {
    enum Phase: String, Sendable { case stationary, scrolling }
    private struct Sample: @unchecked Sendable {
        // Retain the sample, not only its borrowed image buffer, through the GPU completion.
        let buffer: CMSampleBuffer
        let image: CVPixelBuffer
        let surfaceID: UInt32
        let number: Int
        let phase: Phase
        let pts: Double
        let arrival: TimeInterval
    }
    private struct RawTime { let pts: Double, arrival: TimeInterval }
    private struct EqualOutput { let phase: Phase, pts: Double, arrival: TimeInterval }
    private struct Counts {
        var pairs = 0, equal = 0, lumaOnly = 0, chromaOnly = 0, both = 0
        var centerSameFullDifferent = 0, centerChanged = 0
        mutating func add(_ result: FramePlaneComparison.Result) {
            pairs += 1
            let y = result.changedLumaTiles > 0, uv = result.changedChromaTiles > 0
            if !y && !uv { equal += 1 }
            else if y && uv { both += 1 }
            else if y { lumaOnly += 1 }
            else { chromaOnly += 1 }
            if result.changedCenterSamples > 0 { centerChanged += 1 }
            else if y || uv { centerSameFullDifferent += 1 }
        }
        var line: String {
            "pairs=\(pairs), equalPlaneBytes=\(equal), lumaOnly=\(lumaOnly), chromaOnly=\(chromaOnly), both=\(both), centerChanged=\(centerChanged), centerSameFullDifferent=\(centerSameFullDifferent)"
        }
    }
    struct Report {
        let text: String
        let valid: Bool
    }
    private let comparison: FramePlaneComparison
    private let lock = NSLock()
    private var active = false, busy = false
    private var phase: Phase = .stationary
    private var previous: Sample?
    private var olderInFlightSurface: UInt32?
    private var probeAnchor: Sample?
    private var probeBusy = false
    private var delivered = 0, skippedBusy = 0, reusedHeldSurface = 0, failures = 0, gaps = 0, boundaryPairs = 0
    private var skippedForProbe = 0, probeMissedFirstRaw = 0, probeStarted = 0, probeChanged = 0, probeEqual = 0, probeUnfinished = 0
    private var raw: [RawTime] = [], equalOutputs: [EqualOutput] = []
    private var counts: [Phase: Counts] = [:]
    private var gpuMS: [Double] = [], completionMS: [Double] = [], probeLagsMS: [Double] = []

    init() throws { comparison = try FramePlaneComparison() }

    func begin() { lock.withLock { active = true } }
    func setPhase(_ phase: Phase) { lock.withLock { self.phase = phase } }
    func failed() { lock.withLock { failures += 1 } }

    /// Keep numeric timestamps for every raw callback. Only after an exact duplicate was
    /// observed, temporarily retain its next raw sample and compare it against that output.
    func observeRaw(_ buffer: CMSampleBuffer) {
        let pts = CMSampleBufferGetPresentationTimeStamp(buffer)
        let value = CMTimeGetSeconds(pts), arrival = ProcessInfo.processInfo.systemUptime
        lock.lock()
        guard active else { lock.unlock(); return }
        guard pts.isNumeric, value.isFinite, raw.count < 4096 else { failures += 1; lock.unlock(); return }
        raw.append(RawTime(pts: value, arrival: arrival))
        guard let anchor = probeAnchor, !busy, value > anchor.pts, arrival > anchor.arrival else { lock.unlock(); return }
        guard let image = CMSampleBufferGetImageBuffer(buffer),
              let surface = CVPixelBufferGetIOSurface(image)?.takeUnretainedValue() else {
            failures += 1; probeAnchor = nil; previous = nil; lock.unlock(); return
        }
        let id = IOSurfaceGetID(surface)
        guard id != anchor.surfaceID else {
            reusedHeldSurface += 1; probeAnchor = nil; previous = nil; lock.unlock(); return
        }
        let next = Sample(buffer: buffer, image: image, surfaceID: id, number: -1,
                          phase: anchor.phase, pts: value, arrival: arrival)
        probeAnchor = nil; previous = nil; busy = true; probeBusy = true
        olderInFlightSurface = anchor.surfaceID; probeStarted += 1
        probeLagsMS.append((arrival - anchor.arrival) * 1000)
        lock.unlock()
        Task.detached(priority: .userInitiated) { [self, anchor, next] in
            do {
                let result = try await comparison.compare(anchor.image, next.image)
                withExtendedLifetime((anchor.buffer, next.buffer)) { completedProbe(result) }
            } catch {
                withExtendedLifetime((anchor.buffer, next.buffer)) { completedFailure() }
            }
        }
    }

    /// One pending previous sample and one GPU comparison at most. Busy callbacks are skipped,
    /// not queued, so a stalled GPU cannot retain an unbounded number of ScreenCaptureKit frames.
    func observe(_ buffer: CMSampleBuffer) {
        guard let image = CMSampleBufferGetImageBuffer(buffer),
              CVPixelBufferGetWidth(image) == 2008, CVPixelBufferGetHeight(image) == 1428,
              let surface = CVPixelBufferGetIOSurface(image)?.takeUnretainedValue() else { failed(); return }
        let time = CMSampleBufferGetPresentationTimeStamp(buffer)
        let pts = CMTimeGetSeconds(time)
        guard time.isNumeric, pts.isFinite else { failed(); return }
        let id = IOSurfaceGetID(surface)
        let arrival = ProcessInfo.processInfo.systemUptime
        lock.lock()
        guard active else { lock.unlock(); return }
        delivered += 1
        let current = Sample(buffer: buffer, image: image, surfaceID: id, number: delivered, phase: phase, pts: pts, arrival: arrival)
        if probeAnchor != nil || probeBusy { skippedForProbe += 1; lock.unlock(); return }
        if id == previous?.surfaceID || id == olderInFlightSurface {
            // Ambiguous ownership/reuse: never compare a surface against itself or infer equality.
            reusedHeldSurface += 1; lock.unlock(); return
        }
        if busy { skippedBusy += 1; lock.unlock(); return }
        guard let older = previous else { previous = current; lock.unlock(); return }
        previous = current; busy = true; olderInFlightSurface = older.surfaceID
        lock.unlock()
        Task.detached(priority: .userInitiated) { [self, older, current] in
            do {
                let result = try await comparison.compare(older.image, current.image)
                // Both CMSampleBuffers must outlive the GPU read, even if the caller stops.
                withExtendedLifetime((older.buffer, current.buffer)) {
                    completed(older, current, result: result)
                }
            } catch {
                withExtendedLifetime((older.buffer, current.buffer)) { completedFailure() }
            }
        }
    }

    private func completed(_ older: Sample, _ current: Sample, result: FramePlaneComparison.Result) {
        let elapsed = (ProcessInfo.processInfo.systemUptime - current.arrival) * 1000
        lock.withLock {
            busy = false; olderInFlightSurface = nil
            if result.samePlaneBytes && result.changedCenterSamples != 0 { failures += 1 }
            if older.number + 1 != current.number { gaps += 1 }
            else if older.phase != current.phase { boundaryPairs += 1 }
            else {
                counts[current.phase, default: Counts()].add(result)
                if result.samePlaneBytes {
                    equalOutputs.append(EqualOutput(phase: current.phase, pts: current.pts, arrival: current.arrival))
                    if current.phase == .scrolling, active {
                        if raw.contains(where: { $0.pts > current.pts && $0.arrival > current.arrival }) {
                            // The first next sample arrived while the GPU was still comparing.
                            probeMissedFirstRaw += 1
                        } else { probeAnchor = current }
                    }
                }
            }
            if let gpu = result.gpuSeconds { gpuMS.append(gpu * 1000) }
            if elapsed.isFinite && elapsed >= 0 { completionMS.append(elapsed) }
        }
    }

    private func completedProbe(_ result: FramePlaneComparison.Result) {
        lock.withLock {
            busy = false; probeBusy = false; olderInFlightSurface = nil
            if result.samePlaneBytes { probeEqual += 1 } else { probeChanged += 1 }
        }
    }

    private func completedFailure() { lock.withLock { busy = false; probeBusy = false; olderInFlightSurface = nil; failures += 1 } }

    func finish() async -> Report {
        lock.withLock {
            active = false; previous = nil
            if probeAnchor != nil { probeUnfinished += 1; probeAnchor = nil }
        }
        let deadline = ContinuousClock.now + .seconds(3)
        while lock.withLock({ busy }), ContinuousClock.now < deadline {
            try? await Task.sleep(for: .milliseconds(10))
        }
        let data = lock.withLock {
            (busy, delivered, skippedBusy, reusedHeldSurface, failures, gaps, boundaryPairs,
             counts[.stationary] ?? Counts(), counts[.scrolling] ?? Counts(), gpuMS, completionMS, raw, equalOutputs,
             skippedForProbe, probeMissedFirstRaw, probeStarted, probeChanged, probeEqual, probeUnfinished, probeLagsMS)
        }
        func percentile(_ input: [Double], _ fraction: Double) -> Double? {
            let values = input.sorted()
            guard !values.isEmpty else { return nil }
            return values[min(values.count - 1, Int((Double(values.count) * fraction).rounded(.up)) - 1)]
        }
        let valid = !data.0 && data.1 > 0 && data.3 == 0 && data.4 == 0 && data.7.pairs > 0 && data.8.pairs > 0
        let rawOrdered = zip(data.11, data.11.dropFirst()).allSatisfy { $0.pts < $1.pts && $0.arrival <= $1.arrival }
        let rawPTS = Set(data.11.map(\.pts))
        let scrollingEqual = data.12.filter { $0.phase == .scrolling }
        let unmatched = scrollingEqual.filter { !rawPTS.contains($0.pts) }.count
        let newerBefore = scrollingEqual.filter { output in
            data.11.contains { $0.pts > output.pts && $0.arrival <= output.arrival }
        }.count
        let laterLags = scrollingEqual.compactMap { output in
            data.11.first { $0.pts > output.pts && $0.arrival > output.arrival }.map { ($0.arrival - output.arrival) * 1000 }
        }
        let result = "FULL PLANE OWN WINDOW: valid=\(valid), delivered=\(data.1), skippedBusy=\(data.2), heldSurfaceReuse=\(data.3), failures=\(data.4), nonAdjacentPairs=\(data.5), phaseBoundaryPairs=\(data.6); "
            + "stationary {\(data.7.line)}; scrolling {\(data.8.line)}; "
            + "gpuP50Ms=\(percentile(data.9, 0.5) ?? -1), gpuP95Ms=\(percentile(data.9, 0.95) ?? -1), "
            + "arrivalToComparisonP95Ms=\(percentile(data.10, 0.95) ?? -1); "
            + "rawTiming {count=\(data.11.count), ordered=\(rawOrdered), scrollingEqualOutputs=\(scrollingEqual.count), unmatchedPTS=\(unmatched), newerRawAlreadyArrived=\(newerBefore), laterRawCount=\(laterLags.count), laterRawLagP50Ms=\(percentile(laterLags, 0.5) ?? -1), laterRawLagP95Ms=\(percentile(laterLags, 0.95) ?? -1)}; "
            + "nextRawFullPlane {started=\(data.15), changed=\(data.16), equal=\(data.17), missedFirstRaw=\(data.14), unfinished=\(data.18), skippedOutputs=\(data.13), lagP50Ms=\(percentile(data.19, 0.5) ?? -1), lagP95Ms=\(percentile(data.19, 0.95) ?? -1)}; "
            + "8-bit active Y and UV bytes only, no color metadata, no user pixels saved, not desktop FPS"
        return Report(text: result, valid: valid)
    }
}
