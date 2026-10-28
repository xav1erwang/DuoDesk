// Copyright 2026 DUO你电脑 contributors. SPDX-License-Identifier: Apache-2.0
// The receiver delay and input gap are injected; encoding, QUIC, decoding and presentation are real.
import AppKit
import AVFoundation
import CoreMedia
import CoreVideo
import Foundation
import StreamProtocol

extension HardwareDecoderRouter: LoopbackVideoDecoder { }

actor ReceiverGate {
    private var continuation: CheckedContinuation<Void, any Error>?
    private var held = false, flushCount = 0
    func beforeEnqueue(_ sequence: Int64) async throws {
        guard sequence == 2 else { return }
        held = true
        try await withCheckedThrowingContinuation { continuation = $0 }
    }
    func flushed() {
        flushCount += 1
        continuation?.resume(throwing: CancellationError())
        continuation = nil
    }
    var state: (held: Bool, flushes: Int) { (held, flushCount) }
}
enum ReceiverFault { static let gate = ReceiverGate() }
final class Results: @unchecked Sendable {
    private let lock = NSLock()
    private var luma: [UInt8] = [], tokens: [UInt64] = [], errors: [String] = []
    private var requests = 0, encoded = 0, invalidations = 0, channel: LoopbackVideo?
    func attach(_ value: LoopbackVideo?) { lock.withLock { channel = value } }
    func request() { let target = lock.withLock { requests += 1; return channel }; target?.requestKeyframe() }
    func fail(_ value: String) { lock.withLock { errors.append(value) } }
    func sent() { lock.withLock { encoded += 1 } }
    func invalidate() { lock.withLock { invalidations += 1 } }
    func sample(_ sample: CMSampleBuffer, token: UInt64) {
        guard let pixel = CMSampleBufferGetImageBuffer(sample), CVPixelBufferGetPlaneCount(pixel) >= 1,
              CVPixelBufferGetWidthOfPlane(pixel, 0) == 2008, CVPixelBufferGetHeightOfPlane(pixel, 0) == 1428,
              CVPixelBufferLockBaseAddress(pixel, .readOnly) == kCVReturnSuccess else { fail("decoded buffer"); return }
        defer { CVPixelBufferUnlockBaseAddress(pixel, .readOnly) }
        guard let base = CVPixelBufferGetBaseAddressOfPlane(pixel, 0)?.assumingMemoryBound(to: UInt8.self) else {
            fail("decoded luma"); return
        }
        let value = base[714 * CVPixelBufferGetBytesPerRowOfPlane(pixel, 0) + 1004]
        lock.withLock { luma.append(value); tokens.append(token) }
    }
    var state: (luma: [UInt8], tokens: [UInt64], errors: [String], requests: Int, encoded: Int, invalidations: Int) {
        lock.withLock { (luma, tokens, errors, requests, encoded, invalidations) }
    }
}
enum Failure: Error { case timeout(String), invalid(String) }
@MainActor func wait(_ label: String, _ condition: () async -> Bool) async throws {
    let end = ContinuousClock.now + .seconds(6)
    while !(await condition()) {
        guard ContinuousClock.now < end else { throw Failure.timeout(label) }
        try await Task.sleep(for: .milliseconds(10))
    }
}
func frame(_ luminance: UInt8) throws -> CVPixelBuffer {
    var result: CVPixelBuffer?
    guard CVPixelBufferCreate(nil, 2008, 1428, kCVPixelFormatType_420YpCbCr8BiPlanarFullRange,
                              [kCVPixelBufferIOSurfacePropertiesKey: [:]] as CFDictionary, &result) == kCVReturnSuccess,
          let result, CVPixelBufferLockBaseAddress(result, []) == kCVReturnSuccess else { throw Failure.invalid("input") }
    defer { CVPixelBufferUnlockBaseAddress(result, []) }
    for plane in 0..<2 {
        guard let base = CVPixelBufferGetBaseAddressOfPlane(result, plane) else { throw Failure.invalid("plane") }
        memset(base, plane == 0 ? Int32(luminance) : 128,
               CVPixelBufferGetBytesPerRowOfPlane(result, plane) * CVPixelBufferGetHeightOfPlane(result, plane))
    }
    return result
}
@main
enum Check {
    @MainActor static func main() {
        setbuf(stdout, nil)
        let app = NSApplication.shared
        app.setActivationPolicy(.regular)
        let window = NSWindow(contentRect: CGRect(x: 160, y: 180, width: 640, height: 450),
                              styleMask: [.titled, .closable], backing: .buffered, defer: false)
        window.title = "DuoDesk • owned hardware presentation recovery check"
        window.isReleasedWhenClosed = false
        let content = NSView(frame: window.contentView!.bounds)
        content.wantsLayer = true; window.contentView = content
        let layer = AVSampleBufferDisplayLayer()
        layer.frame = content.bounds; content.layer!.addSublayer(layer)
        let results = Results()
        let presenter = HardwareVideoPresenter(renderer: layer.sampleBufferRenderer, onFirstImage: { _, _ in },
            onFailure: { message, _, _ in results.fail(message) })
        let router = HardwareDecoderRouter(onFormat: { _, token in presenter.reset(token) }, onSample: { sample, token, permit in
            results.sample(sample, token: token); presenter.enqueue(sample, generation: token, permit: permit)
        }, onFailure: { message, _ in results.fail(message) }, onNeedsKeyframe: { _ in results.request() },
        onReset: { token in presenter.reset(token) }, onOutputInvalidated: { permit, token in
            results.invalidate(); presenter.invalidateOutput(permit, generation: token)
        })
        window.makeKeyAndOrderFront(nil); app.activate()
        Task { @MainActor in
            do {
                router.require(DuoDesktopResolution(width: 2007, height: 1427))
                let encoder = try HEVCEncoder(width: 2008, height: 1428, fps: 120, bitrate: 20_000_000,
                                              prioritizeSpeed: true, software: false, quiet: true)
                let loop = try await LoopbackVideo.connect(decoder: router, encoder: encoder)
                results.attach(loop)
                defer { results.attach(nil); loop.close(); _ = router.clear(); _ = encoder.abandon() }
                try await wait("initial reset") { loop.counters.resets > 0 }
                encoder.onEncoded = { bytes, keyframe, parameters in
                    results.sent(); loop.sendEncoded(bytes, keyframe: keyframe, parameters: parameters)
                }
                encoder.encode(try frame(48), pts: CMTime(value: 1, timescale: 120))
                try await wait("initial presentation") {
                    guard let token = results.state.tokens.first else { return !results.state.errors.isEmpty }
                    return presenter.isReady(token) || !results.state.errors.isEmpty
                }
                guard let token = results.state.tokens.first, results.state.luma.first.map({ $0 < 100 }) == true,
                      results.state.errors.isEmpty else { throw Failure.invalid("initial image") }
                encoder.encode(try frame(192), pts: CMTime(value: 2, timescale: 120))
                try await wait("hardware output held in presenter") { await ReceiverFault.gate.state.held || !results.state.errors.isEmpty }
                guard results.state.errors.isEmpty else { throw Failure.invalid("held image") }
                router.enqueue(Data(), isKeyframe: false)
                try await wait("recovery keyframe presented") {
                    let sequence = await presenter.pump.lastSequence
                    let state = results.state, gate = await ReceiverFault.gate.state
                    return (sequence >= 3 && state.luma.count >= 3 && state.invalidations >= 1 && gate.flushes >= 1)
                        || !state.errors.isEmpty
                }
                try loop.check()
                let state = results.state, gate = await ReceiverFault.gate.state
                let sequence = await presenter.pump.lastSequence
                guard state.errors.isEmpty, state.requests >= 1, state.encoded >= 3, state.invalidations == 1,
                      state.tokens.allSatisfy({ $0 == token }), state.luma.last.map({ $0 > 150 }) == true,
                      loop.counters.keyframes >= 2, gate.flushes >= 1, sequence >= 3, presenter.isReady(token) else {
                    throw Failure.invalid("recovery outcome: \(state), gate=\(gate), sequence=\(sequence)")
                }
                print("PRESENTER EPOCH INTEGRATED PASS: hardware HEVC, local mutual-TLS QUIC, injected gap and suspended receiver; fresh same-generation frame accepted by AVFoundation, luma=\(state.luma), sequence=\(sequence), flushes=\(gate.flushes)")
                print("SCOPE: synthetic frames, owned window, injected receiver delay; renderer acceptance, not panel pixels, actual desktop, FPS, WAN or Duo")
                await ReceiverFault.gate.flushed(); window.close(); app.terminate(nil)
            } catch {
                print("PRESENTER EPOCH INTEGRATED FAIL: \(error)")
                await ReceiverFault.gate.flushed(); window.close(); exit(1)
            }
        }
        app.run()
    }
}
