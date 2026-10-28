// Copyright 2026 DUO你电脑 contributors. SPDX-License-Identifier: Apache-2.0
// Production session with an injected synthetic source and ephemeral paired loopback QUIC.
import Foundation
import CoreMedia
import CoreVideo
import Network
import StreamProtocol

extension HardwareDecoderRouter: LoopbackVideoDecoder { }

final class TouchBarObserver: @unchecked Sendable {
    static let shared = TouchBarObserver()
    private let lock = NSLock()
    private var frameHandler: ((Data) -> Void)?
    private var statusHandler: ((Data) -> Void)?
    func set(frame: ((Data) -> Void)?, status: ((Data) -> Void)?) {
        lock.withLock { frameHandler = frame; statusHandler = status }
    }
    func frame(_ data: Data) { let f = lock.withLock { frameHandler }; f?(data) }
    func status(_ data: Data) { let f = lock.withLock { statusHandler }; f?(data) }
}
final class Results: @unchecked Sendable {
    private let lock = NSLock()
    private var statuses: [TouchBarStatus] = [], luma: [Int] = [], failures: [String] = []
    func status(_ value: TouchBarStatus) { lock.withLock { statuses.append(value) } }
    func failure(_ value: String) { lock.withLock { failures.append(value) } }
    func sample(_ sample: CMSampleBuffer, _ permit: VideoOutputPermit) {
        guard permit.isValid, let pixel = CMSampleBufferGetImageBuffer(sample), CVPixelBufferGetPlaneCount(pixel) > 0,
              CVPixelBufferLockBaseAddress(pixel, .readOnly) == kCVReturnSuccess else { failure("sample"); return }
        defer { CVPixelBufferUnlockBaseAddress(pixel, .readOnly) }
        guard let p = CVPixelBufferGetBaseAddressOfPlane(pixel, 0)?.assumingMemoryBound(to: UInt8.self) else {
            failure("luma"); return
        }
        let value = Int(p[30 * CVPixelBufferGetBytesPerRowOfPlane(pixel, 0) + 1004])
        lock.withLock { luma.append(value) }
    }
    var state: ([TouchBarStatus], [Int], [String]) { lock.withLock { (statuses, luma, failures) } }
}
@MainActor final class PermissionFixture {
    var recording = false
    var input = true
}
@MainActor final class SyntheticTouchBarSource: TouchBarCaptureSource {
    var starts = 0, stops = 0
    var posted: [TouchBarTouch] = []
    private var frameHandler: (@Sendable (TouchBarCapturedFrame) -> Void)?
    private var oldFrameHandler: (@Sendable (TouchBarCapturedFrame) -> Void)?
    private var stoppedHandler: (@Sendable () -> Void)?
    func start(onFrame: @escaping @Sendable (TouchBarCapturedFrame) -> Void,
               onStopped: @escaping @Sendable () -> Void) throws {
        starts += 1; frameHandler = onFrame; stoppedHandler = onStopped
    }
    func post(_ touch: TouchBarTouch) -> Bool { posted.append(touch); return true }
    func stop() { stops += 1; oldFrameHandler = frameHandler; frameHandler = nil; stoppedHandler?(); stoppedHandler = nil }
    func emit(_ frame: TouchBarCapturedFrame) { frameHandler?(frame) }
    func emitAfterStop(_ frame: TouchBarCapturedFrame) { oldFrameHandler?(frame) }
}
enum Failure: Error { case timeout(String), invalid(String) }
@MainActor func waitFor(_ name: String, _ condition: () -> Bool) async throws {
    let deadline = ContinuousClock.now + .seconds(6)
    while !condition() {
        guard ContinuousClock.now < deadline else { throw Failure.timeout(name) }
        try await Task.sleep(for: .milliseconds(10))
    }
}
func frame(_ luma: Int) throws -> TouchBarCapturedFrame {
    var pixel: CVPixelBuffer?
    guard CVPixelBufferCreate(nil, 2008, 60, kCVPixelFormatType_420YpCbCr8BiPlanarFullRange,
        [kCVPixelBufferIOSurfacePropertiesKey: [:]] as CFDictionary, &pixel) == kCVReturnSuccess,
        let pixel, CVPixelBufferLockBaseAddress(pixel, []) == kCVReturnSuccess else { throw Failure.invalid("input") }
    defer { CVPixelBufferUnlockBaseAddress(pixel, []) }
    for plane in 0..<2 {
        guard let base = CVPixelBufferGetBaseAddressOfPlane(pixel, plane) else { throw Failure.invalid("plane") }
        memset(base, plane == 0 ? Int32(luma) : 128,
               CVPixelBufferGetBytesPerRowOfPlane(pixel, plane) * CVPixelBufferGetHeightOfPlane(pixel, plane))
    }
    return TouchBarCapturedFrame(pixels: pixel, contentWidth: 2008, contentHeight: 60,
                                 pts: CMClockGetTime(CMClockGetHostTimeClock()))
}

