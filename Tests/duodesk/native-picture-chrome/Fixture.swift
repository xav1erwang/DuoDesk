// Copyright 2026 DUO你电脑 contributors. SPDX-License-Identifier: Apache-2.0
// A synthetic SwiftUI picture only: no host, network, screen capture, decoder or input injection.
import SwiftUI
import UIKit

private struct Pattern: View {
    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 0) { Color.red; Color.blue }
            HStack(spacing: 0) { Color.green; Color.yellow }
        }
        .frame(width: 200, height: 150)
    }
}

@main struct NativePictureChromeFixture: App {
    @State private var result = "Checking…"

    var body: some Scene {
        WindowGroup {
            VStack(spacing: 20) {
                Text("Synthetic picture frame").font(.headline)
                Text(result).font(.subheadline.monospaced())
                Text("Native").font(.caption)
                Pattern().modifier(DesktopPictureChrome(native: true))
                Text("Legacy").font(.caption)
                Pattern().modifier(DesktopPictureChrome(native: false))
            }
            .padding()
            .background(Color.black)
            .foregroundStyle(.white)
            .task { result = runChecks() }
        }
    }

    @MainActor private func runChecks() -> String {
        func render<V: View>(_ view: V) -> UIImage? {
            let renderer = ImageRenderer(content: view.background(Color.black))
            renderer.scale = 3
            return renderer.uiImage
        }
        func rgba(_ image: UIImage) -> [UInt8]? {
            guard let cg = image.cgImage else { return nil }
            var bytes = [UInt8](repeating: 0, count: cg.width * cg.height * 4)
            let made = bytes.withUnsafeMutableBytes { buffer -> Bool in
                guard let context = CGContext(data: buffer.baseAddress, width: cg.width, height: cg.height,
                    bitsPerComponent: 8, bytesPerRow: cg.width * 4, space: CGColorSpaceCreateDeviceRGB(),
                    bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue | CGBitmapInfo.byteOrder32Big.rawValue)
                else { return false }
                context.draw(cg, in: CGRect(x: 0, y: 0, width: cg.width, height: cg.height))
                return true
            }
            return made ? bytes : nil
        }
        guard let baseline = render(Pattern()), let native = render(Pattern().modifier(DesktopPictureChrome(native: true))),
              let legacy = render(Pattern().modifier(DesktopPictureChrome(native: false))),
              let reference = rgba(baseline), let actual = rgba(native), let old = rgba(legacy),
              reference.count == actual.count, reference.count == old.count,
              let cg = baseline.cgImage, cg.width == 600, cg.height == 450 else { return "RENDER FAILED" }

        func changedPixels(_ lhs: [UInt8], _ rhs: [UInt8]) -> Int {
            stride(from: 0, to: lhs.count, by: 4).reduce(0) { total, i in
                total + (lhs[i..<(i + 4)].elementsEqual(rhs[i..<(i + 4)]) ? 0 : 1)
            }
        }
        let nativeChanged = changedPixels(reference, actual)
        let legacyChanged = changedPixels(reference, old)
        let cornerOffsets = [0, (cg.width - 1) * 4, (cg.height - 1) * cg.width * 4,
                             ((cg.height - 1) * cg.width + cg.width - 1) * 4]
        let nativeCorners = cornerOffsets.map { reference[$0..<($0 + 4)].elementsEqual(actual[$0..<($0 + 4)]) }
        let legacyCorners = cornerOffsets.map { !reference[$0..<($0 + 4)].elementsEqual(old[$0..<($0 + 4)]) }
        let passed = nativeChanged == 0 && nativeCorners.allSatisfy { $0 } && legacyChanged > 0 && legacyCorners.allSatisfy { $0 }
        let report: [String: Any] = ["passed": passed, "nativeChangedPixels": nativeChanged,
            "legacyChangedPixels": legacyChanged, "nativeCornersMatch": nativeCorners,
            "legacyCornersDiffer": legacyCorners, "width": cg.width, "height": cg.height,
            "syntheticPicture": true, "realDuoVerified": false, "networkUsed": false,
            "runID": ProcessInfo.processInfo.environment["NATIVE_FRAME_RUN_ID"] ?? "missing"]
        do {
            let directory = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
            for (name, image) in [("reference.png", baseline), ("native.png", native), ("legacy.png", legacy)] {
                try image.pngData()?.write(to: directory.appendingPathComponent(name), options: .atomic)
            }
            let data = try JSONSerialization.data(withJSONObject: report, options: [.prettyPrinted, .sortedKeys])
            try data.write(to: directory.appendingPathComponent("result.json"), options: .atomic)
        } catch { return "SAVE FAILED: \(error)" }
        return passed ? "PASS" : "FAIL — native changed \(nativeChanged) pixels"
    }
}
