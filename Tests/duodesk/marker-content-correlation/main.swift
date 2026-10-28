// Copyright 2026 DUO你电脑 contributors. SPDX-License-Identifier: Apache-2.0
// Validate association and GPU marker sampling with synthetic owned buffers, without capture.
import CoreMedia
import CoreVideo
import Foundation

func cells(_ value: Int) -> [UInt8] {
    [255, 0] + (0..<MarkerContentCorrelation.bitCount).map { value & (1 << $0) == 0 ? 0 : 255 } + [255, 0]
}
func signature(_ value: UInt8) -> [UInt8] { [UInt8](repeating: value, count: 128 * 90) }
func syntheticBuffer(marker: Int, center: UInt8, points: [(Int, Int)]) throws -> CVPixelBuffer {
    var pixel: CVPixelBuffer?
    let attrs = [kCVPixelBufferIOSurfacePropertiesKey: [:], kCVPixelBufferMetalCompatibilityKey: true] as CFDictionary
    guard CVPixelBufferCreate(nil, 2008, 1428, kCVPixelFormatType_420YpCbCr8BiPlanarFullRange,
                              attrs, &pixel) == kCVReturnSuccess, let pixel,
          CVPixelBufferLockBaseAddress(pixel, []) == kCVReturnSuccess else { throw PixelMotionAudit.Failure.texture }
    defer { CVPixelBufferUnlockBaseAddress(pixel, []) }
    guard let y = CVPixelBufferGetBaseAddressOfPlane(pixel, 0)?.assumingMemoryBound(to: UInt8.self),
          let uv = CVPixelBufferGetBaseAddressOfPlane(pixel, 1) else { throw PixelMotionAudit.Failure.texture }
    let row = CVPixelBufferGetBytesPerRowOfPlane(pixel, 0)
    memset(y, Int32(center), row * CVPixelBufferGetHeightOfPlane(pixel, 0))
    memset(uv, 128, CVPixelBufferGetBytesPerRowOfPlane(pixel, 1) * CVPixelBufferGetHeightOfPlane(pixel, 1))
    for (point, value) in zip(points, cells(marker)) { y[point.1 * row + point.0] = value }
    return pixel
}
@main
enum Check {
    static func main() async {
        var checks = 0, failures = 0
        func check(_ label: String, _ condition: Bool) {
            checks += 1; if !condition { failures += 1 }
            print("\(condition ? "PASS" : "FAIL") \(label)")
        }
        check("marker decodes zero and full 12-bit range", MarkerContentCorrelation.decode(cells(0)) == 0
              && MarkerContentCorrelation.decode(cells(4095)) == 4095 && MarkerContentCorrelation.decode(cells(619)) == 619)
        var corrupted = cells(619); corrupted[0] = 0
        check("sentinel mismatch is rejected", MarkerContentCorrelation.decode(corrupted) == nil)
        corrupted = cells(619); corrupted[5] = 128
        check("ambiguous cell and incomplete marker are rejected", MarkerContentCorrelation.decode(corrupted) == nil
              && MarkerContentCorrelation.decode(Array(cells(1).dropLast())) == nil)
        let markers = [1, 1, 2, 3, 3], centers: [UInt8] = [20, 20, 20, 50, 80]
        let raw = (0..<5).map { i in PhaseSelection.Sample(pts: Double(i + 1), arrived: Double(i + 1) + 0.1,
                                                           signature: signature(centers[i]), marker: markers[i]) }
        let outputs = raw.map { PhaseSelection.Output(pts: $0.pts, delivered: $0.arrived + 0.1) }
        let draws = [MarkerContentCorrelation.Draw(marker: 1, time: 0.5), .init(marker: 2, time: 2.5), .init(marker: 3, time: 3.5)]
        let summary = MarkerContentCorrelation.analyze(raw: raw, outputs: outputs, draws: draws, start: 2, end: 6)
        check("same-buffer marker and center classify all four combinations", summary.valid && summary.raw.comparisons == 4
              && summary.raw.sameMarkerSameCenter == 1 && summary.raw.sameMarkerChangedCenter == 1
              && summary.raw.changedMarkerSameCenter == 1 && summary.raw.changedMarkerChangedCenter == 1
              && summary.output.comparisons == 4)
        let repeatOutputs = [outputs[0], outputs[1], outputs[1], outputs[2], outputs[3], outputs[4]]
        let repeated = MarkerContentCorrelation.analyze(raw: raw, outputs: repeatOutputs, draws: draws, start: 2, end: 6)
        check("reused output is not counted as a new frame", !repeated.valid && repeated.output.reused == 1)
        var unknown = raw; unknown[2] = .init(pts: raw[2].pts, arrived: raw[2].arrived, signature: raw[2].signature, marker: 999)
        check("unknown marker fails closed", !MarkerContentCorrelation.analyze(raw: unknown, outputs: outputs, draws: draws, start: 2, end: 6).valid)
        let lateDraws = [draws[0], .init(marker: 2, time: 3.2), draws[2]]
        check("marker observed before its draw is rejected", !MarkerContentCorrelation.analyze(raw: raw, outputs: outputs, draws: lateDraws, start: 2, end: 6).valid)
        check("ambiguous repeated draw is rejected", !MarkerContentCorrelation.analyze(raw: raw, outputs: outputs,
              draws: draws + [.init(marker: 2, time: 2.6)], start: 2, end: 6).valid)
        let wrongOrder = [outputs[0], outputs[2], outputs[1], outputs[3], outputs[4]]
        check("out-of-order output is rejected", !MarkerContentCorrelation.analyze(raw: raw, outputs: wrongOrder, draws: draws, start: 2, end: 6).valid)
        do {
            let points = (0..<MarkerContentCorrelation.cellCount).map { (32 + 2 * $0, 32) }
            let study = try SamplePhaseStudy(markerPoints: points)
            study.begin(at: 0, seconds: 5)
            let gpuMarkers = [1, 2, 2, 3, 4], gpuCenters: [UInt8] = [20, 30, 30, 30, 50]
            for i in 0..<5 {
                let pts = 1.0 + Double(i) * 0.5
                let pixel = try syntheticBuffer(marker: gpuMarkers[i], center: gpuCenters[i], points: points)
                study.inspect(pixel, pts: CMTime(seconds: pts, preferredTimescale: 1_000_000),
                              arrived: CMTime(seconds: pts + 0.01, preferredTimescale: 1_000_000))
                study.emitted(pts: CMTime(seconds: pts, preferredTimescale: 1_000_000),
                              at: CMTime(seconds: pts + 0.02, preferredTimescale: 1_000_000))
            }
            _ = await study.report(fullPixelFPS: nil)
            let gpuDraws = [(1, 0.9), (2, 1.4), (3, 2.4), (4, 2.9)].map { value, seconds in
                (value, CMClockConvertHostTimeToSystemUnits(CMTime(seconds: seconds, preferredTimescale: 1_000_000)))
            }
            let report = study.markerReport(draws: gpuDraws)
            check("GPU reads marker and center from the same synthetic buffers", report.contains("valid=true")
                  && report.contains("sameMarkerSameCenter=1") && report.contains("changedMarkerSameCenter=1")
                  && report.contains("changedMarkerChangedCenter=1"))
            print(report)
            let name = "Temp/AirAcceptance-20261027/capture-marker-synthetic-\(UUID().uuidString).json"
            let url = URL(fileURLWithPath: name)
            try study.writeTimeline(to: url, draws: gpuDraws)
            let object = try JSONSerialization.jsonObject(with: Data(contentsOf: url)) as? [String: Any]
            let rows = object?["raw"] as? [[String: Any]]
            check("timeline contains hashes and timing, not pixel arrays", rows?.count == 5
                  && (rows?.first?["centerSHA256"] as? String)?.count == 64 && rows?.first?["signature"] == nil)
            var refusedOverwrite = false
            do { try study.writeTimeline(to: url, draws: gpuDraws) } catch { refusedOverwrite = true }
            check("timeline refuses overwriting existing evidence", refusedOverwrite)
            print("Synthetic timeline retained: \(name)")
        } catch { check("GPU marker sampling available: \(error)", false) }
        print("MARKER CONTENT: \(checks) checks, \(failures) failures; synthetic owned buffers only")
        exit(failures == 0 ? 0 : 1)
    }
}
