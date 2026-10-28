// Copyright 2026 DUO你电脑 contributors. SPDX-License-Identifier: Apache-2.0
// Artificially interleave production decoder output, backlog admission and presentation permit.
import CoreMedia
import CoreVideo
import Foundation
import StreamProtocol

let mode = CommandLine.arguments.dropFirst().first ?? "before-router"
enum EpochFault {
    static let entered = DispatchSemaphore(value: 0), release = DispatchSemaphore(value: 0)
    static let once = Once()
    static func beforeRouter() {
        if mode == "before-router" && once.take() { entered.signal(); release.wait() }
    }
}
final class Once: @unchecked Sendable {
    private let lock = NSLock(); private var first = true
    func take() -> Bool { lock.withLock { defer { first = false }; return first } }
}
final class Results: @unchecked Sendable {
    private let lock = NSLock(); private var admitted = 0, requests = 0, failures = 0, revocations = 0
    func admit() { lock.withLock { admitted += 1 } }
    func request() { lock.withLock { requests += 1 } }
    func fail() { lock.withLock { failures += 1 } }
    func revoke() { lock.withLock { revocations += 1 } }
    var state: (admitted: Int, requests: Int, failures: Int, revocations: Int) {
        lock.withLock { (admitted, requests, failures, revocations) }
    }
}
func image() -> CVPixelBuffer {
    var result: CVPixelBuffer?
    guard CVPixelBufferCreate(nil, 16, 16, kCVPixelFormatType_420YpCbCr8BiPlanarFullRange, nil, &result) == kCVReturnSuccess,
          let result else { fatalError("pixel") }
    return result
}
let results = Results(), afterEntered = DispatchSemaphore(value: 0), afterRelease = DispatchSemaphore(value: 0), once = Once()
let done = DispatchSemaphore(value: 0)
let router = HardwareDecoderRouter(onFormat: { _, _ in }, onSample: { _, _, permit in
    if mode != "before-router" && once.take() { afterEntered.signal(); afterRelease.wait() }
    permit.admit { results.admit() }
}, onFailure: { _, _ in results.fail() }, onNeedsKeyframe: { _ in results.request() },
   onOutputInvalidated: { _, _ in results.revoke() })
let token = router.require(DuoDesktopResolution(width: 2007, height: 1427))
let deadline = ProcessInfo.processInfo.systemUptime + 2
while !router.lock.withLock({ router.retiring.isEmpty }) && ProcessInfo.processInfo.systemUptime < deadline {
    Thread.sleep(forTimeInterval: 0.005)
}
guard router.lock.withLock({ router.retiring.isEmpty }) else { fatalError("initial retirement") }
let decoder = router.lock.withLock { router.decoder! }
decoder.queue.sync { }
let flight = decoder.lock.withLock { () -> HardwareHEVCDecoder.Flight in
    let ticket = decoder.backlog.admit(bytes: 1, keyframe: true)!
    decoder.backlog.complete(ticket); decoder.inFlight = 1; decoder.inFlightBytes = 1
    decoder.outputPermitHasFlight = true
    return HardwareHEVCDecoder.Flight(generation: token, ticket: ticket, sequence: 1,
        started: ProcessInfo.processInfo.systemUptime, outputPermit: decoder.outputPermit!, compressedBytes: 1)
}
let buffer = image()
DispatchQueue.global(qos: .userInitiated).async {
    decoder.decoded(buffer, status: noErr, flags: [], flight: flight, pts: .invalid)
    done.signal()
}
let gate = mode == "before-router" ? EpochFault.entered : afterEntered
let held = gate.wait(timeout: .now() + 2) == .success
let before = decoder.lock.withLock { decoder.backlog.epoch }
var reservation: VideoDecodeBacklog.Ticket?
if mode == "preserved" {
    // Simulate a different large in-flight keyframe consuming the combined wire budget.
    decoder.lock.withLock { decoder.inFlight = 1; decoder.inFlightBytes = StreamMessage.maxFramePayload }
    decoder.enqueue(Data([1]), isKeyframe: false)
} else if mode == "overflow" || mode == "preserve-queue" {
    // Reserve queue space without allocating the compressed data. A normal eight MiB queue
    // invalidates its tickets; a larger queued keyframe remains valid through a later gap.
    let size = (mode == "overflow" ? 8 : 9) * 1024 * 1024
    reservation = decoder.lock.withLock { decoder.backlog.admit(bytes: size, keyframe: true) }
    decoder.enqueue(Data([1]), isKeyframe: false)
} else if mode == "missing" {
    let missing = decoder.lock.withLock { () -> HardwareHEVCDecoder.Flight in
        let ticket = decoder.backlog.admit(bytes: 1, keyframe: false)!
        decoder.backlog.complete(ticket); decoder.inFlight = 1; decoder.inFlightBytes = 1
        return HardwareHEVCDecoder.Flight(generation: token, ticket: ticket, sequence: 2,
            started: ProcessInfo.processInfo.systemUptime, outputPermit: decoder.outputPermit!, compressedBytes: 1)
    }
    decoder.decoded(nil, status: noErr, flags: [], flight: missing, pts: .invalid)
} else {
    decoder.enqueue(Data(), isKeyframe: false)
    // Empty-input floods must not queue a new invalidation event for every unused permit.
    if mode == "before-router" { for _ in 0..<12 { decoder.enqueue(Data(), isKeyframe: false) } }
}
let after = decoder.lock.withLock { decoder.backlog.epoch }
let activePermit = decoder.admissionPermit(for: token)!
let preserved = mode == "preserved" || mode == "preserve-queue"
let permitCorrect = preserved ? activePermit === flight.outputPermit && activePermit.isValid
                              : activePermit !== flight.outputPermit && activePermit.isValid && !flight.outputPermit.isValid
if mode == "before-router" { EpochFault.release.signal() } else { afterRelease.signal() }
let returned = done.wait(timeout: .now() + 2) == .success
router.recoveryQueue.sync { }
let state = results.state
if let reservation { decoder.lock.withLock { decoder.backlog.complete(reservation) } }
if mode == "preserved" { decoder.lock.withLock { decoder.inFlight = 0; decoder.inFlightBytes = 0 } }
// A later recovery keyframe must receive the current permit and reach the consumer.
let recovery = decoder.lock.withLock { () -> HardwareHEVCDecoder.Flight in
    let ticket = decoder.backlog.admit(bytes: 1, keyframe: true)!
    decoder.backlog.complete(ticket); decoder.inFlight = 1; decoder.inFlightBytes = 1
    return HardwareHEVCDecoder.Flight(generation: token, ticket: ticket, sequence: 3,
        started: ProcessInfo.processInfo.systemUptime, outputPermit: decoder.outputPermit!, compressedBytes: 1)
}
decoder.decoded(image(), status: noErr, flags: [], flight: recovery, pts: .invalid)
let recoveryAdmitted = results.state.admitted == state.admitted + 1
let notificationCorrect = state.revocations == (preserved ? 0 : 1)
let passed = held && returned && permitCorrect && recoveryAdmitted && notificationCorrect && state.failures == 0
    && (preserved ? after == before && state.admitted == 1 : after != before && state.admitted == 0)
print("\(passed ? "PASS" : "FAIL") epoch handoff mode=\(mode), before=\(before), after=\(after), prior=\(state.admitted), recovery=\(recoveryAdmitted), permit=\(permitCorrect), notifications=\(state.revocations), failures=\(state.failures); synthetic callbacks only")
_ = router.clear()
exit(passed ? 0 : 1)
