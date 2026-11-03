import AppKit
import Foundation
import SillHostCore

setvbuf(stdout, nil, _IOLBF, 0)
let app = NSApplication.shared
app.setActivationPolicy(.prohibited)
var coordinator: StreamCoordinator?
HostShutdown.install { coordinator }
Task { @MainActor in
    do {
        var config = HostConfig.standard
        config.shareClipboard = false
        config.prioritizeSpeed = true
        let host = try StreamCoordinator(config: config, appKitLoop: true, testHooks: true, advertise: false)
        coordinator = host
        await host.start(preselect: nil, promptForPermissions: false)
        print("NATIVE PIPELINE HOST READY: real screen, real encoder, loopback only")
    } catch {
        print("NATIVE PIPELINE HOST FAILED:", error)
        exit(1)
    }
}
app.run()
