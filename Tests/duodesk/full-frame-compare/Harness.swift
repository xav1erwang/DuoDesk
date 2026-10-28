// Copyright 2026 DUO你电脑 contributors. SPDX-License-Identifier: Apache-2.0
// In-memory diagnostic only: no capture, user pixels, display changes, network or input.
import CoreVideo
import Darwin
import Foundation

enum CheckFailure: Error { case failed(String) }
enum Edit { case none, padding, lastLuma, lastU, lastV, both, sampledCenter, unsampledCenter }

func image(_ edit: Edit, width: Int = 2008, height: Int = 1428,
           format: OSType = kCVPixelFormatType_420YpCbCr8BiPlanarFullRange) throws -> CVPixelBuffer {
    var result: CVPixelBuffer?
    let options: [CFString: Any] = [kCVPixelBufferIOSurfacePropertiesKey: [:], kCVPixelBufferMetalCompatibilityKey: true]
    guard CVPixelBufferCreate(nil, width, height, format, options as CFDictionary, &result) == kCVReturnSuccess,
          let result, CVPixelBufferLockBaseAddress(result, []) == kCVReturnSuccess else { throw CheckFailure.failed("buffer") }
    defer { CVPixelBufferUnlockBaseAddress(result, []) }
    guard CVPixelBufferGetPlaneCount(result) == 2, let y = CVPixelBufferGetBaseAddressOfPlane(result, 0),
          let uv = CVPixelBufferGetBaseAddressOfPlane(result, 1) else { throw CheckFailure.failed("planes") }
    let yRow = CVPixelBufferGetBytesPerRowOfPlane(result, 0), uvRow = CVPixelBufferGetBytesPerRowOfPlane(result, 1)
    let yWidth = CVPixelBufferGetWidthOfPlane(result, 0), yHeight = CVPixelBufferGetHeightOfPlane(result, 0)
    let uvWidth = CVPixelBufferGetWidthOfPlane(result, 1), uvHeight = CVPixelBufferGetHeightOfPlane(result, 1)
    let padding: Int32 = edit == .padding ? 77 : 0
    for row in 0..<yHeight { memset(y.advanced(by: row * yRow), padding, yRow); memset(y.advanced(by: row * yRow), 64, yWidth) }
    for row in 0..<uvHeight { memset(uv.advanced(by: row * uvRow), padding, uvRow); memset(uv.advanced(by: row * uvRow), 128, uvWidth * 2) }
    let lastY = (yHeight - 1) * yRow + yWidth - 1, lastUV = (uvHeight - 1) * uvRow + (uvWidth - 1) * 2
    if edit == .lastLuma || edit == .both { y.storeBytes(of: UInt8(65), toByteOffset: lastY, as: UInt8.self) }
    if edit == .sampledCenter || edit == .unsampledCenter {
        let x = yWidth * 3 / 10 + (edit == .unsampledCenter ? 1 : 0), row = yHeight * 3 / 10
        y.storeBytes(of: UInt8(65), toByteOffset: row * yRow + x, as: UInt8.self)
    }
    if edit == .lastU || edit == .both { uv.storeBytes(of: UInt8(129), toByteOffset: lastUV, as: UInt8.self) }
    if edit == .lastV { uv.storeBytes(of: UInt8(129), toByteOffset: lastUV + 1, as: UInt8.self) }
    return result
}

/// Independent CPU check of the old 128×90 sampled center grid, not a full-image comparison.
func cpuChangedCenterSamples(_ a: CVPixelBuffer, _ b: CVPixelBuffer) throws -> Int {
    guard CVPixelBufferLockBaseAddress(a, .readOnly) == kCVReturnSuccess else { throw CheckFailure.failed("grid lock first") }
    defer { CVPixelBufferUnlockBaseAddress(a, .readOnly) }
    guard CVPixelBufferLockBaseAddress(b, .readOnly) == kCVReturnSuccess else { throw CheckFailure.failed("grid lock second") }
    defer { CVPixelBufferUnlockBaseAddress(b, .readOnly) }
    guard let first = CVPixelBufferGetBaseAddressOfPlane(a, 0)?.assumingMemoryBound(to: UInt8.self),
          let second = CVPixelBufferGetBaseAddressOfPlane(b, 0)?.assumingMemoryBound(to: UInt8.self) else {
        throw CheckFailure.failed("grid plane")
    }
    let w = CVPixelBufferGetWidthOfPlane(a, 0), h = CVPixelBufferGetHeightOfPlane(a, 0)
    let firstStride = CVPixelBufferGetBytesPerRowOfPlane(a, 0), secondStride = CVPixelBufferGetBytesPerRowOfPlane(b, 0)
    var changed = 0
    for row in 0..<90 {
        let y = min(h - 1, h * 3 / 10 + row * (max(h * 4 / 10, 1) - 1) / 89)
        for column in 0..<128 {
            let x = min(w - 1, w * 3 / 10 + column * (max(w * 4 / 10, 1) - 1) / 127)
            if first[y * firstStride + x] != second[y * secondStride + x] { changed += 1 }
        }
    }
    return changed
}

