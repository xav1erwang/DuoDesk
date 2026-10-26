// Test the GPU diagnostic before using it to recognize the owned desktop input fixture.
import Foundation
import CoreVideo

enum AuditError: Error { case failed(String) }
final class Once: @unchecked Sendable {
    private let lock = NSLock()
    private var answered = false
    func take() -> Bool { lock.withLock { if answered { return false }; answered = true; return true } }
}

@main enum MarkerAuditCheck {
    static func image(center: UInt8, validRing: Bool) throws -> CVPixelBuffer {
        var pixel: CVPixelBuffer?
        let attributes = [kCVPixelBufferIOSurfacePropertiesKey: [:], kCVPixelBufferMetalCompatibilityKey: true] as CFDictionary
        guard CVPixelBufferCreate(nil, 2008, 1428, kCVPixelFormatType_420YpCbCr8BiPlanarFullRange,
                                  attributes, &pixel) == kCVReturnSuccess, let pixel else { throw AuditError.failed("image") }
        CVPixelBufferLockBaseAddress(pixel, [])
        defer { CVPixelBufferUnlockBaseAddress(pixel, []) }
        let y = CVPixelBufferGetBaseAddressOfPlane(pixel, 0)!.assumingMemoryBound(to: UInt8.self)
        let uv = CVPixelBufferGetBaseAddressOfPlane(pixel, 1)!.assumingMemoryBound(to: UInt8.self)
        let stride = CVPixelBufferGetBytesPerRowOfPlane(pixel, 0)
        let uvStride = CVPixelBufferGetBytesPerRowOfPlane(pixel, 1)
        memset(y, 30, stride * 1428); memset(uv, 128, uvStride * 714)
        for (index, point) in [(0.42, 0.5), (0.58, 0.5), (0.5, 0.4), (0.5, 0.6)].enumerated() {
            let x = Int(point.0 * 2008), row = Int(point.1 * 1428)
            y[row * stride + x] = !validRing && index == 0 ? 30 : 150
            let chroma = row / 2 * uvStride + x / 2 * 2
            uv[chroma] = 40; uv[chroma + 1] = 40
        }
        y[714 * stride + 1004] = center
        return pixel
    }
    @MainActor static func main() async throws {
        let audit = try PixelMotionAudit(fixtureMarker: true)
        let cases: [(UInt8, Bool, Int32)] = [(30, true, 1), (240, true, 2), (240, false, -1)]
        for (center, ring, expected) in cases {
            let pixel = try image(center: center, validRing: ring)
            let actual = try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Int32, Error>) in
                let once = Once()
                DispatchQueue.global().asyncAfter(deadline: .now() + 5) {
                    if once.take() { continuation.resume(throwing: AuditError.failed("GPU deadline")) }
                }
                audit.inspect(pixel, at: 0) { value, _ in
                    if once.take() { continuation.resume(returning: value) }
                }
            }
            guard actual == expected else { throw AuditError.failed("expected \(expected), got \(actual)") }
        }
        print("GPU fixture marker PASS: dark owned marker, clicked marker, invalid ring rejected; no CPU video mapping")
    }
}
