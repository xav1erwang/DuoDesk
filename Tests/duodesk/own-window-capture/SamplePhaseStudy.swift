// Copyright 2026 DUO你电脑 contributors. SPDX-License-Identifier: Apache-2.0
// Diagnostic only: sample a small grid from each actual own-window luma surface on the GPU.
// Signatures stay in memory; only aggregate phase counts and timing are printed.
import CoreMedia
import CoreVideo
import CryptoKit
import Foundation
import Metal

final class SamplePhaseStudy: @unchecked Sendable {
    private static let columns = 128, rows = 90
    private final class Surface: @unchecked Sendable {
        let image: CVPixelBuffer
        let texture: CVMetalTexture
        init(_ image: CVPixelBuffer, _ texture: CVMetalTexture) { self.image = image; self.texture = texture }
    }
    private let queue: any MTLCommandQueue
    private let pipeline: any MTLComputePipelineState
    private let markerCoordinates: any MTLBuffer
    private let hasMarker: Bool
    private let cache: CVMetalTextureCache
    private let submitQueue = DispatchQueue(label: "duodesk.phase-signature", qos: .userInteractive)
    private let pending = DispatchGroup()
    private let lock = NSLock()
    private var inFlight = 0, next = 0, dropped = 0, failed = 0
    private var samples: [Int: PhaseSelection.Sample] = [:]
    private var outputs: [PhaseSelection.Output] = []
    private var start = Double.infinity, end = Double.infinity

    init(markerPoints: [(Int, Int)]? = nil) throws {
        guard let device = MTLCreateSystemDefaultDevice(), let queue = device.makeCommandQueue() else {
            throw PixelMotionAudit.Failure.unavailable
        }
        var cache: CVMetalTextureCache?
        guard CVMetalTextureCacheCreate(nil, nil, device, nil, &cache) == kCVReturnSuccess, let cache else {
            throw PixelMotionAudit.Failure.unavailable
        }
        let library = try device.makeLibrary(source: """
        #include <metal_stdlib>
        using namespace metal;
        kernel void sampleCenter(texture2d<float, access::read> image [[texture(0)]],
                                 device uchar *out [[buffer(0)]], constant uint2 *points [[buffer(1)]],
                                 constant uint &hasMarker [[buffer(2)]], uint2 p [[thread_position_in_grid]]) {
            if (p.x >= 128u || p.y >= 90u) return;
            uint w = image.get_width(), h = image.get_height();
            uint x = w * 3u / 10u + (p.x * (w * 4u / 10u - 1u)) / 127u;
            uint y = h * 3u / 10u + (p.y * (h * 4u / 10u - 1u)) / 89u;
            out[p.y * 128u + p.x] = uchar(clamp(round(image.read(uint2(x, y)).r * 255.0), 0.0, 255.0));
            if (hasMarker != 0u && p.y == 0u && p.x < 16u) {
                uint2 point = points[p.x];
                out[128u * 90u + p.x] = point.x < w && point.y < h
                    ? uchar(clamp(round(image.read(point).r * 255.0), 0.0, 255.0)) : uchar(128);
            }
        }
        """, options: nil)
        guard let function = library.makeFunction(name: "sampleCenter") else { throw PixelMotionAudit.Failure.unavailable }
        self.pipeline = try device.makeComputePipelineState(function: function)
        if let markerPoints {
            guard markerPoints.count == MarkerContentCorrelation.cellCount,
                  markerPoints.allSatisfy({ $0.0 >= 0 && $0.1 >= 0 && $0.0 <= Int(UInt32.max) && $0.1 <= Int(UInt32.max) })
            else { throw PixelMotionAudit.Failure.unavailable }
        }
        hasMarker = markerPoints != nil
        let points = (markerPoints ?? [(Int, Int)](repeating: (0, 0), count: MarkerContentCorrelation.cellCount))
            .map { SIMD2<UInt32>(UInt32($0.0), UInt32($0.1)) }
        guard let buffer = points.withUnsafeBytes({ bytes -> (any MTLBuffer)? in
            guard let base = bytes.baseAddress else { return nil }
            return device.makeBuffer(bytes: base, length: bytes.count, options: .storageModeShared)
        }) else { throw PixelMotionAudit.Failure.unavailable }
        markerCoordinates = buffer
        self.queue = queue; self.cache = cache
    }

