// Copyright 2026 DUO你电脑 contributors. SPDX-License-Identifier: Apache-2.0
// One synthetic buffer through the production hardware encoder and decoder on this Mac. It does
// not capture a desktop, measure frame rate, or prove decoding on the Duo.
import Foundation
import CoreMedia
import CoreVideo
import StreamProtocol

let wanted = DuoDesktopResolution(width: 2007, height: 2853)
let canvas = DuoDesktopCanvas(width: wanted.encodedWidth, height: wanted.encodedHeight)
let done = DispatchSemaphore(value: 0)
let lock = NSLock()
var decoded = false
var failure: String?
let decoder = HardwareHEVCDecoder(onFormat: { _, _ in }, onSample: { sample, _, _ in
    let image = CMSampleBufferGetImageBuffer(sample)
    lock.lock()
    decoded = image.map { CVPixelBufferGetWidth($0) == canvas.encodedWidth && CVPixelBufferGetHeight($0) == canvas.encodedHeight } ?? false
    lock.unlock()
    done.signal()
}, onFailure: { message, _ in
    lock.lock(); failure = message; lock.unlock()
    done.signal()
})
decoder.require(wanted)
let encoder = try HEVCEncoder(width: canvas.encodedWidth, height: canvas.encodedHeight, fps: 120,
                              bitrate: 30_000_000, prioritizeSpeed: true, quiet: true)
encoder.onEncoded = { data, key, parameters in
    if var parameters {
        parameters.nativeDesktopCanvas = canvas
        decoder.apply(parameters)
    }
    decoder.enqueue(data, isKeyframe: key)
}
var pixel: CVPixelBuffer?
let attrs = [kCVPixelBufferIOSurfacePropertiesKey: [:]] as CFDictionary
guard CVPixelBufferCreate(nil, canvas.encodedWidth, canvas.encodedHeight,
                          kCVPixelFormatType_420YpCbCr8BiPlanarFullRange, attrs, &pixel) == kCVReturnSuccess,
      let pixel else { fatalError("Could not allocate the synthetic buffer") }
CVPixelBufferLockBaseAddress(pixel, [])
for plane in 0..<CVPixelBufferGetPlaneCount(pixel) {
    guard let base = CVPixelBufferGetBaseAddressOfPlane(pixel, plane) else { fatalError("Missing pixel plane") }
    memset(base, plane == 0 ? 96 : 128,
           CVPixelBufferGetBytesPerRowOfPlane(pixel, plane) * CVPixelBufferGetHeightOfPlane(pixel, plane))
}
CVPixelBufferUnlockBaseAddress(pixel, [])
encoder.encode(pixel, pts: CMTime(value: 0, timescale: 120))
let result = done.wait(timeout: .now() + 10)
lock.lock(); let ok = decoded; let error = failure; lock.unlock()
guard result == .success, ok, error == nil else {
    print("EXTENDED CODEC FAIL: decoded=\(ok), error=\(error ?? "timeout or wrong dimensions")")
    exit(1)
}
print("EXTENDED CODEC PASS: one synthetic 2008×2854 frame encoded and decoded in hardware on Air; no FPS or Duo claim")
