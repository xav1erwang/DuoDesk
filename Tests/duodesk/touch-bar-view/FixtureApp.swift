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
}
@main struct FixtureApp: App {
    @StateObject private var model = FixtureModel()
    var body: some Scene { WindowGroup {
        VStack(spacing: 24) {
            Text("模拟触摸夹具：未连接 Mac")
            DuoTouchBarRemoteView(video: model.video, surface: model.surface, canBegin: { true }, send: model.receive)
                .frame(width: 360, height: 60)
                .background(Color(white: 0.12))
            Text(model.description).accessibilityIdentifier("fixture.events")
            Button("替换来源") { model.events = []; model.source = model.first; model.replaceOnBegin = true }
            Button("替换画面容器") { model.events = []; model.source = model.first; model.alternate = false; model.replaceViewOnBegin = true }
            Button("设为只读") { model.events = []; model.acceptsInput = false }
            Button("恢复触摸") { model.events = []; model.acceptsInput = true }
            Button("触摸时设为只读") { model.events = []; model.acceptsInput = true; model.readOnlyOnBegin = true }
        }.padding()
    }}
}
