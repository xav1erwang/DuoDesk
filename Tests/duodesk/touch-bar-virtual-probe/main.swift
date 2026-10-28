// Copyright 2026 DUO你电脑 contributors. SPDX-License-Identifier: Apache-2.0
// Standalone opt-in diagnostic, never linked to the product. No pixel data or touch is saved.
import ApplicationServices
import CoreVideo
import Foundation

final class Audit: @unchecked Sendable {
    private let lock = NSLock()
    private var count = 0, dimensions: (Int, Int, Int, Int)?, stopped = false
    func frame(_ value: TouchBarCapturedFrame) {
        lock.withLock {
            count += 1
            dimensions = (value.contentWidth, value.contentHeight,
                          CVPixelBufferGetWidth(value.pixels), CVPixelBufferGetHeight(value.pixels))
        }
    }
    func ended() { lock.withLock { stopped = true } }
    var state: (Int, (Int, Int, Int, Int)?, Bool) { lock.withLock { (count, dimensions, stopped) } }
}
@main struct Probe {
    @MainActor static func main() async {
        let arguments = Array(CommandLine.arguments.dropFirst())
        guard arguments.isEmpty || arguments == ["--sample"] else {
            print("usage: touch-bar-virtual-probe [--sample]"); exit(64)
        }
        let recording = CGPreflightScreenCaptureAccess()
        print("recording=\(recording ? "allowed" : "not-allowed") explicitSample=\(arguments == ["--sample"] ? "yes" : "no")")
        guard arguments == ["--sample"] else { print("PREFLIGHT ONLY: no runtime loaded"); return }
        guard recording else { print("SKIPPED: existing recording permission is absent; no request made"); exit(2) }
        let audit = Audit(), driver = TouchBarVirtualDriver()
        let source = TouchBarReadOnlySource(driver: driver)
        do {
            try source.start(onFrame: { audit.frame($0) }, onStopped: { audit.ended() })
        } catch { print("UNAVAILABLE: source start refused"); exit(3) }
        let deadline = ContinuousClock.now + .seconds(3)
        while ContinuousClock.now < deadline && !audit.state.2 {
            try? await Task.sleep(for: .milliseconds(25))
        }
        source.stop()
        let stopDeadline = ContinuousClock.now + .seconds(2)
        while !driver.isQuiescent && ContinuousClock.now < stopDeadline {
            try? await Task.sleep(for: .milliseconds(25))
        }
        let (frames, size, ended) = audit.state
        guard driver.isQuiescent else {
            print("UNAVAILABLE: stop callback timed out; process exits without freeing a potentially active stream")
            exit(5)
        }
        let dims = size.map { "\($0.0)x\($0.1) encoded=\($0.2)x\($0.3)" } ?? "none"
        print("VIRTUAL METADATA ONLY: frames=\(frames) content=\(dims) sourceEnded=\(ended)")
        print("SCOPE: virtual simulator only; no physical Touch Bar, input, network, Duo or FPS acceptance")
        if frames == 0 { exit(4) }
    }
}
