// Copyright 2026 DUO你电脑 contributors. SPDX-License-Identifier: Apache-2.0
// Checks the GPU audit itself with in-memory buffers; this is not a desktop FPS test.
import CoreMedia
import CoreVideo
import Foundation

func image(_ index: Int) throws -> CVPixelBuffer {
    let width = 2008, height = 1428
    var buffer: CVPixelBuffer?
    let options: [CFString: Any] = [kCVPixelBufferIOSurfacePropertiesKey: [:], kCVPixelBufferMetalCompatibilityKey: true]
    guard CVPixelBufferCreate(nil, width, height, kCVPixelFormatType_420YpCbCr8BiPlanarFullRange,
                              options as CFDictionary, &buffer) == kCVReturnSuccess, let buffer else {
        throw PixelMotionAudit.Failure.texture
    }
    CVPixelBufferLockBaseAddress(buffer, [])
    defer { CVPixelBufferUnlockBaseAddress(buffer, []) }
    guard let base = CVPixelBufferGetBaseAddressOfPlane(buffer, 0),
          let chroma = CVPixelBufferGetBaseAddressOfPlane(buffer, 1) else { throw PixelMotionAudit.Failure.texture }
    let row = CVPixelBufferGetBytesPerRowOfPlane(buffer, 0)
    memset(base, index == 0 ? 240 : 239, row * height)
    memset(chroma, 128, CVPixelBufferGetBytesPerRowOfPlane(buffer, 1) * CVPixelBufferGetHeightOfPlane(buffer, 1))
    if index >= 2 {
        let phase = min(index - 2, 5) * 3
        let pixels = base.assumingMemoryBound(to: UInt8.self)
        for y in 500..<900 where (y + phase) % 32 < 5 {
            memset(pixels + y * row + 700, 50, 600)
        }
        // The ninth buffer only changes a corner outside the expected document region.
        if index == 8 {
            for y in 0..<200 { memset(pixels + y * row, 20, 200) }
        }
    }
    return buffer
}

func sample(_ index: Int) throws -> CMSampleBuffer {
    let buffer = try image(index)
    var format: CMVideoFormatDescription?
    guard CMVideoFormatDescriptionCreateForImageBuffer(allocator: nil, imageBuffer: buffer,
                                                       formatDescriptionOut: &format) == noErr, let format else {
        throw PixelMotionAudit.Failure.texture
    }
    var timing = CMSampleTimingInfo(duration: .invalid, presentationTimeStamp: .zero, decodeTimeStamp: .invalid)
    var result: CMSampleBuffer?
    guard CMSampleBufferCreateReadyWithImageBuffer(allocator: nil, imageBuffer: buffer, formatDescription: format,
                                                   sampleTiming: &timing, sampleBufferOut: &result) == noErr,
          let result else { throw PixelMotionAudit.Failure.texture }
    return result
}

@main
struct Harness {
    static func main() async {
        setbuf(stdout, nil)
        do { try await run() }
        catch { fputs("DESKTOP AUDIT UNIT CHECK FAILED: \(error)\n", stderr); exit(1) }
    }
    private static func run() async throws {
        let audit = try DesktopContentAudit()
        let warmedAudit = try DesktopContentAudit(activeOffsetSeconds: 2)
        for index in 0..<9 {
            let time = index < 2 ? Double(index) * 0.3 : 1.1 + Double(index - 2) * 0.2
            let buffer = try image(index)
            audit.inspect(buffer, at: time, onResult: nil)
            warmedAudit.inspect(buffer, at: time, onResult: nil)
            try await Task.sleep(for: .milliseconds(10))
        }
        print(await audit.report(from: 0, seconds: 5))
        try audit.validate()
        guard audit.changedFramesPerSecond == 1.5 else { throw PixelMotionAudit.Failure.invalidFrames }
        print("DESKTOP AUDIT UNIT CHECK PASS: stationary drift and outside-only motion are excluded; six center changes are counted")
        print(await warmedAudit.report(from: 0, seconds: 5))
        try warmedAudit.validate()
        guard warmedAudit.changedFramesPerSecond == 1.0 / 3.0 else { throw PixelMotionAudit.Failure.invalidFrames }
        print("DESKTOP AUDIT UNIT CHECK PASS: warmup frames are excluded from the fixed active interval")

        let movingBaseline = try DesktopContentAudit()
        for (index, time) in [(2, 0.1), (3, 0.4), (4, 1.2)] {
            movingBaseline.inspect(try image(index), at: time, onResult: nil)
            try await Task.sleep(for: .milliseconds(10))
        }
        print(await movingBaseline.report(from: 0, seconds: 5))
        var rejected = false
        do { try movingBaseline.validate() } catch { rejected = true }
        guard rejected else { throw PixelMotionAudit.Failure.invalidFrames }
        print("DESKTOP AUDIT UNIT CHECK PASS: a moving stationary baseline is rejected")

        // Delay the second completion until later GPU work has finished. Results must still be
        // reported in capture order, with the same stationary baseline and center changes.
        let reordered = try DesktopContentAudit()
        reordered.testingSecondFinishDelay = 0.25
        let times = [0.1, 0.4, 1.1, 1.3, 1.5]
        for index in times.indices {
            reordered.inspect(try image(index), at: times[index], onResult: nil)
            try await Task.sleep(for: .milliseconds(10))
        }
        print(await reordered.report(from: 0, seconds: 5))
        try reordered.validate()
        let order = reordered.testingFinishedOrder
        guard let second = order.firstIndex(of: 2), let third = order.firstIndex(of: 3), second > third,
              reordered.comparisonSnapshot().map(\.time) == Array(times.dropFirst()),
              reordered.changedFramesPerSecond == 0.75 else { throw PixelMotionAudit.Failure.invalidFrames }
        print("DESKTOP AUDIT UNIT CHECK PASS: reordered completion \(order) preserves capture order")

        // Passing the same IOSurface twice while its preceding sample is still held must not
        // produce a comparison that could be mistaken for an independently delivered frame.
        let strict = try DesktopContentAudit()
        let duplicate = try sample(2)
        strict.inspect(duplicate, at: 0.1)
        strict.inspect(duplicate, at: 0.2)
        _ = await strict.report(from: 0, seconds: 2)
        let health = strict.diagnosticHealth()
        guard health.submitted == 2, health.failed == 1, health.reused == 1, health.dropped == 0,
              health.waiting == 0, strict.comparisonSnapshot().isEmpty else { throw PixelMotionAudit.Failure.invalidFrames }
        print("DESKTOP AUDIT UNIT CHECK PASS: a still-held IOSurface is rejected, not counted")
    }
}
