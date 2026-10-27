// Copyright 2026 DUO你电脑 contributors. SPDX-License-Identifier: Apache-2.0
// Production compressed-frame admission and callback accounting, without a codec session.
import Foundation
import CoreMedia
import CoreVideo
import StreamProtocol

final class Requests: @unchecked Sendable {
    private let lock = NSLock()
    private var values: [UInt64] = []
    func add(_ value: UInt64) { lock.withLock { values.append(value) } }
    var count: Int { lock.withLock { values.count } }
}
final class Samples: @unchecked Sendable {
    private let lock = NSLock()
    private var values = 0
    func add() { lock.withLock { values += 1 } }
    var count: Int { lock.withLock { values } }
}
func pixel() -> CVPixelBuffer {
    var value: CVPixelBuffer?
    guard CVPixelBufferCreate(nil, 16, 16, kCVPixelFormatType_420YpCbCr8BiPlanarFullRange,
                              nil, &value) == kCVReturnSuccess, let value else { fatalError("pixel") }
    return value
}

var checks = 0, failures = 0
func check(_ name: String, _ condition: Bool) {
    checks += 1
    if !condition { failures += 1 }
    print("\(condition ? "PASS" : "FAIL") \(name)")
}

let mib = 1024 * 1024, wire = StreamMessage.maxFramePayload
var backlog = VideoDecodeBacklog(frameLimit: 3, byteLimit: 8 * mib, maxFrameBytes: wire)
check("initial delta cannot bypass keyframe", backlog.admit(bytes: 9 * mib, keyframe: false) == nil)
let large = backlog.admit(bytes: 9 * mib, keyframe: true)
check("single nine MiB keyframe is admitted", large != nil && backlog.frames == 1 && backlog.bytes == 9 * mib)
check("extra queued frame is rejected while the earlier keyframe stays valid", backlog.admit(bytes: 1, keyframe: false) == nil
      && backlog.waitingForKeyframe && large.map { backlog.isCurrent($0) } == true)
check("subsequent deltas wait for a new keyframe", backlog.admit(bytes: 1, keyframe: false) == nil
      && backlog.waitingForKeyframe && large.map { backlog.isCurrent($0) } == true)
if let large { backlog.complete(large) }
let maximum = backlog.admit(bytes: wire, keyframe: true)
check("single wire-limit keyframe is admitted", maximum != nil && backlog.bytes == wire)
if let maximum { backlog.complete(maximum) }
check("above-wire and arithmetic-extreme sizes are rejected", backlog.admit(bytes: wire + 1, keyframe: true) == nil
      && backlog.admit(bytes: Int.max, keyframe: true) == nil && backlog.bytes == 0)
let small = backlog.admit(bytes: 5 * mib, keyframe: true)
let delta = backlog.admit(bytes: 3 * mib, keyframe: false)
check("ordinary queue retains its eight MiB limit", small != nil && delta != nil && backlog.bytes == 8 * mib)
check("ordinary queue overflow invalidates dependent tickets", backlog.admit(bytes: 1, keyframe: false) == nil
      && small.map { !backlog.isCurrent($0) } == true && delta.map { !backlog.isCurrent($0) } == true)
if let small { backlog.complete(small) }
if let delta { backlog.complete(delta) }
check("stale reservations are released", backlog.frames == 0 && backlog.bytes == 0)
var custom = VideoDecodeBacklog(byteLimit: 100)
check("existing custom limit remains strict", custom.admit(bytes: 101, keyframe: true) == nil)

let native = DuoDesktopResolution(width: 2007, height: 1427)
let requests = Requests()
let decoder = HardwareHEVCDecoder(onFormat: { _, _ in }, onSample: { _, _, _ in }, onFailure: { _, _ in },
                                  onNeedsKeyframe: { requests.add($0) })
_ = decoder.require(native); decoder.queue.sync { }
let gate = DispatchSemaphore(value: 0), entered = DispatchSemaphore(value: 0)
decoder.queue.async { entered.signal(); gate.wait() }
let blocked = entered.wait(timeout: .now() + 2) == .success
decoder.lock.withLock { decoder.inFlight = 1; decoder.inFlightBytes = 24 * mib }
decoder.enqueue(Data(count: 8 * mib), isKeyframe: true)
check("in-flight plus queued compressed bytes can reach the limit", blocked && decoder.lock.withLock {
    decoder.inFlightBytes == 24 * mib && decoder.backlog.bytes == 8 * mib && !decoder.backlog.waitingForKeyframe
})
decoder.enqueue(Data(count: 1), isKeyframe: false)
check("combined budget overflow requests recovery", requests.count == 1 && decoder.lock.withLock {
    decoder.backlog.waitingForKeyframe && decoder.inFlightBytes + decoder.backlog.bytes == wire
})
gate.signal(); decoder.queue.sync { }
_ = decoder.clear(); decoder.queue.sync { }

