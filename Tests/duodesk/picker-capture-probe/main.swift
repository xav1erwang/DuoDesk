// Copyright 2026 DUO你电脑 contributors. SPDX-License-Identifier: Apache-2.0
// Runs the production sampler with the system-selected filter, without a global TCC request.
import AppKit
import CoreMedia
import CoreVideo
import ScreenCaptureKit
import StreamProtocol

setbuf(stdout, nil)
let app = NSApplication.shared
app.setActivationPolicy(.accessory)
let window = NSWindow(contentRect: NSRect(x: 100, y: 100, width: 440, height: 140),
                      styleMask: [.titled], backing: .buffered, defer: false)
window.title = "DUO 桌面采样"
window.contentView = NSTextField(wrappingLabelWithString: "正在使用 macOS 屏幕共享选择器。采集只在本机运行，结束后自动恢复桌面。")
window.center()
let activity = ProcessInfo.processInfo.beginActivity(options: [.userInitiatedAllowingIdleSystemSleep, .latencyCritical],
                                                    reason: "Duo native desktop sampling")

func displaySnapshot() -> [[String: Double]] {
    var count: UInt32 = 0
    guard CGGetOnlineDisplayList(0, nil, &count) == .success else { return [] }
    var ids = [CGDirectDisplayID](repeating: 0, count: Int(count))
    guard CGGetOnlineDisplayList(count, &ids, &count) == .success else { return [] }
    return ids.sorted().compactMap { id in
        guard let mode = CGDisplayCopyDisplayMode(id) else { return nil }
        let bounds = CGDisplayBounds(id)
        return ["id": Double(id), "main": id == CGMainDisplayID() ? 1 : 0,
                "mode": Double(mode.ioDisplayModeID), "width": Double(mode.width), "height": Double(mode.height),
                "pixelWidth": Double(mode.pixelWidth), "pixelHeight": Double(mode.pixelHeight), "hz": mode.refreshRate,
                "x": bounds.origin.x, "y": bounds.origin.y, "boundsWidth": bounds.width, "boundsHeight": bounds.height,
                "mirror": Double(CGDisplayMirrorsDisplay(id))]
    }
}
func printSnapshot(_ name: String, _ value: [[String: Double]]) {
    if let json = try? JSONSerialization.data(withJSONObject: value, options: [.sortedKeys]),
       let string = String(data: json, encoding: .utf8) { print("\(name): \(string)") }
}
func verifyRestored(_ before: [[String: Double]]) async -> Bool {
    var after = displaySnapshot()
    for _ in 0..<30 {
        if after == before { break }
        try? await Task.sleep(for: .milliseconds(100))
        after = displaySnapshot()
    }
    printSnapshot("DISPLAY_AFTER", after)
    print("DISPLAY_EXACT_RESTORE: \(!before.isEmpty && after == before)")
    return !before.isEmpty && after == before
}

final class Frames: @unchecked Sendable {
    let audit: PixelMotionAudit?
    let onFrameID: (@Sendable (Int32, Double) -> Void)?
    private let lock = NSLock()
    private var start = Double.infinity, end = Double.infinity
    private var count = 0, badSize = 0
    private var seen = 0
    private var stopError: String?
    init(audit: PixelMotionAudit?, onFrameID: (@Sendable (Int32, Double) -> Void)? = nil) {
        self.audit = audit; self.onFrameID = onFrameID
    }
    func begin(seconds: Int) -> Double {
        lock.withLock {
            start = ProcessInfo.processInfo.systemUptime
            end = start + Double(seconds)
            return start
        }
    }
    func receive(_ image: CVPixelBuffer) {
        let now = ProcessInfo.processInfo.systemUptime
        let accepts = lock.withLock {
            seen += 1
            guard now >= start, now < end else { return false }
            guard CVPixelBufferGetWidth(image) == 2008, CVPixelBufferGetHeight(image) == 1428 else {
                badSize += 1; return false
            }
            count += 1
            return true
        }
        if accepts { audit?.inspect(image, at: now, onResult: onFrameID) }
    }
    var summary: (Int, Int) { lock.withLock { (count, badSize) } }
    var samplesSeen: Int { lock.withLock { seen } }
    func stopped(_ error: any Error) { lock.withLock { stopError = String(describing: error) } }
    func check() throws {
        if let error = lock.withLock({ stopError }) {
            throw NSError(domain: "DuoCaptureStopped", code: 1, userInfo: [NSLocalizedDescriptionKey: error])
        }
    }
}

