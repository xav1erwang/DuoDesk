// Copyright 2026 DUO你电脑 contributors. SPDX-License-Identifier: Apache-2.0
// HID/wire/host-key mapping checked against macOS's installed keyboard layout. Never posts input.
import Carbon
import Foundation
import StreamProtocol

func failure(_ message: String) -> NSError {
    NSError(domain: "DuoKeyboardCase", code: 1, userInfo: [NSLocalizedDescriptionKey: message])
}

func layoutData() throws -> Data {
    let match = [kTISPropertyInputSourceID as String: "com.apple.keylayout.US"] as CFDictionary
    guard let sources = TISCreateInputSourceList(match, true)?.takeRetainedValue(), CFArrayGetCount(sources) == 1 else {
        throw failure("Installed US keyboard layout unavailable; no input source will be changed")
    }
    let source = unsafeBitCast(CFArrayGetValueAtIndex(sources, 0), to: TISInputSource.self)
    guard let property = TISGetInputSourceProperty(source, kTISPropertyUnicodeKeyLayoutData) else {
        throw failure("US keyboard layout has no readable Unicode table")
    }
    return Unmanaged<CFData>.fromOpaque(property).takeUnretainedValue() as Data
}

func character(_ stroke: KeyStroke, layout: Data) throws -> String {
    var modifiers: UInt32 = 0
    if stroke.flags & KeyStrokes.capsLock != 0 { modifiers |= UInt32(alphaLock) }
    if stroke.flags & KeyStrokes.shift != 0 { modifiers |= UInt32(shiftKey) }
    if stroke.flags & KeyStrokes.option != 0 { modifiers |= UInt32(optionKey) }
    if stroke.flags & KeyStrokes.control != 0 { modifiers |= UInt32(controlKey) }
    if stroke.flags & KeyStrokes.command != 0 { modifiers |= UInt32(cmdKey) }
    return try layout.withUnsafeBytes { bytes in
        guard let table = bytes.baseAddress?.assumingMemoryBound(to: UCKeyboardLayout.self) else {
            throw failure("Empty keyboard layout")
        }
        var dead: UInt32 = 0
        var actual = 0
        var units = [UniChar](repeating: 0, count: 8)
        let result = UCKeyTranslate(table, stroke.virtualKey, UInt16(kUCKeyActionDown), modifiers >> 8,
                                    UInt32(LMGetKbdType()), OptionBits(kUCKeyTranslateNoDeadKeysMask),
                                    &dead, units.count, &actual, &units)
        guard result == noErr else { throw failure("Native keyboard translation failed: \(result)") }
        return String(utf16CodeUnits: units, count: Int(actual))
    }
}

