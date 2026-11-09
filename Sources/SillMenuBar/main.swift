import AppKit
import ApplicationServices
import ServiceManagement
import SillHostCore

// Sill.app's executable (Scripts/make-app.sh wraps it into the signed bundle). The AppKit
// lifecycle, like the CLI's --virtual-display branch: NSApplication.run() is what lets this
// process see its virtual display's modes (VirtualDisplay.swift, "Event loop").

// Line-buffered stdout, so a run from Terminal reads live, as the CLI's does.
setvbuf(stdout, nil, _IOLBF, 0)
// A write to a closed pipe (stdout of a Terminal that went away) must not end the host.
signal(SIGPIPE, SIG_IGN)

if CommandLine.arguments.contains("--boot-service") {
    do {
        let service = try BootServiceDaemon(startingService: ())
        service.run()
        withExtendedLifetime(service) { dispatchMain() }
    } catch {
        fputs("DUO boot service: \(error)\n", stderr)
        exit(1)
    }
}

// Rebind the existing user service after relocating/updating a signed app. No host or UI
// starts in this maintenance invocation, so unregistering cannot terminate its own process.
if CommandLine.arguments.contains("--refresh-session-service") {
    let service = SMAppService.agent(plistName: BootService.sessionPlist)
    Task { @MainActor in
        do {
            if service.status != .notRegistered, service.status != .notFound { try await service.unregister() }
            try service.register()
            Swift.print("User service registered from \(Bundle.main.bundlePath)")
            exit(0)
        } catch {
            fputs("User service registration failed: \(error)\n", stderr)
            exit(1)
        }
    }
    dispatchMain()
}

if CommandLine.arguments.contains("--login-window-host") {
    guard geteuid() == 0 else { exit(1) }
    HostLog.shared.configure(keepLines: 500, fileURL: BootService.directory.appendingPathComponent("login-window.log"))
    _ = CGMainDisplayID()
    let app = NSApplication.shared
    app.setActivationPolicy(.prohibited)
    let delegate = MainActor.assumeIsolated { LoginWindowHost() }
    app.delegate = delegate
    withExtendedLifetime(delegate) { app.run() }
    exit(0)
}

if CommandLine.arguments.contains("--session-host"),
   let bundle = Bundle.main.bundleIdentifier,
   NSRunningApplication.runningApplications(withBundleIdentifier: bundle).contains(where: {
       $0.processIdentifier != getpid() && $0.bundleURL?.standardizedFileURL == Bundle.main.bundleURL.standardizedFileURL
   }) {
    // The root LoginWindow host uses its protected copy and may still be handing off. It must
    // not prevent the user's supervised host from starting in the new Aqua session.
    exit(0)
}

// Read the app's own TCC state before initializing logs, identity storage, UI or listeners.
// Launch this bundle through LaunchServices: the SSH/Terminal CLI has separate permissions.
// Preflight never requests a grant or opens a system authorization prompt.
if CommandLine.arguments.contains("--print-permissions") {
    print("Screen capture: \(CGPreflightScreenCaptureAccess() ? "allowed" : "not allowed")")
    print("Input control: \(AXIsProcessTrusted() ? "allowed" : "not allowed")")
    print("Application: \(Bundle.main.bundleIdentifier ?? "unbundled")")
    exit(0)
}

// Before anything prints: the host's lines go to the Log window's ring and the log file too.
HostLog.shared.configure(keepLines: 5_000, fileURL: DebugHooks.logFileURL)

// The CLI's self-tests work here too, so the app's own identity (its TCC grants, its hardened
// runtime) can be checked: `Sill.app/Contents/MacOS/Sill --virtual-display-selftest`.
if CommandLine.arguments.contains("--encoder-selftest") {
    EncoderSelfTest.run()
}
if let menuApp = MenuSelfTest.requested(in: CommandLine.arguments) {
    MenuSelfTest.run(app: menuApp)   // `Sill --menu-selftest[=APP]`: read-only, as the CLI's
}
// CoreGraphics must be initialized on the main thread before ScreenCaptureKit touches it.
_ = CGMainDisplayID()
if CommandLine.arguments.contains("--virtual-display-selftest") {
    VirtualDisplaySelfTest.run()
}

let app = NSApplication.shared
// The bundle says LSUIElement; the bare .build/release/SillMenuBar has no Info.plist to say it.
app.setActivationPolicy(.accessory)
// NSApplication.delegate is weak: a global keeps the delegate alive for the process.
let delegate = MainActor.assumeIsolated { AppDelegate() }
app.delegate = delegate
MainActor.assumeIsolated { app.mainMenu = MainMenu.make() }
app.run()
