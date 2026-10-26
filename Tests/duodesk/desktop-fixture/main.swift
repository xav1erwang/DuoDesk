// Disposable AppKit surface for real desktop capture/input acceptance. No global event taps.
import AppKit
import QuartzCore

setbuf(stdout, nil)
struct FixtureEvent: Codable, Sendable {
    let kind: String
    let keyCode: Int
    let characters: String
    let flags: UInt
    let eventUptime: Double
    let handledUptime: Double
    let handledUnix: Double
    let eventDispatchDelayMs: Double
}
final class Fixture: NSView {
    let marker = CALayer()
    let markerRing = CALayer()
    let stripe = CALayer()
    var events: [FixtureEvent] = []
    private let eventWriter = DispatchQueue(label: "duodesk.fixture.events", qos: .utility)
    var displayLink: CADisplayLink?
    var tickCount = 0
    var tickStart = ProcessInfo.processInfo.systemUptime
    var metal: MetalMotionView?
    var imeText: IMETextView?
    var imeMarker: IMEFixtureMarker?
    let serverAnimation = ProcessInfo.processInfo.environment["DUODESK_FIXTURE_SERVER_ANIMATION"] == "1"
    func startClock() {
        if metal != nil || serverAnimation { return }
        let link = self.displayLink(target: self, selector: #selector(tick(_:)))
        link.preferredFrameRateRange = CAFrameRateRange(minimum: 120, maximum: 120, preferred: 120)
        link.add(to: .main, forMode: .common)
        displayLink = link
    }
    @objc func tick(_ sender: CADisplayLink) {
        tickCount += 1
        CATransaction.begin(); CATransaction.setDisableActions(true)
        stripe.position.x = CGFloat(tickCount % 240) / 240 * bounds.width
        CATransaction.commit()
        CATransaction.flush()
        if tickCount % 120 == 0 { print("Fixture display ticks=\(tickCount), elapsed=\(ProcessInfo.processInfo.systemUptime - tickStart)") }
    }
    override var acceptsFirstResponder: Bool { true }
    override init(frame: NSRect) {
        super.init(frame: frame)
        wantsLayer = true
        layer?.backgroundColor = NSColor(calibratedRed: 0.05, green: 0.12, blue: 0.22, alpha: 1).cgColor
        stripe.backgroundColor = NSColor.systemCyan.cgColor
        marker.backgroundColor = NSColor(white: 0.1, alpha: 1).cgColor
        markerRing.backgroundColor = NSColor(calibratedRed: 0, green: 1, blue: 0, alpha: 1).cgColor
        layer?.addSublayer(stripe); layer?.addSublayer(markerRing); layer?.addSublayer(marker)
        if ProcessInfo.processInfo.environment["DUODESK_FIXTURE_METAL"] == "1", let surface = try? MetalMotionView(motionFrame: bounds) {
            metal = surface; addSubview(surface)
            markerRing.zPosition = 100; marker.zPosition = 101
        }
        if let text = IMETextView.makeIfRequested() {
            imeText = text; addSubview(text)
            let overlay = IMEFixtureMarker(frame: bounds)
            overlay.wantsLayer = true
            imeMarker = overlay; addSubview(overlay, positioned: .above, relativeTo: nil)
            markerRing.isHidden = true; marker.isHidden = true
            text.onActualClick = { [weak overlay] in overlay?.clicked = true }
        }
    }
    required init?(coder: NSCoder) { fatalError() }
    override func layout() {
        super.layout()
        metal?.frame = bounds
        imeText?.frame = NSRect(x: 30, y: 35, width: max(100, bounds.width - 60), height: max(40, bounds.height * 0.18))
        imeMarker?.frame = bounds
        imeMarker?.needsDisplay = true
        CATransaction.begin(); CATransaction.setDisableActions(true)
        markerRing.frame = NSRect(x: bounds.midX - 110, y: bounds.midY - 110, width: 220, height: 220)
        marker.frame = NSRect(x: bounds.midX - 55, y: bounds.midY - 55, width: 110, height: 110)
        stripe.frame = NSRect(x: 0, y: 0, width: 16, height: bounds.height)
        CATransaction.commit()
        if serverAnimation {
            let motion = CABasicAnimation(keyPath: "position.x")
            motion.fromValue = 0; motion.toValue = bounds.width
            motion.duration = 2; motion.repeatCount = .infinity
            motion.preferredFrameRateRange = CAFrameRateRange(minimum: 120, maximum: 120, preferred: 120)
            stripe.add(motion, forKey: "qa.motion")
            print("Fixture server animation requested at 120 FPS")
        }
    }
    override func draw(_ dirtyRect: NSRect) {
        let style: [NSAttributedString.Key: Any] = [.font: NSFont.monospacedSystemFont(ofSize: 22, weight: .semibold), .foregroundColor: NSColor.white]
        for (text, point) in [("TOP LEFT", NSPoint(x: 20, y: bounds.height - 45)),
                              ("TOP RIGHT", NSPoint(x: bounds.width - 160, y: bounds.height - 45)),
                              ("BOTTOM LEFT", NSPoint(x: 20, y: 20)), ("BOTTOM RIGHT", NSPoint(x: bounds.width - 200, y: 20))] {
            (text as NSString).draw(at: point, withAttributes: style)
        }
    }
    func record(_ kind: String, _ event: NSEvent) {
        let keyEvent = event.type == .keyDown || event.type == .keyUp
        let code = keyEvent ? Int(event.keyCode) : -1
        let handledUptime = ProcessInfo.processInfo.systemUptime
        events.append(FixtureEvent(kind: kind, keyCode: code, characters: keyEvent ? event.characters ?? "" : "",
            flags: event.modifierFlags.rawValue, eventUptime: event.timestamp, handledUptime: handledUptime,
            handledUnix: Date().timeIntervalSince1970, eventDispatchDelayMs: (handledUptime - event.timestamp) * 1000))
        if let path = CommandLine.arguments.dropFirst().first {
            let snapshot = events
            // The timing observer must not hold the render thread on JSON encoding or disk I/O.
            eventWriter.async {
                if let data = try? JSONEncoder().encode(snapshot) {
                    try? data.write(to: URL(fileURLWithPath: path), options: .atomic)
                }
            }
        }
        print("Fixture \(kind) keyCode=\(code)")
    }
    override func mouseDown(with event: NSEvent) {
        if let imeText { imeText.focusForTest() } else { window?.makeFirstResponder(self) }
        CATransaction.begin(); CATransaction.setDisableActions(true)
        marker.backgroundColor = NSColor.white.cgColor; CATransaction.commit()
        imeMarker?.clicked = true
        record("mouseDown", event)
    }
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
    override func mouseUp(with event: NSEvent) { record("mouseUp", event) }
    override func keyDown(with event: NSEvent) { record("keyDown", event) }
    override func keyUp(with event: NSEvent) { record("keyUp", event) }
}
let app = NSApplication.shared
let activity = ProcessInfo.processInfo.beginActivity(options: [.userInitiated, .latencyCritical], reason: "Native desktop capture acceptance")
app.setActivationPolicy(.regular)
let menu = NSMenu()
let applicationItem = NSMenuItem()
let applicationMenu = NSMenu()
applicationMenu.addItem(withTitle: "Quit Desktop Fixture", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
applicationItem.submenu = applicationMenu; menu.addItem(applicationItem); app.mainMenu = menu
let view = Fixture(frame: NSRect(x: 0, y: 0, width: 800, height: 500))
let unobscured = ProcessInfo.processInfo.environment["DUODESK_FIXTURE_UNOBSCURED"] == "1"
if unobscured { view.marker.isHidden = true; view.markerRing.isHidden = true; view.stripe.isHidden = true }
let window = NSWindow(contentRect: view.frame, styleMask: unobscured ? [.borderless] : [.titled, .closable], backing: .buffered, defer: false)
window.title = "DUO Desktop Acceptance Fixture"; window.contentView = view
window.isRestorable = false
window.level = unobscured ? .screenSaver : .modalPanel
func fit() {
    guard let screen = NSScreen.screens.first else { return }
    window.setFrame(unobscured ? screen.frame : screen.visibleFrame.insetBy(dx: 20, dy: 20), display: true)
    // Manual subview frames and marker layers must be recomputed after a display resize,
    // including when NSTextView changes AppKit's automatic layout scheduling.
    view.needsLayout = true
    view.layoutSubtreeIfNeeded()
    view.imeText?.geometryChanged()
    if view.imeText == nil || window.firstResponder !== view.imeText { window.makeFirstResponder(view) }
    print("Fixture desktop bounds \(screen.frame), window \(window.frame), screen=\(screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] ?? 0), maxFPS=\(screen.maximumFramesPerSecond)")
    if let marker = view.imeMarker {
        print("IME fixture content \(view.bounds), marker view \(marker.frame), text view \(String(describing: view.imeText?.frame))")
    }
}
let observer = NotificationCenter.default.addObserver(forName: NSApplication.didChangeScreenParametersNotification, object: nil, queue: .main) { _ in
    DispatchQueue.main.asyncAfter(deadline: .now() + 0.4) { fit() }
}
fit(); view.startClock(); window.makeKeyAndOrderFront(nil); app.activate()
app.run()
