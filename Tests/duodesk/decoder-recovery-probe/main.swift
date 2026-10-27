// Copyright 2026 DUO你电脑 contributors. SPDX-License-Identifier: Apache-2.0
// Simulate decoder callbacks/admission without starting a VideoToolbox session.
import Foundation
import CoreMedia
import CoreVideo
import StreamProtocol
import VideoToolbox

final class Requests: @unchecked Sendable {
    private let lock = NSLock()
    private var values: [UInt64] = []
    func add(_ token: UInt64) { lock.withLock { values.append(token) } }
    var snapshot: [UInt64] { lock.withLock { values } }
}
final class Samples: @unchecked Sendable {
    private let lock = NSLock()
    private var values: [Int64] = []
    func add(_ sample: CMSampleBuffer) { lock.withLock { values.append(CMSampleBufferGetPresentationTimeStamp(sample).value) } }
    var snapshot: [Int64] { lock.withLock { values } }
}

func waitUntil(_ condition: () -> Bool, timeout: TimeInterval = 1) -> Bool {
    let deadline = ProcessInfo.processInfo.systemUptime + timeout
    while ProcessInfo.processInfo.systemUptime < deadline {
        if condition() { return true }
        Thread.sleep(forTimeInterval: 0.005)
    }
    return condition()
}
func decoder(_ requests: Requests, samples: Samples = Samples()) -> HardwareHEVCDecoder {
    HardwareHEVCDecoder(onFormat: { _, _ in }, onSample: { sample, _ in samples.add(sample) }, onFailure: { _, _ in },
                        onNeedsKeyframe: { requests.add($0) })
}
func flight(_ decoder: HardwareHEVCDecoder, _ token: UInt64, _ sequence: Int64) -> HardwareHEVCDecoder.Flight {
    decoder.lock.withLock {
        let ticket = decoder.backlog.admit(bytes: 1, keyframe: true)!
        decoder.backlog.complete(ticket)
        decoder.inFlight += 1
        return HardwareHEVCDecoder.Flight(generation: token, ticket: ticket, sequence: sequence,
                                           started: ProcessInfo.processInfo.systemUptime)
    }
}
func image() -> CVPixelBuffer {
    var pixel: CVPixelBuffer?
    guard CVPixelBufferCreate(nil, 16, 16, kCVPixelFormatType_420YpCbCr8BiPlanarFullRange, nil, &pixel) == kCVReturnSuccess,
          let pixel else { fatalError("Unable to create the in-memory pixel buffer") }
    return pixel
}
var checks = 0, failures = 0
func check(_ name: String, _ passed: Bool) {
    checks += 1
    if !passed { failures += 1 }
    print("\(passed ? "PASS" : "FAIL") \(name)")
}
let native = DuoDesktopResolution(width: 2007, height: 1427)
let droppedRequests = Requests(), dropped = decoder(droppedRequests)
let droppedToken = dropped.require(native)
dropped.queue.sync { }
let missing = flight(dropped, droppedToken, 1)
dropped.decoded(nil, status: noErr, flags: [], flight: missing, pts: .zero)
let dropRecovered = waitUntil { droppedRequests.snapshot == [droppedToken] }
check("nil decoder output requests a recovery keyframe", dropRecovered)
check("nil output releases its in-flight slot and fences dependent frames", dropped.lock.withLock {
    dropped.inFlight == 0 && dropped.backlog.waitingForKeyframe && !dropped.backlog.isCurrent(missing.ticket)
})

let quietRequests = Requests(), quiet = decoder(quietRequests)
let quietToken = quiet.require(native)
quiet.queue.sync { }
quiet.lock.withLock { quiet.lastRecoveryRequest = ProcessInfo.processInfo.systemUptime }
quiet.enqueue(Data([1]), isKeyframe: false)
let retried = waitUntil { quietRequests.snapshot == [quietToken] }
check("rate-limited recovery is retried when no later frame arrives", retried)

let duplicateRequests = Requests(), duplicateSamples = Samples()
let duplicate = decoder(duplicateRequests, samples: duplicateSamples), duplicateToken = duplicate.require(native)
duplicate.queue.sync { }
let dropFirst = flight(duplicate, duplicateToken, 1)
duplicate.queue.sync { duplicate.completeSubmission(noErr, flags: [.frameDropped], flight: dropFirst) }
duplicate.decoded(image(), status: noErr, flags: [], flight: dropFirst, pts: .zero)
check("synchronous drop and late success complete once", duplicateRequests.snapshot == [duplicateToken]
      && duplicateSamples.snapshot.isEmpty && duplicate.lock.withLock { duplicate.inFlight == 0 })

