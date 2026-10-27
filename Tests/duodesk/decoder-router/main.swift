// Copyright 2026 DUO你电脑 contributors. SPDX-License-Identifier: Apache-2.0
import CoreMedia
import CoreVideo
import Foundation
import StreamProtocol
import VideoToolbox

final class Results: @unchecked Sendable {
    private let lock = NSLock()
    private var samples = 0, formats = 0, failures = 0
    func sample() { lock.withLock { samples += 1 } }
    func format() { lock.withLock { formats += 1 } }
    func failure() { lock.withLock { failures += 1 } }
    var state: (samples: Int, formats: Int, failures: Int) { lock.withLock { (samples, formats, failures) } }
}
func makeRouter(_ results: Results) -> HardwareDecoderRouter {
    HardwareDecoderRouter(onFormat: { _, _ in results.format() }, onSample: { _, _, _ in results.sample() },
                          onFailure: { _, _ in results.failure() })
}
func wait(_ condition: () -> Bool, timeout: TimeInterval = 2) -> Bool {
    let deadline = ProcessInfo.processInfo.systemUptime + timeout
    while ProcessInfo.processInfo.systemUptime < deadline {
        if condition() { return true }
        Thread.sleep(forTimeInterval: 0.005)
    }
    return condition()
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
var checks = 0, failures = 0
func check(_ name: String, _ condition: Bool) {
    checks += 1; if !condition { failures += 1 }
    print("\(condition ? "PASS" : "FAIL") \(name)")
}
let native = DuoDesktopResolution(width: 2007, height: 1427)
let changed = DuoDesktopResolution(width: 2005, height: 1425)
let results = Results(), router = makeRouter(results)
let first = router.require(native)
check("initial retirement completes", wait { router.lock.withLock { router.retiring.isEmpty } })
let (old, oldID) = router.lock.withLock { (router.decoder!, router.identity) }
let oldPermit = old.admissionPermit(for: first)!
let gate = DispatchSemaphore(value: 0), entered = DispatchSemaphore(value: 0)
old.queue.async { entered.signal(); gate.wait() }
let blocked = entered.wait(timeout: .now() + 2) == .success
let invalid = ParameterSets(nalUnitHeaderLength: 4, sets: [Data([1]), Data([2]), Data([3])])
router.apply(invalid); router.enqueue(Data([1]), isKeyframe: true)
let second = router.clear()
let (replacement, replacementID, retiring) = router.lock.withLock { (router.decoder!, router.identity, router.retiring.count) }
router.sample(sample(), token: first, identity: oldID, permit: oldPermit)
router.format(CGSize(width: 16, height: 16), token: first, identity: oldID)
router.failed("old", token: first, identity: oldID)
check("blocked predecessor is replaced and old callbacks are fenced", blocked && replacement !== old && second > first
      && retiring == 1 && results.state.samples == 0 && results.state.formats == 0 && results.state.failures == 0)
let third = router.clear()
check("a second reset keeps the one-retiring-session limit", third > second && router.lock.withLock {
    router.decoder === replacement && router.identity == replacementID && router.retiring.count == 1
})
gate.signal()
let drained = wait { router.lock.withLock { router.retiring.isEmpty } }
check("retirement completes without reviving queued old input", drained && results.state.formats == 0 && results.state.failures == 0)
let fourth = router.clear()
check("a drained slot allows a later replacement", fourth > third && router.lock.withLock { router.decoder !== replacement })

let failResults = Results(), failRouter = makeRouter(failResults)
let failToken = failRouter.require(native)
_ = wait { failRouter.lock.withLock { failRouter.retiring.isEmpty } }
let failedDecoder = failRouter.lock.withLock { failRouter.decoder! }
failedDecoder.fail(kVTVideoDecoderBadDataErr, generation: failToken)
check("failure without parameters is reported without retry", failResults.state.failures == 1
      && failRouter.isCurrent(failToken) && !failRouter.canOutput(failToken)
      && failRouter.lock.withLock { failRouter.decoder === failedDecoder })

let resizeResults = Results(), resize = makeRouter(resizeResults)
let sizeToken = resize.require(native)
_ = wait { resize.lock.withLock { resize.retiring.isEmpty } }
let sizeOld = resize.lock.withLock { resize.decoder! }
let sizeGate = DispatchSemaphore(value: 0), sizeEntered = DispatchSemaphore(value: 0)
sizeOld.queue.async { sizeEntered.signal(); sizeGate.wait() }
let sizeBlocked = sizeEntered.wait(timeout: .now() + 2) == .success
let resized = resize.require(changed)
check("resolution change also isolates a blocked previous queue", sizeBlocked && resized > sizeToken
      && !resize.canOutput(sizeToken) && resize.lock.withLock { resize.decoder !== sizeOld && resize.retiring.count == 1 })
sizeGate.signal()
_ = wait { resize.lock.withLock { resize.retiring.isEmpty } }

let fullResults = Results(), full = makeRouter(fullResults)
_ = full.require(native)
_ = wait { full.lock.withLock { full.retiring.isEmpty } }
let firstBlocked = full.lock.withLock { full.decoder! }
let firstGate = DispatchSemaphore(value: 0), firstEntered = DispatchSemaphore(value: 0)
firstBlocked.queue.async { firstEntered.signal(); firstGate.wait() }
let firstReady = firstEntered.wait(timeout: .now() + 2) == .success
_ = full.clear()
let secondBlocked = full.lock.withLock { full.decoder! }
let secondGate = DispatchSemaphore(value: 0), secondEntered = DispatchSemaphore(value: 0)
secondBlocked.queue.async { secondEntered.signal(); secondGate.wait() }
let secondReady = secondEntered.wait(timeout: .now() + 2) == .success
_ = full.clear(); _ = full.clear()
let now = ProcessInfo.processInfo.systemUptime
secondBlocked.lock.withLock { secondBlocked.queueCheckpointAt = now - 10; secondBlocked.lastWatchdogCheck = now - 10 }
secondBlocked.checkWatchdog()
let grace = fullResults.state.failures == 0 && secondBlocked.lock.withLock {
    secondBlocked.queueCheckpointAgain && secondBlocked.queueCheckpointAt.map { ProcessInfo.processInfo.systemUptime - $0 < 1 } == true
}
let later = ProcessInfo.processInfo.systemUptime
secondBlocked.lock.withLock { secondBlocked.queueCheckpointAt = later - 4; secondBlocked.lastWatchdogCheck = later }
secondBlocked.checkWatchdog()
let fenced = full.clear()
full.apply(invalid); full.apply(invalid)
let reported = wait { fullResults.state.failures == 2 }
check("a full retirement slot detects a blocked reset and does not silently reuse a failed queue", firstReady && secondReady
      && grace && reported && !full.canOutput(fenced) && full.lock.withLock {
          full.decoder === secondBlocked && full.retiring.count == 1
      })
firstGate.signal(); secondGate.signal()
_ = wait { full.lock.withLock { full.retiring.isEmpty } }

let raceResults = Results(), racing = makeRouter(raceResults)
_ = racing.require(native)
_ = wait { racing.lock.withLock { racing.retiring.isEmpty } }
let group = DispatchGroup()
for _ in 0..<24 {
    group.enter(); DispatchQueue.global(qos: .userInitiated).async { _ = racing.clear(); group.leave() }
    group.enter(); DispatchQueue.global(qos: .userInitiated).async { racing.enqueue(Data([1]), isKeyframe: false); group.leave() }
}
let finished = group.wait(timeout: .now() + 5) == .success
check("concurrent resets and admissions stay bounded without deadlock", finished && racing.lock.withLock { racing.retiring.count <= 1 })
_ = router.clear(); _ = failRouter.clear(); _ = resize.clear(); _ = full.clear(); _ = racing.clear()
print("DECODER ROUTER: \(checks) checks, \(failures) failures; synthetic state and queue blocking only")
exit(failures == 0 ? 0 : 1)
