// Copyright 2026 DUO你电脑 contributors. SPDX-License-Identifier: Apache-2.0
// Real SCK and hardware HEVC restart check on this process's generated document window only.
// The native desktop topology is simulated from read-only display metadata; no display is changed.
import AppKit
import CoreGraphics
import CoreMedia
import CoreVideo
import Foundation
import ScreenCaptureKit
import StreamProtocol

setbuf(stdout, nil)
setenv("DUODESK_WORKLOAD_OWN_TEXT", "1", 1)
let app = NSApplication.shared
app.setActivationPolicy(.regular)
let workload = MainActor.assumeIsolated { DocumentWorkload(frameSize: NSSize(width: 1004, height: 714), usesStdin: false) }
let activity = ProcessInfo.processInfo.beginActivity(options: [.userInitiatedAllowingIdleSystemSleep, .latencyCritical],
                                                     reason: "Own document sampling restart check")

private struct DisplayState: Equatable {
    let id: CGDirectDisplayID, main: CGDirectDisplayID, mirror: CGDirectDisplayID
    let mode: Int32, width: Int, height: Int, pixelWidth: Int, pixelHeight: Int
    let bounds: CGRect, refresh: Double
}

private func displayState() -> [DisplayState]? {
    var count: UInt32 = 0
    guard CGGetOnlineDisplayList(0, nil, &count) == .success, count > 0 else { return nil }
    var ids = [CGDirectDisplayID](repeating: 0, count: Int(count))
    guard CGGetOnlineDisplayList(count, &ids, &count) == .success else { return nil }
    let main = CGMainDisplayID()
    let states = ids.prefix(Int(count)).compactMap { id -> DisplayState? in
        guard let mode = CGDisplayCopyDisplayMode(id) else { return nil }
        return DisplayState(id: id, main: main, mirror: CGDisplayMirrorsDisplay(id), mode: mode.ioDisplayModeID,
                            width: mode.width, height: mode.height, pixelWidth: mode.pixelWidth,
                            pixelHeight: mode.pixelHeight, bounds: CGDisplayBounds(id), refresh: mode.refreshRate)
    }.sorted { $0.id < $1.id }
    return states.count == Int(count) ? states : nil
}

private enum CheckFailure: Error {
    case unexpectedRecordingGrant, missingDisplay, missingOwnWindow, wrongDimensions, noFrame, pipeline(String),
         badAudit, noChangedImages, changedDisplay, invalidReportPath
}

/// Every audited CMSampleBuffer is retained until its GPU comparison completes.
/// The audit counts meaningful luma changes in the document center, not callback repetitions.
private final class FrameCounter: @unchecked Sendable {
    let audit: DesktopContentAudit
    private let lock = NSLock()
    private var interval: (Double, Double)?
    private var total = 0, measured = 0, wrong = 0
    private var error: String?
    init() throws { audit = try DesktopContentAudit(activeOffsetSeconds: 1) }
    func begin(at start: Double, seconds: Int) { lock.withLock { interval = (start, start + Double(seconds)) } }
    func receive(_ sample: CMSampleBuffer) {
        let now = ProcessInfo.processInfo.systemUptime
        guard let image = CMSampleBufferGetImageBuffer(sample) else { fail("sample has no image"); return }
        let accepted = lock.withLock { () -> Bool in
            total += 1
            guard CVPixelBufferGetWidth(image) == 2008, CVPixelBufferGetHeight(image) == 1428 else {
                wrong += 1; return false
            }
            guard let interval, now >= interval.0, now < interval.1 else { return false }
            measured += 1; return true
        }
        if accepted { audit.inspect(sample, at: now) }
    }
    func fail(_ text: String) { lock.withLock { if error == nil { error = text } } }
    var state: (total: Int, measured: Int, wrong: Int, error: String?) {
        lock.withLock { (total, measured, wrong, error) }
    }
    func result(from start: Double, seconds: Int) async throws -> [String: Any] {
        // report drains pending GPU work; its stationary-baseline validation is not used here,
        // because scrolling intentionally continues through each restart.
        _ = await audit.report(from: start, seconds: seconds)
        let health = audit.diagnosticHealth()
        let comparisons = audit.comparisonSnapshot().filter { $0.time >= start && $0.time < start + Double(seconds) }
        let changed = comparisons.filter { $0.full >= 0.01 && $0.center >= 0.12 && $0.changedPixels >= 500 }.count
        let snapshot = state
        guard snapshot.error == nil, snapshot.wrong == 0 else { throw CheckFailure.pipeline(snapshot.error ?? "wrong frame dimensions") }
        guard health.failed == 0, health.dropped == 0, health.waiting == 0, health.reused == 0 else { throw CheckFailure.badAudit }
        guard changed > 5 else { throw CheckFailure.noChangedImages }
        return ["framesReceived": snapshot.measured, "comparisonPairs": comparisons.count,
                "meaningfullyChanged": changed, "changedPerSecond": Double(changed) / Double(seconds),
                "auditSubmitted": health.submitted, "auditFailed": health.failed, "auditDropped": health.dropped,
                "auditReusedHeldSurfaces": health.reused]
    }
}

