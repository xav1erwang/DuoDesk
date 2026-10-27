// Copyright 2026 DUO你电脑 contributors. SPDX-License-Identifier: Apache-2.0
// Real AVFoundation renderer and owned window; the output handoff delay is intentionally injected.
import AppKit
import AVFoundation
import CoreMedia
import CoreVideo
import Foundation
import StreamProtocol
import VideoToolbox

final class Observations: @unchecked Sendable {
    private let lock = NSLock()
    private var first: [UInt64] = [], errors: [String] = [], decoderFailures = 0
    func image(_ token: UInt64) { lock.withLock { first.append(token) } }
    func error(_ message: String) { lock.withLock { errors.append(message) } }
    func failed() { lock.withLock { decoderFailures += 1 } }
    var state: (first: [UInt64], errors: [String], failures: Int) { lock.withLock { (first, errors, decoderFailures) } }
}
final class Flag: @unchecked Sendable {
    private let lock = NSLock(); private var set = false
    func mark() { lock.withLock { set = true } }
    var value: Bool { lock.withLock { set } }
}
final class Once: @unchecked Sendable {
    private let lock = NSLock(); private var first = true
    func take() -> Bool { lock.withLock { defer { first = false }; return first } }
}
// This fixture creates an immutable sample before passing it to the worker queue.
final class SampleBox: @unchecked Sendable {
    let value: CMSampleBuffer
    init(_ value: CMSampleBuffer) { self.value = value }
}
enum Failure: Error { case invalid(String), timeout(String) }
@MainActor func wait(_ name: String, _ condition: () -> Bool) async throws {
    let deadline = ContinuousClock.now + .seconds(4)
    while !condition() {
        guard ContinuousClock.now < deadline else { throw Failure.timeout(name) }
        try await Task.sleep(for: .milliseconds(10))
    }
}
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

@main
enum Check {
    @MainActor static func main() throws {
        setbuf(stdout, nil)
        let app = NSApplication.shared
        app.setActivationPolicy(.regular)
        let window = NSWindow(contentRect: CGRect(x: 160, y: 180, width: 640, height: 450),
                              styleMask: [.titled, .closable], backing: .buffered, defer: false)
        window.title = "DuoDesk • owned output admission check"
        window.isReleasedWhenClosed = false
        let content = NSView(frame: window.contentView!.bounds)
        content.wantsLayer = true; window.contentView = content
        let layer = AVSampleBufferDisplayLayer()
        layer.frame = content.bounds; content.layer!.addSublayer(layer)
        let observations = Observations(), entered = Flag(), returned = Flag(), release = DispatchSemaphore(value: 0), once = Once()
        let presenter = HardwareVideoPresenter(renderer: layer.sampleBufferRenderer, onFirstImage: { _, token in observations.image(token) },
            onFailure: { message, _, _ in observations.error(message) })
        let router = HardwareDecoderRouter(onFormat: { _, _ in }, onSample: { buffer, token, permit in
            if once.take() { entered.mark(); release.wait() }
            presenter.enqueue(buffer, generation: token, permit: permit)
        }, onFailure: { _, token in presenter.refreshSurface(token); observations.failed() })
        window.makeKeyAndOrderFront(nil); app.activate()
        Task { @MainActor in
            defer { release.signal(); window.close() }
            do {
                let old = router.require(DuoDesktopResolution(width: 2007, height: 1427))
                try await wait("initial decoder retirement") { router.lock.withLock { router.retiring.isEmpty } }
                presenter.reset(old)
                let (decoder, id) = router.lock.withLock { (router.decoder!, router.identity) }
                let first = SampleBox(try sample(1))
                DispatchQueue.global(qos: .userInitiated).async {
                    router.sample(first.value, token: old, identity: id); returned.mark()
                }
                try await wait("old callback held") { entered.value }
                decoder.fail(kVTVideoDecoderBadDataErr, generation: old)
                guard observations.state.failures == 1 else { throw Failure.invalid("failure was not delivered") }
                release.signal()
                try await wait("old callback returned") { returned.value }
                try await Task.sleep(for: .milliseconds(300))
                guard !presenter.isReady(old), observations.state.first.isEmpty else {
                    throw Failure.invalid("old image admitted after decoder failure")
                }
                let next = router.clear(), nextID = router.lock.withLock { router.identity }
                presenter.reset(next)
                router.sample(try sample(2), token: next, identity: nextID)
                try await wait("fresh presenter image") { presenter.isReady(next) || !observations.state.errors.isEmpty }
                guard observations.state.errors.isEmpty, observations.state.first == [next], next > old else {
                    throw Failure.invalid("fresh generation failed to present")
                }
                let previousInput = presenter.makeInputFence(next)
                guard previousInput() else { throw Failure.invalid("fresh input fence") }
                let active = router.lock.withLock { router.decoder! }
                active.fail(kVTVideoDecoderBadDataErr, generation: next)
                guard observations.state.failures == 2, !previousInput(), !presenter.isReady(next), !router.canOutput(next) else {
                    throw Failure.invalid("failure did not invalidate displayed input")
                }
                let recovered = router.clear(), recoveredID = router.lock.withLock { router.identity }
                presenter.reset(recovered)
                for sequence in 3..<18 {
                    if presenter.isReady(recovered) { break }
                    router.sample(try sample(Int64(sequence)), token: recovered, identity: recoveredID)
                    try await Task.sleep(for: .milliseconds(20))
                }
                try await wait("presenter after failure flush") { presenter.isReady(recovered) || !observations.state.errors.isEmpty }
                guard observations.state.errors.isEmpty, observations.state.first == [next, recovered], !previousInput() else {
                    throw Failure.invalid("failure flush or input fence recovery")
                }
                print("PRESENTER OUTPUT ADMISSION PASS: delayed old image denied; fresh native-size samples admitted, failure invalidates input, next generation resumes")
                print("SCOPE: owned window, synthetic image and injected delay; no capture, network or real Duo")
                _ = router.clear(); app.terminate(nil)
            } catch {
                print("PRESENTER OUTPUT ADMISSION FAIL: \(error)")
                exit(1)
            }
        }
        app.run()
    }
}
