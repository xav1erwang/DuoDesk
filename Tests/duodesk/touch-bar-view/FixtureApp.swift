// Copyright 2026 DUO你电脑 contributors. SPDX-License-Identifier: Apache-2.0
import SwiftUI
import UIKit
import Foundation

final class FixtureModel: ObservableObject {
    let first = UUID(uuidString: "00000000-0000-0000-0000-000000000001")!
    let second = UUID(uuidString: "00000000-0000-0000-0000-000000000002")!
    @Published var source = UUID(uuidString: "00000000-0000-0000-0000-000000000001")!
    @Published var events: [TouchBarTouch] = []
    var replaceOnBegin = false
    var replaceViewOnBegin = false
    var readOnlyOnBegin = false
    @Published var alternate = false
    @Published var acceptsInput = true
    @Published var chromeAudit = "Checking"
    let primaryVideo = HEVCDisplayView(frame: .zero)
    let alternateVideo: HEVCDisplayView = {
        let view = HEVCDisplayView(frame: .zero)
        view.backgroundColor = .systemGreen
        return view
    }()
    var video: HEVCDisplayView { alternate ? alternateVideo : primaryVideo }
    var surface: TouchBarSurface { TouchBarSurface(id: source, pixelWidth: 2008, pixelHeight: 60,
                                                    encodedWidth: 2008, encodedHeight: 60, acceptsInput: acceptsInput) }
    var description: String { events.isEmpty ? "none" : events.map {
        "\($0.phase.rawValue):\(Int(($0.x * 100).rounded())):\($0.surfaceID == first ? 1 : 2)"
    }.joined(separator: ",") }
    func receive(_ value: TouchBarTouch) {
        // Cancellation can be emitted while SwiftUI reconfigures the representable. The product
        // sends it to the connection; this fixture must defer its published test log update.
        if value.phase == .cancelled {
            DispatchQueue.main.async { self.events.append(value) }
            return
        }
        events.append(value)
        if replaceOnBegin && value.phase == .began { replaceOnBegin = false; source = second }
        if replaceViewOnBegin && value.phase == .began { replaceViewOnBegin = false; alternate = true }
        if readOnlyOnBegin && value.phase == .began { readOnlyOnBegin = false; acceptsInput = false }
    }

    /// Render only a synthetic picture, not a decoded or captured Touch Bar.
    @MainActor func auditChrome() {
        let picture = VStack(spacing: 0) {
            HStack(spacing: 0) { Color.red; Color.blue }
            HStack(spacing: 0) { Color.green; Color.yellow }
        }.frame(width: 360, height: 30)
        func render<V: View>(_ view: V) -> [UInt8]? {
            let renderer = ImageRenderer(content: view.background(Color.black))
            renderer.scale = 3
            guard let image = renderer.uiImage?.cgImage, image.width == 1080, image.height == 90 else { return nil }
            var bytes = [UInt8](repeating: 0, count: image.width * image.height * 4)
            let success = bytes.withUnsafeMutableBytes { buffer -> Bool in
                guard let context = CGContext(data: buffer.baseAddress, width: image.width, height: image.height,
                    bitsPerComponent: 8, bytesPerRow: image.width * 4, space: CGColorSpaceCreateDeviceRGB(),
                    bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue | CGBitmapInfo.byteOrder32Big.rawValue)
                else { return false }
                context.draw(image, in: CGRect(x: 0, y: 0, width: image.width, height: image.height))
                return true
            }
            return success ? bytes : nil
        }
        let legacy = picture.clipShape(RoundedRectangle(cornerRadius: 9))
            .overlay(RoundedRectangle(cornerRadius: 9).strokeBorder(.white.opacity(0.2), lineWidth: 0.5))
        guard let baseline = render(picture),
              let live = render(picture.modifier(TouchBarPictureChrome(showingPicture: true))),
              let placeholder = render(picture.modifier(TouchBarPictureChrome(showingPicture: false))),
              let previous = render(legacy) else { chromeAudit = "FAIL render"; return }
        func changes(_ a: [UInt8], _ b: [UInt8]) -> Int {
            stride(from: 0, to: a.count, by: 4).reduce(0) { count, i in
                count + (a[i..<(i + 4)].elementsEqual(b[i..<(i + 4)]) ? 0 : 1)
            }
        }
        let liveChanges = changes(baseline, live), legacyChanges = changes(baseline, previous)
        let placeholderChanges = changes(placeholder, previous)
        chromeAudit = "\(liveChanges == 0 && legacyChanges > 0 && placeholderChanges == 0 ? "PASS" : "FAIL") live=\(liveChanges) legacy=\(legacyChanges) placeholder=\(placeholderChanges)"
    }
}
@main struct FixtureApp: App {
    @StateObject private var model = FixtureModel()
    var body: some Scene { WindowGroup {
        VStack(spacing: 24) {
            Text("模拟触摸夹具：未连接 Mac")
            DuoTouchBarRemoteView(video: model.video, surface: model.surface, canBegin: { true }, send: model.receive)
                .frame(width: 360, height: 60)
                .background(Color(white: 0.12))
                .modifier(TouchBarPictureChrome(showingPicture: true))
            Text(model.description).accessibilityIdentifier("fixture.events")
            Text(model.chromeAudit).accessibilityIdentifier("fixture.chromeAudit")
            Button("替换来源") { model.events = []; model.source = model.first; model.replaceOnBegin = true }
            Button("替换画面容器") { model.events = []; model.source = model.first; model.alternate = false; model.replaceViewOnBegin = true }
            Button("设为只读") { model.events = []; model.acceptsInput = false }
            Button("恢复触摸") { model.events = []; model.acceptsInput = true }
            Button("触摸时设为只读") { model.events = []; model.acceptsInput = true; model.readOnlyOnBegin = true }
        }.padding().task { model.auditChrome() }
    }}
}
