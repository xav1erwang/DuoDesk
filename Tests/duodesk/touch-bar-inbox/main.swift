// Copyright 2026 DUO你电脑 contributors. SPDX-License-Identifier: Apache-2.0
// Queue ordering and bounded admission only; no capture, UI, system input or network connection.
import Foundation
import Network
import StreamProtocol

enum CheckError: Error { case failed(String) }
@MainActor final class Audit {
    var events: [String] = []
}

@main struct Check {
    @MainActor static func run() async throws {
        let audit = Audit(), inbox = DuoTouchBarInbox()
        let old = NWConnection(host: "127.0.0.1", port: 1, using: .tcp)
        let current = NWConnection(host: "127.0.0.1", port: 2, using: .tcp)
        let a = UUID(), b = UUID()
        let surfaceA = TouchBarSurface(id: a, pixelWidth: 2008, pixelHeight: 60, encodedWidth: 2008, encodedHeight: 60, acceptsInput: true)
        let surfaceB = TouchBarSurface(id: b, pixelWidth: 2008, pixelHeight: 60, encodedWidth: 2008, encodedHeight: 60, acceptsInput: true)
        let ps = ParameterSets(nalUnitHeaderLength: 4, sets: [Data([1]), Data([2]), Data([3])])
        func packet(_ surface: UUID, _ marker: UInt8) -> Data {
            TouchBarKeyframe(surfaceID: surface, parameters: ps, accessUnit: Data([marker]))!.encoded
        }
        inbox.attach(status: { status, source in
            audit.events.append("status:\(status.surface?.id == b ? "b" : "other"):\(source === current)")
        }, frame: { frame, source in
            audit.events.append("frame:\(frame.surfaceID == b ? "b" : "other"):\(frame.accessUnit[0]):\(source === current)")
        })
        // The main queue is deliberately held by this synchronous sequence. New status B must
        // invalidate A's already-scheduled status and drain, then retain only B's latest frame.
        inbox.receiveStatus(Wire.encode(TouchBarStatus(availability: .live, surface: surfaceA)), from: old)
        inbox.receiveFrame(packet(a, 1), keyframe: true, from: old)
        inbox.receiveStatus(Wire.encode(TouchBarStatus(availability: .live, surface: surfaceB)), from: current)
        inbox.receiveFrame(packet(b, 2), keyframe: true, from: current)
        inbox.receiveFrame(packet(b, 3), keyframe: true, from: current)
        inbox.receiveFrame(packet(b, 4), keyframe: false, from: current)
        inbox.receiveFrame(Data([1, 2, 3]), keyframe: true, from: current)
        try await Task.sleep(for: .milliseconds(60))
        guard audit.events == ["status:b:true", "frame:b:3:true"] else { throw CheckError.failed("latest frame/status order: \(audit.events)") }

        audit.events.removeAll()
        inbox.receiveStatus(Wire.encode(TouchBarStatus(availability: .live, surface: surfaceB)), from: current)
        inbox.receiveFrame(packet(b, 5), keyframe: true, from: current)
        inbox.invalidate()
        try await Task.sleep(for: .milliseconds(60))
        guard audit.events.isEmpty else { throw CheckError.failed("invalidated queue delivered: \(audit.events)") }

        inbox.receiveStatus(Data([0xff]), from: current)
        try await Task.sleep(for: .milliseconds(60))
        guard audit.events == ["status:other:true"] else { throw CheckError.failed("malformed status did not clear") }
        print("TOUCH BAR INBOX PASS: latest frame, ordered status replacement, malformed status and invalidation; no capture, input or connected network")
    }
    static func main() async {
        do { try await run() }
        catch { print("TOUCH BAR INBOX FAIL: \(error)"); exit(1) }
    }
}
