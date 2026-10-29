// Copyright 2026 DUO你电脑 contributors. SPDX-License-Identifier: Apache-2.0
// Real ScreenCaptureKit samples of this process's own generated window only. A deliberate
// destination rectangle induces scaling; no display configuration or TCC request is made.
import AppKit
import CoreGraphics
import CoreMedia
import Darwin
import Foundation
import ScreenCaptureKit

setbuf(stdout, nil)
private let pixelWidth = 2008, pixelHeight = 1428

private final class Counts: @unchecked Sendable {
    private let lock = NSLock()
    private var frames = 0
    private var stops = 0
    private var geometryFailures = 0
    private var lastStop: WindowCapture.Stop?
    func frame() { lock.withLock { frames += 1 } }
    func stopped(_ stop: WindowCapture.Stop) {
        lock.withLock {
            stops += 1
            lastStop = stop
            if stop.error is WindowCapture.NativeGeometryFailure { geometryFailures += 1 }
        }
    }
    var snapshot: (Int, Int, Int) { lock.withLock { (frames, stops, geometryFailures) } }
    var lastStopValue: WindowCapture.Stop? { lock.withLock { lastStop } }
}

private enum Failure: Error { case assertions, noOwnWindow, wrongFilterSize, noFrame, acceptedScaledFrame, changedDisplay }

private final class FixtureView: NSView {
    var changed = false
    override func draw(_ dirtyRect: NSRect) {
        NSColor(calibratedRed: changed ? 0.55 : 0.15, green: 0.4, blue: 0.65, alpha: 1).setFill()
        bounds.fill()
        NSColor.white.setFill()
        NSRect(x: 0, y: 0, width: 60, height: 60).fill()
        NSRect(x: bounds.width - 60, y: bounds.height - 60, width: 60, height: 60).fill()
    }
}

@MainActor private final class Fixture: NSObject, NSApplicationDelegate {
    private var window: NSWindow?
    func applicationDidFinishLaunching(_ notification: Notification) {
        let window = NSWindow(contentRect: NSRect(x: 130, y: 130, width: 1004, height: 714),
                              styleMask: [.borderless], backing: .buffered, defer: false)
        window.title = "DUO native capture geometry fixture"
        window.contentView = FixtureView(frame: NSRect(x: 0, y: 0, width: 1004, height: 714))
        window.makeKeyAndOrderFront(nil)
        window.displayIfNeeded()
        self.window = window
        Task { await run() }
    }

    private func wait(_ test: () -> Bool) async -> Bool {
        for _ in 0..<60 {
            if test() { return true }
            try? await Task.sleep(for: .milliseconds(50))
        }
        return test()
    }