let callbackRequests = Requests()
let callbacks = HardwareHEVCDecoder(onFormat: { _, _ in }, onSample: { _, _, _ in }, onFailure: { _, _ in },
                                    onNeedsKeyframe: { callbackRequests.add($0) })
let token = callbacks.require(native); callbacks.queue.sync { }
let flight = callbacks.lock.withLock { () -> HardwareHEVCDecoder.Flight in
    let ticket = callbacks.backlog.admit(bytes: 1, keyframe: true)!
    callbacks.backlog.complete(ticket)
    callbacks.inFlight = 1; callbacks.inFlightBytes = 9 * mib
    return HardwareHEVCDecoder.Flight(generation: token, ticket: ticket, sequence: 1,
        started: ProcessInfo.processInfo.systemUptime, outputPermit: callbacks.outputPermit!, compressedBytes: 9 * mib)
}
callbacks.decoded(nil, status: noErr, flags: [], flight: flight, pts: .invalid)
callbacks.decoded(nil, status: noErr, flags: [], flight: flight, pts: .invalid)
check("callback releases compressed reservation exactly once", callbacks.lock.withLock {
    callbacks.inFlight == 0 && callbacks.inFlightBytes == 0 && callbacks.backlog.waitingForKeyframe
} && callbackRequests.count == 1)
_ = callbacks.clear(); callbacks.queue.sync { }

let pressureRequests = Requests(), pressureSamples = Samples()
let pressure = HardwareHEVCDecoder(onFormat: { _, _ in }, onSample: { _, _, _ in pressureSamples.add() },
    onFailure: { _, _ in }, onNeedsKeyframe: { pressureRequests.add($0) })
let pressureToken = pressure.require(native); pressure.queue.sync { }
let pressureFlight = pressure.lock.withLock { () -> HardwareHEVCDecoder.Flight in
    let ticket = pressure.backlog.admit(bytes: 1, keyframe: true)!
    pressure.backlog.complete(ticket)
    pressure.inFlight = 1; pressure.inFlightBytes = wire
    return HardwareHEVCDecoder.Flight(generation: pressureToken, ticket: ticket, sequence: 1,
        started: ProcessInfo.processInfo.systemUptime, outputPermit: pressure.outputPermit!, compressedBytes: wire)
}
pressure.enqueue(Data([1]), isKeyframe: false)
let earlierValid = pressure.lock.withLock { pressure.backlog.waitingForKeyframe && pressure.backlog.isCurrent(pressureFlight.ticket)
    && pressureFlight.outputPermit.isValid }
pressure.decoded(pixel(), status: noErr, flags: [], flight: pressureFlight, pts: .invalid)
check("budget pressure preserves an earlier in-flight keyframe", earlierValid && pressureSamples.count == 1
      && pressureRequests.count == 1 && pressure.lock.withLock { pressure.inFlightBytes == 0 })
pressure.enqueue(Data([2]), isKeyframe: true)
pressure.queue.sync { }
check("a new keyframe resumes after the large frame completes", pressure.lock.withLock {
    !pressure.backlog.waitingForKeyframe && pressure.backlog.bytes == 0 && pressure.inFlightBytes == 0
})
_ = pressure.clear(); pressure.queue.sync { }

let staleRequests = Requests()
let stale = HardwareHEVCDecoder(onFormat: { _, _ in }, onSample: { _, _, _ in }, onFailure: { _, _ in },
                                onNeedsKeyframe: { staleRequests.add($0) })
let oldToken = stale.require(native); stale.queue.sync { }
let oldFlight = stale.lock.withLock { () -> HardwareHEVCDecoder.Flight in
    let ticket = stale.backlog.admit(bytes: 1, keyframe: true)!
    stale.backlog.complete(ticket)
    stale.inFlight = 1; stale.inFlightBytes = 9 * mib
    return HardwareHEVCDecoder.Flight(generation: oldToken, ticket: ticket, sequence: 1,
        started: ProcessInfo.processInfo.systemUptime, outputPermit: stale.outputPermit!, compressedBytes: 9 * mib)
}
_ = stale.clear(); stale.queue.sync { }
stale.lock.withLock { stale.inFlight = 1; stale.inFlightBytes = 5 * mib }
stale.decoded(nil, status: noErr, flags: [], flight: oldFlight, pts: .invalid)
check("late previous-generation callback cannot release the new budget", stale.lock.withLock {
    stale.inFlight == 1 && stale.inFlightBytes == 5 * mib
} && staleRequests.count == 0)
_ = stale.clear(); stale.queue.sync { }
print("DECODER FRAME BUDGET: \(checks) checks, \(failures) failures; no codec session or capture")
exit(failures == 0 ? 0 : 1)
