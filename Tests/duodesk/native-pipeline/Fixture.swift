// An owned application for real pointer/text acceptance. No input targets the user's apps.
import AppKit
import CoreGraphics
import Foundation
setbuf(stdout, nil)

let app = NSApplication.shared
app.setActivationPolicy(.regular)
let output = URL(fileURLWithPath: CommandLine.arguments[1])

final class InputWindow: NSWindow {
    var mouseEvents: [String] = []
    var downs = 0
    var ups = 0
    var lastPoint: CGPoint?
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { true }
    override func sendEvent(_ event: NSEvent) {
        if event.type == .leftMouseDown || event.type == .leftMouseUp {
            if event.type == .leftMouseDown { downs += 1 }
            if event.type == .leftMouseUp { ups += 1 }
            lastPoint = event.locationInWindow
            mouseEvents.append("\(event.type.rawValue):\(event.locationInWindow)")
        }
        super.sendEvent(event)
    }
}
final class InputField: NSView {
    var downs = 0
    var text = ""
    override var acceptsFirstResponder: Bool { true }
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
    override func mouseDown(with event: NSEvent) { downs += 1; window?.makeFirstResponder(self) }
    override func keyDown(with event: NSEvent) {
        text += event.characters ?? ""; needsDisplay = true
    }
    override func draw(_ dirtyRect: NSRect) {
        NSColor.white.setFill(); bounds.fill()
        (text.isEmpty ? "DUO input check" : text).draw(at: CGPoint(x: 8, y: 8), withAttributes: [
            .font: NSFont.systemFont(ofSize: 18), .foregroundColor: NSColor.black])
    }
}
@MainActor final class Fixture {
    var windows: [UInt32: InputWindow] = [:]
    var fields: [UInt32: InputField] = [:]
    var canvases: [UInt32: CGRect] = [:]
    var timer: Timer?
    var lastRecord: Data?
    func report() {
        let rows = CGWindowListCopyWindowInfo(.optionOnScreenOnly, 0) as? [[String: Any]] ?? []
        var displays: [[String: Any]] = []
        for (id, window) in windows {
            guard let row = rows.first(where: { ($0[kCGWindowNumber as String] as? NSNumber)?.intValue == window.windowNumber }),
                  let data = row[kCGWindowBounds as String] as? [String: Any],
                  let frame = CGRect(dictionaryRepresentation: data as CFDictionary), let field = fields[id] else { continue }
            let source = CGDisplayMirrorsDisplay(id) == 0 ? id : CGDisplayMirrorsDisplay(id)
            let bounds = CGDisplayBounds(source)
            let appHeight = NSScreen.screens.first?.frame.height ?? 0
            let oldCocoa = window.frame
            let oldCoherent = abs(oldCocoa.minX - frame.minX) < 2 && abs(appHeight - oldCocoa.maxY - frame.minY) < 2
            if canvases[id] != bounds || !oldCoherent {
                canvases[id] = bounds
                // NSWindow coordinates use AppKit's first screen, which can be the physical
                // mirror endpoint while CGMainDisplayID names the virtual capture endpoint.
                let mainHeight = NSScreen.screens.first?.frame.height ?? CGDisplayBounds(CGMainDisplayID()).height
                window.setFrameOrigin(CGPoint(x: bounds.minX + 80, y: mainHeight - bounds.minY - 300))
                window.orderFrontRegardless()
            }
            let point = CGPoint(x: frame.minX + field.frame.midX, y: frame.maxY - field.frame.midY)
            let cocoa = window.frame
            let coherent = abs(cocoa.minX - frame.minX) < 2 && abs(appHeight - cocoa.maxY - frame.minY) < 2
            let top = rows.first { candidate in
                guard let layer = candidate[kCGWindowLayer as String] as? Int, (0...3).contains(layer),
                      let data = candidate[kCGWindowBounds as String] as? [String: Any],
                      let frame = CGRect(dictionaryRepresentation: data as CFDictionary) else { return false }
                return frame.contains(point)
            }
            displays.append(["id": id, "window": window.windowNumber, "pid": ProcessInfo.processInfo.processIdentifier,
                             "visible": window.isOnActiveSpace, "frame": [frame.minX, frame.minY, frame.width, frame.height],
                             "source": source, "bounds": [bounds.minX, bounds.minY, bounds.width, bounds.height],
                             "point": [point.x, point.y], "downs": min(window.downs, window.ups),
                             "topmost": coherent && (top?[kCGWindowNumber as String] as? NSNumber)?.intValue == window.windowNumber,
                             "cocoaFrame": [cocoa.minX, cocoa.minY, cocoa.width, cocoa.height], "appHeight": appHeight,
                             "mouseEvents": window.mouseEvents,
                             "lastPoint": window.lastPoint.map { [$0.x, $0.y] } as Any? ?? NSNull(),
                             "focused": window.isKeyWindow && window.firstResponder === field,
                             "text": field.text])
        }
        let record: [String: Any] = ["main": CGMainDisplayID(), "screens": displays]
        if let data = try? JSONSerialization.data(withJSONObject: record, options: [.sortedKeys]) {
            try? data.write(to: output, options: .atomic)
            if data != lastRecord { lastRecord = data; print("FIXTURE STATE " + String(decoding: data, as: UTF8.self)) }
        }
    }
    func start() {
        for screen in NSScreen.screens {
            guard let id = (screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber)?.uint32Value else { continue }
            let rect = CGRect(x: screen.frame.minX + 80, y: screen.frame.maxY - 340, width: 360, height: 220)
            let window = InputWindow(contentRect: rect, styleMask: [.borderless], backing: .buffered, defer: false, screen: screen)
            window.setFrameOrigin(rect.origin)
            window.isReleasedWhenClosed = false; window.isRestorable = false
            window.level = .floating
            window.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
            window.backgroundColor = id == CGMainDisplayID() ? .systemBlue : .systemOrange
            window.title = "DUO owned input fixture \(id)"
            let field = InputField(frame: CGRect(x: 20, y: 85, width: 320, height: 40))
            window.contentView?.addSubview(field); window.orderFrontRegardless()
            windows[id] = window; fields[id] = field
        }
        timer = Timer.scheduledTimer(withTimeInterval: 0.04, repeats: true) { [weak self] _ in MainActor.assumeIsolated { self?.report() } }
        report()
    }
}
MainActor.assumeIsolated { let fixture = Fixture(); fixture.start(); withExtendedLifetime(fixture) { app.run() } }