    func begin(at start: Double, seconds: Int) {
        lock.withLock { self.start = start; end = start + Double(seconds) }
    }

    func inspect(_ image: CVPixelBuffer, pts: CMTime, arrived: CMTime) {
        guard pts.isNumeric, pts.timescale > 0, arrived.isNumeric, arrived.timescale > 0,
              pts.epoch == arrived.epoch else { lock.withLock { failed += 1 }; return }
        let time = CMTimeGetSeconds(pts)
        let arrival = CMTimeGetSeconds(arrived)
        guard time.isFinite, arrival.isFinite else { lock.withLock { failed += 1 }; return }
        let number: Int? = lock.withLock {
            guard inFlight < 8 else { dropped += 1; return nil }
            inFlight += 1; next += 1; return next
        }
        guard let number else { return }
        pending.enter()
        submitQueue.async { [self, image] in
            do {
                guard CVPixelBufferGetWidth(image) == 2008, CVPixelBufferGetHeight(image) == 1428,
                      CVPixelBufferIsPlanar(image), CVPixelBufferGetPlaneCount(image) == 2 else {
                    throw PixelMotionAudit.Failure.texture
                }
                var texture: CVMetalTexture?
                guard CVMetalTextureCacheCreateTextureFromImage(nil, cache, image, nil, .r8Unorm,
                    CVPixelBufferGetWidthOfPlane(image, 0), CVPixelBufferGetHeightOfPlane(image, 0), 0,
                    &texture) == kCVReturnSuccess, let texture, let source = CVMetalTextureGetTexture(texture),
                      let result = queue.device.makeBuffer(length: Self.columns * Self.rows
                          + (hasMarker ? MarkerContentCorrelation.cellCount : 0), options: .storageModeShared),
                      let command = queue.makeCommandBuffer(), let encoder = command.makeComputeCommandEncoder() else {
                    throw PixelMotionAudit.Failure.submission
                }
                encoder.setComputePipelineState(pipeline)
                encoder.setTexture(source, index: 0); encoder.setBuffer(result, offset: 0, index: 0)
                encoder.setBuffer(markerCoordinates, offset: 0, index: 1)
                var flag: UInt32 = hasMarker ? 1 : 0
                encoder.setBytes(&flag, length: MemoryLayout<UInt32>.stride, index: 2)
                encoder.dispatchThreads(MTLSize(width: Self.columns, height: Self.rows, depth: 1),
                                        threadsPerThreadgroup: MTLSize(width: 8, height: 8, depth: 1))
                encoder.endEncoding()
                let surface = Surface(image, texture)
                command.addCompletedHandler { [self, surface, result] command in
                    let captured: (signature: [UInt8], marker: Int?)? = withExtendedLifetime(surface) {
                        guard command.status == .completed else { return nil }
                        let base = result.contents().assumingMemoryBound(to: UInt8.self), count = Self.columns * Self.rows
                        let signature = Array(UnsafeBufferPointer(start: base, count: count))
                        let marker = !hasMarker ? nil : MarkerContentCorrelation.decode(
                            Array(UnsafeBufferPointer(start: base.advanced(by: count), count: MarkerContentCorrelation.cellCount)))
                        return (signature, marker)
                    }
                    lock.withLock {
                        inFlight -= 1
                        if let captured { samples[number] = .init(pts: time, arrived: arrival, signature: captured.signature, marker: captured.marker) }
                        else { failed += 1 }
                    }
                    pending.leave()
                }
                command.commit()
            } catch {
                lock.withLock { inFlight -= 1; failed += 1 }
                pending.leave()
            }
        }
    }

