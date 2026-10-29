// Copyright 2026 DUO你电脑 contributors. SPDX-License-Identifier: Apache-2.0
// Synthetic framed bytes over a real paired TLS/TCP loopback connection; no screen or input.
import Foundation
import StreamProtocol

private enum Failure: Error { case timeout(String), invalid(String) }
private final class Sink: LoopbackVideoDecoder {
    func clear() -> UInt64 { 0 }
    func apply(_ parameters: ParameterSets) { }
    func enqueue(_ data: Data, isKeyframe: Bool) { }
}
private func waitFor(_ name: String, _ check: () -> Bool) async throws {
    let end = ContinuousClock.now + .seconds(6)
    while !check() {
        guard ContinuousClock.now < end else { throw Failure.timeout(name) }
        try await Task.sleep(for: .milliseconds(10))
    }
}
private func waitForSemaphore(_ semaphore: DispatchSemaphore) async -> Bool {
    await withCheckedContinuation { continuation in
        DispatchQueue.global(qos: .userInitiated).async {
            continuation.resume(returning: semaphore.wait(timeout: .now() + 3) == .success)
        }
    }
}

@main private struct Check {
    static func checkPermits() throws {
        let box = TrustBox(), first = Data([1]), other = Data([2])
        box.update { $0.requirePairing = false; $0.paired[other] = "other" }
        var permit: TrustBox.VideoPermit? = box.videoPermit(fingerprint: first, observed: box.snapshot) {
            $0.paired[first] != nil || !$0.requirePairing
        }
        guard permit?.admit({}) == true else { throw Failure.invalid("unpaired home session denied") }
        box.update { $0.paired.removeValue(forKey: other) }
        guard permit?.admit({}) == true else { throw Failure.invalid("unrelated removal invalidated session") }
        box.update { $0.paired[first] = "first" }
        guard permit?.admit({}) == true else { throw Failure.invalid("pairing invalidated session") }
        box.update { $0.paired.removeValue(forKey: first) }
        box.update { $0.paired[first] = "first" }
        guard permit?.admit({}) == false else { throw Failure.invalid("removed key revived old permit") }
        permit = nil
        guard box.videoPermits.isEmpty else { throw Failure.invalid("permit not released") }
        let old = box.snapshot
        box.update { $0.pairingOpen.toggle() }
        guard box.videoPermit(fingerprint: first, observed: old, allowed: { _ in true }) == nil else {
            throw Failure.invalid("stale admission snapshot")
        }
        box.update { $0.remoteAccess = true; $0.internetAccess = true }
        let remote = box.videoPermit(fingerprint: first, observed: box.snapshot) {
            $0.remoteAccess && $0.internetAccess && $0.paired[first] != nil
        }
        guard remote?.admit({}) == true else { throw Failure.invalid("valid remote session denied") }
        box.update { $0.internetAccess = false }
        box.update { $0.internetAccess = true }
        guard remote?.admit({}) == false else { throw Failure.invalid("internet policy revived old permit") }
        print("PASS: unpaired home, unrelated removal, pair/remove/re-pair, stale admission and remote policy permits")
    }

    static func scenario(unpaired: Bool) async throws {
        if unpaired { setenv("DUO_TEST_UNPAIRED", "1", 1) } else { unsetenv("DUO_TEST_UNPAIRED") }
        let encoder = try HEVCEncoder(width: 2008, height: 60, fps: 30, bitrate: 1_000_000,
                                      prioritizeSpeed: true, software: false, quiet: true)
        let loop = try await LoopbackVideo.connect(decoder: Sink(), encoder: encoder)
        let quic = ProcessInfo.processInfo.environment["DUO_TEST_QUIC"] == "1"
        let remote = ProcessInfo.processInfo.environment["DUO_TEST_REMOTE"] == "1"
        let hold = DispatchSemaphore(value: 0)
        var holding = false
        defer { if holding { hold.signal() }; loop.close(); _ = encoder.abandon() }
        guard case .tls(let home) = loop.server.homeMode,
              let client = loop.server.queue.sync(execute: { loop.server.clients.values.first }),
              let fingerprint = client.route.fingerprint,
              (home.trust.snapshot.paired[fingerprint] == nil) == unpaired,
              client.route.isRemote == remote,
              loop.server.queue.sync(execute: { (client.transport != nil) == quic }) else {
            throw Failure.invalid("transport fixture")
        }
        let sets = ParameterSets(nalUnitHeaderLength: 4, sets: [Data([1]), Data([2]), Data([3])])
        loop.sendEncoded(Data([0, 0, 0, 1, 0x26]), keyframe: true, parameters: sets)
        try await waitFor("initial frame") { loop.counters.frames > 0 }
        let before = loop.server.queue.sync { loop.server.testDesktopVideoSends }
        guard before > 0 else { throw Failure.invalid("initial frame not handed to Network") }
        let entered = DispatchSemaphore(value: 0)
        holding = true
        loop.server.queue.async { entered.signal(); hold.wait() }
        guard await waitForSemaphore(entered) else { throw Failure.timeout("network hold") }
        loop.sendEncoded(Data([0, 0, 0, 1, 0x02]), keyframe: false, parameters: nil)
        guard loop.server.videoIngressLock.withLock({ loop.server.videoIngress.pending != nil }) else {
            throw Failure.invalid("frame was not queued")
        }
        if remote {
            home.trust.update { $0.internetAccess = false }
            home.trust.update { $0.internetAccess = true }
        } else {
            if unpaired { home.trust.update { $0.paired[fingerprint] = "later paired" } }
            home.trust.update { $0.paired.removeValue(forKey: fingerprint) }
            // Restoring trust before the queued frame drains must not resurrect the old session.
            home.trust.update { $0.paired[fingerprint] = "restored" }
        }
        hold.signal(); holding = false
        let after = loop.server.queue.sync { loop.server.testDesktopVideoSends }
        let caseName = remote ? "internet off/on" : (unpaired ? "initially unpaired, remove/re-pair" : "initially paired, remove/re-pair")
        print("DESKTOP REVOCATION (\(caseName)): sends \(before)→\(after)")
        guard after == before else { throw Failure.invalid("desktop frame handed to Network after revocation") }
    }
    static func run() async throws {
        try checkPermits()
        try await scenario(unpaired: false)
        if ProcessInfo.processInfo.environment["DUO_TEST_REMOTE"] != "1" {
            try await scenario(unpaired: true)
        }
        print("PASS: queued desktop frames withheld after the tested policy change; no actual screen, input, Duo or WAN")
    }
    static func main() async {
        do { try await run() }
        catch { print("DESKTOP TRUST EGRESS FAIL: \(error)"); exit(1) }
    }
}
