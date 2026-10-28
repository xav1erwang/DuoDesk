// Copyright 2026 DUO你电脑 contributors. SPDX-License-Identifier: Apache-2.0
// Injected virtual runtime -> read-only source -> coordinator -> paired local QUIC -> hardware decoder.
import CoreMedia
import CoreVideo
import Foundation
import IOSurface
import Network
import StreamProtocol

extension HardwareDecoderRouter: LoopbackVideoDecoder { }
final class TouchBarObserver: @unchecked Sendable {
    static let shared = TouchBarObserver()
    private let lock = NSLock()
    private var onFrame: ((Data) -> Void)?
    private var onStatus: ((Data) -> Void)?
    func set(frame: ((Data) -> Void)?, status: ((Data) -> Void)?) { lock.withLock { onFrame = frame; onStatus = status } }
    func frame(_ data: Data) { lock.withLock { onFrame }?(data) }
    func status(_ data: Data) { lock.withLock { onStatus }?(data) }
}
struct SurfaceBox: @unchecked Sendable { let value: IOSurfaceRef }
final class FakeRuntime: TouchBarVirtualRuntime, @unchecked Sendable {
    private let lock = NSLock()
    private var queue: DispatchQueue?
    private var frame: (@Sendable (IOSurfaceRef, CMTime) -> Void)?
    private var unavailable: (@Sendable () -> Void)?
    private var stopped: (@Sendable () -> Void)?
    private var starts = 0, stops = 0
    func start(queue: DispatchQueue, onSurface: @escaping @Sendable (IOSurfaceRef, CMTime) -> Void,
               onUnavailable: @escaping @Sendable () -> Void, onStopped: @escaping @Sendable () -> Void) throws {
        lock.withLock { starts += 1; self.queue = queue; frame = onSurface; unavailable = onUnavailable; stopped = onStopped }
    }
    func stop() {
        let action = lock.withLock { () -> (DispatchQueue, @Sendable () -> Void)? in
            guard stops == 0, let queue, let stopped else { return nil }
            stops += 1; return (queue, stopped)
        }
        if let (queue, callback) = action { queue.async(execute: callback) }
    }
    func emit(_ source: IOSurfaceRef) {
        let action = lock.withLock { () -> (DispatchQueue, @Sendable (IOSurfaceRef, CMTime) -> Void)? in
            guard let queue, let frame else { return nil }; return (queue, frame)
        }
        if let (queue, callback) = action {
            let box = SurfaceBox(value: source)
            queue.async { callback(box.value, CMClockGetTime(CMClockGetHostTimeClock())) }
        }
    }
    func blank() {
        let action = lock.withLock { () -> (DispatchQueue, @Sendable () -> Void)? in
            guard let queue, let unavailable else { return nil }; return (queue, unavailable)
        }
        if let (queue, callback) = action { queue.async(execute: callback) }
    }
    var counts: (Int, Int) { lock.withLock { (starts, stops) } }
}
final class Audit: @unchecked Sendable {
    private let lock = NSLock()
    private var statuses: [TouchBarStatus] = [], samples: [(Int, Int, Int)] = [], errors: [String] = []
    func status(_ status: TouchBarStatus) { lock.withLock { statuses.append(status) } }
    func fail(_ error: String) { lock.withLock { errors.append(error) } }
    func sample(_ sample: CMSampleBuffer, _ permit: VideoOutputPermit) {
        guard permit.isValid, let pixel = CMSampleBufferGetImageBuffer(sample), CVPixelBufferGetPlaneCount(pixel) > 0,
              CVPixelBufferLockBaseAddress(pixel, .readOnly) == kCVReturnSuccess else { fail("sample"); return }
        defer { CVPixelBufferUnlockBaseAddress(pixel, .readOnly) }
        guard let p = CVPixelBufferGetBaseAddressOfPlane(pixel, 0)?.assumingMemoryBound(to: UInt8.self) else { fail("plane"); return }
        let width = CVPixelBufferGetWidth(pixel), height = CVPixelBufferGetHeight(pixel)
        let value = Int(p[(height / 2) * CVPixelBufferGetBytesPerRowOfPlane(pixel, 0) + width / 2])
        lock.withLock { samples.append((width, height, value)) }
    }
    var state: ([TouchBarStatus], [(Int, Int, Int)], [String]) { lock.withLock { (statuses, samples, errors) } }
}
enum Failure: Error { case timeout(String), invalid(String) }
@MainActor func waitFor(_ name: String, _ test: () -> Bool) async throws {
    let deadline = ContinuousClock.now + .seconds(8)
    while !test() {
        guard ContinuousClock.now < deadline else { throw Failure.timeout(name) }
        try await Task.sleep(for: .milliseconds(10))
    }
}
func surface() throws -> IOSurfaceRef {
    let props: [CFString: Any] = [kIOSurfaceWidth: 2007, kIOSurfaceHeight: 59,
        kIOSurfaceBytesPerElement: 4, kIOSurfacePixelFormat: kCVPixelFormatType_32BGRA]
    guard let surface = IOSurfaceCreate(props as CFDictionary), IOSurfaceLock(surface, [], nil) == kIOReturnSuccess else {
        throw Failure.invalid("surface")
    }
    let base = IOSurfaceGetBaseAddress(surface), row = IOSurfaceGetBytesPerRow(surface)
    for y in 0..<59 {
        let p = base.advanced(by: y * row).assumingMemoryBound(to: UInt8.self)
        for x in 0..<2007 { p[x * 4] = 96; p[x * 4 + 1] = 96; p[x * 4 + 2] = 96; p[x * 4 + 3] = 255 }
    }
    IOSurfaceUnlock(surface, [], nil)
    return surface
}
@main struct Check {
    @MainActor static func run() async throws {
        let audit = Audit(), runtime = FakeRuntime()
        let encoder = try HEVCEncoder(width: 2008, height: 60, fps: 30, bitrate: 3_000_000,
                                      prioritizeSpeed: true, software: false, quiet: true, independentFrames: true)
        let decoder = HardwareDecoderRouter(onFormat: { _, _ in }, onSample: { sample, _, permit in audit.sample(sample, permit) },
                                             onFailure: { message, _ in audit.fail(message) })
        let loop = try await LoopbackVideo.connect(decoder: decoder, encoder: encoder)
        let driver = TouchBarVirtualDriver(recordingAllowed: { true }, makeRuntime: { runtime })
        let source = TouchBarReadOnlySource(driver: driver, recordingAllowed: { true })
        let session = TouchBarHostSession(server: loop.server, makeSource: { source }, recordingAllowed: { true },
                                          inputAllowed: { true }, authorized: { _ in true })
        defer { session.stop(); TouchBarObserver.shared.set(frame: nil, status: nil); loop.close(); _ = decoder.clear(); _ = encoder.abandon() }
        try await waitFor("desktop reset") { loop.counters.resets > 0 }
        TouchBarObserver.shared.set(frame: { data in
            guard let packet = TouchBarKeyframe(encoded: data) else { audit.fail("frame parse"); return }
            decoder.apply(packet.parameters); decoder.enqueue(packet.accessUnit, isKeyframe: true)
        }, status: { data in
            guard let status = Wire.decode(TouchBarStatus.self, from: data), status.isValid else { audit.fail("status parse"); return }
            audit.status(status)
            if let surface = status.surface {
                _ = decoder.requireVideo(.touchBar(id: surface.id, width: surface.encodedWidth, height: surface.encodedHeight))
            } else { _ = decoder.requireVideo(nil) }
        })
        guard let client = loop.server.queue.sync(execute: { loop.server.clients.values.first }) else { throw Failure.invalid("client") }
        let route = loop.server.queue.sync { client.route }, connection = client.connection
        let coordinator = try StreamCoordinator(config: .standard, synthetic: true, appKitLoop: false)
        defer { coordinator.touchBarSession = nil }
        coordinator.routes[ObjectIdentifier(connection)] = route
        coordinator.touchBarSession = session
        guard let control = coordinator.server.onTouchBarControl, let input = coordinator.server.onTouchBarInput else {
            throw Failure.invalid("coordinator callbacks")
        }
        loop.server.queue.sync { loop.server.onTouchBarControl = control; loop.server.onTouchBarInput = input }
        loop.sendControl(.touchBarSubscription, payload: Wire.encode(TouchBarSubscription(watching: true)))
        try await waitFor("fake virtual source start") { runtime.counts.0 == 1 }
        let image = try surface()
        runtime.emit(image)
        try await waitFor("read-only hardware frame") { !audit.state.1.isEmpty || !audit.state.2.isEmpty }
        guard audit.state.2.isEmpty, let live = audit.state.0.last(where: { $0.availability == .live })?.surface,
              !live.acceptsInput, live.pixelWidth == 2007, live.pixelHeight == 59,
              let decoded = audit.state.1.last, decoded.0 == 2008, decoded.1 == 60, (70...120).contains(decoded.2) else {
            throw Failure.invalid("read-only frame")
        }
        try await waitFor("input permit") { loop.server.queue.sync { client.touchBarInputPermit?.surfaceID == live.id } }
        loop.sendControl(.touchBarTouch, payload: Wire.encode(TouchBarTouch(surfaceID: live.id, phase: .began, x: 0.5, y: 0.5)))
        try await Task.sleep(for: .milliseconds(100))
        guard session.touch.last == nil else { throw Failure.invalid("capture-only source took a touch") }
        runtime.blank()
        try await waitFor("blank unavailable") { audit.state.0.last?.availability == .unavailable && runtime.counts.1 == 1 }
        let count = audit.state.1.count
        runtime.emit(image)
        try await Task.sleep(for: .milliseconds(150))
        guard audit.state.1.count == count, audit.state.2.isEmpty else { throw Failure.invalid("late frame after blank") }
        try loop.check()
        print("TOUCH BAR VIRTUAL LOOPBACK PASS: synthetic BGRA source -> copied read-only adapter -> coordinator -> paired TLS/QUIC -> hardware HEVC, blank/late-frame fence")
        print("SCOPE: injected fake runtime and permissions; no private DFR call, real capture, input, physical Touch Bar, Duo, WAN or FPS acceptance")
    }
    static func main() async {
        do { try await run() }
        catch { print("TOUCH BAR VIRTUAL LOOPBACK FAIL: \(error)"); exit(1) }
    }
}
