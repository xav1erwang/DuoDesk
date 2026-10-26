// Isolates native desktop capture from encoding, networking and catalog screenshots.
import AppKit
import CoreGraphics
import CoreMedia
import CoreVideo
import ScreenCaptureKit
import StreamProtocol

setbuf(stdout, nil)
final class Output: NSObject, SCStreamOutput, @unchecked Sendable {
    let lock = NSLock()
    let countOnly = CommandLine.arguments.contains("--count-only")
    let pixelAudit: PixelMotionAudit?
    var complete = 0, idle = 0, changed = 0
    var previous = -1
    var starts = Double.infinity, ends = Double.infinity
    var frameAges: [Double] = [], sourceIntervals: [Double] = []
    var lastDisplayTime: Double?
    var framesBySecond: [Int: Int] = [:]
    var printedMetadata = false
    init(pixelAudit: PixelMotionAudit?) {
        self.pixelAudit = pixelAudit
        super.init()
    }
    func begin(seconds: Double) {
        lock.withLock {
            starts = ProcessInfo.processInfo.systemUptime; ends = starts + seconds
        }
    }
    func timingReport() -> String {
        lock.withLock {
            func values(_ samples: [Double]) -> String {
                let sorted = samples.sorted()
                guard !sorted.isEmpty else { return "unavailable" }
                return String(format: "mean=%.2f,p50=%.2f,p95=%.2f,max=%.2f ms", sorted.reduce(0,+)/Double(sorted.count), sorted[sorted.count/2], sorted[Int(Double(sorted.count-1)*0.95)], sorted.last!)
            }
            return "display→callback {\(values(frameAges))}; source intervals {\(values(sourceIntervals))}"
        }
    }
    func stream(_ stream: SCStream, didOutputSampleBuffer sample: CMSampleBuffer, of type: SCStreamOutputType) {
        let now = ProcessInfo.processInfo.systemUptime
        lock.lock(); defer { lock.unlock() }
        guard now >= starts, now < ends else { return }
        guard let info = CMSampleBufferGetSampleAttachmentsArray(sample, createIfNecessary: false) as? [[SCStreamFrameInfo: Any]],
              let raw = info.first?[.status] as? Int else { return }
        if raw == SCFrameStatus.idle.rawValue { idle += 1; return }
        guard raw == SCFrameStatus.complete.rawValue, let image = CMSampleBufferGetImageBuffer(sample) else { return }
        if !printedMetadata {
            printedMetadata = true
            print("Capture image: \(CVPixelBufferGetWidth(image))×\(CVPixelBufferGetHeight(image)), contentRect=\(String(describing: info.first?[.contentRect])), contentScale=\(String(describing: info.first?[.contentScale])), scaleFactor=\(String(describing: info.first?[.scaleFactor]))")
        }
        complete += 1
        framesBySecond[Int(now - starts), default: 0] += 1
        pixelAudit?.inspect(image, at: now)
        if let time = info.first?[.displayTime] as? UInt64 {
            let seconds = CMClockMakeHostTimeFromSystemUnits(time).seconds
            let age = (now - seconds) * 1000
            // A native-rate stream can arrive before its scheduled display time. Preserve the
            // signed difference; it is not an end-to-end input latency measurement.
            if age.isFinite, abs(age) < 10_000 { frameAges.append(age) }
            if let lastDisplayTime, seconds > lastDisplayTime { sourceIntervals.append((seconds - lastDisplayTime) * 1000) }
            lastDisplayTime = seconds
        }
        // CPU mapping a captured IOSurface can itself synchronize the compositor. This mode
        // measures callback throughput without mapping pixels or involving an encoder.
        if countOnly || pixelAudit != nil { return }
        CVPixelBufferLockBaseAddress(image, .readOnly)
        defer { CVPixelBufferUnlockBaseAddress(image, .readOnly) }
        let width = CVPixelBufferGetWidth(image), height = CVPixelBufferGetHeight(image)
        let y = height / 5
        var position = -1
        if CVPixelBufferIsPlanar(image), let luma = CVPixelBufferGetBaseAddressOfPlane(image, 0),
           let uv = CVPixelBufferGetBaseAddressOfPlane(image, 1) {
            let row = y * CVPixelBufferGetBytesPerRowOfPlane(image, 0)
            let chromaRow = y / 2 * CVPixelBufferGetBytesPerRowOfPlane(image, 1)
            for x in 0..<width {
                let chroma = chromaRow + x / 2 * 2
                if luma.load(fromByteOffset: row + x, as: UInt8.self) > 100,
                   uv.load(fromByteOffset: chroma, as: UInt8.self) > 120,
                   uv.load(fromByteOffset: chroma + 1, as: UInt8.self) < 110 { position = x; break }
            }
        } else if let pixels = CVPixelBufferGetBaseAddress(image) {
            let row = y * CVPixelBufferGetBytesPerRow(image)
            for x in 0..<width {
                let p = row + x * 4
                let b = Int(pixels.load(fromByteOffset: p, as: UInt8.self))
                let g = Int(pixels.load(fromByteOffset: p + 1, as: UInt8.self))
                let r = Int(pixels.load(fromByteOffset: p + 2, as: UInt8.self))
                if g > r + 50 && b > r + 80 { position = x; break }
            }
        }
        if position >= 0, position != previous { changed += 1 }
        previous = position
    }
}
private final class ScreenshotRequest: @unchecked Sendable {
    private let lock = NSLock()
    private var finished = false
    func take() -> Bool { lock.withLock { if finished { return false }; finished = true; return true } }
}
private func boundedScreenshot(filter: SCContentFilter, configuration: SCStreamConfiguration) async throws -> CMSampleBuffer {
    try await withCheckedThrowingContinuation { continuation in
        let request = ScreenshotRequest()
        DispatchQueue.global(qos: .userInitiated).asyncAfter(deadline: .now() + 5) {
            if request.take() { continuation.resume(throwing: NSError(domain: "DuoScreenshotTimeout", code: 1)) }
        }
        SCScreenshotManager.captureSampleBuffer(contentFilter: filter, configuration: configuration) { sample, error in
            guard request.take() else { return }
            if let sample { continuation.resume(returning: sample) }
            else { continuation.resume(throwing: error ?? NSError(domain: "DuoScreenshotMissingImage", code: 1)) }
        }
    }
}
let app = NSApplication.shared
// Match the production menu app's activity guard even after hiding this probe's own window.
// A background CLI must not turn App Nap scheduling into an apparent capture-rate ceiling.
let captureActivity = ProcessInfo.processInfo.beginActivity(options: [.userInitiatedAllowingIdleSystemSleep, .latencyCritical],
                                                         reason: "Native desktop capture measurement")
