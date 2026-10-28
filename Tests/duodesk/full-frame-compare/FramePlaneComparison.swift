// Copyright 2026 DUO你电脑 contributors. SPDX-License-Identifier: Apache-2.0
// Diagnostic only. Never linked into the app or used to suppress a captured frame.
import CoreVideo
import Foundation
import Metal

/// Compares the actual bytes in both 8-bit bi-planar image planes, excluding stride padding.
/// The caller must keep both buffers immutable until the comparison finishes. A single occupied
/// slot bounds retained IOSurfaces if the GPU stalls. Pixel attachments and color interpretation
/// are not compared: equal plane bytes alone do not prove equal rendered colors.
final class FramePlaneComparison: @unchecked Sendable {
    enum Failure: Error { case unavailable, busy, format, dimensions, texture, submission, gpu }
    struct Result {
        let changedLumaTiles: Int
        let changedChromaTiles: Int
        let gpuSeconds: Double?
        var samePlaneBytes: Bool { changedLumaTiles == 0 && changedChromaTiles == 0 }
    }
    private final class Submission: @unchecked Sendable {
        let images: [CVPixelBuffer]
        let surfaces: [CVMetalTexture]
        let result: any MTLBuffer
        init(images: [CVPixelBuffer], surfaces: [CVMetalTexture], result: any MTLBuffer) {
            self.images = images; self.surfaces = surfaces; self.result = result
        }
    }
    private let lock = NSLock()
    private var busy = false
    private let queue: any MTLCommandQueue
    private let pipeline: any MTLComputePipelineState
    private let cache: CVMetalTextureCache

    init() throws {
        guard let device = MTLCreateSystemDefaultDevice(), let queue = device.makeCommandQueue() else { throw Failure.unavailable }
        var textureCache: CVMetalTextureCache?
        guard CVMetalTextureCacheCreate(nil, nil, device, nil, &textureCache) == kCVReturnSuccess,
              let textureCache else { throw Failure.unavailable }
        let library = try device.makeLibrary(source: """
        #include <metal_stdlib>
        using namespace metal;
        kernel void comparePlanes(texture2d<float, access::read> aY [[texture(0)]],
                                  texture2d<float, access::read> bY [[texture(1)]],
                                  texture2d<float, access::read> aUV [[texture(2)]],
                                  texture2d<float, access::read> bUV [[texture(3)]],
                                  device uint2 *out [[buffer(0)]], uint2 tile [[thread_position_in_grid]]) {
            uint columns = (aY.get_width() + 15u) / 16u;
            uint rows = (aY.get_height() + 15u) / 16u;
            if (tile.x >= columns || tile.y >= rows) return;
            uint2 origin = tile * 16u;
            bool yChanged = false, uvChanged = false;
            for (uint y = origin.y; y < min(origin.y + 16u, aY.get_height()) && !yChanged; ++y)
                for (uint x = origin.x; x < min(origin.x + 16u, aY.get_width()); ++x)
                    if (aY.read(uint2(x, y)).r != bY.read(uint2(x, y)).r) { yChanged = true; break; }
            for (uint y = origin.y; y < min(origin.y + 16u, aUV.get_height()) && !uvChanged; ++y)
                for (uint x = origin.x; x < min(origin.x + 16u, aUV.get_width()); ++x)
                    if (any(aUV.read(uint2(x, y)).rg != bUV.read(uint2(x, y)).rg)) { uvChanged = true; break; }
            out[tile.y * columns + tile.x] = uint2(yChanged ? 1u : 0u, uvChanged ? 1u : 0u);
        }
        """, options: nil)
        guard let function = library.makeFunction(name: "comparePlanes") else { throw Failure.unavailable }
        pipeline = try device.makeComputePipelineState(function: function)
        self.queue = queue; cache = textureCache
    }