/// Independent CPU byte comparison of active image bytes; test buffers are held immutable.
func cpuEqual(_ a: CVPixelBuffer, _ b: CVPixelBuffer, plane: Int) throws -> Bool {
    guard CVPixelBufferLockBaseAddress(a, .readOnly) == kCVReturnSuccess else { throw CheckFailure.failed("lock first") }
    defer { CVPixelBufferUnlockBaseAddress(a, .readOnly) }
    guard CVPixelBufferLockBaseAddress(b, .readOnly) == kCVReturnSuccess else { throw CheckFailure.failed("lock second") }
    defer { CVPixelBufferUnlockBaseAddress(b, .readOnly) }
    guard let first = CVPixelBufferGetBaseAddressOfPlane(a, plane), let second = CVPixelBufferGetBaseAddressOfPlane(b, plane) else {
        throw CheckFailure.failed("CPU plane")
    }
    let width = CVPixelBufferGetWidthOfPlane(a, plane) * (plane == 1 ? 2 : 1)
    let rows = CVPixelBufferGetHeightOfPlane(a, plane)
    let firstStride = CVPixelBufferGetBytesPerRowOfPlane(a, plane), secondStride = CVPixelBufferGetBytesPerRowOfPlane(b, plane)
    for row in 0..<rows where memcmp(first.advanced(by: row * firstStride), second.advanced(by: row * secondStride), width) != 0 { return false }
    return true
}

@main struct Harness {
    static func main() async {
        do { try await run() }
        catch { fputs("FULL PLANE COMPARE FAIL: \(error)\n", stderr); exit(1) }
    }
    static func run() async throws {
        let audit = try FramePlaneComparison(), reference = try image(.none)
        let lumaPadding = CVPixelBufferGetBytesPerRowOfPlane(reference, 0) - CVPixelBufferGetWidthOfPlane(reference, 0)
        let chromaPadding = CVPixelBufferGetBytesPerRowOfPlane(reference, 1) - CVPixelBufferGetWidthOfPlane(reference, 1) * 2
        guard lumaPadding > 0, chromaPadding > 0 else { throw CheckFailure.failed("padding fixture has no row padding") }
        print("FIXTURE ROW PADDING: luma=\(lumaPadding), chroma=\(chromaPadding) bytes")
        let fixtures: [(String, Edit, Bool, Bool)] = [
            ("equal", .none, true, true), ("padding-only", .padding, true, true),
            ("last luma pixel", .lastLuma, false, true), ("last U byte", .lastU, true, false),
            ("last V byte", .lastV, true, false), ("both planes", .both, false, false),
            ("sampled center", .sampledCenter, false, true), ("unsampled center", .unsampledCenter, false, true)
        ]
        var equalCopy: CVPixelBuffer?
        for (name, edit, expectedY, expectedUV) in fixtures {
            let other = try image(edit)
            let result = try await audit.compare(reference, other)
            let cpuY = try cpuEqual(reference, other, plane: 0), cpuUV = try cpuEqual(reference, other, plane: 1)
            let cpuCenter = try cpuChangedCenterSamples(reference, other)
            guard cpuY == expectedY, cpuUV == expectedUV,
                  (result.changedLumaTiles == 0) == cpuY, (result.changedChromaTiles == 0) == cpuUV,
                  result.samePlaneBytes == (cpuY && cpuUV), result.changedCenterSamples == cpuCenter,
                  edit != .sampledCenter || cpuCenter > 0,
                  edit != .unsampledCenter || cpuCenter == 0 else { throw CheckFailure.failed(name) }
            if edit == .none { equalCopy = other }
            print("PASS: \(name), lumaTiles=\(result.changedLumaTiles), chromaTiles=\(result.changedChromaTiles), centerSamples=\(result.changedCenterSamples)")
        }
        guard let equalCopy else { throw CheckFailure.failed("equal buffer") }
        let mismatch = try image(.none, width: 2006)
        do { _ = try await audit.compare(reference, mismatch); throw CheckFailure.failed("size accepted") }
        catch FramePlaneComparison.Failure.dimensions { print("PASS: different dimensions refused") }
        let videoRange = try image(.none, format: kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange)
        do { _ = try await audit.compare(reference, videoRange); throw CheckFailure.failed("range accepted") }
        catch FramePlaneComparison.Failure.format { print("PASS: different pixel formats refused") }

        // A short serial cost probe only: these are synthetic immutable buffers, not real capture
        // or evidence of delivered desktop frame rate. Warm the command path first.
        for _ in 0..<2 { _ = try await audit.compare(reference, equalCopy) }
        var gpu: [Double] = [], wall: [Double] = []
        for _ in 0..<16 {
            let start = ProcessInfo.processInfo.systemUptime
            let result = try await audit.compare(reference, equalCopy)
            wall.append((ProcessInfo.processInfo.systemUptime - start) * 1000)
            if let time = result.gpuSeconds { gpu.append(time * 1000) }
            guard result.samePlaneBytes else { throw CheckFailure.failed("cost probe changed data") }
        }
        func quantile(_ values: [Double], _ fraction: Double) -> Double {
            let sorted = values.sorted()
            return sorted[min(sorted.count - 1, Int((Double(sorted.count) * fraction).rounded(.up)) - 1)]
        }
        guard gpu.count == wall.count else { throw CheckFailure.failed("GPU timing unavailable") }
        print("SYNTHETIC COMPARISON COST: count=\(wall.count), gpuP50Ms=\(quantile(gpu, 0.5)), gpuP95Ms=\(quantile(gpu, 0.95)), wallP50Ms=\(quantile(wall, 0.5)), wallP95Ms=\(quantile(wall, 0.95))")
        print("FULL PLANE COMPARE PASS: full 2008x1428 luma and chroma bytes; no padding, capture, actual desktop FPS or visual color-metadata equality claim")
    }
}
