// Copyright 2026 DUO你电脑 contributors. SPDX-License-Identifier: Apache-2.0
// Tests the production identity policy in memory, without configuring any display.
import Foundation

func identity(_ serial: UInt32, vendor: UInt32 = 42, model: UInt32 = 7, builtIn: Bool = false) -> DisplayRestoreIdentity {
    DisplayRestoreIdentity(vendor: vendor, model: model, serial: serial, builtIn: builtIn)
}
let serial = identity(1234), noSerial = identity(0)
let checks: [(String, Bool)] = [
    ("continuously online identical display", serial.permitsRestore(current: serial, wasOffline: false, originalMatches: 1, onlineMatches: 1)),
    ("continuous identity mismatch rejected", !serial.permitsRestore(current: identity(9876), wasOffline: false, originalMatches: 1, onlineMatches: 1)),
    ("offline unique serial match", serial.permitsRestore(current: serial, wasOffline: true, originalMatches: 1, onlineMatches: 1)),
    ("offline missing serial rejected", !noSerial.permitsRestore(current: noSerial, wasOffline: true, originalMatches: 1, onlineMatches: 1)),
    ("offline sentinel serial rejected", !identity(.max).permitsRestore(current: identity(.max), wasOffline: true, originalMatches: 1, onlineMatches: 1)),
    ("offline missing vendor rejected", !identity(1234, vendor: 0).permitsRestore(current: identity(1234, vendor: 0), wasOffline: true, originalMatches: 1, onlineMatches: 1)),
    ("offline different serial rejected", !serial.permitsRestore(current: identity(9876), wasOffline: true, originalMatches: 1, onlineMatches: 1)),
    ("offline duplicate in original inventory rejected", !serial.permitsRestore(current: serial, wasOffline: true, originalMatches: 2, onlineMatches: 1)),
    ("offline duplicate in online inventory rejected", !serial.permitsRestore(current: serial, wasOffline: true, originalMatches: 1, onlineMatches: 2)),
    ("unstable or missing inventory rejected", !serial.permitsRestore(current: serial, wasOffline: true, originalMatches: 1, onlineMatches: 0)),
    ("built-in mismatch rejected", !serial.permitsRestore(current: identity(1234, builtIn: true), wasOffline: true, originalMatches: 1, onlineMatches: 1)),
    ("exact refresh restored", DisplayRestoreIdentity.exactRefreshRestored(current: 170, original: 170)),
    ("fractional refresh change rejected", !DisplayRestoreIdentity.exactRefreshRestored(current: 59.94, original: 60)),
    ("invalid refresh rejected", !DisplayRestoreIdentity.exactRefreshRestored(current: .nan, original: .nan))
]
for (name, pass) in checks { print("\(pass ? "PASS" : "FAIL") \(name)") }
exit(checks.allSatisfy(\.1) ? 0 : 1)