private final class WeakEncoder: @unchecked Sendable { weak var value: HEVCEncoder? }

private final class HardwarePhase: @unchecked Sendable {
    let captureFrames: FrameCounter
    let decodedFrames: FrameCounter
    let decoder: HardwareHEVCDecoder
    private var encoder: HEVCEncoder?

    init(fps: Int) throws {
        let captured = try FrameCounter(), decoded = try FrameCounter(), weakEncoder = WeakEncoder()
        captureFrames = captured; decodedFrames = decoded
        decoder = HardwareHEVCDecoder(onFormat: { size, _ in
            if size != CGSize(width: 2008, height: 1428) { decoded.fail("unexpected hardware decoder dimensions") }
        }, onSample: { sample, _, _ in
            decoded.receive(sample)
        }, onFailure: { message, _ in decoded.fail(message) }, onNeedsKeyframe: { _ in weakEncoder.value?.requestKeyframe() })
        decoder.require(DuoDesktopResolution(width: 2007, height: 1427))
        let compressor = try HEVCEncoder(width: 2008, height: 1428, fps: fps, bitrate: 15_000_000 * fps / 60,
                                         prioritizeSpeed: true, software: false)
        let receiver = decoder
        compressor.onEncoded = { data, keyframe, parameters in
            if let parameters { receiver.apply(parameters) }
            receiver.enqueue(data, isKeyframe: keyframe)
        }
        compressor.onHung = { captured.fail("hardware encoder stalled") }
        encoder = compressor; weakEncoder.value = compressor
    }
    func receive(_ image: CVPixelBuffer, pts: CMTime) {
        encoder?.encode(image, pts: pts)
    }
    func releaseEncoder() { encoder = nil }
}