/// Matches actual pixel IDs at capture/decode callbacks; excludes network, display and input.
final class CodecMotionLatency: @unchecked Sendable {
    private let lock = NSLock()
    private var captured: [Int32: Double] = [:]
    private var decoded: [Int32: Double] = [:]
    func capture(_ id: Int32, _ time: Double) {
        guard id >= 0 else { return }
        lock.withLock { if captured[id] == nil { captured[id] = time } }
    }
    func decode(_ id: Int32, _ time: Double) {
        guard id >= 0 else { return }
        lock.withLock { if decoded[id] == nil { decoded[id] = time } }
    }
    func report() -> String {
        lock.withLock {
            let values = captured.compactMap { id, began -> Double? in
                decoded[id].map { ($0 - began) * 1000 }
            }.sorted()
            guard !values.isEmpty else { return "CAPTURE_TO_DECODE_MS unavailable; matched=0" }
            return String(format: "CAPTURE_TO_DECODE_MS matched=%d mean=%.3f p50=%.3f p95=%.3f max=%.3f; network/display/input excluded",
                          values.count, values.reduce(0, +) / Double(values.count), values[values.count / 2],
                          values[Int(Double(values.count - 1) * 0.95)], values.last!)
        }
    }
}

@MainActor
func runCapture() async {
    window.makeKeyAndOrderFront(nil)
    app.activate()
    let desktop = DuoDesktopDisplay()
    let picker = DesktopCapturePicker()
    let capture = WindowCapture()
    var fixture: Process?
    var encoded: HEVCEncoder?
    var decoded: HardwareHEVCDecoder?
    let native = CommandLine.arguments.contains("--native")
    let before = displaySnapshot()
    printSnapshot("DISPLAY_BEFORE", before)
    do {
        guard !before.isEmpty else { throw DuoDesktopDisplay.Failure.noDisplay }
        let beforeIDs = NSScreen.screens.map { $0.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] ?? 0 }
        print("Desktop before preparation: main=\(CGMainDisplayID()), AppKit=\(beforeIDs), mainOnline=\(CGDisplayIsOnline(CGMainDisplayID()))")
        let id = native ? try await desktop.prepareGraphics(DuoDesktopResolution(width: 2007, height: 1427), fps: 120, deferMirror: true) : CGMainDisplayID()
        if native {
            // Control Center cancels a picker shown while WindowServer is still publishing a
            // changed display graph. Allow the graph to settle before presenting system UI.
            var stableSince: TimeInterval?
            let limit = ProcessInfo.processInfo.systemUptime + 5
            while ProcessInfo.processInfo.systemUptime < limit {
                let now = ProcessInfo.processInfo.systemUptime
                if let mode = CGDisplayCopyDisplayMode(id), mode.pixelWidth == 2008, mode.pixelHeight == 1428,
                   abs(mode.refreshRate - 120) < 0.5 {
                    if let stableSince, now - stableSince >= 0.6 { break }
                    if stableSince == nil { stableSince = now }
                } else { stableSince = nil }
                try await Task.sleep(for: .milliseconds(100))
            }
            let screenIDs = NSScreen.screens.map { $0.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] ?? 0 }
            print("AppKit displays after settling: \(screenIDs)")
        }
        print("PICKER READY pid=\(ProcessInfo.processInfo.processIdentifier), expectedDisplay=\(id), native=\(native), globalRecording=\(CGPreflightScreenCaptureAccess())")
        let filter = try await picker.selectDisplay()
        window.orderOut(nil)
        print("PICKER SELECTED ids=\(filter.includedDisplays.map(\.displayID)), rect=\(filter.contentRect), scale=\(filter.pointPixelScale)")
        guard filter.includedDisplays.first?.displayID == id else { throw DesktopCapturePicker.Failure.wrongContent }
        if native {
            try desktop.attachPreparedMirror()
            try await Task.sleep(for: .milliseconds(600))
        }
        if !native {
            // The initial smoke check only proves that a new identity can use the official picker.
            let frames = Frames(audit: nil)
            capture.onFrame = { image, _ in frames.receive(image) }
            _ = frames.begin(seconds: 2)
            try await capture.start(filter: filter, width: 2008, height: 1428, fps: 120, showsCursor: false)
            try await Task.sleep(for: .seconds(2))
            await capture.stop()
            guard frames.summary.0 > 0 else { throw PixelMotionAudit.Failure.invalidFrames }
            print("PICKER CAPTURE START/STOP PASS samples=\(frames.summary.0); performanceAcceptance=false; nativeGeometryAcceptance=false")
        } else {
            guard desktop.followsNativeCadence else { throw DuoDesktopDisplay.Failure.modeRejected }
            if let path = ProcessInfo.processInfo.environment["DUODESK_PICKER_FIXTURE"] {
                let process = Process()
                process.executableURL = URL(fileURLWithPath: path)
                var environment = ProcessInfo.processInfo.environment
                environment["DUODESK_FIXTURE_UNOBSCURED"] = "1"
                environment["DUODESK_FIXTURE_METAL"] = "1"
                environment["DUODESK_FIXTURE_METAL_LINK"] = "1"
                environment["DUODESK_FIXTURE_FRAME_CODE"] = "1"
                environment["DUODESK_FIXTURE_FPS"] = "120"
                process.environment = environment
                try process.run()
                fixture = process
            }
            let latency = CommandLine.arguments.contains("--hardware-codec") ? CodecMotionLatency() : nil
            let frames = Frames(audit: try PixelMotionAudit(), onFrameID: { id, time in latency?.capture(id, time) })
            var decodedFrames: Frames?
            if CommandLine.arguments.contains("--hardware-codec") {
                let received = Frames(audit: try PixelMotionAudit(), onFrameID: { id, time in latency?.decode(id, time) })
                let decoder = HardwareHEVCDecoder(onFormat: { size, _ in
                    if size != CGSize(width: 2008, height: 1428) {
                        received.stopped(DuoDesktopDisplay.Failure.invalidResolution)
                    }
                }, onSample: { sample, _ in
                    if let image = CMSampleBufferGetImageBuffer(sample) { received.receive(image) }
                }, onFailure: { message, _ in
                    received.stopped(NSError(domain: "DuoHardwareDecoder", code: 1,
                                             userInfo: [NSLocalizedDescriptionKey: message]))
                })
                decoder.require(DuoDesktopResolution(width: 2007, height: 1427))
                let encoder = try HEVCEncoder(width: 2008, height: 1428, fps: 120, bitrate: 80_000_000,
                                              prioritizeSpeed: true, software: false)
                encoder.onEncoded = { bytes, keyframe, parameters in
                    if let parameters { decoder.apply(parameters) }
                    decoder.enqueue(bytes, isKeyframe: keyframe)
                }
                encoder.onHung = { received.stopped(NSError(domain: "DuoHardwareEncoder", code: 1)) }
                capture.onFrame = { image, pts in frames.receive(image); encoder.encode(image, pts: pts) }
                encoded = encoder; decoded = decoder; decodedFrames = received
            } else {
                capture.onFrame = { image, _ in frames.receive(image) }
            }
            capture.onStopped = { stop in frames.stopped(stop.error); print("CAPTURE STOPPED unexpectedly: \(stop.error)") }
            try await capture.start(filter: filter, width: 2008, height: 1428, fps: 120, showsCursor: false,
                                    nativeCadence: desktop.followsNativeCadence)
            if CommandLine.arguments.contains("--restart") {
                try await Task.sleep(for: .seconds(2))
                try frames.check(); try decodedFrames?.check()
                guard frames.samplesSeen > 0, decodedFrames == nil || decodedFrames!.samplesSeen > 0 else {
                    throw PixelMotionAudit.Failure.invalidFrames
                }
                await capture.stop()
                let stoppedCount = frames.samplesSeen
                try await Task.sleep(for: .milliseconds(200))
                guard frames.samplesSeen == stoppedCount else { throw PixelMotionAudit.Failure.invalidFrames }
                try await capture.start(filter: filter, width: 2008, height: 1428, fps: 120, showsCursor: false,
                                        nativeCadence: desktop.followsNativeCadence)
                print("Actual ScreenCaptureKit stop/drain/restart completed; previousSamples=\(stoppedCount)")
            }
            try await Task.sleep(for: .seconds(3))
            try frames.check()
            let began = frames.begin(seconds: 30)
            let decodedBegan = decodedFrames?.begin(seconds: 30)
            for _ in 0..<60 {
                try await Task.sleep(for: .milliseconds(500))
                try frames.check()
                try decodedFrames?.check()
                guard desktop.followsNativeCadence else { throw DuoDesktopDisplay.Failure.modeRejected }
            }
            await capture.stop()
            capture.onFrame = nil
            let (count, badSize) = frames.summary
            var accepted = badSize == 0 && count > 0
            print("NATIVE SAMPLES: count=\(count), fps=\(Double(count) / 30), wrongDimensions=\(badSize)")
            if let audit = frames.audit {
                print(await audit.report(from: began, seconds: 30))
                do { try audit.validate() } catch { accepted = false }
                accepted = accepted && (audit.changedFramesPerSecond ?? 0) >= 119.5
            }
            if let received = decodedFrames, let audit = received.audit, let decodedBegan {
                let (decodedCount, badDecodedSize) = received.summary
                print("HARDWARE DECODED: count=\(decodedCount), fps=\(Double(decodedCount) / 30), wrongDimensions=\(badDecodedSize)")
                print(await audit.report(from: decodedBegan, seconds: 30))
                do { try audit.validate() } catch { accepted = false }
                accepted = accepted && badDecodedSize == 0 && (audit.changedFramesPerSecond ?? 0) >= 119.5
            }
            _ = encoded?.abandon()
            decoded?.clear()
            if let latency { print(latency.report()) }
            guard accepted else { throw PixelMotionAudit.Failure.invalidFrames }
            print("CAPTURE SAMPLING CHECK FINISHED; inProcessHardwareCodec=\(decodedFrames != nil); networkAcceptance=false; realDuoAcceptance=false")
        }
    } catch {
        await capture.stop()
        capture.onFrame = nil
        _ = encoded?.abandon()
        encoded = nil
        decoded?.clear()
        decoded = nil
        print("PICKER CAPTURE FAILED: \(error)")
        picker.end()
        if let fixture, fixture.isRunning { fixture.terminate() }
        print("Desktop restored after failure: \(desktop.restore())")
        _ = await verifyRestored(before)
        exit(1)
    }
    if let fixture, fixture.isRunning { fixture.terminate() }
    picker.end()
    let restored = desktop.restore()
    print("Desktop restore submitted: \(restored)")
    let exactRestore = await verifyRestored(before)
    ProcessInfo.processInfo.endActivity(activity)
    guard restored, exactRestore else { exit(1) }
    app.terminate(nil)
}
@MainActor
final class CaptureApplicationDelegate: NSObject, NSApplicationDelegate {
    func applicationDidFinishLaunching(_ notification: Notification) {
        Task { @MainActor in await runCapture() }
    }
}
let applicationDelegate = MainActor.assumeIsolated { CaptureApplicationDelegate() }
app.delegate = applicationDelegate
app.run()
