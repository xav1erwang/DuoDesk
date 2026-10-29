// Copyright 2026 DUO你电脑 contributors. SPDX-License-Identifier: Apache-2.0
// Integration only: an even own-window source is deliberately requested at odd SCK output size.
// SCK scales it, so this is NOT evidence of an unscaled odd physical desktop or FPS.
import AppKit
import CoreGraphics
import CoreMedia
import CoreVideo
import Darwin
import Foundation
import ScreenCaptureKit
import StreamProtocol

private let canvas = DuoDesktopCanvas(width: 2007, height: 1427)
private final class Counts: @unchecked Sendable {
    private let lock = NSLock()
    private var captured = 0, decoded = 0
    private var failure: String?
    func capturedFrame() { lock.withLock { captured += 1 } }
    func decodedFrame(_ sample: CMSampleBuffer, _ permit: VideoOutputPermit) {
        guard permit.isValid, let image = CMSampleBufferGetImageBuffer(sample),
              CVPixelBufferGetWidth(image) == 2008, CVPixelBufferGetHeight(image) == 1428 else { fail("wrong decoded canvas"); return }
        lock.withLock { decoded += 1 }
    }
    func fail(_ text: String) { lock.withLock { if failure == nil { failure = text } } }
    var state: (Int, Int, String?) { lock.withLock { (captured, decoded, failure) } }
}

private enum Failure: Error { case window, geometry, padder, timeout, pipeline, displayChanged }
private final class View: NSView {
    override func draw(_ dirtyRect: NSRect) {
        NSColor(calibratedRed: 0.22, green: 0.45, blue: 0.68, alpha: 1).setFill()
        bounds.fill()
    }
}

@MainActor private final class Fixture: NSObject, NSApplicationDelegate {
    private var window: NSWindow?
    func applicationDidFinishLaunching(_ notification: Notification) {
        let window = NSWindow(contentRect: NSRect(x: 130, y: 130, width: 1004, height: 714),
                              styleMask: [.borderless], backing: .buffered, defer: false)
        window.title = "DUO odd buffer integration fixture"
        window.contentView = View(frame: NSRect(x: 0, y: 0, width: 1004, height: 714))
        window.makeKeyAndOrderFront(nil); window.displayIfNeeded(); self.window = window
        Task { await run() }
    }
    private func run() async {
        let before = CGDisplayCopyDisplayMode(CGMainDisplayID())
        let capture = WindowCapture()
        let counts = Counts()
        var encoder: HEVCEncoder?, decoder: HardwareDecoderRouter?
        var passed = false
        print("ODD SCK PIPELINE: own window only; global recording=\(CGPreflightScreenCaptureAccess()); no permission request or display writes")
        do {
            guard let window else { throw Failure.window }
            try await Task.sleep(for: .milliseconds(500))
            let content = try await SCShareableContent.currentProcess
            guard let own = content.windows.first(where: { $0.windowID == UInt32(window.windowNumber) && $0.owningApplication?.processID == getpid() }) else { throw Failure.window }
            let filter = SCContentFilter(desktopIndependentWindow: own)
            guard !WindowCapture.NativeGeometry(width: canvas.width, height: canvas.height)
                .acceptsFilter(rect: filter.contentRect, scale: Double(filter.pointPixelScale)) else { throw Failure.geometry }
            guard let padder = NativeDesktopPadder(canvas: canvas) else { throw Failure.padder }
            let d = HardwareDecoderRouter(onFormat: { _, _ in }, onSample: { sample, _, permit in counts.decodedFrame(sample, permit) },
                                          onFailure: { message, _ in counts.fail(message) })
            _ = d.require(DuoDesktopResolution(width: canvas.width, height: canvas.height)); decoder = d
            let e = try HEVCEncoder(width: canvas.encodedWidth, height: canvas.encodedHeight, fps: 30, bitrate: 16_000_000,
                                    prioritizeSpeed: true, software: false, quiet: true)
            encoder = e
            e.onEncoded = { bytes, keyframe, parameters in
                guard keyframe, var parameters else { return }
                parameters.nativeDesktopCanvas = canvas
                guard let decoded = ParameterSets(encoded: parameters.encoded()) else { counts.fail("metadata"); return }
                d.apply(decoded); d.enqueue(bytes, isKeyframe: true)
            }
            e.onHung = { counts.fail("encoder watchdog") }
            capture.onStopped = { counts.fail("capture stopped: \($0.error)") }
            capture.onFrame = { source, pts in
                if counts.state.0 == 0 {
                    let planes = (0..<CVPixelBufferGetPlaneCount(source)).map {
                        "\(CVPixelBufferGetWidthOfPlane(source, $0))×\(CVPixelBufferGetHeightOfPlane(source, $0)),stride=\(CVPixelBufferGetBytesPerRowOfPlane(source, $0))"
                    }
                    print("SCK BUFFER: format=\(CVPixelBufferGetPixelFormatType(source)), planes=\(planes)")
                }
                guard CVPixelBufferGetWidth(source) == canvas.width, CVPixelBufferGetHeight(source) == canvas.height,
                      let padded = padder.pad(source) else { counts.fail("odd SCK plane layout or pad failed"); return }
                counts.capturedFrame(); e.encode(padded, pts: pts)
            }
            try await capture.start(filter: filter, width: canvas.width, height: canvas.height, fps: 30,
                                    showsCursor: false, pixelFormat: kCVPixelFormatType_32BGRA)
            for _ in 0..<100 {
                let state = counts.state
                if state.1 > 0 || state.2 != nil { break }
                try await Task.sleep(for: .milliseconds(100))
            }
            let result = counts.state
            guard result.2 == nil, result.0 > 0, result.1 > 0 else { throw Failure.pipeline }
            print("PASS: real odd SCK BGRA buffer -> lossless edge copy -> metadata -> hardware HEVC decode; source was scaled by SCK")
            let after = CGDisplayCopyDisplayMode(CGMainDisplayID())
            guard before?.ioDisplayModeID == after?.ioDisplayModeID, before?.refreshRate == after?.refreshRate else { throw Failure.displayChanged }
            passed = true
        } catch { print("ODD SCK PIPELINE FAILED: \(error), details=\(String(describing: counts.state.2))") }
        await capture.stop()
        capture.onFrame = nil; capture.onStopped = nil
        _ = encoder?.abandon(); _ = decoder?.clear()
        window?.close()
        print(passed ? "ODD SCK PIPELINE PASS" : "ODD SCK PIPELINE FAIL")
        print("SCOPE: own window, deliberately scaled SCK source; no full desktop, real Duo, physical mode switch or FPS acceptance")
        exit(passed ? 0 : 1)
    }
}

@main private struct Main {
    static func main() {
        setbuf(stdout, nil)
        let app = NSApplication.shared
        app.setActivationPolicy(.regular)
        let delegate = MainActor.assumeIsolated { Fixture() }
        app.delegate = delegate
        app.run()
        withExtendedLifetime(delegate) {}
    }
}
