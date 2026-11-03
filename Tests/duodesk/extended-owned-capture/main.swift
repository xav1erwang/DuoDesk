// Copyright 2026 DUO你电脑 contributors. SPDX-License-Identifier: Apache-2.0
// Uses the production extension geometry and capture/codec components with a window owned by
// this process only. This is not a complete-desktop, network, Duo, input or frame-rate test.
import AppKit
import CoreMedia
import CoreVideo
import ScreenCaptureKit
import StreamProtocol

struct ExistingDisplay: Equatable {
    let id: CGDirectDisplayID
    let mode: Int32
    let pixelWidth: Int
    let pixelHeight: Int
    let refresh: Double
    let bounds: CGRect
    let mirror: CGDirectDisplayID
    let main: Bool

    static func read(_ id: CGDirectDisplayID) -> ExistingDisplay? {
        guard CGDisplayIsOnline(id) > 0, let mode = CGDisplayCopyDisplayMode(id) else { return nil }
        return ExistingDisplay(id: id, mode: mode.ioDisplayModeID, pixelWidth: mode.pixelWidth,
                               pixelHeight: mode.pixelHeight, refresh: mode.refreshRate,
                               bounds: CGDisplayBounds(id), mirror: CGDisplayMirrorsDisplay(id),
                               main: CGMainDisplayID() == id)
    }
}

func existingDisplays() -> [ExistingDisplay]? {
    var count: UInt32 = 0
    guard CGGetOnlineDisplayList(0, nil, &count) == .success, count > 0 else { return nil }
    let expected = count
    var ids = [CGDirectDisplayID](repeating: 0, count: Int(expected))
    guard CGGetOnlineDisplayList(expected, &ids, &count) == .success, count == expected,
          !ids.contains(kCGNullDirectDisplay), Set(ids).count == ids.count else { return nil }
    let displays = ids.compactMap(ExistingDisplay.read).sorted { $0.id < $1.id }
    return displays.count == ids.count ? displays : nil
}

final class DisplayMonitor: @unchecked Sendable {
    private let lock = NSLock()
    private let baseline: [CGDirectDisplayID: ExistingDisplay]
    private var changed = false
    private var modeEvents = 0
    private var afterEvents = 0
    init(_ displays: [ExistingDisplay]) { baseline = Dictionary(uniqueKeysWithValues: displays.map { ($0.id, $0) }) }
    func observe(_ id: CGDirectDisplayID, _ flags: CGDisplayChangeSummaryFlags) {
        guard let before = baseline[id], !flags.contains(.beginConfigurationFlag) else { return }
        let after = ExistingDisplay.read(id)
        lock.withLock {
            afterEvents += 1
            if flags.contains(.setModeFlag) { modeEvents += 1 }
            if after != before { changed = true }
        }
    }
    func result() -> (changed: Bool, modeEvents: Int, afterEvents: Int) {
        lock.withLock { (changed, modeEvents, afterEvents) }
    }
}

let callback: CGDisplayReconfigurationCallBack = { id, flags, context in
    guard let context else { return }
    Unmanaged<DisplayMonitor>.fromOpaque(context).takeUnretainedValue().observe(id, flags)
}

final class Once: @unchecked Sendable {
    private let lock = NSLock()
    private var done = false
    func first() -> Bool { lock.withLock { if done { return false }; done = true; return true } }
}