@main struct Check {
    @MainActor static func run() async throws {
        let results = Results(), permission = PermissionFixture(), fake = SyntheticTouchBarSource()
        let encoder = try HEVCEncoder(width: 2008, height: 60, fps: 30, bitrate: 3_000_000,
                                      prioritizeSpeed: true, software: false, quiet: true, independentFrames: true)
        let decoder = HardwareDecoderRouter(onFormat: { _, _ in }, onSample: { sample, _, permit in results.sample(sample, permit) },
                                             onFailure: { message, _ in results.failure(message) })
        let loop = try await LoopbackVideo.connect(decoder: decoder, encoder: encoder)
        let session = TouchBarHostSession(server: loop.server, makeSource: { fake },
                                          recordingAllowed: { permission.recording }, inputAllowed: { permission.input })
        defer { session.stop(); TouchBarObserver.shared.set(frame: nil, status: nil); loop.close(); _ = decoder.clear(); _ = encoder.abandon() }
        try await waitFor("initial desktop reset") { loop.counters.resets > 0 }
        TouchBarObserver.shared.set(frame: { data in
            guard let packet = TouchBarKeyframe(encoded: data) else { results.failure("frame parse"); return }
            decoder.apply(packet.parameters); decoder.enqueue(packet.accessUnit, isKeyframe: true)
        }, status: { data in
            guard let status = Wire.decode(TouchBarStatus.self, from: data), status.isValid else { results.failure("status parse"); return }
            results.status(status)
            if let surface = status.surface {
                _ = decoder.requireVideo(.touchBar(id: surface.id, width: surface.encodedWidth, height: surface.encodedHeight))
            } else { _ = decoder.requireVideo(nil) }
        })
        guard let client = loop.server.queue.sync(execute: { loop.server.clients.values.first }) else { throw Failure.invalid("client") }
        let route = loop.server.queue.sync { client.route }, connection = client.connection
        guard route.encrypted, route.pairedName != nil else { throw Failure.invalid("paired route") }
        session.subscribe(TouchBarSubscription(watching: true), from: connection, route: route)
        try await waitFor("recording preflight") { results.state.0.contains { $0.availability == .unavailable } }
        guard fake.starts == 0 else { throw Failure.invalid("started without recording permission") }
        permission.recording = true
        session.subscribe(TouchBarSubscription(watching: true), from: connection, route: .home(.loopback, peer: nil))
        guard fake.starts == 0 else { throw Failure.invalid("unpaired start") }
        session.subscribe(TouchBarSubscription(watching: true), from: connection, route: route)
        fake.emit(try frame(96))
        try await waitFor("live synthetic frame") {
            results.state.0.contains { $0.availability == .live } && !results.state.1.isEmpty || !results.state.2.isEmpty
        }
        guard results.state.2.isEmpty, let surface = results.state.0.last(where: { $0.availability == .live })?.surface,
              surface.acceptsInput, results.state.1.last.map({ abs($0 - 96) <= 20 }) == true else { throw Failure.invalid("live output") }
        let begin = TouchBarTouch(surfaceID: surface.id, phase: .began, x: 0.2, y: 0.5)
        session.receive(begin, from: connection, route: .home(.loopback, peer: nil))
        session.receive(TouchBarTouch(surfaceID: UUID(), phase: .began, x: 0.2, y: 0.5), from: connection, route: route)
        guard fake.posted.isEmpty else { throw Failure.invalid("unpaired or stale input") }
        session.receive(begin, from: connection, route: route)
        session.clientLeft(connection)
        guard fake.posted.map(\.phase) == [.began, .cancelled], fake.stops == 1, session.token == nil else {
            throw Failure.invalid("disconnect release")
        }
        let observed = results.state.1.count
        fake.emitAfterStop(try frame(192))
        try await Task.sleep(for: .milliseconds(150))
        guard results.state.1.count == observed else { throw Failure.invalid("late frame after stop") }

        permission.input = false
        session.subscribe(TouchBarSubscription(watching: true), from: connection, route: route)
        fake.emit(try frame(144))
        try await waitFor("read-only surface") {
            results.state.0.last(where: { $0.availability == .live })?.surface?.id != surface.id
        }
        guard let readOnly = results.state.0.last(where: { $0.availability == .live })?.surface, !readOnly.acceptsInput else {
            throw Failure.invalid("input preflight")
        }
        let before = fake.posted.count
        session.receive(TouchBarTouch(surfaceID: readOnly.id, phase: .began, x: 0.5, y: 0.5), from: connection, route: route)
        guard fake.posted.count == before else { throw Failure.invalid("posted without input permission") }
        permission.input = true
        session.receive(TouchBarTouch(surfaceID: readOnly.id, phase: .began, x: 0.5, y: 0.5), from: connection, route: route)
        try await waitFor("updated input capability") {
            results.state.0.last(where: { $0.availability == .live })?.surface?.acceptsInput == true
        }
        session.receive(TouchBarTouch(surfaceID: readOnly.id, phase: .began, x: 0.5, y: 0.5), from: connection, route: route)
        guard fake.posted.count == before + 1 else { throw Failure.invalid("input after capability update") }
        permission.input = false
        session.receive(TouchBarTouch(surfaceID: readOnly.id, phase: .moved, x: 0.6, y: 0.5), from: connection, route: route)
        guard fake.stops == 2, fake.posted.count == before + 1, session.token == nil else {
            throw Failure.invalid("input revocation did not stop source")
        }
        // Stand in for a VideoToolbox creation call that never returned. A new source may not
        // allocate a second worker or leave its capture alive behind that blocked preparation.
        permission.input = true
        guard session.encoderCreation.acquire() else { throw Failure.invalid("preparation gate setup") }
        session.subscribe(TouchBarSubscription(watching: true), from: connection, route: route)
        fake.emit(try frame(96))
        try await waitFor("busy preparation stops source") { fake.stops == 3 }
        guard session.token == nil, !session.preparingEncoder else { throw Failure.invalid("unbounded preparation") }
        session.encoderCreation.release()

        // Recording access can disappear while a touch is held. The source stops and the held
        // contact is released only through the still-trusted input side.
        session.subscribe(TouchBarSubscription(watching: true), from: connection, route: route)
        fake.emit(try frame(192))
        try await waitFor("capture revocation setup") { session.surface != nil }
        guard let finalSurface = session.surface else { throw Failure.invalid("missing final source") }
        let beforeRevocation = fake.posted.count
        session.receive(TouchBarTouch(surfaceID: finalSurface.id, phase: .began, x: 0.4, y: 0.5), from: connection, route: route)
        permission.recording = false
        session.receive(TouchBarTouch(surfaceID: finalSurface.id, phase: .moved, x: 0.5, y: 0.5), from: connection, route: route)
        guard fake.stops == 4, session.token == nil,
              fake.posted.count == beforeRevocation + 2, fake.posted.last?.phase == .cancelled else {
            throw Failure.invalid("recording revocation did not stop and release")
        }
        try loop.check()
        print("TOUCH BAR SESSION PASS: synthetic source, paired mTLS/QUIC, hardware frame, permission gates, disconnect/revocation release, late-frame fence and bounded preparation")
        print("SCOPE: injected fake permissions and source; no actual capture or system input, no physical Touch Bar, Duo, WAN or FPS acceptance")
    }
    static func main() async {
        do { try await run() }
        catch { print("TOUCH BAR SESSION FAIL: \(error)"); exit(1) }
    }
}