@MainActor private func run() async {
    let capture = WindowCapture()
    let before = displayState()
    var valid = false, details: [[String: Any]] = []
    var failure: String?
    var phase: HardwarePhase?
    let arguments = CommandLine.arguments
    let reportPath = arguments.count == 3 && arguments[1] == "--report" ? arguments[2] : ""
    let reportURL = URL(fileURLWithPath: reportPath)
    print("SAMPLING SWITCH START: globalRecording=\(CGPreflightScreenCaptureAccess()), own window only, no display writes")
    do {
        guard reportPath.hasPrefix("/"), !FileManager.default.fileExists(atPath: reportPath) else { throw CheckFailure.invalidReportPath }
        // This independent LaunchServices process must not inherit another application's grant.
        guard !CGPreflightScreenCaptureAccess() else { throw CheckFailure.unexpectedRecordingGrant }
        guard let before, !before.isEmpty else { throw CheckFailure.missingDisplay }
        guard let window = workload.window else { throw CheckFailure.missingOwnWindow }
        try await Task.sleep(for: .milliseconds(400))
        let content = try await SCShareableContent.currentProcess
        guard let own = content.windows.first(where: {
            $0.windowID == UInt32(window.windowNumber) && $0.owningApplication?.processID == getpid()
        }) else { throw CheckFailure.missingOwnWindow }
        let filter = SCContentFilter(desktopIndependentWindow: own)
        guard Int((filter.contentRect.width * CGFloat(filter.pointPixelScale)).rounded()) == 2008,
              Int((filter.contentRect.height * CGFloat(filter.pointPixelScale)).rounded()) == 1428 else { throw CheckFailure.wrongDimensions }
        let desktop = try DuoDesktopDisplay.readOnlySamplingFixtureForTesting()
        guard let resolution = desktop.resolution, let sourceClock = desktop.currentSamplingCeiling else { throw CheckFailure.missingDisplay }
        let initialID = try await desktop.prepareGraphics(resolution, fps: 120)
        workload.startScrolling()
        for wanted in [120, 60, 120] {
            let target = StreamSamplingPolicy.target(maximum: 120, highestRequested: wanted,
                                                     softwareEncoder: false, sourceClockCeiling: sourceClock)
            guard try await desktop.prepareGraphics(resolution, fps: target) == initialID else { throw CheckFailure.changedDisplay }
            let current = try HardwarePhase(fps: target)
            phase = current
            capture.onDeliveredSample = { [current] sample in current.captureFrames.receive(sample) }
            capture.onFrame = { [current] image, pts in current.receive(image, pts: pts) }
            capture.onStopped = { [current] stop in current.captureFrames.fail(stop.error.localizedDescription) }
            let switchStart = ProcessInfo.processInfo.systemUptime
            try await capture.start(filter: filter, width: 2008, height: 1428, fps: target, showsCursor: false,
                                    nativeCadence: desktop.followsNativeCadence, resampleCadence: desktop.needsCadenceResampling)
            let deadline = switchStart + 3
            while current.decodedFrames.state.total == 0 && ProcessInfo.processInfo.systemUptime < deadline {
                if let problem = current.decodedFrames.state.error ?? current.captureFrames.state.error { throw CheckFailure.pipeline(problem) }
                try await Task.sleep(for: .milliseconds(50))
            }
            guard current.decodedFrames.state.total > 0 else { throw CheckFailure.noFrame }
            let firstFrameMs = (ProcessInfo.processInfo.systemUptime - switchStart) * 1000
            try await Task.sleep(for: .milliseconds(400))
            let start = ProcessInfo.processInfo.systemUptime, seconds = 3
            current.captureFrames.begin(at: start, seconds: seconds)
            current.decodedFrames.begin(at: start, seconds: seconds)
            try await Task.sleep(for: .seconds(seconds))
            await capture.stop(); capture.onDeliveredSample = nil; capture.onFrame = nil; capture.onStopped = nil
            current.releaseEncoder()
            try await Task.sleep(for: .milliseconds(150))
            let captured = try await current.captureFrames.result(from: start, seconds: seconds)
            let decoded = try await current.decodedFrames.result(from: start, seconds: seconds)
            current.decoder.clear()
            let record: [String: Any] = ["requestedFPS": wanted, "samplingTarget": target, "sourceClockHz": sourceClock,
                                         "firstDecodedWithinPollingMs": firstFrameMs,
                                         "captured": captured, "hardwareDecoded": decoded]
            details.append(record)
            print("SAMPLING PHASE: \(record)")
            phase = nil
        }
        guard before == displayState() else { throw CheckFailure.changedDisplay }
        valid = true
    } catch { failure = String(describing: error); print("SAMPLING SWITCH FAILED: \(error)") }
    await capture.stop(); capture.onDeliveredSample = nil; capture.onFrame = nil; capture.onStopped = nil
    phase?.releaseEncoder(); phase?.decoder.clear()
    workload.stopScrolling(); workload.window?.close()
    let unchanged = before != nil && before == displayState()
    let report: [String: Any] = ["valid": valid && unchanged, "displayStateUnchanged": unchanged,
                                 "phases": details, "failure": failure ?? "", "ownWindowOnly": true,
                                 "virtualTopologySimulated": true, "realDesktopAcceptance": false,
                                 "realDuoAcceptance": false, "publicNetworkAcceptance": false]
    if !reportPath.isEmpty, !FileManager.default.fileExists(atPath: reportPath),
       let bytes = try? JSONSerialization.data(withJSONObject: report, options: [.prettyPrinted, .sortedKeys]) {
        do { try bytes.write(to: reportURL, options: .atomic) } catch { print("REPORT WRITE FAILED: \(error)"); valid = false }
    } else { valid = false }
    ProcessInfo.processInfo.endActivity(activity)
    print("SAMPLING SWITCH END: valid=\(valid && unchanged), displayUnchanged=\(unchanged), ownWindowOnly=true, actualDesktopAcceptance=false")
    exit(valid && unchanged ? 0 : 1)
}

MainActor.assumeIsolated { workload.onReady = { Task { @MainActor in await run() } } }
app.delegate = workload
app.run()
