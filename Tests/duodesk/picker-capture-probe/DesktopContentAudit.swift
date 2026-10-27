// Copyright 2026 DUO你电脑 contributors. SPDX-License-Identifier: Apache-2.0
// Test-only comparison of actual luma pixels. No pixels are written to disk.
import CoreVideo
import Metal

/// Compares every luma pixel with the preceding frame on the GPU. The center region is inside the
/// normal document window; requiring changes there prevents background-only motion from counting.
/// Differences below three luma levels are ignored to make the audit resistant to small codec noise.
final class DesktopContentAudit: FrameAudit, @unchecked Sendable {
    private final class Surface: @unchecked Sendable {
        let image: CVPixelBuffer
        let texture: CVMetalTexture
        init(image: CVPixelBuffer, texture: CVMetalTexture) { self.image = image; self.texture = texture }
    }
    private final class Submission: @unchecked Sendable {
        let current: Surface
        let previous: Surface
        let result: any MTLBuffer
        init(current: Surface, previous: Surface, result: any MTLBuffer) {
            self.current = current; self.previous = previous; self.result = result
        }
    }
    private struct Result {
        let time: Double
        let tiles: [UInt32]?
        let width: Int
        let height: Int
    }
    private let queue: any MTLCommandQueue
    private let pipeline: any MTLComputePipelineState
    private let cache: CVMetalTextureCache
    private let activeOffsetSeconds: Int
    private let submissionQueue = DispatchQueue(label: "duodesk.desktop-content-audit", qos: .userInteractive)
    private var previous: Surface?  // submissionQueue only
    private let pending = DispatchGroup()
    private let lock = NSLock()
    private var inFlight = 0, sequence = 0, next = 1, failed = 0, dropped = 0
    private var ready: [Int: Result] = [:]
    private var comparisons: [(Double, Double, Double, Int)] = []
    private var validationPassed = false
    private var reportedFPS: Double?
    var changedFramesPerSecond: Double? { lock.withLock { reportedFPS } }

