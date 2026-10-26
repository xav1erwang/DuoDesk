// Test-only GPU readback: verify a changing cyan fixture stripe without CPU-mapping IOSurface.
import CoreVideo
import Metal

final class PixelMotionAudit: @unchecked Sendable {
    /// One immutable submission: the GPU only reads the video; this fresh result buffer is
    /// written by that command and read by its completion handler. No resources are reused or
    /// CPU-mutated while the command is in flight. Retain every CoreVideo wrapper until then.
    private final class Submission: @unchecked Sendable {
        let image: CVPixelBuffer
        let ySurface: CVMetalTexture
        let uvSurface: CVMetalTexture
        let result: any MTLBuffer
        init(image: CVPixelBuffer, ySurface: CVMetalTexture, uvSurface: CVMetalTexture, result: any MTLBuffer) {
            self.image = image; self.ySurface = ySurface; self.uvSurface = uvSurface; self.result = result
        }
    }
    enum Failure: Error { case unavailable, texture, submission, invalidFrames }
    private let queue: any MTLCommandQueue
    private let pipeline: any MTLComputePipelineState
    private let cache: CVMetalTextureCache
    private let lock = NSLock()
    private let pending = DispatchGroup()
    private var inFlight = 0
    private var dropped = 0
    private var failed = 0
    private var sequence = 0
    private var positions: [(Int, Double, Int32)] = []
    private var validationPassed = false
    private var reportedFPS: Double?
    private let frameCodes: Bool
    private let maxInFlight: Int
    var changedFramesPerSecond: Double? { lock.withLock { reportedFPS } }

    init(fixtureMarker: Bool = false) throws {
        frameCodes = !fixtureMarker && CommandLine.arguments.contains("--gpu-frame-code")
        maxInFlight = fixtureMarker ? 2 : 8
        guard let device = MTLCreateSystemDefaultDevice(), let queue = device.makeCommandQueue() else {
            throw Failure.unavailable
        }
        var cache: CVMetalTextureCache?
        guard CVMetalTextureCacheCreate(nil, nil, device, nil, &cache) == kCVReturnSuccess, let cache else {
            throw Failure.unavailable
        }
        let library = try device.makeLibrary(source: """
        #include <metal_stdlib>
        using namespace metal;
        kernel void stripe(texture2d<float, access::read> y [[texture(0)]],
                           texture2d<float, access::read> uv [[texture(1)]],
                           device int *result [[buffer(0)]]) {
            uint row = y.get_height() / 5;
            *result = -1;
            for (uint x = 0; x < y.get_width(); ++x) {
                float luma = y.read(uint2(x, row)).r;
                float2 chroma = uv.read(uint2(x / 2, row / 2)).rg;
                if (luma > 100.0 / 255.0 && chroma.x > 120.0 / 255.0 && chroma.y < 110.0 / 255.0) {
                    *result = int(x); return;
                }
            }
        }
        kernel void frameCode(texture2d<float, access::read> y [[texture(0)]],
                              device int *result [[buffer(0)]]) {
            *result = -1;
            uint rows[3] = {y.get_height() / 10, y.get_height() / 2, y.get_height() * 9 / 10};
            for (uint r = 0; r < 3; ++r) {
                uint prefix = 0, frame = 0, checksum = 0;
                for (uint column = 0; column < 36; ++column) {
                    uint x = min(y.get_width() - 1, uint((float(column) + 0.5) / 36.0 * y.get_width()));
                    uint bit = y.read(uint2(x, rows[r])).r > 0.5;
                    if (column < 4) prefix = (prefix << 1) | bit;
                    else if (column < 28) frame = (frame << 1) | bit;
                    else checksum = (checksum << 1) | bit;
                }
                uint expected = (frame ^ (frame >> 8) ^ (frame >> 16) ^ 0xA5u) & 255u;
                if (prefix == 0xAu && checksum == expected) { *result = int(frame); return; }
            }
        }
        kernel void fixtureInputMarker(texture2d<float, access::read> y [[texture(0)]],
                                       texture2d<float, access::read> uv [[texture(1)]],
                                       device int *result [[buffer(0)]]) {
            *result = -1;
            float2 points[4] = {float2(0.42, 0.5), float2(0.58, 0.5), float2(0.5, 0.4), float2(0.5, 0.6)};
            for (uint i = 0; i < 4; ++i) {
                uint2 p = uint2(points[i] * float2(y.get_width(), y.get_height()));
                float luma = y.read(p).r * 255.0;
                float2 chroma = uv.read(p / 2).rg * 255.0;
                if (!(luma > 120.0 && luma < 220.0 && chroma.x < 100.0 && chroma.y < 100.0)) return;
            }
            float center = y.read(uint2(y.get_width() / 2, y.get_height() / 2)).r * 255.0;
            *result = center < 60.0 ? 1 : (center > 220.0 ? 2 : 0);
        }
        """, options: nil)
        let kernel = fixtureMarker ? "fixtureInputMarker" : (frameCodes ? "frameCode" : "stripe")
        guard let function = library.makeFunction(name: kernel) else { throw Failure.unavailable }
        self.pipeline = try device.makeComputePipelineState(function: function)
        self.queue = queue
        self.cache = cache
    }

