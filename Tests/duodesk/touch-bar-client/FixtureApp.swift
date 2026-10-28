// Copyright 2026 DUO你电脑 contributors. SPDX-License-Identifier: Apache-2.0
import SwiftUI
import Network
import StreamProtocol

@MainActor final class Fixture: ObservableObject {
    @Published var result = "RUNNING"
    var sent: [(StreamMessageKind, Data)] = []

    func run() async {
        do {
            let inbox = DuoTouchBarInbox()
            let client = DuoTouchBarClient(inbox: inbox) { [weak self] kind, data in self?.sent.append((kind, data)) }
            let old = NWConnection(host: "127.0.0.1", port: 1, using: .tcp)
            let new = NWConnection(host: "127.0.0.1", port: 2, using: .tcp)
            let a = UUID(), b = UUID()
            func surface(_ id: UUID) -> TouchBarSurface {
                TouchBarSurface(id: id, pixelWidth: 2008, pixelHeight: 60, encodedWidth: 2008, encodedHeight: 60, acceptsInput: true)
            }
            let ps = ParameterSets(nalUnitHeaderLength: 4, sets: [Data([1]), Data([2]), Data([3])])
            func frame(_ id: UUID, _ byte: UInt8) -> Data {
                TouchBarKeyframe(surfaceID: id, parameters: ps, accessUnit: Data([byte]))!.encoded
            }
            func expect(_ value: Bool, _ name: String) throws {
                if !value { throw Failure.failed(name) }
            }
            client.setConnection(old); client.setVisible(true)
            try expect(sent.first?.0 == .touchBarSubscription &&
                       Wire.decode(TouchBarSubscription.self, from: sent.first!.1)?.watching == true, "subscribe")
            inbox.receiveStatus(Wire.encode(TouchBarStatus(availability: .live, surface: surface(a))), from: old)
            inbox.receiveFrame(frame(a, 10), keyframe: true, from: old)
            try await Task.sleep(for: .milliseconds(100))
            try expect(client.status.surface?.id == a && client.video.frames == [Data([10])], "first source")
            client.send(TouchBarTouch(surfaceID: a, phase: .began, x: 0.1, y: 0.5))
            client.send(TouchBarTouch(surfaceID: a, phase: .moved, x: 0.3, y: 0.5))
            client.send(TouchBarTouch(surfaceID: a, phase: .moved, x: 0.8, y: 0.5))
            client.send(TouchBarTouch(surfaceID: a, phase: .ended, x: 0.8, y: 0.5))
            let touches = sent.filter { $0.0 == .touchBarTouch }.compactMap { Wire.decode(TouchBarTouch.self, from: $0.1) }
            try expect(touches.map(\.phase) == [.began, .moved, .ended] && touches[1].x == 0.8, "coalesced ordered touches")
            client.setConnection(new)
            inbox.receiveStatus(Wire.encode(TouchBarStatus(availability: .live, surface: surface(a))), from: old)
            inbox.receiveFrame(frame(a, 20), keyframe: true, from: old)
            try await Task.sleep(for: .milliseconds(100))
            try expect(client.status.surface == nil && client.video.frames == [Data([10])], "old connection fenced")
            inbox.receiveStatus(Wire.encode(TouchBarStatus(availability: .live, surface: surface(b))), from: new)
            inbox.receiveFrame(frame(b, 30), keyframe: true, from: new)
            try await Task.sleep(for: .milliseconds(100))
            try expect(client.status.surface?.id == b && client.video.frames.last == Data([30]), "new connection")
            try expect(client.video.requirements == [a, nil, b], "decoder generations")
            client.setVisible(false)
            let last = sent.last
            try expect(last?.0 == .touchBarSubscription && Wire.decode(TouchBarSubscription.self, from: last!.1)?.watching == false,
                       "unsubscribe while hidden")
            let count = sent.count
            client.send(TouchBarTouch(surfaceID: b, phase: .began, x: 0.5, y: 0.5))
            try expect(sent.count == count && client.status.surface == nil, "hidden input rejected")
            result = "PASS"
        } catch { result = "FAIL: \(error)" }
    }
    enum Failure: Error { case failed(String) }
}

@main struct FixtureApp: App {
    @StateObject private var fixture = Fixture()
    var body: some Scene { WindowGroup {
        VStack {
            Text("合成 Touch Bar 客户端夹具：未连接 Mac")
            Text(fixture.result).accessibilityIdentifier("fixture.result")
        }.task { await fixture.run() }
    }}
}
