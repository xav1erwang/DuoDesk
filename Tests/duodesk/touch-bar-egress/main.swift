// Copyright 2026 DUO你电脑 contributors. SPDX-License-Identifier: Apache-2.0
// Synthetic hardware frames over an ephemeral, paired localhost QUIC session.
import Foundation
import CoreMedia
import CoreVideo
import Network
import StreamProtocol

extension HardwareDecoderRouter: LoopbackVideoDecoder { }

final class TouchBarObserver: @unchecked Sendable {
    static let shared = TouchBarObserver()
    private let lock = NSLock()
    private var callback: ((Data) -> Void)?
    func set(_ value: ((Data) -> Void)?) { lock.withLock { callback = value } }
    func receive(_ data: Data) { let value = lock.withLock { callback }; value?(data) }
}
final class Results: @unchecked Sendable {
    private let lock = NSLock()
    private var source: UUID
    private var encoded = 0, received = 0, requests = 0
    private var lastPacket: (Data, ParameterSets)?
    private var luminances: [Int] = [], failures: [String] = []
    init(_ source: UUID) { self.source = source }
    func current() -> UUID { lock.withLock { source } }
    func change(_ value: UUID) { lock.withLock { source = value } }
    func produced(_ bytes: Data, _ sets: ParameterSets) { lock.withLock { encoded += 1; lastPacket = (bytes, sets) } }
    func got() { lock.withLock { received += 1 } }
    func request() { lock.withLock { requests += 1 } }
    func fail(_ text: String) { lock.withLock { failures.append(text) } }
    func sample(_ sample: CMSampleBuffer, _ permit: VideoOutputPermit) {
        guard permit.isValid, let pixel = CMSampleBufferGetImageBuffer(sample), CVPixelBufferGetPlaneCount(pixel) > 0,
              CVPixelBufferGetWidth(pixel) == 2008, CVPixelBufferGetHeight(pixel) == 60,
              CVPixelBufferLockBaseAddress(pixel, .readOnly) == kCVReturnSuccess else { fail("decoded buffer"); return }
        defer { CVPixelBufferUnlockBaseAddress(pixel, .readOnly) }
        guard let p = CVPixelBufferGetBaseAddressOfPlane(pixel, 0)?.assumingMemoryBound(to: UInt8.self) else {
            fail("decoded plane"); return
        }
        let luma = Int(p[30 * CVPixelBufferGetBytesPerRowOfPlane(pixel, 0) + 1004])
        lock.withLock { luminances.append(luma) }
    }
    var state: (encoded: Int, received: Int, requests: Int, last: (Data, ParameterSets)?, luma: [Int], failures: [String]) {
        lock.withLock { (encoded, received, requests, lastPacket, luminances, failures) }
    }
}
enum Failure: Error { case timeout(String), invalid(String) }
func waitFor(_ name: String, _ condition: () -> Bool) async throws {
    let deadline = ContinuousClock.now + .seconds(6)
    while !condition() {
        guard ContinuousClock.now < deadline else { throw Failure.timeout(name) }
        try await Task.sleep(for: .milliseconds(10))
    }
}
func waitForSemaphore(_ semaphore: DispatchSemaphore) async -> Bool {
    await withCheckedContinuation { continuation in
        DispatchQueue.global(qos: .userInitiated).async {
            continuation.resume(returning: semaphore.wait(timeout: .now() + 3) == .success)
        }
    }
}
func frame(_ brightness: Int) throws -> CVPixelBuffer {
    var pixel: CVPixelBuffer?
    guard CVPixelBufferCreate(nil, 2008, 60, kCVPixelFormatType_420YpCbCr8BiPlanarFullRange,
        [kCVPixelBufferIOSurfacePropertiesKey: [:]] as CFDictionary, &pixel) == kCVReturnSuccess,
        let pixel, CVPixelBufferLockBaseAddress(pixel, []) == kCVReturnSuccess else { throw Failure.invalid("input") }
    defer { CVPixelBufferUnlockBaseAddress(pixel, []) }
    for plane in 0..<2 {
        guard let base = CVPixelBufferGetBaseAddressOfPlane(pixel, plane) else { throw Failure.invalid("plane") }
        memset(base, plane == 0 ? Int32(brightness) : 128,
               CVPixelBufferGetBytesPerRowOfPlane(pixel, plane) * CVPixelBufferGetHeightOfPlane(pixel, plane))
    }
    return pixel
}