    func emitted(pts: CMTime, at delivered: CMTime) {
        guard pts.isNumeric, pts.timescale > 0, delivered.isNumeric, delivered.timescale > 0,
              pts.epoch == delivered.epoch else { lock.withLock { failed += 1 }; return }
        let value = CMTimeGetSeconds(pts)
        let time = CMTimeGetSeconds(delivered)
        guard value.isFinite, time.isFinite else { lock.withLock { failed += 1 }; return }
        lock.withLock { outputs.append(.init(pts: value, delivered: time)) }
    }

    func report(fullPixelFPS: Double?) async -> String {
        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            pending.notify(queue: .global()) { continuation.resume() }
        }
        let data = lock.withLock { (samples.keys.sorted().compactMap { samples[$0] }, outputs, start, end, dropped, failed, next) }
        let raw = data.0, outputs = data.1, start = data.2, end = data.3
        let ordered = zip(raw, raw.dropFirst()).allSatisfy { $0.pts < $1.pts && $0.arrived <= $1.arrived }
            && zip(outputs, outputs.dropFirst()).allSatisfy { $0.delivered <= $1.delivered }
        let ages = raw.map { $0.arrived - $0.pts }
        let compatibleClocks = ages.allSatisfy { $0.isFinite && $0 >= 0 && $0 <= 1 }
        guard raw.count == data.6, !raw.isEmpty, data.4 == 0, data.5 == 0, ordered, compatibleClocks,
              start.isFinite, end.isFinite, end - start > 2 else {
            return "SAMPLE PHASE STUDY INVALID: raw=\(raw.count), expected=\(data.6), dropped=\(data.4), failed=\(data.5), ordered=\(ordered), compatibleClocks=\(compatibleClocks)"
        }
        let activeStart = start + 2
        let actual = PhaseSelection.actual(raw, outputs: outputs, start: activeStart, end: end)
        let stationary = PhaseSelection.actual(raw, outputs: outputs, start: start, end: start + 1)
        let candidates = [0.0, 0.002, 0.004, 0.006].map { phase in
            (phase, PhaseSelection.candidate(raw, start: activeStart, end: end, fps: 120, phase: phase))
        }
        func describe(_ result: PhaseSelection.Result) -> String {
            let sorted = result.sourceAges.sorted()
            let p95 = sorted.isEmpty ? -1 : sorted[(sorted.count * 95 + 99) / 100 - 1] * 1000
            return "slots=\(result.slots),compared=\(result.comparisons),changed=\(result.changed),reused=\(result.reusedSource),missing=\(result.missing),sourceAgeP95Ms=\(String(format: "%.3f", p95))"
        }
        let variants = candidates.map { phase, result in
            "phaseMs=\(Int(phase * 1000)) {\(describe(result))}"
        }.joined(separator: "; ")
        let sortedAges = ages.sorted()
        let p95 = sortedAges[(sortedAges.count * 95 + 99) / 100 - 1] * 1000
        let fullCount = fullPixelFPS.map { $0 * (end - activeStart) }
        // A grid is only a proxy; reject gross disagreement with the independently audited
        // full-resolution output, while still reporting the difference for inspection.
        let consistent = fullCount.map { abs(Double(actual.changed) - $0) <= max(5, Double(actual.slots) * 0.05) } ?? false
        let valid = actual.missing == 0 && actual.reusedSource == 0 && stationary.missing == 0
            && stationary.slots > 1 && stationary.comparisons > 0 && stationary.changed == 0
            && actual.slots > 0 && actual.comparisons > 0 && consistent
            && candidates.allSatisfy { $0.1.missing == 0 && $0.1.slots > 0 && $0.1.comparisons > 0 }
        return "SAMPLE PHASE STUDY: valid=\(valid), raw=\(raw.count), outputs=\(outputs.count), "
            + "rawArrivalAgeP95Ms=\(String(format: "%.3f", p95)), stationaryChanged=\(stationary.changed), "
            + "actual {\(describe(actual))}, fullPixelFPS=\(fullPixelFPS.map { String(format: "%.3f", $0) } ?? "unavailable"), "
            + "gridConsistentWithinFivePercent=\(consistent); "
            + "offline latest-arrival candidates: \(variants); sampled center only, not actual replay or full-desktop acceptance"
    }

    /// Call after report(), which waits for all GPU work. Images remain in memory only; this
    /// joins the actual pacer's PTS to the unpaced sample that supplied its marker and grid.
    func markerReport(draws: [(Int, UInt64)]) -> String {
        let data = lock.withLock { (samples.keys.sorted().compactMap { samples[$0] }, outputs, start, end, dropped, failed, next) }
        guard hasMarker, data.0.count == data.6, data.4 == 0, data.5 == 0,
              data.2.isFinite, data.3.isFinite, data.3 - data.2 > 2 else {
            return "MARKER CONTENT CORRELATION: valid=false, reason=incomplete-gpu-capture"
        }
        let times = draws.map { MarkerContentCorrelation.Draw(marker: $0.0,
            time: CMTimeGetSeconds(CMClockMakeHostTimeFromSystemUnits($0.1))) }
        return MarkerContentCorrelation.analyze(raw: data.0, outputs: data.1, draws: times,
                                                start: data.2 + 2, end: data.3).description
    }

    /// Opt-in owned-fixture timing evidence. No sampled pixels are written: only times, drawn
    /// marker IDs, center-grid hashes and change flags. Do not overwrite earlier evidence.
    func writeTimeline(to url: URL, draws: [(Int, UInt64)]) throws {
        let data = lock.withLock { (samples.keys.sorted().compactMap { samples[$0] }, outputs, start, end, dropped, failed, next) }
        guard hasMarker, data.0.count == data.6, data.4 == 0, data.5 == 0,
              data.2.isFinite, data.3.isFinite else { throw PixelMotionAudit.Failure.invalidFrames }
        let raw = data.0
        let byPTS = Dictionary(uniqueKeysWithValues: raw.enumerated().map { ($0.element.pts, $0.offset) })
        let rawRows: [[String: Any]] = raw.enumerated().map { index, sample in
            let digest = SHA256.hash(data: Data(sample.signature)).map { String(format: "%02x", $0) }.joined()
            let changed: Any = index == 0 ? NSNull() : PhaseSelection.changed(raw[index - 1].signature, sample.signature)
            return ["pts": sample.pts, "arrival": sample.arrived, "marker": sample.marker as Any? ?? NSNull(),
                    "centerSHA256": digest, "changedFromPreviousRaw": changed]
        }
        var previous: Int?
        let outputRows: [[String: Any]] = data.1.map { output in
            let index = byPTS[output.pts].flatMap { output.delivered >= raw[$0].arrived ? $0 : nil }
            let changed: Any
            if let index, let previous { changed = PhaseSelection.changed(raw[previous].signature, raw[index].signature) }
            else { changed = NSNull() }
            previous = index
            return ["pts": output.pts, "delivered": output.delivered, "rawIndex": index as Any? ?? NSNull(),
                    "changedFromPreviousOutput": changed]
        }
        let drawRows: [[String: Any]] = draws.map { marker, ticks in
            ["marker": marker, "time": CMTimeGetSeconds(CMClockMakeHostTimeFromSystemUnits(ticks))]
        }
        let object: [String: Any] = ["version": 1, "scope": "owned synthetic document; no pixels",
            "start": data.2, "end": data.3, "raw": rawRows, "outputs": outputRows, "draws": drawRows]
        let encoded = try JSONSerialization.data(withJSONObject: object, options: [.sortedKeys])
        try encoded.write(to: url, options: .withoutOverwriting)
    }
}
