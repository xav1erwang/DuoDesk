// Copyright 2026 DUO你电脑 contributors. SPDX-License-Identifier: Apache-2.0
// A normal AppKit document window with no generated frame markers.
import AppKit
import Darwin
import QuartzCore

@MainActor
final class DocumentWorkload: NSObject, NSApplicationDelegate {
    private(set) var window: NSWindow?
    private var scroll: NSScrollView?
    private var text: NSTextView?
    private var clock: CADisplayLink?
    private var timer: DispatchSourceTimer?
    private var baselineIndicator: NSProgressIndicator?
    private var ticks = 0
    private var started = 0.0
    private let requestedFrameSize: NSSize?
    private let usesStdin: Bool
    var onReady: (@MainActor () -> Void)?
    var onScrollSample: (@MainActor (UInt64) -> Void)?

    init(frameSize: NSSize? = nil, usesStdin: Bool = true) {
        requestedFrameSize = frameSize; self.usesStdin = usesStdin
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        let environment = ProcessInfo.processInfo.environment
        let document: String
        if environment["DUODESK_WORKLOAD_OWN_TEXT"] == "1" {
            // Authored for this fixture: ordinary static prose, no per-frame marks, no user files.
            let headings = ["工作记录", "阅读笔记", "设计备忘", "项目讨论", "日常整理"]
            let openings = ["今天梳理了手边的工作，将已经完成的内容和仍需处理的事项分开记录。",
                            "这份笔记用于整理思路，保留讨论中的问题、决定以及下一步的安排。",
                            "阅读过程中遇到一些值得继续研究的细节，先写下观察，再核对上下文。",
                            "这一节汇总了当前进展，也列出需要同其他部分衔接的几个方向。"]
            let details = ["把内容按顺序放在一起以后，更容易发现遗漏，后续修改也能保持连贯。",
                           "接下来的工作会围绕实际使用情况展开，重点关注清晰度和稳定性。",
                           "记录保持简洁，并在必要时补充例子，让后来查看的人能够理解背景。",
                           "先确认现有结果，再处理尚未解决的部分，不把推测写成已经验证的结论。",
                           "不同设备上的表现可能有所差别，因此每个结果都需要说明适用范围。"]
            document = (0..<600).map { index in
                "\(headings[index % headings.count]) · 第 \(index + 1) 节\n\(openings[index % openings.count])\n\(details[index % details.count])\n"
            }.joined(separator: "\n")
        } else {
            let paths: [String]
            if let json = environment["DUODESK_WORKLOAD_DOCUMENTS"], let data = json.data(using: .utf8),
               let decoded = try? JSONDecoder().decode([String].self, from: data) {
                paths = decoded
            } else if let path = environment["DUODESK_WORKLOAD_DOCUMENT"] {
                paths = [path]
            } else { paths = [] }
            let documents = paths.compactMap { try? String(contentsOfFile: $0, encoding: .utf8) }
            guard !paths.isEmpty, documents.count == paths.count, documents.allSatisfy({ !$0.isEmpty }) else { exit(1) }
            document = documents.joined(separator: "\n\n")
        }
        let requestedScreen = environment["DUODESK_WORKLOAD_SCREEN_ID"].flatMap(UInt32.init)
        let screen = requestedScreen.flatMap { requested in
            NSScreen.screens.first { screen in
                (screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber)?.uint32Value == requested
            }
        } ?? (requestedScreen == nil ? NSScreen.screens.first : nil)
        guard let screen else { exit(1) }
        let initial = NSSize(width: screen.visibleFrame.width * 0.78, height: screen.visibleFrame.height * 0.78)
        let window = NSWindow(contentRect: NSRect(origin: .zero, size: initial),
                              styleMask: [.titled, .closable, .resizable], backing: .buffered, defer: false)
        if let requestedFrameSize {
            window.setFrame(NSRect(origin: .zero, size: requestedFrameSize), display: false)
            window.hasShadow = false
        }
        let size = window.contentView?.bounds.size ?? initial
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
        text.textStorage?.setAttributedString(NSAttributedString(string: document, attributes: [
            .font: NSFont.systemFont(ofSize: 15), .foregroundColor: NSColor.textColor
        ]))
        scroll.documentView = text
        // An ordinary activity indicator outside the document center causes real frames while the
        // text is still. The audit can then reject codec noise or outside-only changes as motion.
        let indicator = NSProgressIndicator(frame: NSRect(x: 8, y: 8, width: 20, height: 20))
        indicator.style = .spinning; indicator.isIndeterminate = true
        scroll.addSubview(indicator, positioned: .above, relativeTo: nil)
        indicator.startAnimation(nil)
        baselineIndicator = indicator
        window.contentView = scroll
        let visible = screen.visibleFrame
        window.setFrameOrigin(NSPoint(x: visible.midX - window.frame.width / 2,
                                      y: visible.midY - window.frame.height / 2))
        window.makeKeyAndOrderFront(nil); NSApplication.shared.activate()
        text.layoutManager?.ensureLayout(for: text.textContainer!)
        text.sizeToFit()
        self.window = window; self.scroll = scroll; self.text = text
        let number = screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] ?? 0
        let actual = window.screen?.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] ?? 0
        print("NATIVE DOCUMENT READY: requestedScreen=\(number), actualScreen=\(actual), window=\(window.frame), documentHeight=\(text.frame.height), visibleHeight=\(scroll.contentView.bounds.height)")
        onReady?()
        if usesStdin {
            // The capture controller provides one byte only after its stationary baseline.
            DispatchQueue.global(qos: .userInitiated).async { [weak self] in
                let byte = FileHandle.standardInput.readData(ofLength: 1)
                guard !byte.isEmpty else { return }
                DispatchQueue.main.async { self?.startScrolling() }
            }
        }
    }

    func startScrolling() {
        guard let window, let screen = window.screen, let scroll, let text,
              text.frame.height > scroll.contentView.bounds.height + 6_000 else {
            print("NATIVE DOCUMENT ERROR: document is too short or no screen is available")
            NSApplication.shared.terminate(nil); return
        }
        baselineIndicator?.stopAnimation(nil)
        baselineIndicator?.removeFromSuperview()
        baselineIndicator = nil
        started = ProcessInfo.processInfo.systemUptime
        let requestedClock = ProcessInfo.processInfo.environment["DUODESK_WORKLOAD_CLOCK"]
        let clockKind = requestedClock == "window" ? "window" : requestedClock == "timer" ? "timer" : "screen"
        if clockKind == "timer" {
            let source = DispatchSource.makeTimerSource(queue: .main)
            source.schedule(deadline: .now(), repeating: .nanoseconds(8_333_333), leeway: .microseconds(500))
            source.setEventHandler { [weak self] in self?.advanceFrame(intervalMs: 0) }
            source.resume(); timer = source
            print("NATIVE DOCUMENT SCROLLING: clock=timer, screenFPS=\(screen.maximumFramesPerSecond), 1.5 points per timer callback")
            return
        }
        let link = clockKind == "window" ? window.displayLink(target: self, selector: #selector(tick(_:)))
                                          : screen.displayLink(target: self, selector: #selector(tick(_:)))
        link.preferredFrameRateRange = CAFrameRateRange(minimum: 120, maximum: 120, preferred: 120)
        link.add(to: .main, forMode: .common)
        clock = link
        print("NATIVE DOCUMENT SCROLLING: clock=\(clockKind), screenFPS=\(screen.maximumFramesPerSecond), 1.5 points per display callback")
    }

    func stopScrolling() {
        clock?.invalidate(); clock = nil
        timer?.cancel(); timer = nil
    }

    @objc private func tick(_ link: CADisplayLink) {
        advanceFrame(intervalMs: (link.targetTimestamp - link.timestamp) * 1000)
    }

    private func advanceFrame(intervalMs: Double) {
        guard let scroll, let text else { return }
        ticks += 1
        let maximum = max(0, text.bounds.height - scroll.contentView.bounds.height)
        let y = min(maximum, scroll.contentView.bounds.origin.y + 1.5)
        scroll.contentView.scroll(to: NSPoint(x: 0, y: y))
        scroll.reflectScrolledClipView(scroll.contentView)
        onScrollSample?(mach_absolute_time())
        if ticks % 120 == 0 {
            let screen = window?.screen
            let number = screen?.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] ?? 0
            print("NATIVE DOCUMENT: callbacks=\(ticks), elapsed=\(ProcessInfo.processInfo.systemUptime - started), scrollY=\(y), max=\(maximum), screen=\(number), screenFPS=\(screen?.maximumFramesPerSecond ?? 0), intervalMs=\(intervalMs)")
        }
    }
}