@main struct Check {
    static func run() async throws {
        let first = UUID(), second = UUID(), results = Results(first)
        let encoder = try HEVCEncoder(width: 2008, height: 60, fps: 30, bitrate: 3_000_000,
                                      prioritizeSpeed: true, software: false, quiet: true, independentFrames: true)
        let decoder = HardwareDecoderRouter(onFormat: { _, _ in }, onSample: { sample, _, permit in results.sample(sample, permit) },
                                             onFailure: { text, _ in results.fail(text) })
        let loop = try await LoopbackVideo.connect(decoder: decoder, encoder: encoder)
        var holding = false
        let hold = DispatchSemaphore(value: 0)
        defer {
            if holding { hold.signal() }
            TouchBarObserver.shared.set(nil); loop.server.beginTouchBarStream(nil)
            loop.close(); _ = decoder.clear(); _ = encoder.abandon()
        }
        try await waitFor("initial desktop reset") { loop.counters.resets > 0 }
        TouchBarObserver.shared.set { data in
            guard let packet = TouchBarKeyframe(encoded: data), packet.surfaceID == results.current() else { return }
            results.got(); decoder.apply(packet.parameters); decoder.enqueue(packet.accessUnit, isKeyframe: true)
        }
        _ = decoder.requireVideo(.touchBar(id: first, width: 2008, height: 60))
        loop.server.beginTouchBarStream(first)
        loop.server.queue.sync { }
        guard let client = loop.server.queue.sync(execute: { loop.server.clients.values.first }) else {
            throw Failure.invalid("no admitted client")
        }
        let connection = client.connection
        let route = loop.server.queue.sync { client.route }
        guard route.encrypted, route.pairedName != nil else { throw Failure.invalid("paired TLS route missing") }
        // Only the in-memory test route is changed; the actual connection remains mTLS/QUIC.
        loop.server.queue.sync { client.route = .home(.loopback, peer: nil) }
        loop.server.setTouchBarSubscription(first, for: connection)
        loop.server.queue.sync { }
        guard loop.server.queue.sync(execute: { client.touchBarSurface == nil }) else { throw Failure.invalid("unpaired route subscribed") }
        loop.server.queue.sync { client.route = route }
        loop.server.onTouchBarKeyframeNeeded = { token in
            guard token == results.current() else { return }
            results.request(); encoder.requestKeyframe()
        }
        encoder.onEncoded = { bytes, key, parameters in
            guard key, let parameters else { results.fail("non-keyframe or missing sets"); return }
            results.produced(bytes, parameters)
            loop.server.broadcastTouchBarFrame(bytes, keyframe: key, parameters: parameters,
                                               timestamp: Date().timeIntervalSince1970, token: results.current())
        }
        loop.server.setTouchBarSubscription(first, for: connection)
        loop.server.queue.sync { }
        guard loop.server.queue.sync(execute: { client.touchBarSurface == first }) else { throw Failure.invalid("paired subscribe") }
        encoder.encode(try frame(48), pts: CMTime(value: 1, timescale: 30))
        try await waitFor("first frame") { !results.state.luma.isEmpty || !results.state.failures.isEmpty }
        guard results.state.failures.isEmpty, results.state.luma.last.map({ abs($0 - 48) <= 20 }) == true else {
            throw Failure.invalid("first decode")
        }

        let entered = DispatchSemaphore(value: 0)
        holding = true
        loop.server.queue.async { entered.signal(); hold.wait() }
        guard await waitForSemaphore(entered) else { throw Failure.timeout("network hold") }
        for (i, brightness) in [96, 144, 192].enumerated() {
            let prior = results.state.encoded
            encoder.encode(try frame(brightness), pts: CMTime(value: Int64(i + 2), timescale: 30))
            try await waitFor("encoded frame") { results.state.encoded > prior || !results.state.failures.isEmpty }
        }
        let pending = loop.server.touchBarIngressLock.withLock { loop.server.touchBarIngress.pending }
        let last = results.state.last
        guard let pending, let last, pending.isKeyframe,
              let parsed = TouchBarKeyframe(encoded: Data(pending.data.dropFirst(StreamMessage.headerLength))),
              parsed.accessUnit == last.0 else { throw Failure.invalid("latest-frame mailbox") }
        hold.signal(); holding = false
        try await waitFor("latest decoded") { results.state.luma.contains { $0 > 170 } || !results.state.failures.isEmpty }
        guard results.state.failures.isEmpty else { throw Failure.invalid("latest decode") }

        // Switch the source while old encoded bytes can still arrive: the old token must not
        // replace the new packet, and the paired client must subscribe to the new source.
        let block = DispatchSemaphore(value: 0), enteredAgain = DispatchSemaphore(value: 0)
        loop.server.queue.async { enteredAgain.signal(); block.wait() }
        guard await waitForSemaphore(enteredAgain), let previous = results.state.last else {
            block.signal(); throw Failure.timeout("second network hold")
        }
        results.change(second)
        _ = decoder.requireVideo(.touchBar(id: second, width: 2008, height: 60))
        loop.server.beginTouchBarStream(second)
        loop.server.setTouchBarSubscription(second, for: connection)
        loop.server.broadcastTouchBarFrame(previous.0, keyframe: true, parameters: previous.1, timestamp: 1, token: first)
        loop.server.broadcastTouchBarFrame(previous.0, keyframe: true, parameters: previous.1, timestamp: 2, token: second)
        let newer = loop.server.touchBarIngressLock.withLock { loop.server.touchBarIngress.pending }
        guard let newer, let parsed = TouchBarKeyframe(encoded: Data(newer.data.dropFirst(StreamMessage.headerLength))),
              parsed.surfaceID == second else { block.signal(); throw Failure.invalid("stale source won") }
        let prior = results.state.luma.count
        block.signal()
        try await waitFor("replacement frame") { results.state.luma.count > prior || !results.state.failures.isEmpty }
        guard results.state.failures.isEmpty else { throw Failure.invalid("replacement decode") }
        loop.server.setTouchBarSubscription(first, for: connection)
        loop.server.queue.sync { }
        guard loop.server.queue.sync(execute: { client.touchBarSurface == second }) else {
            throw Failure.invalid("stale subscription removed the new source")
        }

        // Artificially hold this subscriber's in-flight slot, then let a normal send completion
        // request a fresh frame. This exercises backpressure without trying to saturate a network.
        try await waitFor("Touch Bar send drained") { loop.server.queue.sync { !client.touchBarFrameInFlight } }
        loop.server.queue.sync { client.touchBarFrameInFlight = true }
        let requestCount = results.state.requests
        loop.server.broadcastTouchBarFrame(previous.0, keyframe: true, parameters: previous.1, timestamp: 3, token: second)
        loop.server.queue.sync { }
        guard loop.server.queue.sync(execute: { client.touchBarRefreshWanted }) else { throw Failure.invalid("slow-client refresh") }
        loop.server.queue.sync { client.touchBarFrameInFlight = false }
        loop.server.send(StreamMessage(kind: .tick, timestamp: 4, isKeyframe: false, payload: Data()), to: connection)
        try await waitFor("refresh after drain") { results.state.requests > requestCount }
        loop.server.setTouchBarSubscription(nil, for: connection)
        loop.server.queue.sync { }
        guard loop.server.queue.sync(execute: { client.touchBarSurface == nil }) else { throw Failure.invalid("unsubscribe") }
        try loop.check()
        loop.server.setTouchBarSubscription(second, for: connection)
        loop.server.queue.sync { }
        let removed = loop.server.queue.sync { () -> Bool in
            loop.server.goodbye(Goodbye(reason: "test"), to: connection)
            return client.touchBarSurface == nil && !client.touchBarRefreshWanted
        }
        guard removed else { throw Failure.invalid("goodbye retained subscription") }
        print("TOUCH BAR EGRESS PASS: paired TLS/QUIC on 127.0.0.1, hardware HEVC, unpaired-route refusal, bounded latest frame, source fencing, backpressure refresh, unsubscribe and goodbye; luma=\(results.state.luma)")
        print("SCOPE: synthetic frames, simulated unpaired route and in-flight stall; no Touch Bar capture, actual input, real Duo, WAN or FPS acceptance")
    }
    static func main() async {
        do { try await run() }
        catch { print("TOUCH BAR EGRESS FAIL: \(error)"); exit(1) }
    }
}
