// Modified for DUO你电脑, 2026. See NOTICE for upstream attribution.
import AppKit

/// The app icon's screen and V, with a single baseline at menu bar size.
/// macOS supplies the light/dark tint; connection state stays in the tooltip and panel.
enum StatusGlyph {
    enum State: Equatable, CaseIterable { case idle, connected, streaming, attention }

    static let size = NSSize(width: 20, height: 18)

    private static let appIcon: NSImage = {
        let image = NSImage(size: size, flipped: true) { _ in
            guard let context = NSGraphicsContext.current?.cgContext else { return false }
            context.setStrokeColor(NSColor.black.cgColor)
            context.setLineWidth(1.25)
            context.setLineCap(.round)
            context.setLineJoin(.round)

            context.addPath(CGPath(roundedRect: CGRect(x: 2.3, y: 2, width: 15.4, height: 10.4),
                                   cornerWidth: 1.9, cornerHeight: 1.9, transform: nil))
            context.strokePath()

            context.move(to: CGPoint(x: 7.4, y: 5.1))
            context.addLine(to: CGPoint(x: 10, y: 9.1))
            context.addLine(to: CGPoint(x: 12.6, y: 5.1))
            context.strokePath()

            context.move(to: CGPoint(x: 1.2, y: 15))
            context.addLine(to: CGPoint(x: 18.8, y: 15))
            context.strokePath()
            return true
        }
        image.isTemplate = true
        image.accessibilityDescription = "DUO你电脑"
        return image
    }()

    static func image(_: State) -> NSImage { appIcon }
}
