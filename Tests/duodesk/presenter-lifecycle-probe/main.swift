// Real AVFoundation presentation, including a removed/reinserted layer. No capture, codec,
// keychain or input injection. Old input permits must stay invalid after a surface rehost.
import AppKit
import AVFoundation
import CoreMedia
import CoreVideo

final class Observations: @unchecked Sendable {
    let lock = NSLock()
    var firstImages: [UInt64] = []
    var errors: [String] = []
}
/// Only the instrumented test copy requests a renderer reset on its first image.
final class PresenterResumeFault: @unchecked Sendable {
    static let shared = PresenterResumeFault()
    private let lock = NSLock()
    private var pending = CommandLine.arguments.contains("--flush-required")
    func take() -> Bool {
        lock.withLock { defer { pending = false }; return pending }
    }
}
enum CheckError: Error { case failed(String) }
func require(_ value: @autoclosure () -> Bool, _ message: String) throws {
    if !value() { throw CheckError.failed(message) }
}
/// Each queued sample owns a separate pixel buffer. The renderer can attach colour metadata to a
/// buffer it receives, so reusing that buffer with an earlier format description is unsafe.
func makeSample(_ sequence: Int64) throws -> CMSampleBuffer {
    var pixel: CVPixelBuffer?
    let attributes = [kCVPixelBufferIOSurfacePropertiesKey: [:]] as CFDictionary
    guard CVPixelBufferCreate(nil, 640, 360, kCVPixelFormatType_420YpCbCr8BiPlanarFullRange,
                              attributes, &pixel) == kCVReturnSuccess, let pixel,
          CVPixelBufferLockBaseAddress(pixel, []) == kCVReturnSuccess else {
        throw CheckError.failed("could not create the owned image")
    }
    for plane in 0..<CVPixelBufferGetPlaneCount(pixel) {
        memset(CVPixelBufferGetBaseAddressOfPlane(pixel, plane), 128,
               CVPixelBufferGetBytesPerRowOfPlane(pixel, plane) * CVPixelBufferGetHeightOfPlane(pixel, plane))
    }
    CVPixelBufferUnlockBaseAddress(pixel, [])
    var description: CMVideoFormatDescription?
    guard CMVideoFormatDescriptionCreateForImageBuffer(allocator: nil, imageBuffer: pixel,
          formatDescriptionOut: &description) == noErr, let description else { throw CheckError.failed("image format") }
    var timing = CMSampleTimingInfo(duration: CMTime(value: 1, timescale: 120),
        presentationTimeStamp: CMTime(value: sequence, timescale: 120), decodeTimeStamp: .invalid)
    var sample: CMSampleBuffer?
    let status = CMSampleBufferCreateReadyWithImageBuffer(allocator: nil, imageBuffer: pixel,
        formatDescription: description, sampleTiming: &timing, sampleBufferOut: &sample)
    guard status == noErr, let sample else {
        throw CheckError.failed("image sample status=\(status), sequence=\(sequence)")
    }
    return sample
}