    func inspect(_ image: CVPixelBuffer, at time: Double, onResult: (@Sendable (Int32, Double) -> Void)? = nil) {
        let number: Int? = lock.withLock {
            guard inFlight < maxInFlight else { dropped += 1; return nil }
            inFlight += 1; sequence += 1; return sequence
        }
        guard let number else { return }
        do {
            guard CVPixelBufferIsPlanar(image), CVPixelBufferGetPlaneCount(image) == 2 else { throw Failure.texture }
            var ySurface: CVMetalTexture?, uvSurface: CVMetalTexture?
            let yStatus = CVMetalTextureCacheCreateTextureFromImage(nil, cache, image, nil, .r8Unorm,
                CVPixelBufferGetWidthOfPlane(image, 0), CVPixelBufferGetHeightOfPlane(image, 0), 0, &ySurface)
            let uvStatus = CVMetalTextureCacheCreateTextureFromImage(nil, cache, image, nil, .rg8Unorm,
                CVPixelBufferGetWidthOfPlane(image, 1), CVPixelBufferGetHeightOfPlane(image, 1), 1, &uvSurface)
            guard yStatus == kCVReturnSuccess, uvStatus == kCVReturnSuccess,
                  let ySurface, let uvSurface, let y = CVMetalTextureGetTexture(ySurface), let uv = CVMetalTextureGetTexture(uvSurface),
                  let result = queue.device.makeBuffer(length: MemoryLayout<Int32>.size, options: .storageModeShared),
                  let command = queue.makeCommandBuffer(), let encoder = command.makeComputeCommandEncoder() else { throw Failure.submission }
            encoder.setComputePipelineState(pipeline)
            encoder.setTexture(y, index: 0); encoder.setTexture(uv, index: 1)
            encoder.setBuffer(result, offset: 0, index: 0)
            encoder.dispatchThreads(MTLSize(width: 1, height: 1, depth: 1), threadsPerThreadgroup: MTLSize(width: 1, height: 1, depth: 1))
            encoder.endEncoding()
            pending.enter()
            let submission = Submission(image: image, ySurface: ySurface, uvSurface: uvSurface, result: result)
            command.addCompletedHandler { [self, submission] completed in
                // Keep the source and both texture wrappers alive until the GPU finishes using them.
                withExtendedLifetime(submission) {
                    let value = completed.status == .completed ? submission.result.contents().load(as: Int32.self) : -2
                    lock.withLock {
                        if completed.status == .completed { positions.append((number, time, value)) }
                        else { failed += 1 }
                        inFlight -= 1
                    }
                    onResult?(value, time)
                }
                pending.leave()
            }
            command.commit()
        } catch {
            lock.withLock { failed += 1; inFlight -= 1 }
            onResult?(-2, time)
        }
    }

    func report(from start: Double, seconds: Int) async -> String {
        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            pending.notify(queue: .global()) { continuation.resume() }
        }
        return lock.withLock {
            let ordered = positions.sorted { $0.0 < $1.0 }
            var previous: Int32 = -1
            var changed = 0, detected = 0, backwards = 0
            var missingRun = 0, longestMissingRun = 0
            var histogram: [Int: Int] = [:]
            var bySecond = [Int](repeating: 0, count: seconds)
            for (_, time, x) in ordered {
                if x >= 0 {
                    detected += 1; histogram[Int(x) / 100, default: 0] += 1; missingRun = 0
                } else {
                    missingRun += 1; longestMissingRun = max(longestMissingRun, missingRun)
                }
                if x >= 0, x != previous {
                    if frameCodes, previous >= 0, (Int(x) - Int(previous)) & 0xFFFFFF >= 0x800000 {
                        backwards += 1; continue
                    }
                    changed += 1
                    let second = Int(time - start)
                    if bySecond.indices.contains(second) { bySecond[second] += 1 }
                }
                if x >= 0 || !frameCodes { previous = x }
            }
            let bins = histogram.keys.sorted().map { "\($0 * 100):\(histogram[$0, default: 0])" }.joined(separator: ",")
            validationPassed = sequence > 0 && failed == 0 && dropped == 0 && detected == sequence && backwards == 0
            reportedFPS = Double(changed) / Double(seconds)
            let detail = frameCodes ? "backwards=\(backwards), firstFrameIDs=\(ordered.prefix(40).map { $0.2 })" : "xBins={\(bins)}, longestMissingRun=\(longestMissingRun), firstPositions=\(ordered.prefix(80).map { $0.2 })"
            return "GPU \(frameCodes ? "FRAME CODES" : "PIXELS"): submitted=\(sequence), detected=\(detected), changed=\(changed), changedFPS=\(Double(changed) / Double(seconds)), missing=\(ordered.count - detected), failed=\(failed), auditDropped=\(dropped), perSecond=\(bySecond); \(detail)"
        }
    }

    /// Capture completion is insufficient when the expected test image was absent or corrupted.
    func validate() throws {
        guard lock.withLock({ validationPassed }) else { throw Failure.invalidFrames }
    }
}
