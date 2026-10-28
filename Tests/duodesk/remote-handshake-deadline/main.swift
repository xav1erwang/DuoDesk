// Copyright 2026 DUO你电脑 contributors. SPDX-License-Identifier: Apache-2.0
// Real production connector against two silent, loopback-only TCP peers. No TLS proof is sent,
// no keychain, capture, input, user identity or external network is used.
import Darwin
import Foundation
import Network
import StreamProtocol

struct Failure: Error { let message: String }

final class SilentPeer: @unchecked Sendable {
    private let lock = NSLock()
    private var sockets: [Int32] = []
    private var closed = false
    private var count = 0
    private let source: DispatchSourceRead
    let port: UInt16

    init() throws {
        let fd = socket(AF_INET, SOCK_STREAM, 0)
        guard fd >= 0 else { throw Failure(message: "socket") }
        var address = sockaddr_in()
        address.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
        address.sin_family = sa_family_t(AF_INET)
        address.sin_addr = in_addr(s_addr: in_addr_t(INADDR_LOOPBACK).bigEndian)
        let bound = withUnsafePointer(to: &address) { ptr in
            ptr.withMemoryRebound(to: sockaddr.self, capacity: 1) { Darwin.bind(fd, $0, socklen_t(MemoryLayout<sockaddr_in>.size)) }
        }
        guard bound == 0, Darwin.listen(fd, 4) == 0 else { Darwin.close(fd); throw Failure(message: "loopback bind/listen") }
        var size = socklen_t(MemoryLayout<sockaddr_in>.size)
        let named = withUnsafeMutablePointer(to: &address) { ptr in
            ptr.withMemoryRebound(to: sockaddr.self, capacity: 1) { getsockname(fd, $0, &size) }
        }
        guard named == 0, fcntl(fd, F_SETFL, O_NONBLOCK) == 0 else { Darwin.close(fd); throw Failure(message: "loopback socket setup") }
        port = UInt16(bigEndian: address.sin_port)
        source = DispatchSource.makeReadSource(fileDescriptor: fd, queue: DispatchQueue(label: "duodesk.silent-peer.\(port)"))
        source.setEventHandler { [weak self] in self?.acceptReady(fd) }
        source.setCancelHandler { Darwin.close(fd) }
        source.resume()
    }

    private func acceptReady(_ fd: Int32) {
        while true {
            let socket = Darwin.accept(fd, nil, nil)
            guard socket >= 0 else { return }
            lock.withLock {
                if closed { Darwin.close(socket) }
                else { sockets.append(socket); count += 1 }
            }
        }
    }

    var accepts: Int { lock.withLock { count } }
    func stop() {
        let held = lock.withLock { () -> [Int32] in
            guard !closed else { return [] }
            closed = true
            let held = sockets; sockets = []
            return held
        }
        held.forEach { Darwin.close($0) }
        source.cancel()
    }
    deinit { stop() }
}

final class Results: @unchecked Sendable {
    private let lock = NSLock()
    private var failures: [RemoteDialPolicy.Failure] = []
    private var winners = 0
    func failed(_ result: RemoteConnector.Failed) { lock.withLock { failures.append(result.failure) } }
    func won(_ result: RemoteConnector.Winner) { lock.withLock { winners += 1 }; result.connection.cancel() }
    var snapshot: ([RemoteDialPolicy.Failure], Int) { lock.withLock { (failures, winners) } }
}

@main struct Checks {
    static func waitFor(_ label: String, timeout: Double, _ condition: () -> Bool) async throws {
        let deadline = ProcessInfo.processInfo.systemUptime + timeout
        while !condition() {
            guard ProcessInfo.processInfo.systemUptime < deadline else { throw Failure(message: label) }
            try await Task.sleep(for: .milliseconds(25))
        }
    }
    static func run() async throws {
        guard let key = RemoteKey.generate(), let identity = RemoteIdentity(privateKey: key) else { throw Failure(message: "ephemeral identity") }
        let first = try SilentPeer(), second = try SilentPeer(), results = Results()
        defer { first.stop(); second.stop() }
        let candidates = [first, second].map {
            RemoteDialPolicy.Candidate(host: "127.0.0.1", port: Int($0.port), kind: MacAddress.lan, via: "")
        }
        let connector = RemoteConnector(candidates: candidates, mode: .pairing(pin: nil), identity: identity,
                                        queue: DispatchQueue(label: "duodesk.handshake-deadline"))
        connector.onWinner = results.won
        connector.onFailed = results.failed
        connector.start()
        defer { connector.cancel() }
        try await waitFor("first silent peer was not connected", timeout: 3) { first.accepts == 1 }
        let began = ProcessInfo.processInfo.systemUptime
        try await Task.sleep(for: .milliseconds(150))
        guard second.accepts == 0 else { throw Failure(message: "pairing attempts overlapped") }
        try await waitFor("TLS-stalled first peer did not advance to the second", timeout: 11.5) { second.accepts == 1 }
        let elapsed = ProcessInfo.processInfo.systemUptime - began
        guard elapsed >= 9 && elapsed < 11.5 else { throw Failure(message: "unexpected first deadline \(elapsed)") }
        try await waitFor("last TLS-stalled peer never failed", timeout: 11.5) { results.snapshot.0.count == 1 }
        guard results.snapshot.0 == [.noAnswer], results.snapshot.1 == 0 else { throw Failure(message: "incorrect result") }
        try await Task.sleep(for: .milliseconds(200))
        guard results.snapshot.0.count == 1 else { throw Failure(message: "failure delivered more than once") }
        print("PAIRING HANDSHAKE DEADLINE PASS: sequential silent TCP peers, 10 s per attempt, one failure, no proof")
        print("SCOPE: localhost only and ephemeral identity; not real Duo, remote WAN or system capture")
    }
    static func main() async {
        do { try await run() }
        catch { print("PAIRING HANDSHAKE DEADLINE FAIL: \(error)"); exit(1) }
    }
}