    func compare(_ a: CVPixelBuffer, _ b: CVPixelBuffer) async throws -> Result {
        guard lock.withLock({ if busy { return false }; busy = true; return true }) else { throw Failure.busy }
        return try await withCheckedThrowingContinuation { continuation in
            do {
                let format = CVPixelBufferGetPixelFormatType(a)
                guard [kCVPixelFormatType_420YpCbCr8BiPlanarFullRange,
                       kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange].contains(format),
                      CVPixelBufferGetPixelFormatType(b) == format,
                      CVPixelBufferIsPlanar(a), CVPixelBufferIsPlanar(b),
                      CVPixelBufferGetPlaneCount(a) == 2, CVPixelBufferGetPlaneCount(b) == 2 else { throw Failure.format }
                let width = CVPixelBufferGetWidth(a), height = CVPixelBufferGetHeight(a)
                guard width > 0, height > 0, width <= 8192, height <= 8192,
                      width * height <= 16_777_216, CVPixelBufferGetWidth(b) == width,
                      CVPixelBufferGetHeight(b) == height else { throw Failure.dimensions }
                for plane in 0..<2 {
                    guard CVPixelBufferGetWidthOfPlane(a, plane) == CVPixelBufferGetWidthOfPlane(b, plane),
                          CVPixelBufferGetHeightOfPlane(a, plane) == CVPixelBufferGetHeightOfPlane(b, plane),
                          CVPixelBufferGetWidthOfPlane(a, plane) > 0,
                          CVPixelBufferGetHeightOfPlane(a, plane) > 0 else { throw Failure.dimensions }
                }
                let yWidth = CVPixelBufferGetWidthOfPlane(a, 0), yHeight = CVPixelBufferGetHeightOfPlane(a, 0)
                guard yWidth == width, yHeight == height,
                      CVPixelBufferGetWidthOfPlane(a, 1) <= yWidth,
                      CVPixelBufferGetHeightOfPlane(a, 1) <= yHeight else { throw Failure.dimensions }
                func surface(_ buffer: CVPixelBuffer, plane: Int, format: MTLPixelFormat) throws -> CVMetalTexture {
                    var texture: CVMetalTexture?
                    let status = CVMetalTextureCacheCreateTextureFromImage(nil, cache, buffer, nil, format,
                        CVPixelBufferGetWidthOfPlane(buffer, plane), CVPixelBufferGetHeightOfPlane(buffer, plane), plane, &texture)
                    guard status == kCVReturnSuccess, let texture else { throw Failure.texture }
                    return texture
                }
                let surfaces = try [surface(a, plane: 0, format: .r8Unorm), surface(b, plane: 0, format: .r8Unorm),
                                    surface(a, plane: 1, format: .rg8Unorm), surface(b, plane: 1, format: .rg8Unorm)]
                let textures = surfaces.compactMap(CVMetalTextureGetTexture)
                let columns = (yWidth + 15) / 16, rows = (yHeight + 15) / 16, count = columns * rows
                guard textures.count == 4,
                      let output = queue.device.makeBuffer(length: count * MemoryLayout<SIMD2<UInt32>>.stride, options: .storageModeShared),
                      let command = queue.makeCommandBuffer(), let encoder = command.makeComputeCommandEncoder() else { throw Failure.submission }
                encoder.setComputePipelineState(pipeline)
                for (index, texture) in textures.enumerated() { encoder.setTexture(texture, index: index) }
                encoder.setBuffer(output, offset: 0, index: 0)
                encoder.dispatchThreads(MTLSize(width: columns, height: rows, depth: 1),
                                        threadsPerThreadgroup: MTLSize(width: 8, height: 8, depth: 1))
                encoder.endEncoding()
                let submission = Submission(images: [a, b], surfaces: surfaces, result: output)
                command.addCompletedHandler { [self, submission] completed in
                    let result: Result? = withExtendedLifetime(submission) {
                        guard completed.status == .completed else { return nil }
                        let tiles = UnsafeBufferPointer(start: submission.result.contents().assumingMemoryBound(to: SIMD2<UInt32>.self), count: count)
                        let y = tiles.reduce(0) { $0 + Int($1.x) }, uv = tiles.reduce(0) { $0 + Int($1.y) }
                        let gpu = completed.gpuEndTime - completed.gpuStartTime
                        return Result(changedLumaTiles: y, changedChromaTiles: uv,
                                      gpuSeconds: completed.gpuStartTime > 0 && gpu.isFinite && gpu >= 0 ? gpu : nil)
                    }
                    lock.withLock { busy = false }
                    if let result { continuation.resume(returning: result) }
                    else { continuation.resume(throwing: Failure.gpu) }
                }
                command.commit()
            } catch {
                lock.withLock { busy = false }
                continuation.resume(throwing: error)
            }
        }
    }
}