app.setActivationPolicy(.accessory)
Task { @MainActor in
    let nativePrimary = CommandLine.arguments.contains("--native-primary")
    let session = DuoDesktopDisplay(layout: nativePrimary ? .nativePrimary : .mirrored)
    let shutdownSignals = [SIGTERM, SIGINT].map { number -> any DispatchSourceSignal in
        signal(number, SIG_IGN)
        let source = DispatchSource.makeSignalSource(signal: number, queue: .main)
        source.setEventHandler {
            Task { @MainActor in
                let restored = session.restore()
                print("Capture probe interrupted; display restore=\(restored)")
                exit(restored ? 130 : 1)
            }
        }
        source.resume()
        return source
    }
    defer { shutdownSignals.forEach { $0.cancel() } }
    let physical = CGMainDisplayID()
    let native = DuoDesktopResolution(width: 2007, height: 1427)
    let existing = NSWindow(contentRect: NSRect(x: 80, y: 80, width: 320, height: 200), styleMask: [.borderless], backing: .buffered, defer: false)
    existing.isReleasedWhenClosed = false; existing.backgroundColor = .systemBlue; existing.orderFrontRegardless()
    defer { existing.close() }
    do {
        guard CGPreflightScreenCaptureAccess() else { throw DuoDesktopDisplay.Failure.screenPermission }
        let prepared: DuoDesktopDisplay.Prepared
        if CommandLine.arguments.contains("--physical") {
            let content = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: true)
            guard let display = content.displays.first(where: { $0.displayID == physical }) else { throw DuoDesktopDisplay.Failure.noDisplay }
            prepared = .init(display: display, bounds: CGDisplayBounds(physical), mirrored: false)
            print("Physical-only diagnostic: no native mode change")
        } else {
            let desktopClock = CommandLine.arguments.contains("--desktop-hz240") ? 240 : 120
            prepared = try await session.prepare(native, fps: desktopClock)
        }
        if CommandLine.arguments.contains("--detach") {
            guard !nativePrimary else { throw DuoDesktopDisplay.Failure.invalidResolution }
            var config: CGDisplayConfigRef?
            guard CGBeginDisplayConfiguration(&config) == .success, let config else { throw DuoDesktopDisplay.Failure.modeRejected }
            CGConfigureDisplayMirrorOfDisplay(config, physical, kCGNullDirectDisplay)
            CGConfigureDisplayOrigin(config, physical, 1200, 0)
            CGConfigureDisplayOrigin(config, prepared.display.displayID, 0, 0)
            guard CGCompleteDisplayConfiguration(config, .forSession) == .success else { throw DuoDesktopDisplay.Failure.modeRejected }
            try await Task.sleep(for: .seconds(1))
            print("Detached primary=\(CGMainDisplayID()), native=\(prepared.display.displayID), existing NSWindow=\(existing.frame), native bounds=\(CGDisplayBounds(prepared.display.displayID))")
        }
        let content = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: true)
        print("Capture probe sources: \(content.displays.map { "\($0.displayID):\($0.width)×\($0.height)" })")
        if CommandLine.arguments.contains("--detach") || nativePrimary {
            let ownWindows = CGWindowListCopyWindowInfo([.optionOnScreenOnly, .excludeDesktopElements], kCGNullWindowID) as? [[String: Any]] ?? []
            guard let own = ownWindows.first(where: { ($0[kCGWindowNumber as String] as? NSNumber)?.intValue == existing.windowNumber }),
                  let rawBounds = own[kCGWindowBounds as String] as? [String: Any],
                  let bounds = CGRect(dictionaryRepresentation: rawBounds as CFDictionary) else {
                throw DuoDesktopDisplay.Failure.displayUnavailable
            }
            let overlap = bounds.intersection(CGDisplayBounds(prepared.display.displayID))
            let screenID = (existing.screen?.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber)?.uint32Value
            guard screenID == prepared.display.displayID, !overlap.isNull,
                  overlap.width * overlap.height >= bounds.width * bounds.height * 0.95 else {
                throw DuoDesktopDisplay.Failure.displayUnavailable
            }
            print("Desktop continuity: pre-existing owned window remains on native primary \(screenID ?? 0), bounds=\(bounds)")
        }
        let gpuVerify = CommandLine.arguments.contains("--gpu-verify") || CommandLine.arguments.contains("--gpu-frame-code")
        // The continuity fixture is no longer needed. Hide our own extra blue window so it
        // cannot contaminate the pixel audit of the independent performance fixture.
        if gpuVerify { existing.orderOut(nil) }
        var cases: [(String, SCDisplay, OSType, CMTime)] = [
            ("master NV12 120", prepared.display, kCVPixelFormatType_420YpCbCr8BiPlanarFullRange, CMTime(value: 1, timescale: 120)),
            ("master NV12 unthrottled", prepared.display, kCVPixelFormatType_420YpCbCr8BiPlanarFullRange, .zero),
            ("master BGRA 120", prepared.display, kCVPixelFormatType_32BGRA, CMTime(value: 1, timescale: 120))]
        if let slave = content.displays.first(where: { $0.displayID == physical }), slave.displayID != prepared.display.displayID {
            cases.append(("physical mirror NV12 120", slave, kCVPixelFormatType_420YpCbCr8BiPlanarFullRange, CMTime(value: 1, timescale: 120)))
        }
        if CommandLine.arguments.contains("--unthrottled") { cases = [cases[1]] }
        if CommandLine.arguments.contains("--quick") { cases = Array(cases.prefix(1)) }
        if CommandLine.arguments.contains("--screenshot-loop") { cases = Array(cases.prefix(1)) }
        var pipelineCases = cases.map { ($0.0, $0.1, $0.2, $0.3, 5, false) }
        if CommandLine.arguments.contains("--pipeline-matrix") {
            pipelineCases = [
                ("NV12 q5 inherited pool", prepared.display, kCVPixelFormatType_420YpCbCr8BiPlanarFullRange, CMTime(value: 1, timescale: 120), 5, false),
                ("NV12 q3 work-item pool", prepared.display, kCVPixelFormatType_420YpCbCr8BiPlanarFullRange, CMTime(value: 1, timescale: 120), 3, true),
                ("BGRA q3 work-item pool", prepared.display, kCVPixelFormatType_32BGRA, CMTime(value: 1, timescale: 120), 3, true),
                ("BGRA q8 unthrottled", prepared.display, kCVPixelFormatType_32BGRA, .zero, 8, true)]
        }
        for (label, display, format, interval, depth, drains) in pipelineCases {
            let warmupSeconds = CommandLine.arguments.contains("--steady") ? 5 : 2
            let measurementSeconds = CommandLine.arguments.contains("--steady") ? 30 : 10
            let audit = gpuVerify ? try PixelMotionAudit() : nil
            let output = Output(pixelAudit: audit), config = SCStreamConfiguration()
            config.width = native.encodedWidth; config.height = native.encodedHeight
            config.pixelFormat = format; config.minimumFrameInterval = interval; config.queueDepth = depth
            config.showsCursor = false; config.colorSpaceName = CGColorSpace.sRGB
            if CommandLine.arguments.contains("--capture-best") { config.captureResolution = .best }
            let filter = CommandLine.arguments.contains("--application-filter")
                ? SCContentFilter(display: display, excludingApplications: [], exceptingWindows: [])
                : SCContentFilter(display: display, excludingWindows: [])
            if CommandLine.arguments.contains("--screenshot-loop") {
                // Diagnostic comparison using the supported single-sample API. The production
                // stream stays unchanged. Count new GPU-verified images, never request completions.
                let starts = ProcessInfo.processInfo.systemUptime + Double(warmupSeconds)
                let ends = starts + Double(measurementSeconds)
                var captured = 0
                var costs: [Double] = []
                var next = ProcessInfo.processInfo.systemUptime
                var reportedFormat = false
                while ProcessInfo.processInfo.systemUptime < ends {
                    let requested = ProcessInfo.processInfo.systemUptime
                    let sample = try await boundedScreenshot(filter: filter, configuration: config)
                    let now = ProcessInfo.processInfo.systemUptime
                    guard let image = CMSampleBufferGetImageBuffer(sample),
                          native.accepts(width: CVPixelBufferGetWidth(image), height: CVPixelBufferGetHeight(image)) else {
                        throw DuoDesktopDisplay.Failure.modeRejected
                    }
                    if !reportedFormat {
                        print("SNAPSHOT FORMAT: \(CVPixelBufferGetPixelFormatType(image)), planar=\(CVPixelBufferIsPlanar(image))")
                        reportedFormat = true
                    }
                    if now >= starts, now < ends {
                        captured += 1; costs.append((now - requested) * 1000)
                        audit?.inspect(image, at: now)
                    }
                    next += 1.0 / 120
                    let wait = next - ProcessInfo.processInfo.systemUptime
                    if wait > 0 { try await Task.sleep(for: .seconds(wait)) }
                    else { next = ProcessInfo.processInfo.systemUptime }
                }
                costs.sort()
                print("SNAPSHOT LOOP: seconds=\(measurementSeconds), received=\(captured), fps=\(Double(captured)/Double(measurementSeconds)), requestMedianMs=\(costs.isEmpty ? -1 : costs[costs.count / 2])")
                if let audit {
                    print(await audit.report(from: starts, seconds: measurementSeconds))
                    try audit.validate()
                    guard (audit.changedFramesPerSecond ?? 0) >= 119.5 else {
                        throw NSError(domain: "DuoScreenshotCaptureBelow120", code: 1)
                    }
                }
                continue
            }
            let stream = SCStream(filter: filter, configuration: config, delegate: nil)
            try stream.addStreamOutput(output, type: .screen, sampleHandlerQueue: DispatchQueue(label: "duodesk.capture-probe", qos: .userInteractive, autoreleaseFrequency: drains ? .workItem : .inherit))
            try await stream.startCapture()
            // Let the display reconfiguration and test window settle before a fixed wall-time
            // measurement. A delayed main-actor wake-up must not change the denominator.
            try await Task.sleep(for: .seconds(warmupSeconds))
            output.begin(seconds: Double(measurementSeconds))
            print("CAPTURE WINDOW \(label): uptime \(output.lock.withLock { output.starts }) for \(measurementSeconds) seconds")
            try await Task.sleep(for: .seconds(measurementSeconds))
            try await stream.stopCapture()
            let counts = output.lock.withLock { (output.complete, output.idle, output.changed) }
            print("CAPTURE \(label): elapsed=\(measurementSeconds), complete=\(counts.0), idle=\(counts.1), changed=\(counts.2), completeFPS=\(Double(counts.0)/Double(measurementSeconds)), changedFPS=\(Double(counts.2)/Double(measurementSeconds))")
            print("CAPTURE SECONDS \(label): \(output.lock.withLock { (0..<measurementSeconds).map { output.framesBySecond[$0, default: 0] } })")
            print("CAPTURE TIMING \(label): \(output.timingReport())")
            if let audit = output.pixelAudit {
                print(await audit.report(from: output.lock.withLock { output.starts }, seconds: measurementSeconds))
                try audit.validate()
            }
        }
        guard session.restore() else { throw DuoDesktopDisplay.Failure.modeRejected }
        exit(0)
    } catch {
        _ = session.restore(); print("Capture probe FAILED: \(error)"); exit(1)
    }
}
app.run()