@main enum PresenterLifecycleCheck {
    @MainActor static func main() throws {
        setbuf(stdout, nil)
        let app = NSApplication.shared
        app.setActivationPolicy(.regular)
        let window = NSWindow(contentRect: CGRect(x: 160, y: 180, width: 640, height: 360),
                              styleMask: [.titled, .closable], backing: .buffered, defer: false)
        window.title = "DuoDesk • owned presentation check"
        window.isReleasedWhenClosed = false
        let content = NSView(frame: window.contentView!.bounds)
        content.wantsLayer = true
        window.contentView = content
        let layer = AVSampleBufferDisplayLayer()
        layer.frame = content.bounds
        content.layer!.addSublayer(layer)
        let observations = Observations()
        let presenter = HardwareVideoPresenter(renderer: layer.sampleBufferRenderer, onFirstImage: { _, generation in
            observations.lock.withLock { observations.firstImages.append(generation) }
        }, onFailure: { message, _, _ in observations.lock.withLock { observations.errors.append(message) } })
        window.makeKeyAndOrderFront(nil)
        app.activate()
        Task { @MainActor in
            var sequence: Int64 = 0
            @MainActor func feed(_ generation: UInt64, frames: Int = 80) async throws {
                for _ in 0..<frames {
                    sequence += 1
                    let sample = try makeSample(sequence)
                    presenter.enqueue(sample, generation: generation)
                    try await Task.sleep(for: .milliseconds(5))
                }
            }
            do {
                presenter.reset(1)
                let checkResume = CommandLine.arguments.contains("--flush-required")
                try await feed(1, frames: checkResume ? 1 : 80)
                if checkResume {
                    for _ in 0..<200 {
                        if presenter.isReady(1) { break }
                        try await Task.sleep(for: .milliseconds(10))
                    }
                }
                try require(presenter.isReady(1), "initial surface did not become ready")
                if checkResume {
                    try require(observations.lock.withLock { observations.errors.isEmpty && observations.firstImages == [1] },
                                "first-image flush did not resume exactly once")
                    print("Presentation resume PASS: one first image survived a required renderer flush without disconnecting or waiting for another frame")
                }
                let queuedBeforeRehost = presenter.makeInputFence(1)
                try require(queuedBeforeRehost(), "initial input permit was invalid")
                layer.removeFromSuperlayer()
                presenter.refreshSurface(1)
                try require(!queuedBeforeRehost() && !presenter.isReady(1), "detached surface retained input permission")
                try await feed(1, frames: 40)
                content.layer!.addSublayer(layer)
                presenter.refreshSurface(1)
                try await feed(1)
                try require(presenter.isReady(1), "reattached surface stalled")
                try require(!queuedBeforeRehost(), "old input revived after reattachment")
                for _ in 0..<8 {
                    let old = presenter.makeInputFence(1)
                    try require(old(), "surface not ready before refresh")
                    presenter.refreshSurface(1)
                    try require(!old(), "refresh did not invalidate queued input immediately")
                    try await feed(1)
                    try require(presenter.isReady(1) && !old(), "refresh failed to resume or revived old input")
                }
                let oldGeneration = presenter.makeInputFence(1)
                presenter.reset(2)
                try require(!oldGeneration(), "a new video generation retained old input")
                try await feed(1, frames: 10)
                try require(!presenter.isReady(1), "an old image revived the previous generation")
                try await feed(2)
                try require(presenter.isReady(2), "new generation failed to display")
                let secondLayer = AVSampleBufferDisplayLayer()
                secondLayer.frame = content.bounds
                content.layer!.addSublayer(secondLayer)
                var discarded: HardwareVideoPresenter? = HardwareVideoPresenter(renderer: secondLayer.sampleBufferRenderer,
                    onFirstImage: { _, _ in }, onFailure: { _, _, _ in })
                discarded!.reset(9)
                let finalSample = try makeSample(0)
                discarded!.enqueue(finalSample, generation: 9)
                for _ in 0..<100 {
                    if discarded!.isReady(9) { break }
                    try await Task.sleep(for: .milliseconds(10))
                }
                try require(discarded!.isReady(9), "temporary presenter did not display")
                let queuedAfterRelease = discarded!.makeInputFence(9)
                weak let released = discarded
                discarded = nil
                try require(released == nil && !queuedAfterRelease(), "destroyed presenter retained input permission")
                try require(observations.lock.withLock { observations.errors.isEmpty }, "renderer reported a failure")
                print("Presentation lifecycle PASS: real layer rehost, 8 surface refreshes, old permits remain invalid, new generation resumes, destruction invalidates input")
                app.terminate(nil)
            } catch {
                print("Presentation lifecycle FAIL: \(error)")
                exit(1)
            }
        }
        app.run()
    }
}
