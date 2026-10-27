// Copyright 2026 DUO你电脑 contributors. SPDX-License-Identifier: Apache-2.0
// Deliberately manipulate production admission/callback bookkeeping; no codec or capture.
import CoreMedia
import CoreVideo
import Foundation
import StreamProtocol
import VideoToolbox

final class Results: @unchecked Sendable {
    private let lock = NSLock()
    private var failures: [UInt64] = [], samples: [Int64] = [], requests = 0
    func failure(_ token: UInt64) { lock.withLock { failures.append(token) } }
    func sample(_ buffer: CMSampleBuffer) { lock.withLock { samples.append(CMSampleBufferGetPresentationTimeStamp(buffer).value) } }
    func request() { lock.withLock { requests += 1 } }
    var state: (failures: [UInt64], samples: [Int64], requests: Int) { lock.withLock { (failures, samples, requests) } }
}
func image() -> CVPixelBuffer {
    var result: CVPixelBuffer?
    guard CVPixelBufferCreate(nil, 16, 16, kCVPixelFormatType_420YpCbCr8BiPlanarFullRange, nil, &result) == kCVReturnSuccess,
          let result else { fatalError("pixel buffer") }
    return result
}
func makeDecoder(_ results: Results) -> HardwareHEVCDecoder {
    HardwareHEVCDecoder(onFormat: { _, _ in }, onSample: { sample, _ in results.sample(sample) },
        onFailure: { _, token in results.failure(token) }, onNeedsKeyframe: { _ in results.request() })
}
func addFlight(_ decoder: HardwareHEVCDecoder, token: UInt64, sequence: Int64, keyframe: Bool) -> HardwareHEVCDecoder.Flight {
    decoder.lock.withLock {
        let ticket = decoder.backlog.admit(bytes: 1, keyframe: keyframe)!
        decoder.backlog.complete(ticket); decoder.inFlight += 1; decoder.inFlightBytes += 1
        return HardwareHEVCDecoder.Flight(generation: token, ticket: ticket, sequence: sequence,
                                          started: ProcessInfo.processInfo.systemUptime, compressedBytes: 1)
    }
}
func setClock(_ decoder: HardwareHEVCDecoder, progressAgo: TimeInterval, tickAgo: TimeInterval = 0) {
    let now = ProcessInfo.processInfo.systemUptime
    decoder.lock.withLock { decoder.callbackProgressAt = now - progressAgo; decoder.lastWatchdogCheck = now - tickAgo }
}
var checks = 0, failures = 0
func check(_ name: String, _ condition: Bool) {
    checks += 1; if !condition { failures += 1 }
    print("\(condition ? "PASS" : "FAIL") \(name)")
}
let native = DuoDesktopResolution(width: 2007, height: 1427)

if CommandLine.arguments.contains("--error-while-blocked") {
    let results = Results(), decoder = makeDecoder(results), token = decoder.require(native)
    decoder.queue.sync { }
    let flight = addFlight(decoder, token: token, sequence: 1, keyframe: true)
    let gate = DispatchSemaphore(value: 0), entered = DispatchSemaphore(value: 0)
    decoder.queue.async { entered.signal(); gate.wait() }
    let blocked = entered.wait(timeout: .now() + 2) == .success
    decoder.decoded(nil, status: kVTVideoDecoderBadDataErr, flags: [], flight: flight, pts: .invalid)
    let deadline = ProcessInfo.processInfo.systemUptime + 0.25
    while results.state.failures.isEmpty && ProcessInfo.processInfo.systemUptime < deadline {
        Thread.sleep(forTimeInterval: 0.005)
    }
    let signalledWhileBlocked = results.state.failures == [token]
    gate.signal(); decoder.queue.sync { }
    _ = decoder.clear()
    print("\(blocked && signalledWhileBlocked ? "PASS" : "FAIL") decoder callback error is reported while its queue is blocked")
    exit(blocked && signalledWhileBlocked ? 0 : 1)
}

let beforeInit = ProcessInfo.processInfo.systemUptime
let initialResults = Results(), initial = makeDecoder(initialResults)
let afterInit = ProcessInfo.processInfo.systemUptime
check("the first watchdog tick has an initial time anchor", initial.lock.withLock {
    initial.lastWatchdogCheck >= beforeInit && initial.lastWatchdogCheck <= afterInit
})

let idleResults = Results(), idle = makeDecoder(idleResults)
_ = idle.require(native); idle.queue.sync { }
setClock(idle, progressAgo: 10); idle.checkWatchdog()
check("no outstanding work cannot trigger a stall", idleResults.state.failures.isEmpty)

let healthyResults = Results(), healthy = makeDecoder(healthyResults), healthyToken = healthy.require(native)
healthy.queue.sync { }
let healthyFlight = addFlight(healthy, token: healthyToken, sequence: 1, keyframe: true)
setClock(healthy, progressAgo: 2); healthy.checkWatchdog()
healthy.decoded(image(), status: noErr, flags: [], flight: healthyFlight, pts: .invalid)
check("timely callback completes normally", healthyResults.state.failures.isEmpty && healthyResults.state.samples == [1]
      && healthy.lock.withLock { healthy.inFlight == 0 && healthy.callbackProgressAt == nil })

