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
final class HeldTouches: @unchecked Sendable {
    struct Item {
        let message: StreamMessage
        let connection: NWConnection
        let route: ClientRoute
        let permit: TouchBarInputPermit
    }
    private let lock = NSLock()
    private var items: [Item] = []
    func put(_ item: Item) { lock.withLock { items.append(item) } }
    func take() -> Item? { lock.withLock { items.isEmpty ? nil : items.removeFirst() } }
    var count: Int { lock.withLock { items.count } }
}
final class HeldControls: @unchecked Sendable {
    struct Item {
        let message: StreamMessage
        let connection: NWConnection
        let route: ClientRoute
        let permit: TouchBarConnectionPermit
    }
    private let lock = NSLock()
    private var items: [Item] = []
    func put(_ item: Item) { lock.withLock { items.append(item) } }
    func take() -> Item? { lock.withLock { items.isEmpty ? nil : items.removeFirst() } }
    var count: Int { lock.withLock { items.count } }
}
@MainActor final class PermissionFixture {
    var recording = false
    var input = true
    var paired = true
}
@MainActor final class SyntheticTouchBarSource: TouchBarCaptureSource {
    var starts = 0, stops = 0
    var supportsInput = true
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
                                          recordingAllowed: { permission.recording }, inputAllowed: { permission.input },
                                          authorized: { _ in permission.paired })
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
        guard let fingerprint = route.fingerprint else { throw Failure.invalid("paired fingerprint") }
        var trust = TrustSnapshot()
        trust.paired[fingerprint] = "synthetic peer"
        guard StreamCoordinator.touchBarRouteAuthorized(route, trust: trust) else { throw Failure.invalid("paired route policy") }
        trust.paired.removeAll()
        guard !StreamCoordinator.touchBarRouteAuthorized(route, trust: trust) else { throw Failure.invalid("removed route policy") }
        let internetRoute = ClientRoute.remote(origin: .internet, label: "test", fingerprint: fingerprint, name: "synthetic peer")
        trust.paired[fingerprint] = "synthetic peer"
        trust.internetAccess = true
        guard !StreamCoordinator.touchBarRouteAuthorized(internetRoute, trust: trust) else { throw Failure.invalid("remote-off route policy") }
        trust.remoteAccess = true; trust.internetAccess = false
        guard !StreamCoordinator.touchBarRouteAuthorized(internetRoute, trust: trust) else { throw Failure.invalid("internet-off route policy") }
        trust.internetAccess = true
        guard StreamCoordinator.touchBarRouteAuthorized(internetRoute, trust: trust) else { throw Failure.invalid("allowed remote route policy") }
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
        // No more frames or touches are sent here. A static system bar must still publish the
        // current input capability when authorization changes in either direction.
        permission.input = false
        try await waitFor("idle input revocation is published") {
            results.state.0.last?.surface?.id == surface.id && results.state.0.last?.surface?.acceptsInput == false
        }
        guard fake.stops == 0 else { throw Failure.invalid("idle input revocation stopped read-only capture") }
        permission.input = true
        try await waitFor("idle input restoration is published") {
            results.state.0.last?.surface?.id == surface.id && results.state.0.last?.surface?.acceptsInput == true
        }
        print("PASS: idle input revocation and restoration publish without a new frame or touch")
        try await waitFor("first input permit") { loop.server.queue.sync { client.touchBarInputPermit != nil } }
        guard var firstPermit = loop.server.queue.sync(execute: { client.touchBarInputPermit }) else { throw Failure.invalid("first permit") }
        let begin = TouchBarTouch(surfaceID: surface.id, phase: .began, x: 0.2, y: 0.5)
        permission.paired = false
        session.receive(begin, from: connection, route: route, permit: firstPermit)
        guard fake.posted.isEmpty else { throw Failure.invalid("current trust was not rechecked") }
        permission.paired = true
        let held = HeldTouches()
        let heldControls = HeldControls()
        loop.server.queue.sync {
            loop.server.onTouchBarInput = { message, connection, route, permit in
                held.put(.init(message: message, connection: connection, route: route, permit: permit))
            }
            loop.server.onTouchBarControl = { message, connection, route, permit in
                heldControls.put(.init(message: message, connection: connection, route: route, permit: permit))
            }
        }
        // The network has read this touch, but its main-actor delivery is deliberately held until
        // after the subscriber is removed. It must not reach even the fake source.
        loop.sendControl(.touchBarTouch, payload: Wire.encode(begin))
        try await waitFor("queued touch") { held.count == 1 }
        guard let delayed = held.take(), let delayedTouch = Wire.decode(TouchBarTouch.self, from: delayed.message.payload) else {
            throw Failure.invalid("queued touch decode")
        }
        loop.server.setTouchBarSubscription(nil, for: connection)
        loop.server.queue.sync { }
        guard !delayed.permit.isValid else { throw Failure.invalid("unsubscribe did not revoke queued input") }
        session.receive(delayedTouch, from: delayed.connection, route: delayed.route, permit: delayed.permit)
        guard fake.posted.isEmpty else { throw Failure.invalid("revoked queued touch posted") }
        loop.server.setTouchBarSubscription(surface.id, for: connection)
        loop.server.queue.sync { }
        guard let replacementPermit = loop.server.queue.sync(execute: { client.touchBarInputPermit }),
              replacementPermit !== firstPermit else { throw Failure.invalid("new subscription did not replace permit") }
        firstPermit = replacementPermit
        // A current touch really crosses the paired network path and reaches the synthetic source.
        loop.sendControl(.touchBarTouch, payload: Wire.encode(begin))
        try await waitFor("current network touch") { held.count == 1 }
        guard let current = held.take(), let currentTouch = Wire.decode(TouchBarTouch.self, from: current.message.payload) else {
            throw Failure.invalid("current touch decode")
        }
        session.receive(currentTouch, from: current.connection, route: current.route, permit: current.permit)
        let end = TouchBarTouch(surfaceID: surface.id, phase: .ended, x: 0.2, y: 0.5)
        session.receive(end, from: connection, route: route, permit: firstPermit)
        guard fake.posted.map(\.phase) == [.began, .ended] else { throw Failure.invalid("current network input") }
        fake.posted.removeAll()
        let wrongConnection = TouchBarInputPermit(surfaceID: surface.id, connectionID: ObjectIdentifier(fake))
        session.receive(begin, from: connection, route: route, permit: wrongConnection)
        guard fake.posted.isEmpty else { throw Failure.invalid("permit bound to another connection") }
        // A source change must fence a touch that was already read from the old source.
        loop.sendControl(.touchBarTouch, payload: Wire.encode(begin))
        try await waitFor("queued touch before source change") { held.count == 1 }
        guard let oldSource = held.take(), let oldTouch = Wire.decode(TouchBarTouch.self, from: oldSource.message.payload) else {
            throw Failure.invalid("old source touch decode")
        }
        loop.server.beginTouchBarStream(UUID())
        loop.server.queue.sync { }
        session.receive(oldTouch, from: oldSource.connection, route: oldSource.route, permit: oldSource.permit)
        guard !oldSource.permit.isValid, fake.posted.isEmpty else { throw Failure.invalid("source change retained queued input") }
        loop.server.beginTouchBarStream(surface.id)
        loop.server.setTouchBarSubscription(surface.id, for: connection)
        loop.server.queue.sync { }
        guard let restored = loop.server.queue.sync(execute: { client.touchBarInputPermit }) else { throw Failure.invalid("source restore permit") }
        firstPermit = restored
        session.receive(begin, from: connection, route: .home(.loopback, peer: nil), permit: firstPermit)
        session.receive(TouchBarTouch(surfaceID: UUID(), phase: .began, x: 0.2, y: 0.5), from: connection, route: route, permit: firstPermit)
        guard fake.posted.isEmpty else { throw Failure.invalid("unpaired or stale input") }
        session.receive(begin, from: connection, route: route, permit: firstPermit)
        session.clientLeft(connection)
        loop.server.queue.sync { }
        guard !firstPermit.isValid else { throw Failure.invalid("disconnect did not revoke permit") }
        guard fake.posted.map(\.phase) == [.began, .cancelled], fake.stops == 1, session.token == nil else {
            throw Failure.invalid("disconnect release")
        }
        let observed = results.state.1.count
        fake.emitAfterStop(try frame(192))
        try await Task.sleep(for: .milliseconds(150))
        guard results.state.1.count == observed else { throw Failure.invalid("late frame after stop") }

        permission.input = false
        fake.supportsInput = false
        session.subscribe(TouchBarSubscription(watching: true), from: connection, route: route)
        fake.emit(try frame(144))
        try await waitFor("read-only surface") {
            results.state.0.last(where: { $0.availability == .live })?.surface?.id != surface.id
        }
        guard let readOnly = results.state.0.last(where: { $0.availability == .live })?.surface, !readOnly.acceptsInput else {
            throw Failure.invalid("input preflight")
        }
        try await waitFor("read-only input permit") { loop.server.queue.sync { client.touchBarInputPermit?.surfaceID == readOnly.id } }
        guard let readOnlyPermit = loop.server.queue.sync(execute: { client.touchBarInputPermit }) else { throw Failure.invalid("read-only permit") }
        let before = fake.posted.count
        session.receive(TouchBarTouch(surfaceID: readOnly.id, phase: .began, x: 0.5, y: 0.5), from: connection, route: route, permit: readOnlyPermit)
        guard fake.posted.count == before else { throw Failure.invalid("posted without input permission") }
        permission.input = true
        session.receive(TouchBarTouch(surfaceID: readOnly.id, phase: .began, x: 0.5, y: 0.5), from: connection, route: route, permit: readOnlyPermit)
        guard fake.posted.count == before else { throw Failure.invalid("capture-only backend accepted input") }
        fake.supportsInput = true
        session.receive(TouchBarTouch(surfaceID: readOnly.id, phase: .began, x: 0.5, y: 0.5), from: connection, route: route, permit: readOnlyPermit)
        try await waitFor("updated input capability") {
            results.state.0.last(where: { $0.availability == .live })?.surface?.acceptsInput == true
        }
        session.receive(TouchBarTouch(surfaceID: readOnly.id, phase: .began, x: 0.5, y: 0.5), from: connection, route: route, permit: readOnlyPermit)
        guard fake.posted.count == before + 1 else { throw Failure.invalid("input after capability update") }
        permission.input = false
        // Losing input access while a contact is held must not wait for another touch or frame.
        try await waitFor("idle held input revocation") { fake.stops == 2 }
        guard fake.stops == 2, fake.posted.count == before + 1, session.token == nil else {
            throw Failure.invalid("input revocation did not stop source")
        }
        print("PASS: idle held-contact input revocation stops the source without injecting a release")
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
        try await waitFor("final input permit") { loop.server.queue.sync { client.touchBarInputPermit?.surfaceID == finalSurface.id } }
        guard let finalPermit = loop.server.queue.sync(execute: { client.touchBarInputPermit }) else { throw Failure.invalid("final permit") }
        let beforeRevocation = fake.posted.count
        session.receive(TouchBarTouch(surfaceID: finalSurface.id, phase: .began, x: 0.4, y: 0.5), from: connection, route: route, permit: finalPermit)
        permission.recording = false
        // Screen access is revoked with no subsequent input or capture callback.
        try await waitFor("idle recording revocation") { fake.stops == 4 }
        guard fake.stops == 4, session.token == nil,
              fake.posted.count == beforeRevocation + 2, fake.posted.last?.phase == .cancelled else {
            throw Failure.invalid("recording revocation did not stop and release")
        }
        print("PASS: idle recording revocation stops the source and releases a trusted held contact")
        try loop.check()

        // Use the production coordinator's actual network callbacks against this paired loopback
        // and an injected source. The coordinator itself never starts a listener or a capture.
        let coordinator = try StreamCoordinator(config: .standard, synthetic: true, appKitLoop: false)
        defer { coordinator.touchBarSession = nil }
        coordinator.routes[ObjectIdentifier(connection)] = route
        coordinator.touchBarSession = session
        guard let controlCallback = coordinator.server.onTouchBarControl,
              let inputCallback = coordinator.server.onTouchBarInput else { throw Failure.invalid("coordinator callbacks") }
        loop.server.queue.sync {
            loop.server.onTouchBarControl = controlCallback
            loop.server.onTouchBarInput = inputCallback
        }
        permission.recording = true
        loop.sendControl(.touchBarSubscription, payload: Wire.encode(TouchBarSubscription(watching: true)))
        try await waitFor("coordinator network subscription") { fake.starts == 5 }
        fake.emit(try frame(96))
        try await waitFor("coordinator live surface") { session.surface != nil }
        guard let coordinatorSurface = session.surface else { throw Failure.invalid("coordinator surface") }
        try await waitFor("coordinator input permit") { loop.server.queue.sync { client.touchBarInputPermit?.surfaceID == coordinatorSurface.id } }
        let beforeCoordinatedInput = fake.posted.count
        loop.sendControl(.touchBarTouch, payload: Wire.encode(TouchBarTouch(surfaceID: coordinatorSurface.id, phase: .began, x: 0.3, y: 0.5)))
        loop.sendControl(.touchBarTouch, payload: Wire.encode(TouchBarTouch(surfaceID: coordinatorSurface.id, phase: .ended, x: 0.3, y: 0.5)))
        loop.sendControl(.touchBarRefresh, payload: TouchBarRefresh(surfaceID: coordinatorSurface.id).encoded)
        try await waitFor("coordinator ordered input") { fake.posted.count == beforeCoordinatedInput + 2 }
        guard Array(fake.posted.suffix(2)).map(\.phase) == [.began, .ended] else { throw Failure.invalid("coordinator input order") }

        // A client can lose the last image when a status supersedes its pending frame. Prove the
        // network refresh recovers the latest source pixels after the synthetic source goes idle.
        let beforeLatest = results.state.1.count
        fake.emit(try frame(32))
        try await waitFor("latest synthetic source frame") {
            results.state.1.dropFirst(beforeLatest).contains { abs($0 - 32) <= 12 }
        }
        // Let initial connection/refresh keyframes drain before measuring the new request.
        try await Task.sleep(for: .milliseconds(800))
        let beforeStaticRefresh = results.state.1.count
        loop.sendControl(.touchBarRefresh, payload: TouchBarRefresh(surfaceID: coordinatorSurface.id).encoded)
        try await waitFor("static frame refresh through coordinator") {
            results.state.1.dropFirst(beforeStaticRefresh).contains { abs($0 - 32) <= 12 }
        }
        print("PASS: paired network refresh recovers the latest synthetic image after its source becomes static")
        loop.sendControl(.touchBarSubscription, payload: Wire.encode(TouchBarSubscription(watching: false)))
        try await waitFor("coordinator network unsubscribe") { session.token == nil && fake.stops == 5 }
        loop.sendControl(.touchBarSubscription, payload: Wire.encode(TouchBarSubscription(watching: true)))
        try await waitFor("coordinator network resubscribe") { fake.starts == 6 }
        fake.emit(try frame(96))
        try await waitFor("coordinator second live surface") { session.surface != nil }
        guard let closingSurface = session.surface else { throw Failure.invalid("goodbye surface") }
        try await waitFor("goodbye permit") { loop.server.queue.sync { client.touchBarInputPermit?.surfaceID == closingSurface.id } }
        loop.server.queue.sync {
            loop.server.onTouchBarInput = { message, connection, route, permit in
                held.put(.init(message: message, connection: connection, route: route, permit: permit))
            }
            loop.server.onTouchBarControl = { message, connection, route, permit in
                heldControls.put(.init(message: message, connection: connection, route: route, permit: permit))
            }
        }

        // Model the remove-device close after its queue turn has processed a goodbye. The client
        // has actually sent a touch, but delivery to the main actor remains paused until then.
        let closingTouch = TouchBarTouch(surfaceID: closingSurface.id, phase: .began, x: 0.5, y: 0.5)
        loop.sendControl(.touchBarTouch, payload: Wire.encode(closingTouch))
        loop.sendControl(.touchBarSubscription, payload: Wire.encode(TouchBarSubscription(watching: true)))
        try await waitFor("queued touch before goodbye") { held.count == 1 }
        try await waitFor("queued control before goodbye") { heldControls.count == 1 }
        guard let closing = held.take(), let decoded = Wire.decode(TouchBarTouch.self, from: closing.message.payload) else {
            throw Failure.invalid("goodbye touch decode")
        }
        guard let closingControl = heldControls.take(), let request = Wire.decode(TouchBarSubscription.self, from: closingControl.message.payload) else {
            throw Failure.invalid("goodbye control decode")
        }
        let beforeGoodbye = fake.posted.count
        loop.server.closeSessions(Goodbye.removed, matching: { _ in true })
        loop.server.queue.sync { }
        session.receive(decoded, from: closing.connection, route: closing.route, permit: closing.permit)
        guard !closing.permit.isValid, fake.posted.count == beforeGoodbye else { throw Failure.invalid("goodbye retained queued input") }
        let startsBeforeControl = fake.starts
        let admitted = closingControl.permit.admit {
            session.subscribe(request, from: closingControl.connection, route: closingControl.route)
        }
        guard !admitted, fake.starts == startsBeforeControl else { throw Failure.invalid("goodbye retained queued subscription") }
        loop.server.setTouchBarSubscription(closingSurface.id, for: connection)
        loop.server.queue.sync { }
        guard loop.server.queue.sync(execute: { client.touchBarInputPermit == nil && client.touchBarClosing }) else {
            throw Failure.invalid("closing session resubscribed")
        }
        print("TOUCH BAR SESSION PASS: synthetic source, coordinator callbacks over paired mTLS/QUIC, hardware frame, current trust policy, queued touch/control fencing, unsubscribe/source change/goodbye, late-frame fence and bounded preparation")
        print("SCOPE: injected fake permissions and source; no actual capture or system input, no physical Touch Bar, Duo, WAN or FPS acceptance")
    }
    static func main() async {
        do { try await run() }
        catch { print("TOUCH BAR SESSION FAIL: \(error)"); exit(1) }
    }
}
