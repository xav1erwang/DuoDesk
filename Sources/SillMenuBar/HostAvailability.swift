// Copyright 2026 DUO你电脑 contributors. SPDX-License-Identifier: Apache-2.0
import AppKit
import Network

/// Login can precede Wi-Fi readiness. Recover on network changes and system wake, with a
/// bounded second attempt after DHCP/Bonjour have settled. No recurring idle polling.
@MainActor
final class HostAvailability {
    private let monitor = NWPathMonitor()
    private var observers: [NSObjectProtocol] = []
    private var recovery: Task<Void, Never>?
    private let refresh: @MainActor () -> Void

    init(refresh: @escaping @MainActor () -> Void) {
        self.refresh = refresh
        monitor.pathUpdateHandler = { [weak self] path in
            guard path.status == .satisfied else { return }
            Task { @MainActor in self?.schedule() }
        }
        monitor.start(queue: DispatchQueue(label: "duodesk.availability"))
        let center = NSWorkspace.shared.notificationCenter
        for name in [NSWorkspace.didWakeNotification, NSWorkspace.screensDidWakeNotification] {
            observers.append(center.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in
                Task { @MainActor in self?.schedule() }
            })
        }
    }

    private func schedule() {
        recovery?.cancel()
        recovery = Task { [weak self] in
            do {
                try await Task.sleep(for: .seconds(2))
                self?.refresh()
                try await Task.sleep(for: .seconds(10))
                self?.refresh()
            } catch { /* A newer network or wake event owns recovery. */ }
        }
    }

    deinit {
        monitor.cancel()
        recovery?.cancel()
        for observer in observers { NSWorkspace.shared.notificationCenter.removeObserver(observer) }
    }
}