let cases: [(name: String, usage: UInt16, latched: KeyModifiers, caps: Bool, expected: String)] = [
    ("caps-a", 0x04, [], true, "A"),
    ("caps-shift-a", 0x04, .shift, true, "A"),
    ("caps-1", 0x1E, [], true, "1"),
    ("caps-shift-1", 0x1E, .shift, true, "!"),
    ("plain-a", 0x04, [], false, "a"),
    ("shift-a", 0x04, .shift, false, "A"),
    ("caps-command-s", 0x16, .command, true, "S")
]
let device = NSObject()
var rows: [[String: Any]] = []
var passed = true
do {
    let layout = try layoutData()
    for item in cases {
        #if DUO_LEGACY_CAPS
        // Exact pre-fix DuoKeyboardView .key action, retained as the failing control.
        let events = KeyChord.press(item.usage, with: item.latched)
        #else
        var touches = DuoKeyboardTouches()
        var events: [InputEvent] = []
        for key in item.latched.keys {
            if let event = touches.began(key.usage, capsLock: item.caps) { events.append(event) }
        }
        if let event = touches.began(item.usage, capsLock: item.caps) { events.append(event) }
        if let event = touches.ended(item.usage, capsLock: item.caps) { events.append(event) }
        for key in item.latched.keys.reversed() {
            if let event = touches.ended(key.usage, capsLock: item.caps) { events.append(event) }
        }
        #endif
        var keys = KeyStrokes()
        var downs: [KeyStroke] = []
        for event in events {
            guard let decoded = Wire.decode(InputEvent.self, from: Wire.encode(event)),
                  case .key(let usage, let down, let modifiers) = decoded,
                  let strokes = keys.key(usage: usage, down: down, modifiers: modifiers, from: ObjectIdentifier(device)) else {
                throw failure("HID wire round-trip or host mapping failed")
            }
            downs += strokes.filter { $0.down && $0.virtualKey == KeyStrokes.virtualKeys[item.usage] }
        }
        guard downs.count == 1 else { throw failure("Letter did not produce exactly one host down") }
        let actual = try character(downs[0], layout: layout)
        guard let key = DuoKeyboardLayout.rows.flatMap({ $0 }).first(where: { $0.action == .key(item.usage) }) else {
            throw failure("Keycap missing for HID fixture")
        }
        #if DUO_LEGACY_CAPS
        let isLetter = (0x04...0x1D).contains(item.usage)
        let legend = isLetter ? ((item.latched.contains(.shift) != item.caps) ? key.legend.uppercased() : key.legend)
            : (item.latched.contains(.shift) ? (key.shifted ?? key.legend) : key.legend)
        #else
        let legend = DuoKeyboardLayout.legend(for: key, latched: item.latched, capsLock: item.caps)
        #endif
        let shortcut = !item.latched.intersection(.shortcutMakers).isEmpty
        let caseMatches = shortcut || (actual == item.expected && actual == legend)
        let flagsMatch = (downs[0].flags & KeyStrokes.capsLock != 0) == item.caps
            && downs[0].flags & item.latched.rawValue == item.latched.rawValue
        let correct = caseMatches && flagsMatch && keys.down.isEmpty && keys.heldFlags == 0
        rows.append(["case": item.name,
                     "expected": shortcut ? "Caps Lock and shortcut flags; all keys released" : item.expected,
                     "actual": actual,
                     "displayedLegend": legend, "shortcutUsesFlagsNotText": shortcut,
                     "hostDownFlags": downs[0].flags, "heldKeysAfterChord": keys.down.count,
                     "heldModifiersAfterChord": keys.heldFlags, "passed": correct])
        passed = passed && correct
    }
    #if !DUO_LEGACY_CAPS
    for enabled in [true, false] {
        var touches = DuoKeyboardTouches()
        let events = [touches.began(0x39, capsLock: enabled), touches.ended(0x39, capsLock: enabled)].compactMap { $0 }
        let carried = events.allSatisfy { event in
            guard case .key(let usage, _, let modifiers) = event else { return false }
            return usage == 0x39 && (modifiers & KeyStrokes.capsLock != 0) == enabled
        }
        rows.append(["case": enabled ? "caps-toggle-on" : "caps-toggle-off", "passed": carried])
        passed = passed && carried
    }
    do {
        var touches = DuoKeyboardTouches()
        var host = KeyStrokes()
        var ok = true
        func deliver(_ event: InputEvent?, held: Set<UInt16>, flags: UInt64) {
            guard let event, case .key(let usage, let down, let modifiers) = event,
                  let strokes = host.key(usage: usage, down: down, modifiers: modifiers, from: ObjectIdentifier(device)) else {
                ok = false
                return
            }
            ok = ok && strokes.count == 1 && Set(host.down.keys) == held && host.heldFlags == flags
        }
        let command = KeyModifiers.command.rawValue
        let shiftCommand = KeyModifiers.shift.union(.command).rawValue
        deliver(touches.began(0xE3, capsLock: false), held: [0xE3], flags: command)
        deliver(touches.began(0xE7, capsLock: false), held: [0xE3, 0xE7], flags: command)
        deliver(touches.began(0xE1, capsLock: false), held: [0xE3, 0xE7, 0xE1], flags: shiftCommand)
        deliver(touches.began(0x1A, capsLock: false), held: [0xE3, 0xE7, 0xE1, 0x1A], flags: shiftCommand)
        deliver(touches.ended(0xE3, capsLock: false), held: [0xE7, 0xE1, 0x1A], flags: shiftCommand)
        deliver(touches.ended(0x1A, capsLock: false), held: [0xE7, 0xE1], flags: shiftCommand)
        deliver(touches.ended(0xE1, capsLock: false), held: [0xE7], flags: command)
        deliver(touches.ended(0xE7, capsLock: false), held: [], flags: 0)
        rows.append(["case": "physical-modifier-lifetimes-on-host", "passed": ok])
        passed = passed && ok
    }
    #endif
    let output = URL(fileURLWithPath: ProcessInfo.processInfo.environment["DUODESK_KEYBOARD_CASE_REPORT"]
                     ?? "Temp/AirAcceptance-20261026/keyboard-case.json")
    let report: [String: Any] = ["passed": passed, "cases": rows, "inputSourceChanged": false,
                               "inputPosted": false, "actualIMEOrDeviceVerified": false]
    try FileManager.default.createDirectory(at: output.deletingLastPathComponent(), withIntermediateDirectories: true)
    try JSONSerialization.data(withJSONObject: report, options: [.prettyPrinted, .sortedKeys]).write(to: output, options: .atomic)
    for row in rows { print("Keyboard case \(row["case"]!): \(row["passed"]!) \(row["actual"] ?? "")") }
    print("Native keyboard case result: \(passed ? "passed" : "FAILED"), \(rows.count) cases; no input posted.")
    exit(passed ? 0 : 1)
} catch {
    print("Keyboard case probe failed: \(error.localizedDescription)")
    exit(2)
}
