// Copyright 2026 DUO你电脑 contributors. SPDX-License-Identifier: Apache-2.0
import Foundation
import StreamProtocol

/// The host has one shared video pipeline. Extension is accepted only for its sole connected
/// device, and a suspended source switch may proceed only for the exact request it started with.
enum ExtendedDesktopPolicy {
    nonisolated static func permits(available: Bool, connectedCount: Int, registered: Bool) -> Bool {
        available && connectedCount == 1 && registered
    }

    nonisolated static func isCurrent(capturedID: UUID?, capturedSize: DuoDesktopResolution?,
                                     currentIDs: [UUID], currentSize: DuoDesktopResolution?) -> Bool {
        guard capturedSize == currentSize else { return false }
        if let capturedID { return currentIDs.count == 1 && currentIDs[0] == capturedID }
        return currentIDs.isEmpty
    }
}