let stalledResults = Results(), stalled = makeDecoder(stalledResults), stalledToken = stalled.require(native)
stalled.queue.sync { }
let stalledFlight = addFlight(stalled, token: stalledToken, sequence: 1, keyframe: true)
setClock(stalled, progressAgo: 4); stalled.checkWatchdog(); stalled.checkWatchdog()
stalled.enqueue(Data([1]), isKeyframe: true)
stalled.decoded(image(), status: noErr, flags: [], flight: stalledFlight, pts: .invalid)
check("timeout reports once and fences late output and further input", stalledResults.state.failures == [stalledToken]
      && stalledResults.state.samples.isEmpty && stalledResults.state.requests == 0 && stalled.lock.withLock {
          stalled.failed && stalled.inFlight == 0 && stalled.inFlightBytes == 0 && stalled.backlog.frames == 0
      })

let resetResults = Results(), reset = makeDecoder(resetResults), oldToken = reset.require(native)
reset.queue.sync { }
let oldFlight = addFlight(reset, token: oldToken, sequence: 1, keyframe: true)
setClock(reset, progressAgo: 4); _ = reset.clear(); reset.queue.sync { }
reset.lock.withLock { reset.inFlight = 1; reset.inFlightBytes = 2; reset.callbackProgressAt = ProcessInfo.processInfo.systemUptime }
reset.decoded(image(), status: noErr, flags: [], flight: oldFlight, pts: .invalid); reset.checkWatchdog()
check("clearing fences a previous callback and watchdog state", resetResults.state.failures.isEmpty && resetResults.state.samples.isEmpty
      && reset.lock.withLock { !reset.failed && reset.inFlight == 1 && reset.inFlightBytes == 2 })

let blockedResults = Results(), blocked = makeDecoder(blockedResults), blockedToken = blocked.require(native)
blocked.queue.sync { }
_ = addFlight(blocked, token: blockedToken, sequence: 1, keyframe: true)
let gate = DispatchSemaphore(value: 0), entered = DispatchSemaphore(value: 0)
blocked.queue.async { entered.signal(); gate.wait() }
let queueBlocked = entered.wait(timeout: .now() + 2) == .success
setClock(blocked, progressAgo: 4)
let deadline = ProcessInfo.processInfo.systemUptime + 1.75
while blockedResults.state.failures.isEmpty && ProcessInfo.processInfo.systemUptime < deadline {
    Thread.sleep(forTimeInterval: 0.01)
}
let signalledWhileBlocked = blockedResults.state.failures == [blockedToken]
gate.signal(); blocked.queue.sync { }
check("the watchdog reports even while the decoder queue is blocked", queueBlocked && signalledWhileBlocked)

let pausedResults = Results(), paused = makeDecoder(pausedResults), pausedToken = paused.require(native)
paused.queue.sync { }
_ = addFlight(paused, token: pausedToken, sequence: 1, keyframe: true)
setClock(paused, progressAgo: 10, tickAgo: 10); paused.checkWatchdog()
let gotGrace = pausedResults.state.failures.isEmpty && paused.lock.withLock {
    paused.callbackProgressAt.map { ProcessInfo.processInfo.systemUptime - $0 < 1 } == true
}
setClock(paused, progressAgo: 4); paused.checkWatchdog()
check("long scheduler gap grants a new grace interval, then genuine inactivity fails", gotGrace && pausedResults.state.failures == [pausedToken])

let progressResults = Results(), progress = makeDecoder(progressResults), progressToken = progress.require(native)
progress.queue.sync { }
let older = addFlight(progress, token: progressToken, sequence: 1, keyframe: true)
let newer = addFlight(progress, token: progressToken, sequence: 2, keyframe: false)
setClock(progress, progressAgo: 4)
progress.decoded(image(), status: noErr, flags: [], flight: newer, pts: .invalid); progress.checkWatchdog()
progress.decoded(image(), status: noErr, flags: [], flight: older, pts: .invalid)
check("a completing frame resets progress while older callbacks cannot replace it", progressResults.state.failures.isEmpty
      && progressResults.state.samples == [2] && progress.lock.withLock { progress.inFlight == 0 })

var racesPass = true
for _ in 0..<24 {
    let results = Results(), decoder = makeDecoder(results), token = decoder.require(native)
    decoder.queue.sync { }
    let flight = addFlight(decoder, token: token, sequence: 1, keyframe: true), buffer = image(), group = DispatchGroup()
    setClock(decoder, progressAgo: 4)
    group.enter(); DispatchQueue.global(qos: .userInitiated).async { decoder.checkWatchdog(); group.leave() }
    group.enter(); DispatchQueue.global(qos: .userInitiated).async {
        decoder.decoded(buffer, status: noErr, flags: [], flight: flight, pts: .invalid); group.leave()
    }
    let finished = group.wait(timeout: .now() + 2) == .success, state = results.state
    let oneOutcome = (state.failures == [token] && state.samples.isEmpty) || (state.failures.isEmpty && state.samples == [1])
    if !finished || !oneOutcome || decoder.lock.withLock({ decoder.inFlight != 0 || decoder.inFlightBytes != 0 }) { racesPass = false }
    _ = decoder.clear()
}
check("racing completion and watchdog produce one consistent outcome", racesPass)

_ = initial.clear(); _ = idle.clear(); _ = healthy.clear(); _ = stalled.clear(); _ = reset.clear(); _ = blocked.clear(); _ = paused.clear(); _ = progress.clear()
print("DECODER WATCHDOG: \(checks) checks, \(failures) failures; injected bookkeeping only")
exit(failures == 0 ? 0 : 1)
