// Copyright 2026 DUO你电脑 contributors. SPDX-License-Identifier: Apache-2.0
import AppKit
import SystemConfiguration
import SillHostCore

/// Runs only in launchd's root LoginWindow session, using a protected identity copy. The normal
/// user app never runs as root, and the login host exposes only desktop video and input.
@MainActor
final class LoginWindowHost: NSObject, NSApplicationDelegate {
    private var coordinator: StreamCoordinator?
    private var availability: HostAvailability?
    private var activity: NSObjectProtocol?
    private var consoleCheck: Timer?
    private var trustWatch: DispatchSourceFileSystemObject?
    private var serviceConnection: NSXPCConnection?
    private var serviceTimeout: Task<Void, Never>?

    func applicationDidFinishLaunching(_ notification: Notification) {
        guard geteuid() == 0, Self.atLoginWindow else { exit(0) }
        do {
            // Retain the authenticated connection for this host's lifetime. Disabling or stopping
            // the daemon also fences an already running login host and its accepted sessions.
            let connection = NSXPCConnection(machServiceName: BootService.machService, options: .privileged)
            connection.remoteObjectInterface = NSXPCInterface(with: BootServiceProtocol.self)
            connection.setCodeSigningRequirement(try BootService.signingRequirement())
            connection.invalidationHandler = { [weak self] in Task { @MainActor in self?.stop() } }
            connection.interruptionHandler = { [weak self] in Task { @MainActor in self?.stop() } }
            serviceConnection = connection
            connection.resume()
            serviceTimeout = Task { [weak self] in
                do { try await Task.sleep(for: .seconds(8)); self?.stop() } catch { }
            }
            guard let proxy = connection.remoteObjectProxyWithErrorHandler({ [weak self] _ in
                Task { @MainActor in self?.stop() }
            }) as? BootServiceProtocol else { stop(); return }
            proxy.readIdentity { [weak self] data, problem in
                Task { @MainActor in
                    guard let self else { return }
                    self.serviceTimeout?.cancel()
                    guard problem == nil, let data, data.count <= 262_144 else { self.stop(); return }
                    do { try self.start(identity: JSONDecoder().decode(BootIdentity.self, from: data)) }
                    catch { print("Login-window host could not start: \(error)"); self.stop() }
                }
            }
        } catch {
            print("Login-window host could not connect to its service: \(error)")
            stop()
        }
    }

    private func stop() {
        HostShutdown.releaseForQuit(coordinator: coordinator)
        exit(75)
    }

    private func start(identity: BootIdentity) throws {
        guard Self.atLoginWindow else { exit(0) }
        let store = try BootIdentityStore(identity)
        let remote = RemoteAccess(store: store)
        guard remote.identityProblem == nil else { exit(1) }
        var config = HostConfig.standard
        config.requirePairing = true
        config.shareClipboard = false
        config.remoteAccess = false
        config.virtualDisplay = false
        let c = try StreamCoordinator(config: config, appKitLoop: true, remote: remote,
                                      homePairing: true, testHooks: false, loginWindow: true)
        coordinator = c
        c.keepRunningOnListenerFailure()
        HostShutdown.install { [weak self] in self?.coordinator }
        activity = ProcessInfo.processInfo.beginActivity(options: [.userInitiatedAllowingIdleSystemSleep],
                                                        reason: "DUO login-window remote access")
        watchTrust()
        Task {
            await c.start(preselect: nil, promptForPermissions: false)
            availability = HostAvailability { c.recoverNetworkAdvertisement() }
            print("Login-window host ready; pairing required; using the existing physical desktop.")
        }
        let timer = Timer(timeInterval: 1, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated {
                guard !Self.atLoginWindow else { return }
                HostShutdown.releaseForQuit(coordinator: self?.coordinator)
                exit(0)
            }
        }
        consoleCheck = timer
        RunLoop.main.add(timer, forMode: .common)
    }

    private static var atLoginWindow: Bool {
        var uid: uid_t = 0
        let user = SCDynamicStoreCopyConsoleUser(nil, &uid, nil) as String?
        return uid == 0 && (user == nil || user == "loginwindow" || user == "root")
    }

    private func watchTrust() {
        let fd = open(BootService.identityURL.path, O_EVTONLY | O_NOFOLLOW | O_CLOEXEC)
        guard fd >= 0 else { exit(1) }
        let source = DispatchSource.makeFileSystemObjectSource(fileDescriptor: fd, eventMask: [.rename, .delete, .write], queue: .main)
        source.setEventHandler { [weak self] in
            MainActor.assumeIsolated {
                HostShutdown.releaseForQuit(coordinator: self?.coordinator)
                // launchd restarts with the newly committed trust list, fencing every old session.
                exit(75)
            }
        }
        source.setCancelHandler { close(fd) }
        trustWatch = source
        source.resume()
    }
}
