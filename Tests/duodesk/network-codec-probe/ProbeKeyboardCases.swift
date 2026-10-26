// Copyright 2026 DUO你电脑 contributors. SPDX-License-Identifier: Apache-2.0
// Real input evidence from the owned desktop fixture, using the client keyboard's events.
import Carbon
import Foundation
import StreamProtocol

enum ProbeKeyboardCases {
    struct Case {
        let name: String
        let usage: UInt16
        let macKeyCode: Int
        let modifiers: KeyModifiers
        let capsLock: Bool
        let usCharacters: String

        var events: [InputEvent] {
            DuoKeyboardLayout.keyEvents(usage, latched: modifiers, capsLock: capsLock)
        }
        var expectedFlags: UInt64 {
            var flags = modifiers
            if capsLock { flags.insert(.capsLock) } else { flags.remove(.capsLock) }
            return flags.rawValue
        }
        // KeyStrokes deliberately releases per-key metadata on key-up, retaining only
        // modifier keys physically held by the chord (Shift is released immediately after).
        var expectedUpFlags: UInt64 { modifiers.subtracting(.capsLock).rawValue }
    }

    static let cases: [Case] = [
        Case(name: "plain-a", usage: 0x04, macKeyCode: 0, modifiers: [], capsLock: false, usCharacters: "a"),
        Case(name: "caps-a", usage: 0x04, macKeyCode: 0, modifiers: [], capsLock: true, usCharacters: "A"),
        Case(name: "caps-shift-a", usage: 0x04, macKeyCode: 0, modifiers: .shift, capsLock: true, usCharacters: "A"),
        Case(name: "caps-semicolon", usage: 0x33, macKeyCode: 41, modifiers: [], capsLock: true, usCharacters: ";"),
        Case(name: "caps-shift-semicolon", usage: 0x33, macKeyCode: 41, modifiers: .shift, capsLock: true, usCharacters: ":"),
        Case(name: "caps-off-a", usage: 0x04, macKeyCode: 0, modifiers: [], capsLock: false, usCharacters: "a")
    ]

    struct Observed: Decodable {
        let kind: String
        let keyCode: Int
        let characters: String
        let flags: UInt64
        let handledUnix: Double
    }

    static func validate(path: String, after sentAt: Double, recordedInputSourceID: String? = nil) throws -> [String: Any] {
        let observed = try JSONDecoder().decode([Observed].self, from: Data(contentsOf: URL(fileURLWithPath: path)))
            .filter { ($0.kind == "keyDown" || $0.kind == "keyUp") && $0.handledUnix >= sentAt }
        guard observed.count == cases.count * 2 else {
            throw ProbeError.failed("owned fixture did not record all keyboard down/up events: \(observed.count)")
        }
        let inputSourceID: String
        if let recordedInputSourceID {
            inputSourceID = recordedInputSourceID
        } else if let inputSource = TISCopyCurrentKeyboardInputSource()?.takeRetainedValue(),
                  let pointer = TISGetInputSourceProperty(inputSource, kTISPropertyInputSourceID) {
            inputSourceID = Unmanaged<CFString>.fromOpaque(pointer).takeUnretainedValue() as String
        } else { inputSourceID = "unknown" }
        let checksUSCharacters = ["com.apple.keylayout.US", "com.apple.keylayout.ABC"].contains(inputSourceID)
        let keyboardFlagMask: UInt64 = 0x1f0000
        var rows: [[String: Any]] = []
        for (index, test) in cases.enumerated() {
            let down = observed[index * 2], up = observed[index * 2 + 1]
            let eventsMatch = down.kind == "keyDown" && up.kind == "keyUp"
                && down.keyCode == test.macKeyCode && up.keyCode == test.macKeyCode
            let flagsMatch = down.flags & keyboardFlagMask == test.expectedFlags
                && up.flags & keyboardFlagMask == test.expectedUpFlags
            let charactersMatch = !checksUSCharacters || down.characters == test.usCharacters
            rows.append(["case": test.name, "eventsMatch": eventsMatch, "flagsMatch": flagsMatch,
                         "charactersChecked": checksUSCharacters, "charactersMatch": charactersMatch,
                         "characters": down.characters, "downFlags": down.flags, "upFlags": up.flags,
                         "expectedDownFlags": test.expectedFlags, "expectedUpFlags": test.expectedUpFlags])
        }
        let passed = rows.allSatisfy { $0["eventsMatch"] as? Bool == true
            && $0["flagsMatch"] as? Bool == true && $0["charactersMatch"] as? Bool == true }
        // Print the evidence before failing, so a mismatch is preserved rather than hidden.
        let report: [String: Any] = ["passed": passed, "inputSourceID": inputSourceID,
                                     "characterAssertionsEnabled": checksUSCharacters, "cases": rows]
        print("KEYBOARD INPUT: " + String(decoding: try JSONSerialization.data(withJSONObject: report, options: [.sortedKeys]), as: UTF8.self))
        guard passed else { throw ProbeError.failed("real owned-fixture keyboard event mismatch") }
        return report
    }
}
