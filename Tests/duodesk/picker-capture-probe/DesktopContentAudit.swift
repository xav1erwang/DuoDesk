// Copyright 2026 DUO你电脑 contributors. SPDX-License-Identifier: Apache-2.0
// Test-only measurement of the actual desktop image. No pixels are written to disk.
import CoreVideo
import Metal

/// Reduces every luma pixel into 16×16 tile sums and centered spatial moments on the GPU. The center region is inside the
/// normal document window; comparing it as well as the complete frame prevents background-only
/// activity from being counted as document scrolling. No synthetic frame codes are used.
final class DesktopContentAudit: FrameAudit, @unchecked Sendable {
    private final class Submission: @unchecked Sendable {
        let image: CVPixelBuffer
        let surface: CVMetalTexture
        let result: any MTLBuffer
        init(image: CVPixelBuffer, surface: CVMetalTexture, result: any MTLBuffer) {
            self.image = image; self.surface = surface; self.result = result
        }
    }
    private struct Result {
        let time: Double
        let tiles: [Int32]?
        let width: Int
        let height: Int
    }
    private let queue: any MTLCommandQueue
    private let pipeline: any MTLComputePipelineState
    private let cache: CVMetalTextureCache
    private let pending = DispatchGroup()
    private let lock = NSLock()
    private var inFlight = 0, sequence = 0, next = 1, failed = 0, dropped = 0
    private var ready: [Int: Result] = [:]
    private var prior: [Int32]?
    private var comparisons: [(Double, Double, Double, Int)] = []
    private var validationPassed = false
    private var reportedFPS: Double?
    var changedFramesPerSecond: Double? { lock.withLock { reportedFPS } }

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
        kernel void tileSums(texture2d<float, access::read> image [[texture(0)]],
                             device int *sums [[buffer(0)]], uint2 tile [[thread_position_in_grid]]) {
            uint2 count = (uint2(image.get_width(), image.get_height()) + 15u) / 16u;
            if (tile.x >= count.x || tile.y >= count.y) return;
            int sum = 0, xMoment = 0, yMoment = 0;
            for (uint y = tile.y * 16u; y < min((tile.y + 1u) * 16u, image.get_height()); ++y)
                for (uint x = tile.x * 16u; x < min((tile.x + 1u) * 16u, image.get_width()); ++x) {
                    int pixel = int(round(image.read(uint2(x, y)).r * 255.0));
                    sum += pixel;
                    xMoment += pixel * (int(x % 16u) * 2 - 15);
                    yMoment += pixel * (int(y % 16u) * 2 - 15);
                }
            uint offset = (tile.y * count.x + tile.x) * 3u;
            sums[offset] = sum; sums[offset + 1u] = xMoment; sums[offset + 2u] = yMoment;
        }
        """, options: nil)
        guard let function = library.makeFunction(name: "tileSums") else { throw PixelMotionAudit.Failure.unavailable }
        self.pipeline = try device.makeComputePipelineState(function: function)
        self.queue = queue; self.cache = cache
    }

    func inspect(_ image: CVPixelBuffer, at time: Double, onResult: (@Sendable (Int32, Double) -> Void)?) {
        let number: Int? = lock.withLock {
            guard inFlight < 8 else { dropped += 1; return nil }
            inFlight += 1; sequence += 1; return sequence
        }
        guard let number else { return }
        let width = CVPixelBufferGetWidth(image), height = CVPixelBufferGetHeight(image)
        let columns = (width + 15) / 16, rows = (height + 15) / 16
        pending.enter()
        do {
            guard CVPixelBufferIsPlanar(image), CVPixelBufferGetPlaneCount(image) == 2 else { throw PixelMotionAudit.Failure.texture }
            var surface: CVMetalTexture?
            let status = CVMetalTextureCacheCreateTextureFromImage(nil, cache, image, nil, .r8Unorm,
                CVPixelBufferGetWidthOfPlane(image, 0), CVPixelBufferGetHeightOfPlane(image, 0), 0, &surface)
            guard status == kCVReturnSuccess, let surface, let texture = CVMetalTextureGetTexture(surface),
                  let result = queue.device.makeBuffer(length: columns * rows * 3 * MemoryLayout<Int32>.size, options: .storageModeShared),
                  let command = queue.makeCommandBuffer(), let encoder = command.makeComputeCommandEncoder() else {
                throw PixelMotionAudit.Failure.submission
            }
            encoder.setComputePipelineState(pipeline); encoder.setTexture(texture, index: 0)
            encoder.setBuffer(result, offset: 0, index: 0)
            encoder.dispatchThreads(MTLSize(width: columns, height: rows, depth: 1),
                                    threadsPerThreadgroup: MTLSize(width: 8, height: 8, depth: 1))
            encoder.endEncoding()
            let submission = Submission(image: image, surface: surface, result: result)
            command.addCompletedHandler { [self, submission] command in
                let values: [Int32]? = withExtendedLifetime(submission) {
                    guard command.status == .completed else { return nil }
                    return Array(UnsafeBufferPointer(start: submission.result.contents().assumingMemoryBound(to: Int32.self),
                                                     count: columns * rows * 3))
                }
                finish(number, Result(time: time, tiles: values, width: width, height: height))
            }
            command.commit()
        } catch {
            finish(number, Result(time: time, tiles: nil, width: width, height: height))
        }
    }

    private func finish(_ number: Int, _ result: Result) {
        lock.withLock {
            inFlight -= 1
            ready[number] = result
            while let result = ready.removeValue(forKey: next) {
                next += 1
                guard let values = result.tiles else { failed += 1; prior = nil; continue }
                defer { prior = values }
                guard let prior, prior.count == values.count else { continue }
                let columns = (result.width + 15) / 16, rows = (result.height + 15) / 16
                var fullDelta: UInt64 = 0, centerDelta: UInt64 = 0
                var centerPixels = 0, movingTiles = 0
                for y in 0..<rows {
                    for x in 0..<columns {
                        let i = (y * columns + x) * 3
                        let difference = UInt64(abs(Int(values[i + 1]) - Int(prior[i + 1]))
                                                + abs(Int(values[i + 2]) - Int(prior[i + 2])))
                        fullDelta += difference
                        if x * 16 >= result.width * 3 / 10, (x + 1) * 16 <= result.width * 7 / 10,
                           y * 16 >= result.height * 3 / 10, (y + 1) * 16 <= result.height * 7 / 10 {
                            centerDelta += difference; centerPixels += 256
                            if difference >= 922 { movingTiles += 1 }
                        }
                    }
                }
                let fullMean = Double(fullDelta) / Double(result.width * result.height * 30)
                let centerMean = centerPixels == 0 ? 0 : Double(centerDelta) / Double(centerPixels * 30)
                comparisons.append((result.time, fullMean, centerMean, movingTiles))
            }
        }
        pending.leave()
    }

    func report(from start: Double, seconds: Int) async -> String {
        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            pending.notify(queue: .global()) { continuation.resume() }
        }
        return lock.withLock {
            // The first second is stationary; the controlling process then starts real text scrolling.
            let active = comparisons.filter { $0.0 >= start + 1 && $0.0 < start + Double(seconds) }
            let changed = active.filter { $0.1 >= 0.01 && $0.2 >= 0.12 && $0.3 >= 20 }
            var perSecond = [Int](repeating: 0, count: seconds)
            for item in changed {
                let second = Int(item.0 - start)
                if perSecond.indices.contains(second) { perSecond[second] += 1 }
            }
            let values = active.map(\.2).sorted()
            let stationary = comparisons.filter { $0.0 >= start && $0.0 < start + 1 }
            let stationaryChanging = stationary.filter { $0.1 >= 0.01 && $0.2 >= 0.12 && $0.3 >= 20 }.count
            let baselineMax = stationary.map(\.2).max() ?? 0
            let p50 = values.isEmpty ? 0 : values[values.count / 2]
            let p95 = values.isEmpty ? 0 : values[Int(Double(values.count - 1) * 0.95)]
            validationPassed = sequence > 0 && failed == 0 && dropped == 0 && ready.isEmpty
                && !active.isEmpty && stationaryChanging == 0
            reportedFPS = Double(changed.count) / Double(max(1, seconds - 1))
            return String(format: "DESKTOP CONTENT: submitted=%d comparisons=%d changing=%d activeFPS=%.3f failed=%d auditDropped=%d; fullImage and centerText spatial-moment thresholds=0.01/0.12 plus 20 moving tiles; stationaryPairs=%d stationaryChanging=%d stationaryMax=%.3f activeCenterP50=%.3f p95=%.3f; perSecond=%@",
                          sequence, active.count, changed.count, reportedFPS ?? 0, failed, dropped, stationary.count,
                          stationaryChanging, baselineMax, p50, p95,
                          String(describing: perSecond))
        }
    }

    func validate() throws {
        guard lock.withLock({ validationPassed }) else { throw PixelMotionAudit.Failure.invalidFrames }
    }
}
