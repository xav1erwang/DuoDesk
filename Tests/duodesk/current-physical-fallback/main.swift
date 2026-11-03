// Copyright 2026 DUO你电脑 contributors. SPDX-License-Identifier: Apache-2.0
// Graphics state is read only. Every display-configuration call is intercepted by the fixture.
import Foundation
import CoreGraphics
import StreamProtocol

enum Failure: Error { case failed(String) }

@main @MainActor struct Checks {
    static func main() async throws {
        let id = CGMainDisplayID()
        guard let mode = CGDisplayCopyDisplayMode(id), mode.refreshRate >= 60 else { throw Failure.failed("main mode") }
        let original = DuoDesktopResolution(width: mode.pixelWidth, height: mode.pixelHeight)
        let requested = DuoDesktopResolution(width: 2007, height: 1427)
        guard original.isValid else { throw Failure.failed("invalid physical pixels") }
        let desktop = DuoDesktopDisplay(layout: .mirrored)
        desktop.testPreventDisplayMutation = true
        desktop.testInterceptConfiguration = true
        let captured = try await desktop.prepareGraphics(original, fps: 60, preservePhysicalMode: true)
        guard captured == id, desktop.activeModeMatches, desktop.testConfigurationAttempts == 0,
              desktop.restore(), desktop.testConfigurationAttempts == 0,
              let after = CGDisplayCopyDisplayMode(id), after.ioDisplayModeID == mode.ioDisplayModeID,
              after.pixelWidth == mode.pixelWidth, after.pixelHeight == mode.pixelHeight,
              after.refreshRate == mode.refreshRate else { throw Failure.failed("physical fallback changed its display") }
        print("PASS: current full-resolution mode is accepted without any display transaction")

        let mismatch = DuoDesktopDisplay(layout: .mirrored)
        mismatch.testPreventDisplayMutation = true
        mismatch.testInterceptConfiguration = true
        do {
            _ = try await mismatch.prepareGraphics(requested, fps: 60, preservePhysicalMode: true)
            if !requested.acceptsDisplayMode(width: mode.pixelWidth, height: mode.pixelHeight) {
                throw Failure.failed("mismatched mode accepted")
            }
        } catch DuoDesktopDisplay.Failure.physicalModeChanged { }
        guard mismatch.testConfigurationAttempts == 0 else { throw Failure.failed("mismatch attempted configuration") }
        print("PASS: a changed or incompatible mode cannot reconfigure the physical display")

        guard DuoDesktopDisplay.physicalFallback(requested: requested, width: 3840, height: 2160)
                == DuoDesktopResolution(width: 3840, height: 2160),
              DuoDesktopDisplay.physicalFallback(requested: requested, width: 1920, height: 1080) == nil,
              DuoDesktopDisplay.physicalFallback(requested: requested, width: 9000, height: 9000) == nil else {
            throw Failure.failed("fallback size rule")
        }
        print("PASS: fallback retains the whole physical canvas and never offers fewer requested pixels")

        let valid = Viewport(width: 669, height: 475, scale: nil, desktopResolution: original, preservePhysicalMode: true)
        let missing = Viewport(width: 669, height: 475, scale: nil, preservePhysicalMode: true)
        let conflicting = Viewport(width: 669, height: 475, scale: nil, desktopResolution: original,
                                   extendedDesktop: true, extendedRequestID: UUID(), preservePhysicalMode: true)
        guard valid.isValid, !missing.isValid, !conflicting.isValid,
              Wire.decode(Viewport.self, from: Wire.encode(valid)) == valid else { throw Failure.failed("viewport contract") }
        print("PASS: fallback viewport must name a physical resolution and cannot request extension")
    }
}
