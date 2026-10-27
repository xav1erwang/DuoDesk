// Copyright 2026 DUO你电脑 contributors. SPDX-License-Identifier: Apache-2.0
// Production routing with real hardware HEVC and a test semaphore blocking the old decoder queue.
import CoreMedia
import CoreVideo
import Foundation
import StreamProtocol

final class Results: @unchecked Sendable {
    private let lock = NSLock()
    private var parameters: ParameterSets?, frame: Data?
    private var samples: [(CMSampleBuffer, UInt64)] = [], errors: [String] = []
    private var requests: [UInt64] = [], resets: [UInt64] = []
    func encoded(_ data: Data, _ parameters: ParameterSets) { lock.withLock { self.frame = data; self.parameters = parameters } }
    func sample(_ image: CMSampleBuffer, _ token: UInt64) { lock.withLock { samples.append((image, token)) } }
    func error(_ value: String) { lock.withLock { errors.append(value) } }
    func request(_ token: UInt64) { lock.withLock { requests.append(token) } }
    func reset(_ token: UInt64) { lock.withLock { resets.append(token) } }
    var state: (parameters: ParameterSets?, frame: Data?, samples: [(CMSampleBuffer, UInt64)], errors: [String],
                requests: [UInt64], resets: [UInt64]) {
        lock.withLock { (parameters, frame, samples, errors, requests, resets) }
    }
}
final class Bridge: @unchecked Sendable {
    private let lock = NSLock()
    private weak var router: HardwareDecoderRouter?
    private var frame: Data?
    func install(_ router: HardwareDecoderRouter, frame: Data) { lock.withLock { self.router = router; self.frame = frame } }
    func replay() {
        let (target, data) = lock.withLock { (router, frame) }
        if let target, let data { target.enqueue(data, isKeyframe: true) }
    }
}
final class Flag: @unchecked Sendable {
    private let lock = NSLock()
    private var set = false
    func mark() { lock.withLock { set = true } }
    var value: Bool { lock.withLock { set } }
}
enum Failure: Error { case unavailable(String), timeout(String) }
func wait(_ label: String, timeout: Duration = .seconds(4), _ condition: () -> Bool) async throws {
    let end = ContinuousClock.now + timeout
    while !condition() {
        guard ContinuousClock.now < end else { throw Failure.timeout(label) }
        try await Task.sleep(for: .milliseconds(10))
    }
}
func frame() throws -> CVPixelBuffer {
    var result: CVPixelBuffer?
    guard CVPixelBufferCreate(nil, 2008, 1428, kCVPixelFormatType_420YpCbCr8BiPlanarFullRange,
                              [kCVPixelBufferIOSurfacePropertiesKey: [:]] as CFDictionary, &result) == kCVReturnSuccess,
          let result, CVPixelBufferLockBaseAddress(result, []) == kCVReturnSuccess else { throw Failure.unavailable("buffer") }
    defer { CVPixelBufferUnlockBaseAddress(result, []) }
    for plane in 0..<2 {
        guard let base = CVPixelBufferGetBaseAddressOfPlane(result, plane) else { throw Failure.unavailable("plane") }
        memset(base, plane == 0 ? 96 : 128,
               CVPixelBufferGetBytesPerRowOfPlane(result, plane) * CVPixelBufferGetHeightOfPlane(result, plane))
    }
    return result
}

