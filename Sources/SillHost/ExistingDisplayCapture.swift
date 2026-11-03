import CoreGraphics
import ScreenCaptureKit
import StreamProtocol

/// Read-only selection of an existing desktop. No display mode, origin, mirror or primary writes.
@MainActor
enum ExistingDisplayCapture {
    struct Prepared {
        let display: SCDisplay
        let canvas: DuoDesktopCanvas
    }

    static func prepare(_ display: SCDisplay) throws -> Prepared {
        guard CGDisplayIsOnline(display.displayID) > 0,
              let mode = CGDisplayCopyDisplayMode(display.displayID) else {
            throw DuoDesktopDisplay.Failure.displayUnavailable
        }
        let canvas = DuoDesktopCanvas(width: mode.pixelWidth, height: mode.pixelHeight)
        guard canvas.isValid else { throw DuoDesktopDisplay.Failure.invalidResolution }
        return Prepared(display: display, canvas: canvas)
    }
}
