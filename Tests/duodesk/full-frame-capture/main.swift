// Copyright 2026 DUO你电脑 contributors. SPDX-License-Identifier: Apache-2.0
// Captures only this process's own generated AppKit document, never another app or the desktop.
import AppKit
import CoreGraphics
import CoreMedia
import Darwin
import Foundation
import ScreenCaptureKit

setbuf(stdout, nil)
setenv("DUODESK_WORKLOAD_OWN_TEXT", "1", 1)
let app = NSApplication.shared
app.setActivationPolicy(.regular)
let workload = MainActor.assumeIsolated { DocumentWorkload(frameSize: NSSize(width: 1004, height: 714), usesStdin: false) }
let activity = ProcessInfo.processInfo.beginActivity(options: [.userInitiatedAllowingIdleSystemSleep, .latencyCritical],
                                                     reason: "Own document frame comparison")

private struct DisplayState: Equatable {
    let id: CGDirectDisplayID, main: CGDirectDisplayID, mirror: CGDirectDisplayID
    let bounds: CGRect
    let width: Int, height: Int, pixelWidth: Int, pixelHeight: Int
    let refresh: Double
}

private func displayState() -> [DisplayState]? {
    var count: UInt32 = 0
    guard CGGetOnlineDisplayList(0, nil, &count) == .success, count > 0 else { return nil }
    var ids = [CGDirectDisplayID](repeating: 0, count: Int(count))
    guard CGGetOnlineDisplayList(count, &ids, &count) == .success else { return nil }
    let main = CGMainDisplayID()
    var state: [DisplayState] = []
    for id in ids.prefix(Int(count)) {
        guard let mode = CGDisplayCopyDisplayMode(id) else { return nil }
        state.append(DisplayState(id: id, main: main, mirror: CGDisplayMirrorsDisplay(id), bounds: CGDisplayBounds(id),
                                  width: mode.width, height: mode.height, pixelWidth: mode.pixelWidth,
                                  pixelHeight: mode.pixelHeight, refresh: mode.refreshRate))
    }
    return state.sorted { $0.id < $1.id }
}

private enum CheckFailure: Error { case missingWindow, missingOwnContent, wrongDimensions, changedDisplays, invalidComparison }

@MainActor private func run() async {
    let capture = WindowCapture()
    var study: FullFrameCaptureStudy?
    var valid = false
    let before = displayState()
    print("FULL PLANE CAPTURE START: globalRecording=\(CGPreflightScreenCaptureAccess()), own process window only, no physical display writes")
    do {
        guard before != nil, let window = workload.window else { throw CheckFailure.missingWindow }
        try await Task.sleep(for: .milliseconds(400))
        let shareable = try await SCShareableContent.currentProcess
        guard let own = shareable.windows.first(where: {
            $0.windowID == UInt32(window.windowNumber) && $0.owningApplication?.processID == getpid()
        }) else { throw CheckFailure.missingOwnContent }
        let filter = SCContentFilter(desktopIndependentWindow: own)
        let width = Int((filter.contentRect.width * CGFloat(filter.pointPixelScale)).rounded())
        let height = Int((filter.contentRect.height * CGFloat(filter.pointPixelScale)).rounded())
        guard width == 2008, height == 1428 else { throw CheckFailure.wrongDimensions }
        print("FULL PLANE FILTER: ownPID=\(getpid()), owner=\(own.owningApplication?.processID ?? 0), pixels=\(width)×\(height), scale=\(filter.pointPixelScale)")
        let comparator = try FullFrameCaptureStudy()
        study = comparator
        capture.onUnpacedSampleBuffer = { sample in comparator.observeRaw(sample) }
        capture.onDeliveredSample = { sample in comparator.observe(sample) }
        capture.onStopped = { _ in comparator.failed() }
        try await capture.start(filter: filter, width: width, height: height, fps: 120, showsCursor: false, resampleCadence: true)
        try await Task.sleep(for: .milliseconds(500))
        comparator.begin()
        try await Task.sleep(for: .milliseconds(1200))
        comparator.setPhase(.scrolling)
        workload.startScrolling()
        try await Task.sleep(for: .milliseconds(4500))
        workload.stopScrolling()
        await capture.stop()
        capture.onDeliveredSample = nil; capture.onUnpacedSampleBuffer = nil
        let report = await comparator.finish()
        print(report.text)
        guard before == displayState() else { throw CheckFailure.changedDisplays }
        guard report.valid else { throw CheckFailure.invalidComparison }
        valid = true
    } catch {
        print("FULL PLANE CAPTURE FAILED: \(error)")
    }
    workload.stopScrolling()
    await capture.stop()
    capture.onDeliveredSample = nil; capture.onUnpacedSampleBuffer = nil
    if !valid, let study { print((await study.finish()).text) }
    workload.window?.close()
    ProcessInfo.processInfo.endActivity(activity)
    print("FULL PLANE CAPTURE END: valid=\(valid), displayStateUnchanged=\(before != nil && before == displayState()), completeDesktop=false, realDuo=false, no physical mode changes")
    exit(valid ? 0 : 1)
}

MainActor.assumeIsolated { workload.onReady = { Task { @MainActor in await run() } } }
app.delegate = workload
app.run()
