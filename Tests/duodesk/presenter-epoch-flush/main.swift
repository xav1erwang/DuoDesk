// Copyright 2026 DUO你电脑 contributors. SPDX-License-Identifier: Apache-2.0
// An injected suspension represents a blocked receiver enqueue; the other frames use AVFoundation.
import AppKit
import AVFoundation
import CoreMedia
import CoreVideo
import Foundation
import StreamProtocol

actor ReceiverGate {
    private var continuation: CheckedContinuation<Void, any Error>?
    private var flushContinuation: CheckedContinuation<Void, Never>?
    private var held = false, flushHeld = false, flushCount = 0
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
    func beforeFlush(_ removing: Bool) async {
        flushed()
        if !removing { await holdFlushIfRequested() }
    }
    func holdFlushIfRequested() async {
        guard CommandLine.arguments.contains("--hold-flush") else { return }
        flushHeld = true
        await withCheckedContinuation { flushContinuation = $0 }
    }
    func releaseFlush() { flushContinuation?.resume(); flushContinuation = nil }
    var state: (held: Bool, flushes: Int, flushHeld: Bool) { (held, flushCount, flushHeld) }
}
enum ReceiverFault { static let gate = ReceiverGate() }
final class Errors: @unchecked Sendable {
    private let lock = NSLock(); private var messages: [String] = []
    func add(_ message: String) { lock.withLock { messages.append(message) } }
    var all: [String] { lock.withLock { messages } }
}
enum Failure: Error { case invalid(String), timeout(String) }
func sample(_ sequence: Int64) throws -> CMSampleBuffer {
    var pixel: CVPixelBuffer?
    guard CVPixelBufferCreate(nil, 2008, 1428, kCVPixelFormatType_420YpCbCr8BiPlanarFullRange,
                              [kCVPixelBufferIOSurfacePropertiesKey: [:]] as CFDictionary, &pixel) == kCVReturnSuccess,
          let pixel, CVPixelBufferLockBaseAddress(pixel, []) == kCVReturnSuccess else { throw Failure.invalid("pixel") }
    defer { CVPixelBufferUnlockBaseAddress(pixel, []) }
    for plane in 0..<2 {
        guard let base = CVPixelBufferGetBaseAddressOfPlane(pixel, plane) else { throw Failure.invalid("plane") }
        memset(base, plane == 0 ? 96 : 128,
               CVPixelBufferGetBytesPerRowOfPlane(pixel, plane) * CVPixelBufferGetHeightOfPlane(pixel, plane))
    }
    var format: CMVideoFormatDescription?
    guard CMVideoFormatDescriptionCreateForImageBuffer(allocator: nil, imageBuffer: pixel, formatDescriptionOut: &format) == noErr,
          let format else { throw Failure.invalid("format") }
    var timing = CMSampleTimingInfo(duration: CMTime(value: 1, timescale: 120),
        presentationTimeStamp: CMTime(value: sequence, timescale: 120), decodeTimeStamp: .invalid)
    var result: CMSampleBuffer?
    guard CMSampleBufferCreateReadyWithImageBuffer(allocator: nil, imageBuffer: pixel, formatDescription: format,
        sampleTiming: &timing, sampleBufferOut: &result) == noErr, let result else { throw Failure.invalid("sample") }
    return result
}
@MainActor func wait(_ name: String, timeout: Duration = .seconds(3), _ condition: () async -> Bool) async throws {
    let deadline = ContinuousClock.now + timeout
    while !(await condition()) {
        guard ContinuousClock.now < deadline else { throw Failure.timeout(name) }
        try await Task.sleep(for: .milliseconds(10))
    }
}

