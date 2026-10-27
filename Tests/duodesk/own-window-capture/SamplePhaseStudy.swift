// Copyright 2026 DUO你电脑 contributors. SPDX-License-Identifier: Apache-2.0
// Diagnostic only: sample a small grid from each actual own-window luma surface on the GPU.
// Signatures stay in memory; only aggregate phase counts and timing are printed.
import CoreMedia
import CoreVideo
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
    private let cache: CVMetalTextureCache
    private let submitQueue = DispatchQueue(label: "duodesk.phase-signature", qos: .userInteractive)
    private let pending = DispatchGroup()
    private let lock = NSLock()
    private var inFlight = 0, next = 0, dropped = 0, failed = 0
    private var samples: [Int: PhaseSelection.Sample] = [:]
    private var outputs: [PhaseSelection.Output] = []
    private var start = Double.infinity, end = Double.infinity

    init() throws {
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
                                 device uchar *out [[buffer(0)]], uint2 p [[thread_position_in_grid]]) {
            if (p.x >= 128u || p.y >= 90u) return;
            uint w = image.get_width(), h = image.get_height();
            uint x = w * 3u / 10u + (p.x * (w * 4u / 10u - 1u)) / 127u;
            uint y = h * 3u / 10u + (p.y * (h * 4u / 10u - 1u)) / 89u;
            out[p.y * 128u + p.x] = uchar(clamp(round(image.read(uint2(x, y)).r * 255.0), 0.0, 255.0));
        }
        """, options: nil)
        guard let function = library.makeFunction(name: "sampleCenter") else { throw PixelMotionAudit.Failure.unavailable }
        self.pipeline = try device.makeComputePipelineState(function: function)
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
                      let result = queue.device.makeBuffer(length: Self.columns * Self.rows, options: .storageModeShared),
                      let command = queue.makeCommandBuffer(), let encoder = command.makeComputeCommandEncoder() else {
                    throw PixelMotionAudit.Failure.submission
                }
                encoder.setComputePipelineState(pipeline)
                encoder.setTexture(source, index: 0); encoder.setBuffer(result, offset: 0, index: 0)
                encoder.dispatchThreads(MTLSize(width: Self.columns, height: Self.rows, depth: 1),
                                        threadsPerThreadgroup: MTLSize(width: 8, height: 8, depth: 1))
                encoder.endEncoding()
                let surface = Surface(image, texture)
                command.addCompletedHandler { [self, surface, result] command in
                    let signature: [UInt8]? = withExtendedLifetime(surface) {
                        guard command.status == .completed else { return nil }
                        return Array(UnsafeBufferPointer(start: result.contents().assumingMemoryBound(to: UInt8.self),
                                                         count: Self.columns * Self.rows))
                    }
                    lock.withLock {
                        inFlight -= 1
                        if let signature { samples[number] = .init(pts: time, arrived: arrival, signature: signature) }
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
}