@main
struct Check {
    static func run() async throws {
        let results = Results(), bridge = Bridge()
        let router = HardwareDecoderRouter(onFormat: { _, _ in }, onSample: { image, token, _ in results.sample(image, token) },
            onFailure: { error, _ in results.error(error) }, onNeedsKeyframe: { token in results.request(token); bridge.replay() },
            onReset: { token in results.reset(token) })
        router.require(DuoDesktopResolution(width: 2007, height: 1427))
        try await wait("initial retirement") { router.lock.withLock { router.retiring.isEmpty } }
        let encoder = try HEVCEncoder(width: 2008, height: 1428, fps: 120, bitrate: 20_000_000,
                                      prioritizeSpeed: true, software: false, quiet: true)
        defer { _ = encoder.abandon(); _ = router.clear() }
        encoder.onEncoded = { data, key, ps in if key, let ps { results.encoded(data, ps) } }
        encoder.encode(try frame(), pts: CMTime(value: 1, timescale: 120))
        try await wait("encoded keyframe") { results.state.parameters != nil && results.state.frame != nil }
        guard let ps = results.state.parameters, let data = results.state.frame else { throw Failure.unavailable("encoded fixture") }
        bridge.install(router, frame: data)
        router.apply(ps); router.enqueue(data, isKeyframe: true)
        try await wait("initial decoded image") { !results.state.samples.isEmpty || !results.state.errors.isEmpty }
        guard let initial = results.state.samples.first, results.state.errors.isEmpty else { throw Failure.unavailable("initial output") }
        let (old, oldID) = router.lock.withLock { (router.decoder!, router.identity) }
        let gate = DispatchSemaphore(value: 0), entered = Flag()
        defer { gate.signal() }
        old.queue.async { entered.mark(); gate.wait() }
        try await wait("blocked old queue", timeout: .seconds(2)) { entered.value }

        let automatic = CommandLine.arguments.contains("--automatic")
        let barrier: UInt64
        if automatic {
            let now = ProcessInfo.processInfo.systemUptime
            old.lock.withLock { old.inFlight = 1; old.inFlightBytes = 1; old.callbackProgressAt = now - 4; old.lastWatchdogCheck = now }
            old.checkWatchdog()
            barrier = initial.1
        } else {
            barrier = router.clear()
            router.apply(ps); router.enqueue(data, isKeyframe: true)
        }
        try await wait("fresh image while old queue remains blocked") {
            results.state.samples.contains { $0.1 > barrier } || !results.state.errors.isEmpty
        }
        let fresh = results.state
        guard fresh.errors.isEmpty, let output = fresh.samples.last, output.1 > barrier,
              router.canOutput(output.1), !router.canOutput(initial.1),
              router.lock.withLock({ router.retiring.count == 1 && router.decoder !== old }) else {
            throw Failure.unavailable("fresh image and old-generation fence")
        }
        let beforeStale = fresh.samples.count
        router.sample(initial.0, token: initial.1, identity: oldID)
        old.enqueue(data, isKeyframe: true); old.apply(ps)
        guard results.state.samples.count == beforeStale else { throw Failure.unavailable("stale callback escaped") }

        if automatic {
            guard fresh.requests.count == 1, fresh.resets.count == 1 else { throw Failure.unavailable("automatic keyframe request") }
            let current = router.lock.withLock { router.decoder! }, now = ProcessInfo.processInfo.systemUptime
            current.lock.withLock { current.inFlight = 1; current.inFlightBytes = 1; current.callbackProgressAt = now - 4; current.lastWatchdogCheck = now }
            current.checkWatchdog()
            guard results.state.errors.count == 1, router.lock.withLock({ router.decoder === current && router.retiring.count == 1 }) else {
                throw Failure.unavailable("bounded automatic retry")
            }
            let fenced = router.clear()
            router.apply(ps); router.apply(ps)
            try await wait("failed replacement reported on the next stream") { results.state.errors.count >= 2 }
            guard results.state.errors.count == 2, !router.canOutput(fenced),
                  router.lock.withLock({ router.decoder === current && router.retiring.count == 1 }) else {
                throw Failure.unavailable("bounded failure is not silent")
            }
        } else {
            // A second reset while the predecessor is still stuck must reuse the current decoder,
            // never spawn a third live session; it must still decode after the reset.
            let current = router.lock.withLock { router.decoder! }, second = router.clear()
            guard router.lock.withLock({ router.decoder === current && router.retiring.count == 1 }) else {
                throw Failure.unavailable("retiring session bound")
            }
            router.apply(ps); router.enqueue(data, isKeyframe: true)
            try await wait("fresh image after bounded second reset") {
                results.state.samples.contains { $0.1 > second } || !results.state.errors.isEmpty
            }
            guard results.state.errors.isEmpty, results.state.samples.contains(where: { $0.1 > second }) else {
                throw Failure.unavailable("second reset output")
            }
        }
        print("DECODER ISOLATION PASS: native hardware HEVC, old queue held, fresh generation decoded, stale callbacks fenced, retiring limit=1, automatic=\(automatic)")
        print("SCOPE: synthetic frames and deliberately blocked queue; no actual VT hang, desktop, network or Duo")
    }
    static func main() async {
        do { try await run() }
        catch { print("DECODER ISOLATION FAIL: \(error); queue obstruction is test-injected"); exit(1) }
    }
}
