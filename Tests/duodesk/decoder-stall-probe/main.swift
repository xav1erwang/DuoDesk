// Copyright 2026 DUO你电脑 contributors. SPDX-License-Identifier: Apache-2.0
// A test-only shim holds one *completed* hardware decoder output before production bookkeeping.
// The compressed input and codec sessions are real; this is not evidence of an actual VT hang.
import CoreMedia
import CoreVideo
import Foundation
import StreamProtocol

enum DecoderFault {
    private static let lock = NSLock()
    private static var callback: (() -> Void)?
    static func hold(_ action: @escaping () -> Void) {
        let saved = lock.withLock { () -> Bool in
            guard callback == nil else { return false }
            callback = action; return true
        }
        if !saved { action() }
    }
    static var held: Bool { lock.withLock { callback != nil } }
    static func release() {
        let action = lock.withLock { () -> (() -> Void)? in defer { callback = nil }; return callback }
        action?()
    }
}

final class Results: @unchecked Sendable {
    private let lock = NSLock()
    private var failures: [(String, UInt64)] = []
    private var errors: [String] = []
    private var samples = 0, requests = 0, encodedBytes = 0
    func failure(_ message: String, _ token: UInt64) { lock.withLock { failures.append((message, token)) } }
    func error(_ message: String) { lock.withLock { errors.append(message) } }
    func sample() { lock.withLock { samples += 1 } }
    func request() { lock.withLock { requests += 1 } }
    func encoded(_ bytes: Int) { lock.withLock { encodedBytes = bytes } }
    var snapshot: (failures: [(String, UInt64)], errors: [String], samples: Int, requests: Int, bytes: Int) {
        lock.withLock { (failures, errors, samples, requests, encodedBytes) }
    }
}

enum Failure: Error { case unavailable(String), timeout(String) }
func wait(_ label: String, timeout: Duration = .seconds(5), _ condition: () -> Bool) async throws {
    let deadline = ContinuousClock.now + timeout
    while !condition() {
        guard ContinuousClock.now < deadline else { throw Failure.timeout(label) }
        try await Task.sleep(for: .milliseconds(10))
    }
}
func image() throws -> CVPixelBuffer {
    var value: CVPixelBuffer?
    let attributes = [kCVPixelBufferIOSurfacePropertiesKey: [:]] as CFDictionary
    guard CVPixelBufferCreate(nil, 2008, 1428, kCVPixelFormatType_420YpCbCr8BiPlanarFullRange,
                              attributes, &value) == kCVReturnSuccess, let value,
          CVPixelBufferLockBaseAddress(value, []) == kCVReturnSuccess else { throw Failure.unavailable("input buffer") }
    defer { CVPixelBufferUnlockBaseAddress(value, []) }
    for plane in 0..<2 {
        guard let base = CVPixelBufferGetBaseAddressOfPlane(value, plane) else { throw Failure.unavailable("input plane") }
        memset(base, plane == 0 ? 48 : 128,
               CVPixelBufferGetBytesPerRowOfPlane(value, plane) * CVPixelBufferGetHeightOfPlane(value, plane))
    }
    return value
}
func withFiller(_ encoded: Data, target: Int) throws -> Data {
    let count = target - encoded.count - 4
    guard count >= 3, count <= Int(UInt32.max) else { throw Failure.unavailable("filler length") }
    let length = UInt32(count)
    var padded = encoded
    padded.append(contentsOf: [UInt8((length >> 24) & 0xff), UInt8((length >> 16) & 0xff),
                               UInt8((length >> 8) & 0xff), UInt8(length & 0xff), 0x4c, 0x01])
    padded.append(Data(repeating: 0xff, count: count - 3)); padded.append(0x80)
    return padded
}

@main
struct Check {
    static func run() async throws {
        let results = Results(), mib = 1024 * 1024
        let decoder = HardwareHEVCDecoder(onFormat: { _, _ in }, onSample: { _, _ in results.sample() },
            onFailure: { message, token in results.failure(message, token) }, onNeedsKeyframe: { _ in results.request() })
        decoder.require(DuoDesktopResolution(width: 2007, height: 1427))
        let encoder = try HEVCEncoder(width: 2008, height: 1428, fps: 120, bitrate: 20_000_000,
                                      prioritizeSpeed: true, software: false, quiet: true)
        defer { _ = decoder.clear(); decoder.queue.sync { }; DecoderFault.release(); _ = encoder.abandon() }
        encoder.onEncoded = { bytes, keyframe, parameters in
            guard keyframe, let parameters else { results.error("expected an initial keyframe and parameters"); return }
            do {
                let padded = try withFiller(bytes, target: 9 * mib)
                results.encoded(padded.count)
                decoder.apply(parameters); decoder.enqueue(padded, isKeyframe: true)
            } catch { results.error("filler: \(error)") }
        }
        encoder.encode(try image(), pts: CMTime(value: 1, timescale: 120))
        try await wait("hardware callback held") { DecoderFault.held || !results.snapshot.errors.isEmpty || !results.snapshot.failures.isEmpty }
        guard DecoderFault.held, results.snapshot.errors.isEmpty, results.snapshot.failures.isEmpty,
              results.snapshot.bytes == 9 * mib,
              decoder.lock.withLock({ decoder.inFlight == 1 && decoder.inFlightBytes == 9 * mib }) else {
            throw Failure.unavailable("initial 9 MiB held hardware callback")
        }
        let quiet = CommandLine.arguments.contains("--quiet-tail")
        if !quiet {
            // Would exceed the 32 MiB shared budget; this input never reaches VideoToolbox.
            decoder.enqueue(Data(count: 24 * mib), isKeyframe: true)
            guard results.snapshot.requests == 1, decoder.lock.withLock({ decoder.backlog.waitingForKeyframe }) else {
                throw Failure.unavailable("budget pressure did not request recovery")
            }
        }
        try await wait("stalled decoder reports failure", timeout: .seconds(5)) { !results.snapshot.failures.isEmpty }
        let token = decoder.lock.withLock { decoder.generation }
        let result = results.snapshot
        guard result.failures.count == 1, result.failures[0].1 == token, result.samples == 0 else {
            throw Failure.unavailable("failure or stale output")
        }
        DecoderFault.release()
        try await Task.sleep(for: .milliseconds(150))
        guard results.snapshot.failures.count == 1, results.snapshot.samples == 0 else {
            throw Failure.unavailable("held callback escaped after failure")
        }
        print("DECODER STALL PASS: native hardware HEVC, held completed callback, bytes=\(result.bytes), requests=\(result.requests), failures=1, lateSamples=0, quietTail=\(quiet)")
        print("SCOPE: artificial callback hold and synthetic pixels; no actual hardware failure, desktop, network or Duo")
    }
    static func main() async {
        do { try await run() }
        catch { print("DECODER STALL FAIL: \(error)"); exit(1) }
    }
}
