// Copyright 2026 DUO你电脑 contributors. SPDX-License-Identifier: Apache-2.0
import Darwin
import Foundation
import StreamProtocol

@MainActor
enum ProbeIMECases {
    struct State: Decodable {
        let kind: String
        let text: String
        let committed: String
        let marked: String
        let hasMarkedText: Bool
        let markedUpdates: Int
        let inputSource: String
        let focused: Bool
        let clickX: Double
        let clickY: Double
    }
    struct Evidence: Decodable {
        let processID: Int32
        let startedAt: Double
        let desiredInputSource: String
        let states: [State]
    }
    static func clickPoint(path: String, fixturePID: Int32) throws -> (Double, Double) {
        let evidence = try JSONDecoder().decode(Evidence.self, from: Data(contentsOf: URL(fileURLWithPath: path)))
        guard evidence.processID == fixturePID, kill(fixturePID, 0) == 0,
              let last = evidence.states.last, (0.05...0.95).contains(last.clickX),
              (0.05...0.95).contains(last.clickY) else { throw ProbeError.failed("owned text field click geometry is unavailable") }
        return (last.clickX, last.clickY)
    }

    static func run(path: String, fixturePID: Int32, current: () -> Bool,
                    send: (InputEvent) -> Void) async throws -> [String: Any] {
        func read() throws -> Evidence {
            let data = try Data(contentsOf: URL(fileURLWithPath: path))
            guard data.count < 2_000_000 else { throw ProbeError.failed("owned IME report exceeds bound") }
            let evidence = try JSONDecoder().decode(Evidence.self, from: data)
            guard evidence.processID == fixturePID, kill(fixturePID, 0) == 0,
                  Date().timeIntervalSince1970 - evidence.startedAt < 90 else {
                throw ProbeError.failed("IME evidence is not from the current owned fixture")
            }
            return evidence
        }
        func latest() throws -> State {
            guard current(), let state = try read().states.last else { throw ProbeError.failed("IME video epoch or fixture state unavailable") }
            return state
        }
        func wait(_ label: String, _ predicate: (State) -> Bool) async throws -> State {
            for _ in 0..<50 {
                let state = try latest()
                if predicate(state) { return state }
                try await Task.sleep(for: .milliseconds(100))
            }
            let state = try latest()
            print("IME phase failed: \(label); source=\(state.inputSource), marked=\(state.hasMarkedText), focused=\(state.focused), text=\(state.text)")
            throw ProbeError.failed("IME phase did not complete: " + label)
        }
        func press(_ usage: UInt16) throws {
            guard try latest().focused else { throw ProbeError.failed("owned IME fixture lost keyboard focus; no more input sent") }
            for event in DuoKeyboardLayout.keyEvents(usage, latched: [], capsLock: false) { send(event) }
        }
        func type(_ ascii: String) async throws {
            for byte in ascii.utf8 {
                guard (97...122).contains(byte) else { throw ProbeError.failed("IME fixture only types fixed lowercase test words") }
                try press(UInt16(byte - 97) + 0x04)
                try await Task.sleep(for: .milliseconds(140))
            }
        }

        let desired = try read().desiredInputSource
        let initial = try await wait("enabled input source and focused native text view") {
            $0.focused && $0.inputSource == desired && $0.text.isEmpty
        }
        try await type("nihao")
        let marked = try await wait("Pinyin marked text") {
            $0.focused && $0.hasMarkedText && !$0.marked.isEmpty && $0.markedUpdates > initial.markedUpdates
        }
        print("IME: actual native marked text observed")
        try press(0x2C) // Space confirms the current native candidate.
        let confirmed = try await wait("Chinese candidate confirmation") { !$0.hasMarkedText && $0.text == "你好" }
        try await type("zhongwen")
        _ = try await wait("second native composition") { $0.hasMarkedText && $0.markedUpdates > marked.markedUpdates }
        try press(0x29) // Escape cancels composition without changing committed text.
        let cancelled = try await wait("composition cancellation") { !$0.hasMarkedText && $0.text == confirmed.text }
        guard try latest().focused else { throw ProbeError.failed("owned IME fixture lost focus before committed Unicode input") }
        send(.text("🙂"))
        let unicode = try await wait("committed Unicode text") { !$0.hasMarkedText && $0.text == "你好🙂" }
        let report: [String: Any] = ["passed": true, "inputSource": desired,
                                    "markedTextObserved": true, "confirmedText": confirmed.text,
                                    "cancelPreservedText": cancelled.text, "unicodeText": unicode.text,
                                    "nativeMacIME": true, "realIOSIMEVerified": false,
                                    "performanceAcceptance": false]
        print("IME INPUT: " + String(decoding: try JSONSerialization.data(withJSONObject: report, options: [.sortedKeys]), as: UTF8.self))
        return report
    }
}
