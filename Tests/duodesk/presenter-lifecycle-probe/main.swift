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
enum CheckError: Error { case failed(String) }
func require(_ value: @autoclosure () -> Bool, _ message: String) throws {
    if !value() { throw CheckError.failed(message) }
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
        var pixel: CVPixelBuffer?
        let attributes = [kCVPixelBufferIOSurfacePropertiesKey: [:]] as CFDictionary
        guard CVPixelBufferCreate(nil, 640, 360, kCVPixelFormatType_420YpCbCr8BiPlanarFullRange,
                                  attributes, &pixel) == kCVReturnSuccess, let pixel else {
            throw CheckError.failed("could not create the owned image")
        }
        CVPixelBufferLockBaseAddress(pixel, [])
        for plane in 0..<CVPixelBufferGetPlaneCount(pixel) {
            memset(CVPixelBufferGetBaseAddressOfPlane(pixel, plane), 128,
                   CVPixelBufferGetBytesPerRowOfPlane(pixel, plane) * CVPixelBufferGetHeightOfPlane(pixel, plane))
        }
        CVPixelBufferUnlockBaseAddress(pixel, [])
        var description: CMVideoFormatDescription?
        guard CMVideoFormatDescriptionCreateForImageBuffer(allocator: nil, imageBuffer: pixel,
              formatDescriptionOut: &description) == noErr, let description else { throw CheckError.failed("image format") }
        window.makeKeyAndOrderFront(nil)
        app.activate()
        Task { @MainActor in
            var sequence: Int64 = 0
            @MainActor func feed(_ generation: UInt64, frames: Int = 80) async throws {
                for _ in 0..<frames {
                    sequence += 1
                    var timing = CMSampleTimingInfo(duration: CMTime(value: 1, timescale: 120),
                        presentationTimeStamp: CMTime(value: sequence, timescale: 120), decodeTimeStamp: .invalid)
                    var sample: CMSampleBuffer?
                    guard CMSampleBufferCreateReadyWithImageBuffer(allocator: nil, imageBuffer: pixel,
                          formatDescription: description, sampleTiming: &timing, sampleBufferOut: &sample) == noErr,
                          let sample else { throw CheckError.failed("image sample") }
                    presenter.enqueue(sample, generation: generation)
                    try await Task.sleep(for: .milliseconds(5))
                }
            }
            do {
                presenter.reset(1)
                try await feed(1)
                try require(presenter.isReady(1), "initial surface did not become ready")
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
                var timing = CMSampleTimingInfo(duration: CMTime(value: 1, timescale: 120),
                    presentationTimeStamp: .zero, decodeTimeStamp: .invalid)
                var finalSample: CMSampleBuffer?
                guard CMSampleBufferCreateReadyWithImageBuffer(allocator: nil, imageBuffer: pixel,
                      formatDescription: description, sampleTiming: &timing, sampleBufferOut: &finalSample) == noErr,
                      let finalSample else { throw CheckError.failed("final image") }
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