func currentProcessContent() async -> SCShareableContent? {
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
final class WhiteView: NSView {
    override func draw(_ dirtyRect: NSRect) {
        NSColor.white.setFill()
        bounds.fill()
    }
}

final class OwnedCaptureResult: @unchecked Sendable {
    private let lock = NSLock()
    private var captured = 0
    private var decoded = 0
    private var whitePixel = false
    private var error: String?

    func receiveCapture(_ image: CVPixelBuffer) {
        lock.withLock {
            if CVPixelBufferGetWidth(image) != 2008 || CVPixelBufferGetHeight(image) != 2854 {
                error = "captured frame dimensions differ"
            }
            captured += 1
        }
    }
    func receiveDecoded(_ sample: CMSampleBuffer) {
        guard let image = CMSampleBufferGetImageBuffer(sample) else { fail("missing decoded image"); return }
        guard CVPixelBufferGetWidth(image) == 2008, CVPixelBufferGetHeight(image) == 2854,
              CVPixelBufferGetPlaneCount(image) >= 1 else { fail("decoded frame dimensions or format differ"); return }
        guard CVPixelBufferLockBaseAddress(image, .readOnly) == kCVReturnSuccess else { fail("cannot inspect decoded frame"); return }
        defer { CVPixelBufferUnlockBaseAddress(image, .readOnly) }
        guard let base = CVPixelBufferGetBaseAddressOfPlane(image, 0) else { fail("missing decoded luma"); return }
        let offset = (2854 / 2) * CVPixelBufferGetBytesPerRowOfPlane(image, 0) + 2008 / 2
        let luma = base.assumingMemoryBound(to: UInt8.self)[offset]
        lock.withLock { decoded += 1; whitePixel = luma > 180 }
    }
    func fail(_ message: String) { lock.withLock { error = message } }
    func snapshot() -> (captured: Int, decoded: Int, whitePixel: Bool, error: String?) {
        lock.withLock { (captured, decoded, whitePixel, error) }
    }
}

setbuf(stdout, nil)
let app = NSApplication.shared
app.setActivationPolicy(.accessory)
Task { @MainActor in
    guard let before = existingDisplays(), before == existingDisplays() else {
        print("EXTENDED OWN CAPTURE FAIL: existing display inventory unstable")
        exit(1)
    }
    let monitor = DisplayMonitor(before)
    let context = Unmanaged.passUnretained(monitor).toOpaque()
    guard CGDisplayRegisterReconfigurationCallback(callback, context) == .success else {
        print("EXTENDED OWN CAPTURE FAIL: display monitor unavailable")
        exit(1)
    }
    let desktop = DuoDesktopDisplay(layout: .extended)
    let capture = WindowCapture()
    let result = OwnedCaptureResult()
    var window: NSWindow?
    var encoder: HEVCEncoder?
    var decoder: HardwareHEVCDecoder?
    var virtualID: CGDirectDisplayID = 0
    var completed = false
    do {
        let wanted = DuoDesktopResolution(width: 2007, height: 2853)
        virtualID = try await desktop.prepareGraphics(wanted, fps: 120)
        guard desktop.isExtendedLayout, desktop.activeModeMatches, desktop.followsNativeCadence,
              CGDisplayMirrorsDisplay(virtualID) == kCGNullDirectDisplay,
              before.allSatisfy({ ExistingDisplay.read($0.id) == $0 }) else { throw ProbeFailure("extension setup") }
        var target: NSScreen?
        for _ in 0..<30 {
            target = NSScreen.screens.first {
                ($0.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber)?.uint32Value == virtualID
            }
            if target != nil { break }
            try await Task.sleep(for: .milliseconds(100))
        }
        guard let target else { throw ProbeFailure("virtual NSScreen unavailable") }
        let fixture = NSWindow(contentRect: target.frame, styleMask: [.borderless], backing: .buffered, defer: false)
        fixture.isReleasedWhenClosed = false
        fixture.hasShadow = false
        fixture.ignoresMouseEvents = true
        fixture.contentView = WhiteView(frame: NSRect(origin: .zero, size: target.frame.size))
        fixture.setFrame(target.frame, display: true)
        fixture.orderFrontRegardless()
        window = fixture
        try await Task.sleep(for: .milliseconds(500))
        guard (fixture.screen?.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber)?.uint32Value == virtualID,
              before.allSatisfy({ ExistingDisplay.read($0.id) == $0 }),
              let content = await currentProcessContent(),
              let owned = content.windows.first(where: {
                  $0.windowID == UInt32(fixture.windowNumber) && $0.owningApplication?.processID == getpid()
              }) else { throw ProbeFailure("own window unavailable on extension") }
        let filter = SCContentFilter(desktopIndependentWindow: owned)
        let canvas = DuoDesktopCanvas(width: 2008, height: 2854)
        let receiving = HardwareHEVCDecoder(onFormat: { _, _ in }, onSample: { sample, _, _ in
            result.receiveDecoded(sample)
        }, onFailure: { message, _ in result.fail(message) })
        receiving.require(wanted)
        let sending = try HEVCEncoder(width: 2008, height: 2854, fps: 120, bitrate: 30_000_000,
                                      prioritizeSpeed: true, software: false, quiet: true)
        sending.onEncoded = { bytes, keyframe, parameters in
            if var parameters { parameters.nativeDesktopCanvas = canvas; receiving.apply(parameters) }
            receiving.enqueue(bytes, isKeyframe: keyframe)
        }
        sending.onHung = { result.fail("hardware encoder stalled") }
        capture.onFrame = { image, pts in result.receiveCapture(image); sending.encode(image, pts: pts) }
        capture.onStopped = { stop in result.fail(stop.error.localizedDescription) }
        encoder = sending
        decoder = receiving
        try await capture.start(filter: filter, width: 2008, height: 2854, fps: 120, showsCursor: false,
                                nativeCadence: desktop.followsNativeCadence, requireNativeGeometry: true)
        for _ in 0..<100 {
            let status = result.snapshot()
            if status.decoded > 0 || status.error != nil { break }
            try await Task.sleep(for: .milliseconds(100))
        }
        let status = result.snapshot()
        print("EXTENDED OWN CAPTURE: captured=\(status.captured), decoded=\(status.decoded), whitePixel=\(status.whitePixel), error=\(status.error ?? "none")")
        completed = status.captured > 0 && status.decoded > 0 && status.whitePixel && status.error == nil
    } catch {
        print("EXTENDED OWN CAPTURE: failed: \(error.localizedDescription)")
    }
    await capture.stop()
    capture.onFrame = nil
    encoder?.abandon()
    encoder = nil
    decoder = nil
    window?.orderOut(nil)
    window?.close()
    let removed = desktop.restore()
    for _ in 0..<30 where virtualID != 0 && CGDisplayIsOnline(virtualID) > 0 {
        try? await Task.sleep(for: .milliseconds(100))
    }
    try? await Task.sleep(for: .milliseconds(500))
    let after = existingDisplays()
    let observations = monitor.result()
    CGDisplayRemoveReconfigurationCallback(callback, context)
    let restored = after == before && (virtualID == 0 || CGDisplayIsOnline(virtualID) <= 0)
    print("EXTENDED OWN CAPTURE: removed=\(removed), original displays unchanged=\(restored), physical mode events=\(observations.modeEvents), observed post events=\(observations.afterEvents), observed drift=\(observations.changed)")
    guard completed && removed && restored && !observations.changed && observations.modeEvents == 0 && observations.afterEvents > 0 else {
        print("EXTENDED OWN CAPTURE FAIL")
        exit(1)
    }
    print("EXTENDED OWN CAPTURE PASS: this process's window only; no full desktop, input, network, Duo or FPS claim")
    exit(0)
}
app.run()

struct ProbeFailure: LocalizedError {
    let message: String
    init(_ message: String) { self.message = message }
    var errorDescription: String? { message }
}
