// Real desktop acceptance with a separate application owning the visible windows.
import AppKit
import CoreGraphics
import Foundation
import ScreenCaptureKit
import StreamProtocol

setbuf(stdout, nil)
let app = NSApplication.shared
app.setActivationPolicy(.prohibited)
let output = URL(fileURLWithPath: CommandLine.arguments[2], isDirectory: true)
let target = CommandLine.arguments.first(where: { $0.hasPrefix("--display=") }).flatMap { UInt32($0.dropFirst("--display=".count)) } ?? CGMainDisplayID()
let full = CommandLine.arguments.contains("--fullscreen")
struct WindowState: Codable {
    var id: Int; var screen: UInt32; var frame: [Double]?; var active: Bool; var fullscreen: Bool
    var rect: CGRect? { frame.map { CGRect(x: $0[0], y: $0[1], width: $0[2], height: $0[3]) } }
}
struct State: Codable { var ready: Bool; var selected: WindowState; var other: WindowState? }
func state() -> State? { (try? Data(contentsOf: output.appendingPathComponent("fixture.json"))).flatMap { try? JSONDecoder().decode(State.self, from: $0) } }
func inventory() -> [String] {
    var count: UInt32 = 0; CGGetOnlineDisplayList(0, nil, &count)
    var ids = [CGDirectDisplayID](repeating: 0, count: Int(count)); CGGetOnlineDisplayList(count, &ids, &count)
    return ids.sorted().map { id in
        let mode = CGDisplayCopyDisplayMode(id)
        return "\(id):\(mode?.ioDisplayModeID ?? 0):\(mode?.pixelWidth ?? 0)x\(mode?.pixelHeight ?? 0):\(mode?.refreshRate ?? 0):\(CGDisplayBounds(id)):\(CGDisplayMirrorsDisplay(id)):\(id == CGMainDisplayID())"
    }
}
func failure(_ value: String) -> NSError { NSError(domain: "DUO live display acceptance", code: 1, userInfo: [NSLocalizedDescriptionKey: value]) }
@MainActor func wait(_ check: () -> Bool) async throws {
    for _ in 0..<100 { if check() { return }; try await Task.sleep(for: .milliseconds(50)) }
    throw failure("fixture state did not settle")
}

Task { @MainActor in
    let before = inventory(), originalMain = CGMainDisplayID()
    let otherTarget = NSScreen.screens.compactMap { ($0.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber)?.uint32Value }.first(where: { $0 != target })!
    let otherOrigin = CGDisplayBounds(otherTarget).origin
    let desktop = DuoDesktopDisplay()
    desktop.selectedDisplayID = target
    let helper = Process()
    helper.executableURL = URL(fileURLWithPath: CommandLine.arguments[1])
    helper.environment = ProcessInfo.processInfo.environment.merging([
        "DUO_FIXTURE_DISPLAY": String(target), "DUO_FIXTURE_OTHER": String(otherTarget), "DUO_FIXTURE_STATE": output.appendingPathComponent("fixture.json").path,
        "DUO_FIXTURE_FULLSCREEN": full ? "1" : "0"
    ]) { _, new in new }
    helper.standardOutput = FileHandle.nullDevice; helper.standardError = FileHandle.nullDevice
    var records: [[String: Any]] = [], problem: String?
    do {
        try FileManager.default.createDirectory(at: output, withIntermediateDirectories: true)
        try helper.run()
        try await wait { state()?.ready == true && state()?.selected.rect != nil }
        try await Task.sleep(for: .milliseconds(650))
        guard let baseline = state(), let originalFrame = baseline.selected.rect,
              CGDisplayBounds(target).intersection(originalFrame).size == originalFrame.size else { throw failure("selected fixture is not on the requested physical display") }
        print("External fixture baseline:", originalFrame, "screen", baseline.selected.screen)
        var firstCaptureID: UInt32?
        for (label, wanted) in [("upper", DuoDesktopResolution(width: 2007, height: 1427)),
                                ("full", .init(width: 2853, height: 2007)), ("upper-again", .init(width: 2007, height: 1427))] {
            let prepared = try await desktop.prepare(wanted, fps: target == originalMain ? 120 : 60)
            if let firstCaptureID { guard firstCaptureID == prepared.display.displayID else { throw failure("fold recreated the desktop") } }
            else { firstCaptureID = prepared.display.displayID }
            guard CGDisplayMirrorsDisplay(target) == prepared.display.displayID,
                  CGMainDisplayID() == (target == originalMain ? prepared.display.displayID : originalMain),
                  CGDisplayMirrorsDisplay(otherTarget) == 0,
                  CGDisplayBounds(otherTarget).origin == otherOrigin else { throw failure("the physical primary moved to another screen") }
            try await wait {
                guard let current = state(), let frame = current.selected.rect else { return false }
                if let old = baseline.other, old.active, old.rect != nil {
                    guard let other = current.other, other.active, other.rect != nil else { return false }
                }
                return current.selected.active && current.selected.fullscreen == full
                    && prepared.bounds.intersection(frame).size == frame.size
            }
            guard let current = state(), let frame = current.selected.rect else { throw failure("selected application disappeared") }
            if let old = baseline.other, old.active, let oldFrame = old.rect {
                guard let other = current.other, other.active, let otherFrame = other.rect else { throw failure("other desktop window disappeared") }
                let origin = CGDisplayBounds(otherTarget).origin
                guard other.screen == otherTarget, otherFrame.size == oldFrame.size,
                      otherFrame.origin.x - origin.x == oldFrame.origin.x - otherOrigin.x,
                      otherFrame.origin.y - origin.y == oldFrame.origin.y - otherOrigin.y else { throw failure("another display's application moved") }
            }
            let config = SCStreamConfiguration(); config.width = prepared.canvasWidth; config.height = prepared.canvasHeight
            let image = try await SCScreenshotManager.captureImage(contentFilter: SCContentFilter(display: prepared.display, excludingWindows: []), configuration: config)
            guard image.width == config.width && image.height == config.height else { throw failure("preview dimensions differ from the requested display") }
            records.append(["stage": label, "captureID": prepared.display.displayID, "main": CGMainDisplayID(),
                            "canvas": [prepared.canvasWidth, prepared.canvasHeight], "window": [frame.minX, frame.minY, frame.width, frame.height],
                            "preview": [image.width, image.height], "fullscreen": full])
            print("PASS external selected desktop:", label, prepared.canvasWidth, prepared.canvasHeight, frame)
        }
        guard desktop.restore() else { throw failure("display restoration pending") }
        try await desktop.waitForRetiredVirtualDisplay()
        try await wait { state()?.selected.screen == target && state()?.selected.rect == originalFrame }
        guard inventory() == before, CGMainDisplayID() == originalMain else { throw failure("display configuration did not restore") }
        print("PASS external desktop restoration: original screen, frame, primary, modes and layout")
    } catch { problem = error.localizedDescription; print("FAIL:", error.localizedDescription) }
    _ = desktop.restore()
    try? await desktop.waitForRetiredVirtualDisplay()
    let restored = inventory() == before
    if helper.isRunning { helper.terminate(); helper.waitUntilExit() }
    let report: [String: Any] = ["passed": problem == nil && restored, "error": problem ?? "", "displayConfigurationRestored": restored,
                                "separateWindowProcess": true, "fullscreen": full, "stages": records,
                                "before": before, "after": inventory(), "inputPosted": false]
    if let data = try? JSONSerialization.data(withJSONObject: report, options: [.prettyPrinted, .sortedKeys]) { try? data.write(to: output.appendingPathComponent("result.json")) }
    exit(problem == nil && restored ? 0 : 1)
}
app.run()
