// Copyright 2026 DUO你电脑 contributors. SPDX-License-Identifier: Apache-2.0
// Drives the real capture callback with inert SCK identities; no capture is started.
import Foundation
import CoreMedia
import CoreVideo
import ScreenCaptureKit

final class FrameLog: @unchecked Sendable {
    private let lock = NSLock()
    private var frames: [Int64] = []
    func add(_ time: CMTime) { lock.withLock { frames.append(time.value) } }
    var snapshot: [Int64] { lock.withLock { frames } }
}
struct Failure: Error, CustomStringConvertible { let description: String }

func sample(_ ticks: Int64) throws -> CMSampleBuffer {
    var pixel: CVPixelBuffer?
    guard CVPixelBufferCreate(kCFAllocatorDefault, 16, 16, kCVPixelFormatType_420YpCbCr8BiPlanarFullRange,
                              nil, &pixel) == kCVReturnSuccess, let pixel else { throw Failure(description: "pixel fixture") }
    var format: CMVideoFormatDescription?
    guard CMVideoFormatDescriptionCreateForImageBuffer(allocator: kCFAllocatorDefault, imageBuffer: pixel,
                                                       formatDescriptionOut: &format) == noErr, let format else {
        throw Failure(description: "format fixture")
    }
    var timing = CMSampleTimingInfo(duration: .invalid, presentationTimeStamp: CMTime(value: ticks, timescale: 100), decodeTimeStamp: .invalid)
    var buffer: CMSampleBuffer?
    guard CMSampleBufferCreateReadyWithImageBuffer(allocator: kCFAllocatorDefault, imageBuffer: pixel, formatDescription: format,
                                                  sampleTiming: &timing, sampleBufferOut: &buffer) == noErr,
          let buffer, let array = CMSampleBufferGetSampleAttachmentsArray(buffer, createIfNecessary: true) else {
        throw Failure(description: "sample fixture")
    }
    let attachment = unsafeBitCast(CFArrayGetValueAtIndex(array, 0), to: NSMutableDictionary.self)
    attachment[SCStreamFrameInfo.status.rawValue] = SCFrameStatus.complete.rawValue
    return buffer
}

@main
struct Checks {
    static func main() async {
        do { try await test(); print("STRICT CAPTURE LIFECYCLE PASS: latest held frame, immediate replacement, stale wakeup, stop invalidation; no capture") }
        catch { fputs("ERROR: \(error)\n", stderr); exit(1) }
    }
    static func test() async throws {
        let capture = WindowCapture(), log = FrameLog()
        let stream = SCStream(filter: SCContentFilter(), configuration: SCStreamConfiguration(), delegate: nil)
        capture.diagnosticUseStrictTimer = true
        capture.onFrame = { _, pts in log.add(pts) }
        capture.stateLock.withLock { capture.stream = stream; capture.framePacer = CaptureFramePacer(fps: 10) }
        let a = try sample(0), b = try sample(4), c = try sample(6)
        capture.queue.sync {
            capture.stream(stream, didOutputSampleBuffer: a, of: .screen)
            capture.stream(stream, didOutputSampleBuffer: b, of: .screen)
            capture.stream(stream, didOutputSampleBuffer: c, of: .screen)
        }
        guard log.snapshot == [0] else { throw Failure(description: "Held frame emitted before its deadline") }
        try await Task.sleep(for: .milliseconds(180))
        guard log.snapshot == [0, 6] else { throw Failure(description: "Latest held sample not delivered: \(log.snapshot)") }
        capture.stream(stream, didStopWithError: NSError(domain: "DuoStrictFixture", code: 1))
        await capture.stop()

        let next = WindowCapture(), nextLog = FrameLog()
        let nextStream = SCStream(filter: SCContentFilter(), configuration: SCStreamConfiguration(), delegate: nil)
        next.diagnosticUseStrictTimer = true
        next.onFrame = { _, pts in nextLog.add(pts) }
        next.stateLock.withLock { next.stream = nextStream; next.framePacer = CaptureFramePacer(fps: 10) }
        let initial = try sample(0), old = try sample(4), immediate = try sample(11), newer = try sample(12), stopped = try sample(13)
        next.queue.sync {
            next.stream(nextStream, didOutputSampleBuffer: initial, of: .screen)
            next.stream(nextStream, didOutputSampleBuffer: old, of: .screen)
            next.stream(nextStream, didOutputSampleBuffer: immediate, of: .screen)
            next.stream(nextStream, didOutputSampleBuffer: newer, of: .screen)
            next.diagnosticStrictTimer?.handleWakeup() // Obsolete queued event after the rearm.
        }
        guard nextLog.snapshot == [0, 11] else { throw Failure(description: "Stale timer or immediate replacement emitted an early frame") }
        try await Task.sleep(for: .milliseconds(180))
        guard nextLog.snapshot == [0, 11, 12] else { throw Failure(description: "Replacement timer lost or duplicated a frame: \(nextLog.snapshot)") }
        next.queue.sync { next.stream(nextStream, didOutputSampleBuffer: stopped, of: .screen) }
        next.stream(nextStream, didStopWithError: NSError(domain: "DuoStrictFixture", code: 2))
        try await Task.sleep(for: .milliseconds(250))
        guard nextLog.snapshot == [0, 11, 12] else { throw Failure(description: "Stopped stream delivered a pending frame") }
        await next.stop()
    }
}
