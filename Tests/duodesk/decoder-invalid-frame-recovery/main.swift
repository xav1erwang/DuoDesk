// Copyright 2026 DUO你电脑 contributors. SPDX-License-Identifier: Apache-2.0
// Exercise the production decoder's admission state without a codec session or capture.
import Foundation
import CoreMedia
import CoreVideo
import StreamProtocol

final class Results: @unchecked Sendable {
    private let lock = NSLock()
    private var tokens: [UInt64] = []
    private var images = 0
    func request(_ token: UInt64) { lock.withLock { tokens.append(token) } }
    func sample() { lock.withLock { images += 1 } }
    var snapshot: ([UInt64], Int) { lock.withLock { (tokens, images) } }
}

func pixel() -> CVPixelBuffer {
    var value: CVPixelBuffer?
    guard CVPixelBufferCreate(nil, 16, 16, kCVPixelFormatType_420YpCbCr8BiPlanarFullRange,
                              nil, &value) == kCVReturnSuccess, let value else { fatalError("pixel buffer") }
    return value
}

func check(_ label: String, size: Int, keyframe: Bool, occupied: Bool = false) -> Bool {
    let results = Results()
    let decoder = HardwareHEVCDecoder(onFormat: { _, _ in }, onSample: { _, _ in results.sample() },
        onFailure: { _, _ in }, onNeedsKeyframe: { results.request($0) })
    let token = decoder.require(DuoDesktopResolution(width: 2007, height: 1427))
    decoder.queue.sync { }
    let prior = decoder.lock.withLock { () -> HardwareHEVCDecoder.Flight in
        let ticket = decoder.backlog.admit(bytes: 1, keyframe: true)!
        decoder.backlog.complete(ticket)
        decoder.inFlight += 1
        return HardwareHEVCDecoder.Flight(generation: token, ticket: ticket, sequence: 1,
                                           started: ProcessInfo.processInfo.systemUptime)
    }
    let waiting = decoder.lock.withLock { occupied ? decoder.backlog.admit(bytes: 1, keyframe: false) : nil }
    decoder.enqueue(Data(count: size), isKeyframe: keyframe)
    let fenced = decoder.lock.withLock { decoder.backlog.waitingForKeyframe && !decoder.backlog.isCurrent(prior.ticket) }
    decoder.decoded(pixel(), status: noErr, flags: [], flight: prior, pts: .zero)
    let after = results.snapshot
    let passed = fenced && after.0 == [token] && after.1 == 0
    print("\(passed ? "PASS" : "FAIL") \(label): fenced=\(fenced), requests=\(after.0.count), oldImages=\(after.1)")
    if let waiting { decoder.lock.withLock { decoder.backlog.complete(waiting) } }
    _ = decoder.clear()
    return passed
}

let results = [
    check("empty delta", size: 0, keyframe: false),
    check("large frame while queue occupied", size: 8 * 1024 * 1024 + 1, keyframe: false, occupied: true),
    check("delta above 32 MiB wire limit", size: StreamMessage.maxFramePayload + 1, keyframe: false),
    check("keyframe above 32 MiB wire limit", size: StreamMessage.maxFramePayload + 1, keyframe: true)
]
print("\(results.filter { $0 }.count)/\(results.count) passed; no codec session, capture, network or input")
exit(results.allSatisfy { $0 } ? 0 : 1)
