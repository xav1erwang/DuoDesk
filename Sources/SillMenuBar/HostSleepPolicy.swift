// Copyright 2026 DUO你电脑 contributors. SPDX-License-Identifier: Apache-2.0
import Foundation

enum HostSleepPolicy {
    enum Hold { case none, available, connected, remote }

    static func hold(keepAvailable: Bool, running: Bool, synthetic: Bool, devices: Int, remote: Int) -> Hold {
        let available = keepAvailable && running && !synthetic
        if remote > 0 || (available && devices > 0) { return .remote }
        if devices > 0 { return .connected }
        return available ? .available : .none
    }

    static func options(for hold: Hold) -> ProcessInfo.ActivityOptions? {
        switch hold {
        case .none: return nil
        case .available: return [.userInitiated]
        case .connected: return [.userInitiatedAllowingIdleSystemSleep, .latencyCritical]
        case .remote: return [.userInitiated, .latencyCritical]
        }
    }
}
