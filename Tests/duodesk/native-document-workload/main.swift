// Copyright 2026 DUO你电脑 contributors. SPDX-License-Identifier: Apache-2.0
// A normal AppKit text document in a regular window; no generated frame markers.
import AppKit
import QuartzCore

setbuf(stdout, nil)
let app = NSApplication.shared
app.setActivationPolicy(.regular)

@MainActor
final class DocumentWorkload: NSObject, NSApplicationDelegate {
    private var window: NSWindow?
    private var scroll: NSScrollView?
    private var text: NSTextView?
    private var clock: CADisplayLink?
    private var ticks = 0
    private var started = 0.0

    func applicationDidFinishLaunching(_ notification: Notification) {
        let environment = ProcessInfo.processInfo.environment
        let paths: [String]
        if let json = environment["DUODESK_WORKLOAD_DOCUMENTS"], let data = json.data(using: .utf8),
           let decoded = try? JSONDecoder().decode([String].self, from: data) {
            paths = decoded
        } else if let path = environment["DUODESK_WORKLOAD_DOCUMENT"] {
            paths = [path]
        } else { paths = [] }
        let documents = paths.compactMap { try? String(contentsOfFile: $0, encoding: .utf8) }
        guard !paths.isEmpty, documents.count == paths.count, documents.allSatisfy({ !$0.isEmpty }),
              let screen = NSScreen.screens.first else { exit(1) }
        let size = NSSize(width: screen.visibleFrame.width * 0.78, height: screen.visibleFrame.height * 0.78)
        let window = NSWindow(contentRect: NSRect(origin: .zero, size: size),
                              styleMask: [.titled, .closable, .resizable], backing: .buffered, defer: false)
        window.title = "DUO 文稿窗口"
        window.isRestorable = false
        let scroll = NSScrollView(frame: NSRect(origin: .zero, size: size))
        scroll.autoresizingMask = [.width, .height]
        scroll.hasVerticalScroller = true
        let text = NSTextView(frame: NSRect(origin: .zero, size: size))
        text.isEditable = false
        text.isSelectable = true
        text.isVerticallyResizable = true
        text.isHorizontallyResizable = false
        text.autoresizingMask = [.width]
        text.textContainer?.widthTracksTextView = true
        text.textContainer?.containerSize = NSSize(width: size.width, height: .greatestFiniteMagnitude)
        text.textContainerInset = NSSize(width: 18, height: 18)
        // Use real project documents; do not embed counters or synthetic video markers.
        text.textStorage?.setAttributedString(NSAttributedString(string: documents.joined(separator: "\n\n"), attributes: [
            .font: NSFont.systemFont(ofSize: 15), .foregroundColor: NSColor.textColor
        ]))
        scroll.documentView = text
        window.contentView = scroll
        window.center(); window.makeKeyAndOrderFront(nil); app.activate()
        text.layoutManager?.ensureLayout(for: text.textContainer!)
        text.sizeToFit()
        self.window = window; self.scroll = scroll; self.text = text
        let number = screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] ?? 0
        print("NATIVE DOCUMENT READY: screen=\(number), window=\(window.frame), documentHeight=\(text.frame.height), visibleHeight=\(scroll.contentView.bounds.height)")
        // The capture controller provides one byte only after its stationary baseline.
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            let byte = FileHandle.standardInput.readData(ofLength: 1)
            guard !byte.isEmpty else { return }
            DispatchQueue.main.async { self?.startScrolling() }
        }
    }

    private func startScrolling() {
        guard let screen = window?.screen, let scroll, let text,
              text.frame.height > scroll.contentView.bounds.height + 6_000 else {
            print("NATIVE DOCUMENT ERROR: document is too short or no screen is available")
            app.terminate(nil); return
        }
        started = ProcessInfo.processInfo.systemUptime
        let link = screen.displayLink(target: self, selector: #selector(tick(_:)))
        link.preferredFrameRateRange = CAFrameRateRange(minimum: 120, maximum: 120, preferred: 120)
        link.add(to: .main, forMode: .common)
        clock = link
        print("NATIVE DOCUMENT SCROLLING: screenFPS=\(screen.maximumFramesPerSecond), 1.5 points per display callback")
    }

    @objc private func tick(_ link: CADisplayLink) {
        guard let scroll, let text else { return }
        ticks += 1
        let maximum = max(0, text.bounds.height - scroll.contentView.bounds.height)
        let y = min(maximum, scroll.contentView.bounds.origin.y + 1.5)
        scroll.contentView.scroll(to: NSPoint(x: 0, y: y))
        scroll.reflectScrolledClipView(scroll.contentView)
        if ticks % 120 == 0 {
            print("NATIVE DOCUMENT: callbacks=\(ticks), elapsed=\(ProcessInfo.processInfo.systemUptime - started), scrollY=\(y), max=\(maximum)")
        }
    }
}

let delegate = MainActor.assumeIsolated { DocumentWorkload() }
app.delegate = delegate
app.run()
