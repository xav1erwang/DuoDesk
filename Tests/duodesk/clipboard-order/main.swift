// Copyright 2026 DUO你电脑 contributors. SPDX-License-Identifier: Apache-2.0
import AppKit
import Network

// Exercise the production clipboard and its real, isolated pasteboard. The transport and
// counters are irrelevant to the ordering of clipboard writes and injected input.
@MainActor final class StreamServer {
    func send(each: [(NWConnection, StreamMessage)]) {}
}
final class Stats {
    static let shared = Stats()
    func bump(_ key: String) {}
}

func check(_ value: @autoclosure () -> Bool, _ message: String) { precondition(value(), message) }

@MainActor
func run() async throws {
    let name = "com.duodesk.clipboard-order.\(UUID())"
    let board = NSPasteboard(name: .init(name))
    defer { board.releaseGlobally() }
    let host = HostClipboard(server: StreamServer(), enabled: true, launchID: "order-test", synthetic: true,
                             environment: ["SILL_TEST_PASTEBOARD": name])
    let first = NWConnection(host: "127.0.0.1", port: 9, using: .tcp)
    let gone = NWConnection(host: "127.0.0.1", port: 9, using: .tcp)
    var input: [String] = []
    host.received(ClipboardPolicy.payload(text: "paste-one")!, from: first, who: "test")
    host.afterPendingWrites(from: first) {
        check(board.string(forType: .string) == "paste-one", "key went before clipboard write")
        input.append("down")
    }
    host.afterPendingWrites(from: first) { input.append("up") }
    check(input.isEmpty, "input did not wait for the asynchronous pasteboard")
    let deadline = Date.now.addingTimeInterval(3)
    while input.count < 2 && Date.now < deadline { try await Task.sleep(for: .milliseconds(10)) }
    check(input == ["down", "up"], "shortcut key down and release were reordered")

    input = []
    host.received(ClipboardPolicy.payload(text: "paste-two")!, from: first, who: "test")
    host.afterPendingWrites(from: gone) { input.append("disconnected-device") }
    host.afterPendingWrites(from: first) {
        check(board.string(forType: .string) == "paste-two", "second paste used stale clipboard")
        input.append("connected-device")
    }
    host.clientLeft(gone)
    let secondDeadline = Date.now.addingTimeInterval(3)
    while input.isEmpty && Date.now < secondDeadline { try await Task.sleep(for: .milliseconds(10)) }
    check(input == ["connected-device"], "disconnected input was injected after the write")

    host.afterPendingWrites(from: first) { input.append("immediate") }
    check(input == ["connected-device", "immediate"], "ordinary input was delayed without a write")
    host.clientLeft(first)
    print("Clipboard ordering: real pasteboard updated before keys; ordered releases and disconnected input passed")
}

try await run()