@main
enum Check {
    @MainActor static func main() {
        setbuf(stdout, nil)
        let app = NSApplication.shared
        app.setActivationPolicy(.regular)
        let window = NSWindow(contentRect: CGRect(x: 160, y: 180, width: 640, height: 450),
                              styleMask: [.titled, .closable], backing: .buffered, defer: false)
        window.title = "DuoDesk • owned receiver recovery check"
        window.isReleasedWhenClosed = false
        let content = NSView(frame: window.contentView!.bounds)
        content.wantsLayer = true; window.contentView = content
        let layer = AVSampleBufferDisplayLayer()
        layer.frame = content.bounds; content.layer!.addSublayer(layer)
        let errors = Errors()
        let presenter = HardwareVideoPresenter(renderer: layer.sampleBufferRenderer, onFirstImage: { _, _ in },
            onFailure: { message, _, _ in errors.add(message) })
        let router = HardwareDecoderRouter(onFormat: { _, _ in }, onSample: { sample, token, permit in
            presenter.enqueue(sample, generation: token, permit: permit)
        }, onFailure: { message, _ in errors.add(message) },
        onOutputInvalidated: { permit, token in presenter.invalidateOutput(permit, generation: token) })
        window.makeKeyAndOrderFront(nil); app.activate()
        Task { @MainActor in
            do {
                let token = router.require(DuoDesktopResolution(width: 2007, height: 1427))
                try await wait("initial retirement") { router.lock.withLock { router.retiring.isEmpty } }
                presenter.reset(token)
                let (decoder, id) = router.lock.withLock { (router.decoder!, router.identity) }
                guard let oldPermit = decoder.admissionPermit(for: token) else { throw Failure.invalid("old permit") }
                // The fixture injects decoded samples directly instead of submitting to VT.
                decoder.lock.withLock { decoder.outputPermitHasFlight = true }
                router.sample(try sample(1), token: token, identity: id, permit: oldPermit)
                try await wait("initial image") { presenter.isReady(token) || !errors.all.isEmpty }
                guard errors.all.isEmpty else { throw Failure.invalid("initial renderer") }
                let initialFlushes = await ReceiverFault.gate.state.flushes
                router.sample(try sample(2), token: token, identity: id, permit: oldPermit)
                try await wait("receiver enqueue held") { await ReceiverFault.gate.state.held }
                router.enqueue(Data(), isKeyframe: false)
                guard !oldPermit.isValid, let nextPermit = decoder.admissionPermit(for: token), nextPermit !== oldPermit else {
                    throw Failure.invalid("epoch reset")
                }
                router.sample(try sample(3), token: token, identity: id, permit: nextPermit)
                var expectedToken = token, expectedSequence: Int64 = 3
                var inputInvalidated = true
                if CommandLine.arguments.contains("--hold-flush") {
                    try await wait("receiver flush held") { await ReceiverFault.gate.state.flushHeld }
                    try await wait("fresh sample waits for flush") { await presenter.pump.flushWaiters.count == 1 }
                    if CommandLine.arguments.contains("--reset") {
                        let oldInput = presenter.makeInputFence(token)
                        guard oldInput() else { throw Failure.invalid("old input not ready") }
                        expectedToken = router.clear(); presenter.reset(expectedToken)
                        inputInvalidated = !oldInput()
                        let (next, nextID) = router.lock.withLock { (router.decoder!, router.identity) }
                        guard let permit = next.admissionPermit(for: expectedToken) else { throw Failure.invalid("new permit") }
                        router.sample(try sample(4), token: expectedToken, identity: nextID, permit: permit)
                        expectedSequence = 4
                        try await wait("reset preserves image-removal request") { await presenter.pump.pendingImageRemoval }
                    }
                    await ReceiverFault.gate.releaseFlush()
                }
                var recovered = false
                do {
                    try await wait("fresh image after invalidated enqueue", timeout: .seconds(2)) {
                        await presenter.pump.lastSequence == expectedSequence || !errors.all.isEmpty
                    }
                    let finalSequence = await presenter.pump.lastSequence
                    recovered = errors.all.isEmpty && finalSequence == expectedSequence && presenter.isReady(expectedToken)
                } catch { recovered = false }
                let state = await ReceiverFault.gate.state
                presenter.invalidateOutput(oldPermit, generation: token)
                try await Task.sleep(for: .milliseconds(100))
                let delayedState = await ReceiverFault.gate.state
                let finalSequence = await presenter.pump.lastSequence
                let requiredFlushes = CommandLine.arguments.contains("--reset") ? 2 : 1
                recovered = recovered && inputInvalidated && state.flushes - initialFlushes == requiredFlushes
                    && delayedState.flushes == state.flushes && finalSequence == expectedSequence
                print("\(recovered ? "PASS" : "FAIL") held enqueue recovery: held=\(state.held), flushes=\(state.flushes), fresh=\(recovered), errors=\(errors.all.count)")
                print("SCOPE: owned window, real renderer for initial/fresh samples, artificial pre-enqueue suspension and gap; not a real AVFoundation hang, desktop, network or Duo")
                await ReceiverFault.gate.releaseFlush(); await ReceiverFault.gate.flushed()
                _ = router.clear(); window.close()
                if recovered { app.terminate(nil) } else { exit(1) }
            } catch {
                print("PRESENTER EPOCH FLUSH FAIL: \(error)")
                await ReceiverFault.gate.releaseFlush(); await ReceiverFault.gate.flushed(); window.close(); exit(1)
            }
        }
        app.run()
    }
}