let callbackRequests = Requests(), callbackSamples = Samples()
let callback = decoder(callbackRequests, samples: callbackSamples), callbackToken = callback.require(native)
callback.queue.sync { }
let callbackFirst = flight(callback, callbackToken, 1)
callback.decoded(image(), status: noErr, flags: [], flight: callbackFirst, pts: .invalid)
callback.queue.sync { callback.completeSubmission(noErr, flags: [.frameDropped], flight: callbackFirst) }
check("successful callback before synchronous result completes once", callbackRequests.snapshot.isEmpty
      && callbackSamples.snapshot == [1] && callback.lock.withLock { callback.inFlight == 0 })

let orderedRequests = Requests(), orderedSamples = Samples()
let ordered = decoder(orderedRequests, samples: orderedSamples), orderedToken = ordered.require(native)
ordered.queue.sync { }
let old = flight(ordered, orderedToken, 1), new = flight(ordered, orderedToken, 2)
ordered.decoded(image(), status: noErr, flags: [], flight: new, pts: .invalid)
ordered.decoded(nil, status: noErr, flags: [.frameDropped], flight: old, pts: .invalid)
check("old drop after newer image does not trigger recovery", orderedRequests.snapshot.isEmpty
      && orderedSamples.snapshot == [2] && ordered.lock.withLock { ordered.inFlight == 0 && !ordered.backlog.waitingForKeyframe })

var racesPassed = true
for _ in 0..<32 {
    let requests = Requests(), samples = Samples(), competing = decoder(requests, samples: samples)
    let token = competing.require(native)
    competing.queue.sync { }
    let item = flight(competing, token, 1), pixel = image(), group = DispatchGroup()
    group.enter()
    competing.queue.async {
        competing.completeSubmission(noErr, flags: [.frameDropped], flight: item)
        group.leave()
    }
    group.enter()
    DispatchQueue.global(qos: .userInitiated).async {
        competing.decoded(pixel, status: noErr, flags: [], flight: item, pts: .zero)
        group.leave()
    }
    let finished = group.wait(timeout: .now() + 2) == .success
    let oneOutcome = (requests.snapshot == [token] && samples.snapshot.isEmpty)
        || (requests.snapshot.isEmpty && samples.snapshot == [1])
    if !finished || !oneOutcome || competing.lock.withLock({ competing.inFlight != 0 }) { racesPassed = false }
    _ = competing.clear()
}
check("racing callback and synchronous drop claim exactly one completion", racesPassed)

let manyRequests = Requests(), many = decoder(manyRequests), manyToken = many.require(native)
many.queue.sync { }
for n in 1...40 {
    let item = flight(many, manyToken, Int64(n))
    many.queue.sync { many.completeSubmission(noErr, flags: [.frameDropped], flight: item) }
}
check("40 synchronous drops cannot leak in-flight slots", many.lock.withLock { many.inFlight == 0 })

let cancelRequests = Requests(), cancelled = decoder(cancelRequests)
_ = cancelled.require(native); cancelled.queue.sync { }
cancelled.lock.withLock { cancelled.lastRecoveryRequest = ProcessInfo.processInfo.systemUptime }
cancelled.enqueue(Data([1]), isKeyframe: false)
_ = cancelled.clear()
Thread.sleep(forTimeInterval: 0.65)
check("disconnect cancels a queued recovery request", cancelRequests.snapshot.isEmpty)
cancelled.enqueue(Data([1]), isKeyframe: false)
check("new generation can request recovery immediately", cancelRequests.snapshot.count == 1)

let keyRequests = Requests(), key = decoder(keyRequests)
_ = key.require(native); key.queue.sync { }
key.lock.withLock { key.lastRecoveryRequest = ProcessInfo.processInfo.systemUptime }
key.enqueue(Data([1]), isKeyframe: false)
key.enqueue(Data([2]), isKeyframe: true)
Thread.sleep(forTimeInterval: 0.65)
check("a keyframe admitted before the deadline cancels the pending request", keyRequests.snapshot.isEmpty)

_ = dropped.clear(); _ = quiet.clear()
_ = duplicate.clear(); _ = callback.clear(); _ = ordered.clear(); _ = many.clear(); _ = cancelled.clear(); _ = key.clear()
print("Decoder recovery: \(checks) checks, \(failures) failures; no codec session, capture, network or input")
exit(failures == 0 ? 0 : 1)
