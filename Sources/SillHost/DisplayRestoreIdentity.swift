// Copyright 2026 DUO你电脑 contributors. SPDX-License-Identifier: Apache-2.0
import Foundation

/// The identity CoreGraphics reported for one saved display. Display IDs alone may be reused.
struct DisplayRestoreIdentity: Hashable {
    let vendor: UInt32
    let model: UInt32
    let serial: UInt32
    let builtIn: Bool

    /// After an observed disconnect, do not guess that a same-ID screen is the original. A
    /// nonzero, encoded serial and a unique match in both inventories are required. This does not
    /// establish identity across an unobserved disconnect or detect a forged duplicate serial.
    func permitsRestore(current: DisplayRestoreIdentity, wasOffline: Bool,
                        originalMatches: Int, onlineMatches: Int) -> Bool {
        guard self == current else { return false }
        guard wasOffline else { return true }
        return vendor != 0 && model != 0 && serial != 0 && serial != UInt32.max
            && originalMatches == 1 && onlineMatches == 1
    }

    static func exactRefreshRestored(current: Double, original: Double) -> Bool {
        current.isFinite && original.isFinite && current == original
    }
}
