// Copyright 2026 DUO你电脑 contributors. SPDX-License-Identifier: Apache-2.0
// Resolution contract and read-only CoreGraphics mode selection; no configuration is changed.
import AppKit
import CoreGraphics
import Foundation
import StreamProtocol

@main struct Check {
    @MainActor static func main() {
        var failed = false
        func check(_ text: String, _ value: Bool) {
            print("\(value ? "PASS" : "FAIL"): \(text)")
            if !value { failed = true }
        }
        let target = DuoDesktopResolution(width: 2007, height: 1427)
        check("aligned native canvas accepted", target.accepts(width: 2008, height: 1428))
        check("double native aspect accepted", target.accepts(width: 4014, height: 2854))
        check("double aligned aspect accepted", target.accepts(width: 4016, height: 2856))
        check("smaller or mismatched aspect rejected", !target.accepts(width: 1920, height: 1080)
              && !target.accepts(width: 3840, height: 2160) && !target.accepts(width: 4016, height: 2854))
        check("odd native source accepted with padded video", target.acceptsDisplayMode(width: 2007, height: 1427)
              && !target.accepts(width: 2007, height: 1427) && target.acceptsPaddedEncoded(width: 2008, height: 1428))
        check("larger odd source requires padded-canvas metadata", target.acceptsDisplayMode(width: 6021, height: 4281)
              && !target.accepts(width: 6022, height: 4282) && target.acceptsPaddedEncoded(width: 6022, height: 4282))
        check("dimensions bounded before arithmetic", !target.accepts(width: Int.max, height: Int.max)
              && !DuoDesktopResolution(width: Int.max, height: 1427).accepts(width: 4014, height: 2854))

        let id = CGMainDisplayID()
        guard let current = CGDisplayCopyDisplayMode(id) else { print("FAIL: no current mode"); exit(1) }
        let options = [kCGDisplayShowDuplicateLowResolutionModes: true] as CFDictionary
        let modes = (CGDisplayCopyAllDisplayModes(id, options) as? [CGDisplayMode]) ?? []
        let synthetic = DuoDesktopResolution(width: current.pixelWidth / 2, height: current.pixelHeight / 2)
        guard current.pixelWidth.isMultiple(of: 4), current.pixelHeight.isMultiple(of: 4), synthetic.isValid else {
            print("FAIL: current display cannot provide a read-only doubled-mode fixture"); exit(1)
        }
        let chosen = DuoDesktopDisplay.physicalMode(modes, wanted: synthetic, current: current, fps: 60)
        check("current higher matching mode is reused", chosen?.ioDisplayModeID == current.ioDisplayModeID)
        let withoutCurrent = modes.filter { $0.ioDisplayModeID != current.ioDisplayModeID }
        let alternatives = withoutCurrent.filter {
            synthetic.acceptsDisplayMode(width: $0.pixelWidth, height: $0.pixelHeight)
                && $0.refreshRate == current.refreshRate && $0.refreshRate >= 59.5
        }
        let best = alternatives.map { $0.pixelWidth * $0.pixelHeight }.min()
        let other = DuoDesktopDisplay.physicalMode(withoutCurrent, wanted: synthetic, current: current, fps: 60)
        check("smallest same-refresh matching alternative is selected", best != nil
              && other.map { $0.pixelWidth * $0.pixelHeight } == best)
        let desktop = DuoDesktopDisplay()
        desktop.originals = [DuoDesktopDisplay.Original(id: id, mode: current, origin: CGDisplayBounds(id).origin,
                                                        mirror: CGDisplayMirrorsDisplay(id))]
        desktop.originalMainID = id; desktop.originalSystemMainID = id; desktop.capturedID = id
        desktop.resolution = synthetic; desktop.requestedFPS = 60; desktop.selectedPhysicalMode = current
        check("the selected live mode is accepted", desktop.activeModeMatches)
        if let other {
            desktop.selectedPhysicalMode = other
            check("a different same-aspect mode cannot retain old capture dimensions", !desktop.activeModeMatches)
        } else { check("a second mode exists for the identity check", false) }
        check("faster than the current clock is rejected", DuoDesktopDisplay.physicalMode(modes, wanted: synthetic,
              current: current, fps: 240) == nil)
        print("SCOPE: live mode metadata and synthetic target only; no display configuration, screen capture, input or FPS measurement")
        if failed { exit(1) }
    }
}