    private func run() async {
        let initial = CGDisplayCopyDisplayMode(CGMainDisplayID())
        var passed = false
        print("NATIVE GEOMETRY: own generated window only; global recording=\(CGPreflightScreenCaptureAccess()); no permission request or display writes")
        do {
            let geometry = WindowCapture.NativeGeometry(width: pixelWidth, height: pixelHeight)
            let full = CGRect(x: 0, y: 0, width: 1004, height: 714)
            let checks = [
                geometry.acceptsFilter(rect: full, scale: 2),
                !geometry.acceptsFilter(rect: full, scale: 1),
                !geometry.acceptsFilter(rect: full, scale: .nan),
                geometry.acceptsFrame(width: pixelWidth, height: pixelHeight, rect: full, scale: 2, contentScale: 1, filterScale: 2),
                !geometry.acceptsFrame(width: pixelWidth - 1, height: pixelHeight, rect: full, scale: 2, contentScale: 1, filterScale: 2),
                !geometry.acceptsFrame(width: pixelWidth, height: pixelHeight, rect: full.offsetBy(dx: 1, dy: 0), scale: 2, contentScale: 1, filterScale: 2),
                !geometry.acceptsFrame(width: pixelWidth, height: pixelHeight, rect: full, scale: 2, contentScale: 0.9993, filterScale: 2),
                !geometry.acceptsFrame(width: pixelWidth, height: pixelHeight, rect: full, scale: 1, contentScale: 1, filterScale: 2),
                !geometry.acceptsFrame(width: pixelWidth, height: pixelHeight, rect: full.insetBy(dx: 0.5, dy: 0), scale: 2, contentScale: 1, filterScale: 2),
                WindowCapture.captureRect(CGRectCreateDictionaryRepresentation(full) as NSDictionary) == full,
                WindowCapture.captureRect(NSValue(rect: full)) == full,
                WindowCapture.captureRect(NSNumber(value: 1)) == nil,
                WindowCapture.captureRect(NSValue(point: .zero)) == nil,
                WindowCapture.captureRect(["bad": 1]) == nil
            ]
            guard checks.allSatisfy({ $0 }) else { throw Failure.assertions }
            print("PASS: fourteen geometry and metadata checks")
            guard let window else { throw Failure.noOwnWindow }
            try await Task.sleep(for: .milliseconds(500))
            let content = try await SCShareableContent.currentProcess
            guard let own = content.windows.first(where: { $0.windowID == UInt32(window.windowNumber) && $0.owningApplication?.processID == getpid() }) else { throw Failure.noOwnWindow }
            let filter = SCContentFilter(desktopIndependentWindow: own)
            guard geometry.acceptsFilter(rect: filter.contentRect, scale: Double(filter.pointPixelScale)) else { throw Failure.wrongFilterSize }
            print("FILTER: own=true, size=\(filter.contentRect.size), scale=\(filter.pointPixelScale)")

            let wrongFilter = WindowCapture()
            do {
                try await wrongFilter.start(filter: filter, width: pixelWidth - 1, height: pixelHeight, fps: 60,
                                            showsCursor: false, requireNativeGeometry: true)
                await wrongFilter.stop()
                throw Failure.assertions
            } catch WindowCapture.NativeGeometryFailure.filter {
                print("PASS: mismatched source geometry rejected before starting SCK")
            }

            let valid = WindowCapture(), accepted = Counts()
            valid.onFrame = { _, _ in accepted.frame() }
            valid.onStopped = { accepted.stopped($0) }
            try await valid.start(filter: filter, width: pixelWidth, height: pixelHeight, fps: 60,
                                  showsCursor: false, requireNativeGeometry: true)
            let gotValid = await wait { accepted.snapshot.0 > 0 || accepted.snapshot.1 > 0 }
            guard gotValid, accepted.snapshot.0 > 0, accepted.snapshot.1 == 0 else { throw Failure.noFrame }
            print("PASS: matching real SCK frame admitted")
            valid.overrideNextContentScaleForTesting(0.9993)
            guard let view = window.contentView as? FixtureView else { throw Failure.noOwnWindow }
            view.changed = true; view.needsDisplay = true; window.displayIfNeeded()
            let failedWhileRunning = await wait { accepted.snapshot.1 > 0 }
            let firstCounts = accepted.snapshot
            guard let oldStop = accepted.lastStopValue, valid.isCurrent(oldStop) else { throw Failure.assertions }
            await valid.stop()
            try await Task.sleep(for: .milliseconds(150))
            guard failedWhileRunning, firstCounts.0 > 0, firstCounts.1 == 1, firstCounts.2 == 1,
                  accepted.snapshot.0 == firstCounts.0, !valid.isCurrent(oldStop) else { throw Failure.acceptedScaledFrame }
            print("PASS: injected geometry change stops an active SCK stream once, with no later frames")
            try await valid.start(filter: filter, width: pixelWidth, height: pixelHeight, fps: 60,
                                  showsCursor: false, requireNativeGeometry: true)
            let restarted = await wait { accepted.snapshot.0 > firstCounts.0 }
            await valid.stop()
            guard restarted, accepted.snapshot.1 == firstCounts.1, !valid.isCurrent(oldStop) else { throw Failure.noFrame }
            print("PASS: same capture object restarts; previous stop remains stale")

            let scaled = WindowCapture(), rejected = Counts()
            scaled.testDestinationRect = CGRect(x: 0, y: 0, width: pixelWidth - 1, height: pixelHeight - 1)
            scaled.onFrame = { _, _ in rejected.frame() }
            scaled.onStopped = { rejected.stopped($0) }
            var startupRejected = false
            do {
                try await scaled.start(filter: filter, width: pixelWidth, height: pixelHeight, fps: 60,
                                       showsCursor: false, requireNativeGeometry: true)
            } catch WindowCapture.NativeGeometryFailure.frame { startupRejected = true }
            let gotRejection = await wait { rejected.snapshot.1 > 0 || startupRejected }
            await scaled.stop()
            let result = rejected.snapshot
            guard gotRejection, result.0 == 0, result.1 <= 1,
                  startupRejected || result.2 == 1 else { throw Failure.acceptedScaledFrame }
            print("PASS: SCK-scaled content rejected before frame delivery, reports=\(result.1), startupRejected=\(startupRejected)")

            let final = CGDisplayCopyDisplayMode(CGMainDisplayID())
            guard initial?.ioDisplayModeID == final?.ioDisplayModeID, initial?.refreshRate == final?.refreshRate else { throw Failure.changedDisplay }
            passed = true
        } catch { print("NATIVE CAPTURE GEOMETRY FAILED: \(error)") }
        window?.close()
        print(passed ? "NATIVE CAPTURE GEOMETRY PASS" : "NATIVE CAPTURE GEOMETRY FAIL")
        print("SCOPE: own window only, not complete desktop, real Duo, physical mode switch or FPS acceptance")
        exit(passed ? 0 : 1)
    }
}

let app = NSApplication.shared
app.setActivationPolicy(.regular)
private let delegate = MainActor.assumeIsolated { Fixture() }
app.delegate = delegate
app.run()
