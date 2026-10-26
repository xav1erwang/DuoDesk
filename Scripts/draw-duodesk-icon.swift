// Copyright 2026 DUO你电脑 contributors. SPDX-License-Identifier: Apache-2.0
import AppKit

let destination = CommandLine.arguments.dropFirst().first ?? "iOSClient/Assets.xcassets/AppIcon.appiconset/AppIcon.png"
let size = NSSize(width: 1024, height: 1024)
let bitmap = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: 1024, pixelsHigh: 1024,
                              bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true,
                              isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
NSGraphicsContext.saveGraphicsState()
NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: bitmap)
NSColor(calibratedWhite: 0.09, alpha: 1).setFill()
NSBezierPath(rect: NSRect(origin: .zero, size: size)).fill()
let screen = NSRect(x: 128, y: 500, width: 768, height: 376)
NSGradient(colors: [NSColor(calibratedRed: 0.13, green: 0.3, blue: 0.62, alpha: 1),
                    NSColor(calibratedRed: 0.36, green: 0.8, blue: 0.85, alpha: 1)])!
    .draw(in: NSBezierPath(roundedRect: screen, xRadius: 32, yRadius: 32), angle: 30)
NSColor(calibratedWhite: 0.86, alpha: 1).setFill()
NSBezierPath(roundedRect: NSRect(x: 128, y: 146, width: 768, height: 326), xRadius: 32, yRadius: 32).fill()
NSColor(calibratedWhite: 0.12, alpha: 1).setFill()
for row in 0..<3 {
    for column in 0..<10 {
        NSBezierPath(roundedRect: NSRect(x: 164 + column * 70, y: 366 - row * 52, width: 61, height: 40), xRadius: 6, yRadius: 6).fill()
    }
}
NSColor(calibratedWhite: 0.65, alpha: 1).setFill()
NSBezierPath(roundedRect: NSRect(x: 375, y: 172, width: 274, height: 68), xRadius: 12, yRadius: 12).fill()
NSGraphicsContext.restoreGraphicsState()
guard let png = bitmap.representation(using: .png, properties: [:]) else { fatalError("Could not render icon") }
try png.write(to: URL(fileURLWithPath: destination))
print("Rendered DUO app icon")
