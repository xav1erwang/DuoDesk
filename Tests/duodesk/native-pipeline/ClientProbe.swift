// The production client, decoder, presentation and input path talking to a real capture host.
// Only the test entry point supplies posture measurements; it cannot ship in the product target.
import UIKit
import Network
import AVFoundation
import StreamProtocol

enum PipelineFailure: Error { case failed(String) }
@main final class ProbeApp: UIResponder, UIApplicationDelegate {
    func application(_ application: UIApplication, configurationForConnecting session: UISceneSession,
                     options: UIScene.ConnectionOptions) -> UISceneConfiguration {
        let config = UISceneConfiguration(name: "Native pipeline", sessionRole: session.role)
        config.delegateClass = ProbeScene.self; return config
    }
}
final class ProbeScene: UIResponder, UIWindowSceneDelegate {
    var window: UIWindow?
    let client = StreamClient()
    var stages: [[String: Any]] = []
    var initialMain: UInt32 = 0
    var fixtureCache: [String: Any]?
    var fixtureFeed: Task<Void, Never>?
    func scene(_ scene: UIScene, willConnectTo session: UISceneSession, options: UIScene.ConnectionOptions) {
        guard let scene = scene as? UIWindowScene else { return }
        let window = UIWindow(windowScene: scene), controller = UIViewController()
        window.rootViewController = controller
        let video = client.displayView; video.frame = CGRect(x: 0, y: 0, width: 360, height: 250)
        controller.view.addSubview(video); window.makeKeyAndVisible(); self.window = window
        Task { @MainActor in await run() }
    }
    @MainActor func wait(_ name: String, seconds: Int = 20, _ check: () -> Bool) async throws {
        let limit = ContinuousClock.now + .seconds(seconds)
        while !check() {
            guard ContinuousClock.now < limit else { throw PipelineFailure.failed("\(name): \(client.status), issue \(client.nativeDesktopIssue ?? "none"), video \(client.videoSize)") }
            try await Task.sleep(for: .milliseconds(30))
        }
    }
    func fixture() -> [String: Any]? {
        if let fixtureCache { return fixtureCache }
        guard let path = UserDefaults.standard.string(forKey: "PipelineFixture"),
              let data = try? Data(contentsOf: URL(fileURLWithPath: path)) else { return nil }
        return (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
    }
    func screen(_ id: UInt32) -> [String: Any]? {
        (fixture()?["screens"] as? [[String: Any]])?.first { ($0["id"] as? NSNumber)?.uint32Value == id }
    }
    func configure(_ label: String) {
        // Stop the cover display of this QA device from replacing controlled inner-screen metrics.
        client.displayView.onNativeDisplaySize = nil
        let landscape = label != "upper"
        let size = landscape ? CGSize(width: 951, height: 669) : CGSize(width: 669, height: 951)
        client.nativeDisplayMetrics = .init(pixels: CGSize(width: 1878, height: 2670), windowSize: size,
                                           renderPixels: CGSize(width: 2007, height: 2853))
        client.updateDuoNativeResolution(innerDisplay: true, frame: CGRect(origin: .zero, size: size),
            fold: landscape ? CGRect(x: 455.5, y: 0, width: 40, height: 669) : CGRect(x: 0, y: 455.5, width: 669, height: 40),
            fillDisplay: label == "full")
        let panel = label == "upper" ? CGSize(width: 669, height: 475.5)
            : label == "full" ? size : CGSize(width: 935, height: 573)
        client.displayView.frame = CGRect(origin: .zero, size: CGSize(width: 360, height: 360 * panel.height / panel.width))
        client.sendViewport(Viewport(width: panel.width, height: panel.height, scale: nil, fps: 60))
    }
    @MainActor func input(on id: UInt32, label: String) async throws {
        try await wait("fixture matches the current native canvas", seconds: 5) {
            guard let bounds = self.screen(id)?["bounds"] as? [Double], let size = self.client.nativeDesktopResolution else { return false }
            return Int(bounds[2] * 2) == size.encodedWidth && Int(bounds[3] * 2) == size.encodedHeight
                && self.screen(id)?["topmost"] as? Bool == true
        }
        guard let before = screen(id), let point = before["point"] as? [Double], let bounds = before["bounds"] as? [Double],
              before["visible"] as? Bool == true, before["topmost"] as? Bool == true,
              let size = client.nativeDesktopResolution else { throw PipelineFailure.failed("owned input fixture unavailable") }
        let x = (point[0] - bounds[0]) / bounds[2] * Double(size.width) / Double(size.encodedWidth)
        let y = (point[1] - bounds[1]) / bounds[3] * Double(size.height) / Double(size.encodedHeight)
        guard (0.05...0.95).contains(x), (0.05...0.95).contains(y) else { throw PipelineFailure.failed("owned input target outside capture") }
        print("INPUT TARGET:", id, before, "normalized", x, y)
        let downs = (before["downs"] as? Int) ?? 0
        client.sendInput(.pointer(.move, x: x, y: y))
        client.sendInput(.pointer(.leftDown, x: x, y: y)); client.sendInput(.pointer(.leftUp, x: x, y: y))
        try await wait("pointer reached chosen fixture", seconds: 5) { (self.screen(id)?["downs"] as? Int) == downs + 1 && self.screen(id)?["focused"] as? Bool == true }
        guard let landed = screen(id)?["lastPoint"] as? [Double], abs(landed[0] - 180) < 2, abs(landed[1] - 105) < 2 else {
            throw PipelineFailure.failed("pointer coordinates did not reach the displayed field")
        }
        let nonce = "DUO\(id)\(label)"
        client.sendInput(.text(nonce))
        try await wait("text reached chosen fixture", seconds: 5) { (self.screen(id)?["text"] as? String)?.contains(nonce) == true }
    }
    @MainActor func stage(_ id: UInt32, _ label: String) async throws {
        configure(label)
        if client.selectedDisplayID != id || client.awaitingDisplaySelection { client.chooseDisplay(id) }
        let wanted = label == "upper" ? DuoDesktopResolution(width: 2007, height: 1427)
            : label == "full" ? DuoDesktopResolution(width: 2853, height: 2007) : DuoDesktopResolution(width: 2805, height: 1719)
        try await wait("native \(label) display \(id)") {
            self.client.selectedDisplayID == id
                && self.client.nativeDesktopResolution == wanted && self.client.hasNativeDesktopVideo
        }
        try await input(on: id, label: label)
        if id != initialMain, (fixture()?["main"] as? NSNumber)?.uint32Value != initialMain { throw PipelineFailure.failed("choosing secondary changed the physical primary") }
        let panel = client.displayView.bounds
        let fit = AVMakeRect(aspectRatio: client.videoSize, insideRect: panel)
        guard abs(fit.width - panel.width) <= 1 && abs(fit.height - panel.height) <= 1 else { throw PipelineFailure.failed("native frame does not fill video panel") }
        stages.append(["display": id, "stage": label, "video": [client.videoSize.width, client.videoSize.height],
                       "currentImage": client.displayView.hasCurrentImage, "pointerAndText": true])
        print("PASS PIPELINE: \(id) \(label) \(client.videoSize), decoded, presented, pointer/text")
    }
    @MainActor func run() async {
        var problem: String?
        do {
            if let text = UserDefaults.standard.string(forKey: "PipelineFixtureURL"), let url = URL(string: text) {
                fixtureFeed = Task { @MainActor in
                    while !Task.isCancelled {
                        if let (data, _) = try? await URLSession.shared.data(from: url),
                           let record = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] { self.fixtureCache = record }
                        try? await Task.sleep(for: .milliseconds(40))
                    }
                }
            }
            try await wait("owned fixture before connection", seconds: 5) { self.fixture() != nil }
            initialMain = (fixture()!["main"] as! NSNumber).uint32Value
            if let name = UserDefaults.standard.string(forKey: "PipelineName") {
                client.startBrowsing()
                try await wait("paired Bonjour host") { self.client.macs.contains { $0.name == name && $0.savedID != nil && $0.route == .network } }
                guard let mac = client.macs.first(where: { $0.name == name && $0.savedID != nil && $0.route == .network }) else { throw PipelineFailure.failed("paired host missing") }
                client.connect(to: mac)
            } else {
                let port = UserDefaults.standard.integer(forKey: "PipelinePort")
                guard port > 0 else { throw PipelineFailure.failed("missing loopback port") }
                _ = client.connect(to: .hostPort(host: .ipv4(.loopback), port: .init(rawValue: UInt16(port))!), name: "Owned native host", trust: .plain, preferQUIC: false)
            }
            try await wait("catalog and initial chooser") { self.client.connected && self.client.awaitingDisplaySelection && self.client.remoteDisplays.count == 2 }
            guard client.active == .none && !client.displayView.hasCurrentImage else { throw PipelineFailure.failed("capture started before choice") }
            guard client.hostResizableMirror else { throw PipelineFailure.failed("host still bypasses native sizing") }
            guard let secondary = client.remoteDisplays.first(where: { !$0.isMain })?.id else { throw PipelineFailure.failed("secondary missing") }
            for id in [initialMain, secondary] {
                for label in ["upper", "landscape", "full", "upper"] { try await stage(id, label) }
            }
            client.chooseDisplay(initialMain); client.chooseDisplay(secondary); client.chooseDisplay(initialMain)
            try await wait("rapid choices settled") { self.client.selectedDisplayID == self.initialMain && self.client.hasNativeDesktopVideo }
            client.chooseDisplay(UInt32.max)
            guard client.selectedDisplayID == initialMain else { throw PipelineFailure.failed("invalid source selected") }
        } catch { problem = String(describing: error); print("FAIL PIPELINE:", error) }
        client.disconnect()
        fixtureFeed?.cancel()
        try? await Task.sleep(for: .seconds(2))
        let result: [String: Any] = ["passed": problem == nil, "error": problem ?? "", "stages": stages,
            "realScreenCapture": true, "realHostEncoder": true, "productionClient": true,
            "controlledPostureMeasurements": true, "simulatorSoftwareDecode": HardwareHEVCDecoder.simulatorSoftwareEnabled]
        let path = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0].appendingPathComponent("pipeline-result.json")
        try? JSONSerialization.data(withJSONObject: result, options: [.prettyPrinted, .sortedKeys]).write(to: path)
        print("PIPELINE COMPLETE:", path.path, problem == nil)
        exit(problem == nil ? 0 : 1)
    }
}
