// Exercises queued parameter sets racing a disconnect using the real hardware codec.
import Foundation
import CoreVideo
import CoreMedia
import StreamProtocol

setbuf(stdout, nil)
final class Results: @unchecked Sendable {
    let lock = NSLock()
    var parameters: ParameterSets?
    var frame: Data?
    var callbacks: [UInt64] = []
    var samples: [UInt64] = []
    var failures: [String] = []
    var recoveryRequests: [UInt64] = []
    var stale = 0
}
let results = Results()
let native = DuoDesktopResolution(width: 2007, height: 1427)
let decoder = HardwareHEVCDecoder(onFormat: { _, token in
    results.lock.withLock { results.callbacks.append(token) }
}, onSample: { _, token, _ in
    results.lock.withLock { results.callbacks.append(token); results.samples.append(token) }
}, onFailure: { message, _ in
    results.lock.withLock { results.failures.append(message) }
}, onNeedsKeyframe: { token in
    results.lock.withLock { results.recoveryRequests.append(token) }
})
let initialToken = decoder.require(native)
decoder.enqueue(Data([0]), isKeyframe: false)
guard results.lock.withLock({ results.recoveryRequests.last == initialToken }) else {
    fatalError("Recovery request lost its decoder generation")
}
let queuedRecoveryFence = { decoder.isCurrent(initialToken) }
_ = decoder.clear()
guard !queuedRecoveryFence() else { fatalError("Old recovery request survived a reset") }
let encoder = try HEVCEncoder(width: native.encodedWidth, height: native.encodedHeight, fps: 120,
                              bitrate: 20_000_000, prioritizeSpeed: true, quiet: true)
encoder.onEncoded = { data, key, ps in
    if key, let ps { results.lock.withLock { results.parameters = ps; results.frame = data } }
}
var image: CVPixelBuffer?
guard CVPixelBufferCreate(nil, native.encodedWidth, native.encodedHeight,
    kCVPixelFormatType_420YpCbCr8BiPlanarFullRange, [kCVPixelBufferIOSurfacePropertiesKey: [:]] as CFDictionary,
    &image) == kCVReturnSuccess, let image else { fatalError("Could not create codec fixture") }
CVPixelBufferLockBaseAddress(image, [])
for plane in 0..<2 {
    if let pixels = CVPixelBufferGetBaseAddressOfPlane(image, plane) {
        memset(pixels, 128, CVPixelBufferGetBytesPerRowOfPlane(image, plane) * CVPixelBufferGetHeightOfPlane(image, plane))
    }
}
CVPixelBufferUnlockBaseAddress(image, [])
encoder.encode(image, pts: .zero)
Task {
    do {
        for _ in 0..<200 {
            if results.lock.withLock({ results.parameters != nil }) { break }
            try await Task.sleep(for: .milliseconds(10))
        }
        guard let ps = results.lock.withLock({ results.parameters }),
              let data = results.lock.withLock({ results.frame }) else { throw NSError(domain: "No fixture frame", code: 1) }
        decoder.apply(ps); decoder.enqueue(data, isKeyframe: true)
        for _ in 0..<200 {
            if results.lock.withLock({ !results.samples.isEmpty }) { break }
            try await Task.sleep(for: .milliseconds(10))
        }
        for _ in 0..<8 {
            guard let old = results.lock.withLock({ results.samples.last }) else {
                throw NSError(domain: "No current decoded fixture", code: 2)
            }
            let queuedInputFence: @Sendable () -> Bool = { decoder.isCurrent(old) }
            guard queuedInputFence() else { throw NSError(domain: "Fixture image is not current", code: 3) }
            let barrier = decoder.clear()
            guard !queuedInputFence() else { throw NSError(domain: "Old input survived a video reset", code: 4) }
            results.lock.withLock { results.samples = [] }
            decoder.apply(ps); decoder.enqueue(data, isKeyframe: true)
            for _ in 0..<200 {
                if results.lock.withLock({ results.samples.contains { $0 > barrier } }) { break }
                try await Task.sleep(for: .milliseconds(10))
            }
            guard let fresh = results.lock.withLock({ results.samples.last }), fresh > barrier, decoder.isCurrent(fresh) else {
                throw NSError(domain: "Identical parameters did not create a fresh image", code: 5)
            }
        }
        print("Decoder lifecycle: 8 identical-format restarts invalidated queued input and produced fresh hardware images")
        for _ in 0..<40 {
            results.lock.withLock { results.callbacks = [] }
            // Already queued old work must never create a newer generation after clear returns.
            for _ in 0..<16 { decoder.apply(ps); decoder.enqueue(data, isKeyframe: true) }
            let barrier = decoder.clear()
            try await Task.sleep(for: .milliseconds(100))
            results.lock.withLock { results.stale += results.callbacks.filter { $0 > barrier }.count }
        }
        let report = results.lock.withLock { (results.stale, results.failures) }
        print("Decoder lifecycle: 40 disconnect races, stale callbacks=\(report.0), failures=\(report.1)")
        let passed = report.0 == 0 && report.1.isEmpty
        print("Decoder lifecycle \(passed ? "PASS" : "FAIL")")
        exit(passed ? 0 : 1)
    } catch { print("Decoder lifecycle FAIL: \(error)"); exit(1) }
}
dispatchMain()
