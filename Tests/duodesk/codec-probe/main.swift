// Production encoder + production decoder, native canvas, actual hardware flags and measured time.
import Foundation
import CoreVideo
import CoreMedia
import StreamProtocol

final class Results: @unchecked Sendable {
    let lock = NSLock()
    var decoded = 0
    var encodeTimes: [Double] = []
    var failures: [String] = []
    var first = Double.infinity
    var last = 0.0
    var start = 0.0
    let duration: Double
    init(duration: Double) { self.duration = duration }
}
let arguments = CommandLine.arguments
func integerOption(_ flag: String, default fallback: Int, allowed: ClosedRange<Int>) -> Int {
    guard let index = arguments.firstIndex(of: flag) else { return fallback }
    guard index + 1 < arguments.count, let value = Int(arguments[index + 1]), allowed.contains(value) else {
        fputs("Invalid \(flag)\n", stderr)
        exit(2)
    }
    return value
}
let targetFPS = integerOption("--fps", default: 120, allowed: 1...240)
let seconds = integerOption("--seconds", default: 30, allowed: 1...120)
let results = Results(duration: Double(seconds))
let native = DuoDesktopResolution(width: 2007, height: 1427)
let decoder = HardwareHEVCDecoder(onFormat: { size, _ in
    print("Codec canvas verified: \(size)")
}, onSample: { sample, _, _ in
    let now = ProcessInfo.processInfo.systemUptime
    results.lock.lock(); defer { results.lock.unlock() }
    guard let image = CMSampleBufferGetImageBuffer(sample),
          native.accepts(width: CVPixelBufferGetWidth(image), height: CVPixelBufferGetHeight(image)) else {
        results.failures.append("decoded canvas mismatch"); return
    }
    if now >= results.start + 2, now < results.start + 2 + results.duration {
        results.decoded += 1; results.first = min(results.first, now); results.last = now
    }
}, onFailure: { message, _ in
    results.lock.lock(); results.failures.append(message); results.lock.unlock()
})
decoder.require(native)
let encoder = try HEVCEncoder(width: native.encodedWidth, height: native.encodedHeight, fps: targetFPS,
                              bitrate: 20_000_000, prioritizeSpeed: true, quiet: true)
encoder.onEncoded = { data, key, ps in
    if let ps { decoder.apply(ps) }
    decoder.enqueue(data, isKeyframe: key)
}
encoder.onEncodeLatency = { ms in
    let now = ProcessInfo.processInfo.systemUptime
    results.lock.lock(); defer { results.lock.unlock() }
    if now >= results.start + 2 { results.encodeTimes.append(ms) }
}
let images: [CVPixelBuffer] = try (0..<3).map { index in
    var buffer: CVPixelBuffer?
    let attrs = [kCVPixelBufferIOSurfacePropertiesKey: [:]] as CFDictionary
    guard CVPixelBufferCreate(nil, native.encodedWidth, native.encodedHeight,
        kCVPixelFormatType_420YpCbCr8BiPlanarFullRange, attrs, &buffer) == kCVReturnSuccess,
        let buffer else { throw NSError(domain: "PixelBuffer", code: -1) }
    CVPixelBufferLockBaseAddress(buffer, [])
    for plane in 0..<2 {
        let height = CVPixelBufferGetHeightOfPlane(buffer, plane), stride = CVPixelBufferGetBytesPerRowOfPlane(buffer, plane)
        if let p = CVPixelBufferGetBaseAddressOfPlane(buffer, plane) {
            for y in 0..<height { memset(p.advanced(by: y * stride), plane == 1 ? 128 : Int32((y / 24 + index * 63) % 220 + 16), stride) }
        }
    }
    CVPixelBufferUnlockBaseAddress(buffer, [])
    return buffer
}
results.start = ProcessInfo.processInfo.systemUptime
let timer = DispatchSource.makeTimerSource(queue: DispatchQueue(label: "duodesk.codec-feed", qos: .userInteractive))
var sent: Int64 = 0
timer.schedule(deadline: .now(), repeating: .nanoseconds(1_000_000_000 / targetFPS), leeway: .microseconds(100))
timer.setEventHandler {
    if ProcessInfo.processInfo.systemUptime - results.start >= results.duration + 2 {
        timer.cancel()
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) {
            results.lock.lock()
            let sorted = results.encodeTimes.sorted(), fps = Double(results.decoded) / results.duration
            let mean = sorted.isEmpty ? -1 : sorted.reduce(0, +) / Double(sorted.count)
            let report: [String: Any] = ["width": native.encodedWidth, "height": native.encodedHeight,
                "durationSeconds": results.duration, "decodedFrames": results.decoded, "decodedFPS": fps,
                "targetFPS": targetFPS,
                "encodeMeanMs": mean, "encodeP95Ms": sorted.isEmpty ? -1 : sorted[Int(Double(sorted.count - 1) * 0.95)],
                "failures": results.failures, "hardwareRequired": true]
            let passed = results.failures.isEmpty && fps >= Double(targetFPS) - 0.5 && mean >= 0 && mean < 1000.0 / Double(targetFPS)
            results.lock.unlock()
            print(String(data: try! JSONSerialization.data(withJSONObject: report, options: [.sortedKeys]), encoding: .utf8)!)
            decoder.clear()
            print("Codec probe \(passed ? "PASS" : "FAIL")")
            exit(passed ? 0 : 1)
        }
        return
    }
    encoder.encode(images[Int(sent % 3)], pts: CMTime(value: sent, timescale: CMTimeScale(targetFPS)))
    sent += 1
}
timer.resume()
dispatchMain()
