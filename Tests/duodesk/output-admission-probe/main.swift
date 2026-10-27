// Copyright 2026 DUO你电脑 contributors. SPDX-License-Identifier: Apache-2.0
// Hold the consumer between the router's final check and its admission to test failure fencing.
import CoreMedia
import CoreVideo
import Foundation
import StreamProtocol
import VideoToolbox

final class Results: @unchecked Sendable {
    private let lock = NSLock()
    private var admitted = 0, failures = 0
    func admit() { lock.withLock { admitted += 1 } }
    func fail() { lock.withLock { failures += 1 } }
    var state: (admitted: Int, failures: Int) { lock.withLock { (admitted, failures) } }
}
final class Once: @unchecked Sendable {
    private let lock = NSLock(); private var first = true
    func take() -> Bool { lock.withLock { defer { first = false }; return first } }
}
func sample() -> CMSampleBuffer {
    var pixel: CVPixelBuffer?
    guard CVPixelBufferCreate(nil, 16, 16, kCVPixelFormatType_420YpCbCr8BiPlanarFullRange, nil, &pixel) == kCVReturnSuccess,
          let pixel else { fatalError("pixel") }
    var format: CMVideoFormatDescription?
    guard CMVideoFormatDescriptionCreateForImageBuffer(allocator: nil, imageBuffer: pixel, formatDescriptionOut: &format) == noErr,
          let format else { fatalError("format") }
    var timing = CMSampleTimingInfo(duration: .invalid, presentationTimeStamp: .zero, decodeTimeStamp: .invalid)
    var buffer: CMSampleBuffer?
    guard CMSampleBufferCreateReadyWithImageBuffer(allocator: nil, imageBuffer: pixel, formatDescription: format,
        sampleTiming: &timing, sampleBufferOut: &buffer) == noErr, let buffer else { fatalError("sample") }
    return buffer
}
let entered = DispatchSemaphore(value: 0), release = DispatchSemaphore(value: 0), done = DispatchSemaphore(value: 0)
let results = Results(), once = Once()
let router = HardwareDecoderRouter(onFormat: { _, _ in }, onSample: { _, _, permit in
    if once.take() { entered.signal(); release.wait() }
    permit.admit { results.admit() }
}, onFailure: { _, _ in results.fail() })
let token = router.require(DuoDesktopResolution(width: 2007, height: 1427))
let retirementDeadline = ProcessInfo.processInfo.systemUptime + 2
while !router.lock.withLock({ router.retiring.isEmpty }) && ProcessInfo.processInfo.systemUptime < retirementDeadline {
    Thread.sleep(forTimeInterval: 0.005)
}
guard router.lock.withLock({ router.retiring.isEmpty }) else { fatalError("initial retirement did not finish") }
let (decoder, id) = router.lock.withLock { (router.decoder!, router.identity) }
let permit = decoder.admissionPermit(for: token)!
let image = sample()
DispatchQueue.global(qos: .userInitiated).async { router.sample(image, token: token, identity: id, permit: permit); done.signal() }
let held = entered.wait(timeout: .now() + 2) == .success
decoder.fail(kVTVideoDecoderBadDataErr, generation: token)
let failedBeforeRelease = results.state.failures == 1
release.signal()
let returned = done.wait(timeout: .now() + 2) == .success
let fenced = held && failedBeforeRelease && returned && results.state.admitted == 0
let fresh = router.clear(), freshID = router.lock.withLock { router.identity }
let freshPermit = router.lock.withLock { router.decoder!.admissionPermit(for: fresh)! }
router.sample(image, token: fresh, identity: freshID, permit: freshPermit)
let beforeResize = router.lock.withLock { router.decoder!.admissionPermit(for: fresh) }
let resized = router.require(DuoDesktopResolution(width: 2005, height: 1425))
let resizeFenced = resized > fresh && beforeResize?.isValid == false
let beforeReset = router.lock.withLock { router.decoder!.admissionPermit(for: resized) }
let reset = router.clear()
let resetFenced = reset > resized && beforeReset?.isValid == false
var disposable: HardwareHEVCDecoder? = HardwareHEVCDecoder(onFormat: { _, _ in }, onSample: { _, _, _ in }, onFailure: { _, _ in })
let finalPermit = disposable?.admissionPermit(for: 0)
weak var releasedDecoder = disposable
disposable = nil
let released = releasedDecoder == nil && finalPermit?.isValid == false
let passed = fenced && fresh > token && results.state.admitted == 1 && resizeFenced && resetFenced && released
print("\(passed ? "PASS" : "FAIL") delayed output denied after failure; new generation admitted=\(results.state.admitted), resize=\(resizeFenced), reset=\(resetFenced), release=\(released), failures=\(results.state.failures)")
_ = router.clear()
exit(passed ? 0 : 1)
