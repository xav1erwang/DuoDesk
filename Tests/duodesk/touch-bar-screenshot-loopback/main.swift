// Copyright 2026 DUO你电脑 contributors. SPDX-License-Identifier: Apache-2.0
// Synthetic still capture -> read-only source -> coordinator -> local paired QUIC -> hardware HEVC.
import CoreGraphics
import CoreMedia
import CoreVideo
import Foundation
import ImageIO
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
enum Failure: Error { case timeout(String), invalid(String) }
final class FakeTask: TouchBarStillTask, @unchecked Sendable {
    private let stop: @Sendable () -> Void
    init(_ stop: @escaping @Sendable () -> Void) { self.stop = stop }
    func cancel() { stop() }
}
final class FakeRunner: TouchBarStillRunner, @unchecked Sendable {
    private let lock = NSLock()
    private var next = 0, cancellations = 0
    private var pending: [Int: @Sendable (Result<Data, Error>) -> Void] = [:]
    func start(completion: @escaping @Sendable (Result<Data, Error>) -> Void) throws -> any TouchBarStillTask {
        let index = lock.withLock { () -> Int in let index = next; next += 1; pending[index] = completion; return index }
        return FakeTask { [weak self] in self?.cancel(index) }
    }
    private func cancel(_ index: Int) {
        let callback = lock.withLock { () -> (@Sendable (Result<Data, Error>) -> Void)? in
            cancellations += 1; return pending.removeValue(forKey: index)
        }
        callback?(.failure(Failure.invalid("synthetic cancellation")))
    }
    func complete(_ index: Int, _ data: Data) {
        let callback = lock.withLock { pending.removeValue(forKey: index) }
        callback?(.success(data))
    }
    var counts: (starts: Int, cancels: Int) { lock.withLock { (next, cancellations) } }
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
        guard let base = CVPixelBufferGetBaseAddressOfPlane(pixel, 0)?.assumingMemoryBound(to: UInt8.self) else { fail("plane"); return }
        let width = CVPixelBufferGetWidth(pixel), height = CVPixelBufferGetHeight(pixel)
        let value = Int(base[(height / 2) * CVPixelBufferGetBytesPerRowOfPlane(pixel, 0) + width / 2])
        lock.withLock { samples.append((width, height, value)) }
    }
    var state: ([TouchBarStatus], [(Int, Int, Int)], [String]) { lock.withLock { (statuses, samples, errors) } }
}
@MainActor func waitFor(_ name: String, _ predicate: () -> Bool) async throws {
    let deadline = ContinuousClock.now + .seconds(8)
    while !predicate() {
        guard ContinuousClock.now < deadline else { throw Failure.timeout(name) }
        try await Task.sleep(for: .milliseconds(10))
    }
}
func png() throws -> Data {
    let width = 2007, height = 59
    var pixels = [UInt8](repeating: 96, count: width * height * 4)
    for index in stride(from: 3, to: pixels.count, by: 4) { pixels[index] = 255 }
    guard let provider = CGDataProvider(data: Data(pixels) as CFData),
          let image = CGImage(width: width, height: height, bitsPerComponent: 8, bitsPerPixel: 32,
                              bytesPerRow: width * 4, space: CGColorSpaceCreateDeviceRGB(),
                              bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.premultipliedLast.rawValue |
                                                       CGBitmapInfo.byteOrder32Big.rawValue),
                              provider: provider, decode: nil, shouldInterpolate: false, intent: .defaultIntent),
          let data = CFDataCreateMutable(nil, 0),
          let destination = CGImageDestinationCreateWithData(data, "public.png" as CFString, 1, nil) else {
        throw Failure.invalid("synthetic image")
    }
    CGImageDestinationAddImage(destination, image, nil)
    guard CGImageDestinationFinalize(destination) else { throw Failure.invalid("synthetic PNG") }
    return data as Data
}
@main struct Check {
    @MainActor static func run() async throws {
        let audit = Audit(), runner = FakeRunner()
        let encoder = try HEVCEncoder(width: 2008, height: 60, fps: 30, bitrate: 3_000_000,
                                      prioritizeSpeed: true, software: false, quiet: true, independentFrames: true)
        let decoder = HardwareDecoderRouter(onFormat: { _, _ in }, onSample: { sample, _, permit in audit.sample(sample, permit) },
                                             onFailure: { message, _ in audit.fail(message) })
        let loop = try await LoopbackVideo.connect(decoder: decoder, encoder: encoder)
        let driver = TouchBarScreenshotDriver(recordingAllowed: { true }, runner: runner, interval: 0.1, timeout: 3)
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
        let defaultSession = coordinator.touchBarSessionForRequest()
        guard let defaultSource = defaultSession.makeSource() as? TouchBarReadOnlySource,
              defaultSource.driver is TouchBarScreenshotDriver, !defaultSource.supportsInput else {
            throw Failure.invalid("product coordinator did not provide read-only screenshot source")
        }
        coordinator.routes[ObjectIdentifier(connection)] = route
        coordinator.touchBarSession = session
        guard let control = coordinator.server.onTouchBarControl, let input = coordinator.server.onTouchBarInput else {
            throw Failure.invalid("coordinator callbacks")
        }
        loop.server.queue.sync { loop.server.onTouchBarControl = control; loop.server.onTouchBarInput = input }
        loop.sendControl(.touchBarSubscription, payload: Wire.encode(TouchBarSubscription(watching: true)))
        try await waitFor("synthetic still start") { runner.counts.starts == 1 }
        runner.complete(0, try png())
        try await waitFor("hardware decoded frame") { !audit.state.1.isEmpty || !audit.state.2.isEmpty }
        guard audit.state.2.isEmpty, let live = audit.state.0.last(where: { $0.availability == .live })?.surface,
              !live.acceptsInput, live.pixelWidth == 2007, live.pixelHeight == 59,
              let decoded = audit.state.1.last, decoded.0 == 2008, decoded.1 == 60, (70...120).contains(decoded.2) else {
            throw Failure.invalid("read-only encoded frame")
        }
        try await waitFor("input permit") { loop.server.queue.sync { client.touchBarInputPermit?.surfaceID == live.id } }
        loop.sendControl(.touchBarTouch, payload: Wire.encode(TouchBarTouch(surfaceID: live.id, phase: .began, x: 0.5, y: 0.5)))
        try await Task.sleep(for: .milliseconds(100))
        guard session.touch.last == nil else { throw Failure.invalid("capture-only source accepted input") }
        try await waitFor("next pending capture") { runner.counts.starts >= 2 }
        loop.sendControl(.touchBarSubscription, payload: Wire.encode(TouchBarSubscription(watching: false)))
        try await waitFor("unsubscribe cancels capture") { runner.counts.cancels == 1 && driver.isQuiescent }
        try loop.check()
        print("TOUCH BAR STILL LOOPBACK PASS: product factory yields read-only screenshot driver; synthetic PNG -> coordinator -> paired local TLS/QUIC -> hardware HEVC; input refused and unsubscribe cancels")
        print("SCOPE: injected still runner and permissions; no real Touch Bar, system screenshot, input, Duo, WAN or FPS acceptance")
    }
    static func main() async {
        do { try await run() }
        catch { print("TOUCH BAR STILL LOOPBACK FAIL: \(error)"); exit(1) }
    }
}