    init(activeOffsetSeconds: Int = 1) throws {
        precondition(activeOffsetSeconds >= 1)
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
        kernel void compareTiles(texture2d<float, access::read> current [[texture(0)]],
                                 texture2d<float, access::read> previous [[texture(1)]],
                                 device uint *results [[buffer(0)]], uint2 tile [[thread_position_in_grid]]) {
            uint2 count = (uint2(current.get_width(), current.get_height()) + 15u) / 16u;
            if (tile.x >= count.x || tile.y >= count.y) return;
            uint sum = 0, changed = 0;
            for (uint y = tile.y * 16u; y < min((tile.y + 1u) * 16u, current.get_height()); ++y)
                for (uint x = tile.x * 16u; x < min((tile.x + 1u) * 16u, current.get_width()); ++x) {
                    int a = int(round(current.read(uint2(x, y)).r * 255.0));
                    int b = int(round(previous.read(uint2(x, y)).r * 255.0));
                    uint delta = uint(abs(a - b));
                    if (delta >= 3u) { sum += delta; ++changed; }
                }
            uint offset = (tile.y * count.x + tile.x) * 2u;
            results[offset] = sum; results[offset + 1u] = changed;
        }
        """, options: nil)
        guard let function = library.makeFunction(name: "compareTiles") else { throw PixelMotionAudit.Failure.unavailable }
        self.pipeline = try device.makeComputePipelineState(function: function)
        self.queue = queue; self.cache = cache; self.activeOffsetSeconds = activeOffsetSeconds
    }

    func inspect(_ image: CVPixelBuffer, at time: Double, onResult: (@Sendable (Int32, Double) -> Void)?) {
        let number: Int? = lock.withLock {
            guard inFlight < 8 else { dropped += 1; return nil }
            inFlight += 1; sequence += 1; return sequence
        }
        guard let number else { return }
        pending.enter()
        submissionQueue.async { [self, image] in submit(image, number: number, time: time) }
    }

    private func submit(_ image: CVPixelBuffer, number: Int, time: Double) {
        let width = CVPixelBufferGetWidth(image), height = CVPixelBufferGetHeight(image)
        let columns = (width + 15) / 16, rows = (height + 15) / 16
        do {
            guard CVPixelBufferIsPlanar(image), CVPixelBufferGetPlaneCount(image) == 2 else { throw PixelMotionAudit.Failure.texture }
            var surface: CVMetalTexture?
            let status = CVMetalTextureCacheCreateTextureFromImage(nil, cache, image, nil, .r8Unorm,
                CVPixelBufferGetWidthOfPlane(image, 0), CVPixelBufferGetHeightOfPlane(image, 0), 0, &surface)
            guard status == kCVReturnSuccess, let surface, let texture = CVMetalTextureGetTexture(surface) else {
                throw PixelMotionAudit.Failure.texture
            }
            let current = Surface(image: image, texture: surface)
            let prior = previous ?? current
            guard CVPixelBufferGetWidth(prior.image) == width, CVPixelBufferGetHeight(prior.image) == height,
                  let previousTexture = CVMetalTextureGetTexture(prior.texture),
                  let result = queue.device.makeBuffer(length: columns * rows * 2 * MemoryLayout<UInt32>.size, options: .storageModeShared),
                  let command = queue.makeCommandBuffer(), let encoder = command.makeComputeCommandEncoder() else {
                throw PixelMotionAudit.Failure.submission
            }
            previous = current
            encoder.setComputePipelineState(pipeline)
            encoder.setTexture(texture, index: 0); encoder.setTexture(previousTexture, index: 1)
            encoder.setBuffer(result, offset: 0, index: 0)
            encoder.dispatchThreads(MTLSize(width: columns, height: rows, depth: 1),
                                    threadsPerThreadgroup: MTLSize(width: 8, height: 8, depth: 1))
            encoder.endEncoding()
            let submission = Submission(current: current, previous: prior, result: result)
            command.addCompletedHandler { [self, submission] command in
                let values: [UInt32]? = withExtendedLifetime(submission) {
                    guard command.status == .completed else { return nil }
                    return Array(UnsafeBufferPointer(start: submission.result.contents().assumingMemoryBound(to: UInt32.self),
                                                     count: columns * rows * 2))
                }
                finish(number, Result(time: time, tiles: values, width: width, height: height))
            }
            command.commit()
        } catch {
            previous = nil
            finish(number, Result(time: time, tiles: nil, width: width, height: height))
        }
    }

    private func finish(_ number: Int, _ result: Result) {
        lock.withLock {
            inFlight -= 1
            ready[number] = result
            while let result = ready.removeValue(forKey: next) {
                let index = next; next += 1
                guard let values = result.tiles else { failed += 1; continue }
                guard index > 1 else { continue }
                let columns = (result.width + 15) / 16, rows = (result.height + 15) / 16
                var fullDelta: UInt64 = 0, centerDelta: UInt64 = 0
                var centerPixels = 0, changedPixels = 0
                for y in 0..<rows {
                    for x in 0..<columns {
                        let i = (y * columns + x) * 2
                        fullDelta += UInt64(values[i])
                        if x * 16 >= result.width * 3 / 10, (x + 1) * 16 <= result.width * 7 / 10,
                           y * 16 >= result.height * 3 / 10, (y + 1) * 16 <= result.height * 7 / 10 {
                            centerDelta += UInt64(values[i]); centerPixels += 256
                            changedPixels += Int(values[i + 1])
                        }
                    }
                }
                let fullMean = Double(fullDelta) / Double(result.width * result.height)
                let centerMean = centerPixels == 0 ? 0 : Double(centerDelta) / Double(centerPixels)
                comparisons.append((result.time, fullMean, centerMean, changedPixels))
            }
        }
        pending.leave()
    }

    func report(from start: Double, seconds: Int) async -> String {
        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            pending.notify(queue: .global()) { continuation.resume() }
        }
        return lock.withLock {
            func meaningful(_ item: (Double, Double, Double, Int)) -> Bool {
                item.1 >= 0.01 && item.2 >= 0.12 && item.3 >= 500
            }
            let active = comparisons.filter { $0.0 >= start + Double(activeOffsetSeconds) && $0.0 < start + Double(seconds) }
            let changed = active.filter(meaningful)
            let missed = active.filter { !meaningful($0) }
            var perSecond = [Int](repeating: 0, count: seconds)
            for item in changed {
                let second = Int(item.0 - start)
                if perSecond.indices.contains(second) { perSecond[second] += 1 }
            }
            let values = active.map(\.2).sorted()
            let stationary = comparisons.filter { $0.0 >= start && $0.0 < start + 1 }
            let stationaryChanging = stationary.filter(meaningful).count
            let baselineMax = stationary.map(\.2).max() ?? 0
            let p50 = values.isEmpty ? 0 : values[values.count / 2]
            let p95 = values.isEmpty ? 0 : values[(values.count * 95 + 99) / 100 - 1]
            validationPassed = sequence > 0 && failed == 0 && dropped == 0 && ready.isEmpty
                && !active.isEmpty && !stationary.isEmpty && stationaryChanging == 0
            reportedFPS = Double(changed.count) / Double(max(1, seconds - activeOffsetSeconds))
            let missSample = missed.prefix(12).map { item in
                String(format: "%.3f:%.3f/%.3f/%d", item.0 - start, item.1, item.2, item.3)
            }.joined(separator: ",")
            let zeroFull = missed.filter { $0.1 == 0 }.count
            let zeroCenter = missed.filter { $0.2 == 0 }.count
            return String(format: "DESKTOP CONTENT: submitted=%d comparisons=%d changing=%d activeFPS=%.3f activeOffset=%d activeSeconds=%d failed=%d auditDropped=%d; per-pixel luma delta>=3; full/center thresholds=0.01/0.12 and 500 changed center pixels; stationaryPairs=%d stationaryChanging=%d stationaryMax=%.3f activeCenterP50=%.3f p95=%.3f; missed=%d zeroFull=%d zeroCenter=%d firstMissed(time:full/center/pixels)=%@; perSecond=%@",
                          sequence, active.count, changed.count, reportedFPS ?? 0, activeOffsetSeconds,
                          seconds - activeOffsetSeconds, failed, dropped, stationary.count,
                          stationaryChanging, baselineMax, p50, p95, missed.count, zeroFull, zeroCenter, missSample,
                          String(describing: perSecond))
        }
    }

    func validate() throws {
        guard lock.withLock({ validationPassed }) else { throw PixelMotionAudit.Failure.invalidFrames }
    }

    /// Aggregate-only diagnostic data: timestamps and differences, never image pixels.
    func comparisonSnapshot() -> [(time: Double, full: Double, center: Double, changedPixels: Int)] {
        lock.withLock { comparisons.map { (time: $0.0, full: $0.1, center: $0.2, changedPixels: $0.3) } }
    }
}
