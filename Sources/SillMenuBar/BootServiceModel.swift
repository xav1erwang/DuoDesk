// Copyright 2026 DUO你电脑 contributors. SPDX-License-Identifier: Apache-2.0
import Foundation
import Observation
import ServiceManagement
import SillHostCore

@MainActor @Observable
final class BootServiceModel {
    private(set) var status: SMAppService.Status = .notRegistered
    private(set) var busy = false
    private(set) var ready = false
    private(set) var error: String?
    let available = Bundle.main.bundleURL.pathExtension == "app" && (try? BootService.signingRequirement()) != nil
    @ObservationIgnored var identity: (() throws -> BootIdentity)?
    @ObservationIgnored private var activation: Task<Void, Never>?
    private var daemon: SMAppService { .daemon(plistName: BootService.daemonPlist) }
    private var session: SMAppService { .agent(plistName: BootService.sessionPlist) }

    var isOn: Bool { status == .enabled || status == .requiresApproval }
    var needsApproval: Bool { status == .requiresApproval }

    init() { refresh() }

    /// Availability after startup is part of the app, rather than a user preference.
    func start() {
        guard available else { return }
        refresh()
        if status == .notRegistered || status == .notFound { set(true) }
    }

    func refresh() {
        guard available else { return }
        let previous = status
        status = daemon.status
        if previous == .requiresApproval, status == .enabled { error = nil }
        if status != .enabled { ready = false }
        if status == .enabled, !ready, !busy, identity != nil, error == nil { activate() }
    }

    func set(_ on: Bool) {
        guard available, !busy else { return }
        error = nil
        if on {
            do {
                // macOS owns administrator authentication and the background-item approval UI.
                try daemon.register()
                status = daemon.status
                if needsApproval { SMAppService.openSystemSettingsLoginItems() }
                else { activate() }
            } catch {
                // register() can report EPERM while macOS has already registered the service
                // pending administrator approval. Show that actionable state, not a stale error.
                status = daemon.status
                if needsApproval {
                    self.error = nil
                    SMAppService.openSystemSettingsLoginItems()
                } else { self.error = error.localizedDescription }
                refresh()
            }
        } else {
            let running = status == .enabled
            busy = true
            activation = Task {
                do {
                    // Keep the user's login keychain current before removing the system copy.
                    if running { try await Task.detached { try BootServiceRPC.deactivate() }.value }
                    if session.status != .notRegistered, session.status != .notFound { try await session.unregister() }
                    try await daemon.unregister()
                    ready = false
                } catch { self.error = "\(error)" }
                busy = false
                refresh()
            }
        }
    }

    private func activate() {
        guard !busy, let identity else { return }
        do {
            let snapshot = try identity()
            busy = true
            activation = Task {
                do {
                    try await Task.detached { try BootServiceRPC.configure(snapshot) }.value
                    // Pairing edits run on this actor. Read the current list after installation,
                    // and commit it synchronously so an older bootstrap snapshot cannot undo one.
                    try BootServiceRPC.updateTrust(identity().paired)
                    try session.register()
                    // The supervised session agent now replaces the ordinary login item.
                    if SMAppService.mainApp.status == .enabled { try await SMAppService.mainApp.unregister() }
                    ready = true
                } catch { self.error = "\(error)" }
                busy = false
                status = daemon.status
            }
        } catch { self.error = "\(error)" }
    }

    func retry() { error = nil; start() }
    func openSystemSettings() { SMAppService.openSystemSettingsLoginItems() }
}
