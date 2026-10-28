// Copyright 2026 DUO你电脑 contributors. SPDX-License-Identifier: Apache-2.0
// Synthetic PNG and a fake capture runner only. No real Touch Bar, screen capture or input.
import ApplicationServices
import CoreGraphics
import CoreVideo
import Darwin
import Foundation
import ImageIO
import StreamProtocol

enum Failure: Error { case check(String), timeout(String) }

final class FakeTask: TouchBarStillTask, @unchecked Sendable {
    private let cancelAction: @Sendable () -> Void
    init(_ action: @escaping @Sendable () -> Void) { cancelAction = action }
    func cancel() { cancelAction() }
}

final class FakeRunner: TouchBarStillRunner, @unchecked Sendable {
    private let lock = NSLock()
    private var next = 0, cancellations = 0
    private var completions: [Int: @Sendable (Result<Data, Error>) -> Void] = [:]
    func start(completion: @escaping @Sendable (Result<Data, Error>) -> Void) throws -> any TouchBarStillTask {
        lock.withLock { completions[next] = completion; next += 1 }
        return FakeTask { [weak self] in self?.lock.withLock { self?.cancellations += 1 } }
    }
    func complete(_ index: Int, _ result: Result<Data, Error>) {
        let callback = lock.withLock { completions.removeValue(forKey: index) }
        callback?(result)
    }
    var counts: (starts: Int, cancels: Int) { lock.withLock { (next, cancellations) } }
}

final class Results: @unchecked Sendable {
    private let lock = NSLock()
    private var frames: [TouchBarCapturedFrame] = []
    private var stops = 0
    private var command: Result<Data, Error>?
    func frame(_ frame: TouchBarCapturedFrame) { lock.withLock { frames.append(frame) } }
    func stopped() { lock.withLock { stops += 1 } }
    func commandResult(_ result: Result<Data, Error>) { lock.withLock { command = result } }
    var state: ([TouchBarCapturedFrame], Int) { lock.withLock { (frames, stops) } }
    var child: Result<Data, Error>? { lock.withLock { command } }
}

final class FakePermission: @unchecked Sendable {
    private let lock = NSLock()
    private var allowed = true
    var value: Bool { lock.withLock { allowed } }
    func revoke() { lock.withLock { allowed = false } }
}

@MainActor func waitFor(_ name: String, _ predicate: () -> Bool) async throws {
    let deadline = ContinuousClock.now + .seconds(4)
    while !predicate() {
        guard ContinuousClock.now < deadline else { throw Failure.timeout(name) }
        try await Task.sleep(for: .milliseconds(10))
    }
}

func syntheticPNG(width: Int = 201, height: Int = 21, variant: UInt8 = 0) throws -> Data {
    var pixels = [UInt8](repeating: 255, count: width * height * 4)
    for y in 0..<height {
        for x in 0..<width {
            let i = (y * width + x) * 4
            pixels[i] = y < height / 2 ? 255 : variant
            pixels[i + 1] = 0
            pixels[i + 2] = y < height / 2 ? variant : 255
        }
    }
    let data = Data(pixels)
    guard let provider = CGDataProvider(data: data as CFData),
          let image = CGImage(width: width, height: height, bitsPerComponent: 8, bitsPerPixel: 32,
                              bytesPerRow: width * 4, space: CGColorSpaceCreateDeviceRGB(),
                              bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.premultipliedLast.rawValue |
                                                       CGBitmapInfo.byteOrder32Big.rawValue),
                              provider: provider, decode: nil, shouldInterpolate: false, intent: .defaultIntent),
          let result = CFDataCreateMutable(nil, 0),
          let destination = CGImageDestinationCreateWithData(result, "public.png" as CFString, 1, nil) else {
        throw Failure.check("synthetic PNG setup")
    }
    CGImageDestinationAddImage(destination, image, nil)
    guard CGImageDestinationFinalize(destination) else { throw Failure.check("synthetic PNG encoding") }
    return result as Data
}

func pixel(_ buffer: CVPixelBuffer, x: Int, y: Int) throws -> [UInt8] {
    guard CVPixelBufferLockBaseAddress(buffer, .readOnly) == kCVReturnSuccess else { throw Failure.check("lock pixel") }
    defer { CVPixelBufferUnlockBaseAddress(buffer, .readOnly) }
    guard let base = CVPixelBufferGetBaseAddress(buffer) else { throw Failure.check("pixel base") }
    let at = base.advanced(by: y * CVPixelBufferGetBytesPerRow(buffer) + x * 4).assumingMemoryBound(to: UInt8.self)
    return Array(UnsafeBufferPointer(start: at, count: 4))
}

@main struct Check {
    @MainActor static func run() async throws {
        guard CommandLine.arguments.count == 2 else { throw Failure.check("synthetic child path") }
        let childURL = URL(fileURLWithPath: CommandLine.arguments[1])
        let temp = NSTemporaryDirectory()
        let before = Set(try FileManager.default.contentsOfDirectory(atPath: temp).filter { $0.hasPrefix("duodesk-touchbar-") })
        let results = Results()
        let child = try TouchBarScreenshotDriver.syntheticCommand(executable: childURL) {
            results.commandResult($0)
        }
        try await waitFor("private ImageIO output") { results.child != nil }
        guard case .success(let bytes)? = results.child,
              let image = CGImageSourceCreateWithData(bytes as CFData, nil),
              let props = CGImageSourceCopyPropertiesAtIndex(image, 0, nil) as? [CFString: Any],
              (props[kCGImagePropertyPixelWidth] as? NSNumber)?.intValue == 4,
              (props[kCGImagePropertyPixelHeight] as? NSNumber)?.intValue == 1 else {
            throw Failure.check("private ImageIO PNG")
        }
        let after = Set(try FileManager.default.contentsOfDirectory(atPath: temp).filter { $0.hasPrefix("duodesk-touchbar-") })
        guard after.subtracting(before).isEmpty else { throw Failure.check("capture directory not removed") }
        withExtendedLifetime(child) { }
        try checkAbandonedDirectories(childURL)
        if !CGPreflightScreenCaptureAccess() {
            var denied = false
            do { _ = try TouchBarScreenshotDriver.systemCommand { _ in }; }
            catch { denied = true }
            guard denied else { throw Failure.check("system capture not gated") }
            print("PASS: the real command did not launch without this process's recording permission")
        } else { print("SKIP: process already has recording permission; no system command launched") }

        let runner = FakeRunner()
        let deniedDriver = TouchBarScreenshotDriver(recordingAllowed: { false }, runner: runner)
        let deniedSource = TouchBarReadOnlySource(driver: deniedDriver, recordingAllowed: { false })
        var denied = false
        do { try deniedSource.start(onFrame: { _ in }, onStopped: {}); }
        catch { denied = true }
        guard denied, runner.counts.starts == 0 else { throw Failure.check("source permission gate") }

        let driver = TouchBarScreenshotDriver(recordingAllowed: { true }, runner: runner, interval: 0.01, timeout: 2)
        let source = TouchBarReadOnlySource(driver: driver, recordingAllowed: { true })
        let frame: @Sendable (TouchBarCapturedFrame) -> Void = { results.frame($0) }
        let stopped: @Sendable () -> Void = { results.stopped() }
        try source.start(onFrame: frame, onStopped: stopped)
        guard !source.supportsInput, !source.post(TouchBarTouch(surfaceID: UUID(), phase: .began, x: 0.5, y: 0.5)) else {
            throw Failure.check("read-only source accepted touch")
        }
        try await waitFor("first fake capture") { runner.counts.starts == 1 }
        let imageA = try syntheticPNG(), imageB = try syntheticPNG(variant: 40)
        runner.complete(0, .success(imageA))
        try await waitFor("first decoded frame") { results.state.0.count == 1 }
        let first = results.state.0[0]
        let top = try pixel(first.pixels, x: 0, y: 0), bottom = try pixel(first.pixels, x: 0, y: 20)
        let padding = try pixel(first.pixels, x: 201, y: 0)
        print("SYNTHETIC PIXELS: size=\(first.contentWidth)x\(first.contentHeight), encoded=\(CVPixelBufferGetWidth(first.pixels))x\(CVPixelBufferGetHeight(first.pixels)), top=\(top), bottom=\(bottom), padding=\(padding)")
        guard first.contentWidth == 201, first.contentHeight == 21,
              CVPixelBufferGetWidth(first.pixels) == 202, CVPixelBufferGetHeight(first.pixels) == 22,
              top == [0, 0, 255, 255], bottom == [255, 0, 0, 255], padding == [0, 0, 0, 0] else {
            throw Failure.check("orientation, dimensions or padding")
        }
        try await waitFor("second fake capture") { runner.counts.starts == 2 }
        runner.complete(1, .success(imageA))
        try await waitFor("third fake capture") { runner.counts.starts == 3 }
        guard results.state.0.count == 1 else { throw Failure.check("duplicate picture delivered") }
        runner.complete(2, .success(imageB))
        try await waitFor("changed picture") { results.state.0.count == 2 }
        try await waitFor("pending capture") { runner.counts.starts == 4 }
        source.stop()
        try await waitFor("cancel pending capture") { runner.counts.cancels == 1 }
        runner.complete(3, .success(imageA))
        try await waitFor("driver released") { driver.isQuiescent }
        guard results.state.0.count == 2, results.state.1 == 0 else { throw Failure.check("late frame or false stop") }

        let stalled = FakeRunner()
        let stuckDriver = TouchBarScreenshotDriver(recordingAllowed: { true }, runner: stalled, interval: 0.01, timeout: 0.1)
        let stuckSource = TouchBarReadOnlySource(driver: stuckDriver, recordingAllowed: { true })
        try stuckSource.start(onFrame: frame, onStopped: stopped)
        try await waitFor("stalled request") { stalled.counts.starts == 1 }
        try await waitFor("timeout") { stalled.counts.cancels == 1 && results.state.1 == 1 }
        let next = TouchBarScreenshotDriver(recordingAllowed: { true }, runner: FakeRunner(), interval: 0.01, timeout: 1)
        var busy = false
        do { try next.start(onSurface: { _, _ in }, onStopped: {}); }
        catch { busy = true }
        guard busy, !stuckDriver.isQuiescent else { throw Failure.check("stalled capture released slot early") }
        stalled.complete(0, .failure(Failure.check("synthetic stop")))
        try await waitFor("stalled child exited") { stuckDriver.isQuiescent }

        let invalidRunner = FakeRunner()
        let invalidDriver = TouchBarScreenshotDriver(recordingAllowed: { true }, runner: invalidRunner, interval: 0.01, timeout: 1)
        let invalidSource = TouchBarReadOnlySource(driver: invalidDriver, recordingAllowed: { true })
        try invalidSource.start(onFrame: frame, onStopped: stopped)
        try await waitFor("invalid request") { invalidRunner.counts.starts == 1 }
        invalidRunner.complete(0, .success(Data([1, 2, 3])))
        try await waitFor("invalid picture rejected") { results.state.1 == 2 && invalidDriver.isQuiescent }
        guard results.state.0.count == 2 else { throw Failure.check("invalid picture delivered") }

        let wrongShapeRunner = FakeRunner()
        let wrongShapeDriver = TouchBarScreenshotDriver(recordingAllowed: { true }, runner: wrongShapeRunner, interval: 0.01, timeout: 1)
        let wrongShapeSource = TouchBarReadOnlySource(driver: wrongShapeDriver, recordingAllowed: { true })
        try wrongShapeSource.start(onFrame: frame, onStopped: stopped)
        try await waitFor("wrong shape request") { wrongShapeRunner.counts.starts == 1 }
        wrongShapeRunner.complete(0, .success(try syntheticPNG(width: 201, height: 100)))
        try await waitFor("non-bar shape rejected") { results.state.1 == 3 && wrongShapeDriver.isQuiescent }
        guard results.state.0.count == 2 else { throw Failure.check("non-bar picture delivered") }

        let permission = FakePermission(), revokedRunner = FakeRunner()
        let revokedDriver = TouchBarScreenshotDriver(recordingAllowed: { permission.value }, runner: revokedRunner,
                                                     interval: 0.3, timeout: 1)
        let revokedSource = TouchBarReadOnlySource(driver: revokedDriver, recordingAllowed: { permission.value })
        try revokedSource.start(onFrame: frame, onStopped: stopped)
        try await waitFor("revocation setup") { revokedRunner.counts.starts == 1 }
        revokedRunner.complete(0, .success(imageA))
        try await waitFor("revocation first frame") { results.state.0.count == 3 }
        permission.revoke()
        try await waitFor("revocation stops capture") { results.state.1 == 4 && revokedDriver.isQuiescent }
        guard revokedRunner.counts.starts == 1 else { throw Failure.check("capture started after permission revoked") }
        print("TOUCH BAR STILL SOURCE PASS: private ImageIO output and cleanup, inherited lock, permission gate, synthetic PNG orientation and padding, changed-frame filtering, cancellation, stalled-child slot and invalid data")
        print("SCOPE: fake runner and synthetic child only; no real system Touch Bar, screen capture, input, Duo or FPS acceptance")
    }
    @MainActor static func checkAbandonedDirectories(_ executable: URL) throws {
        let root = (NSTemporaryDirectory() as NSString).appendingPathComponent("duodesk-cleanup-test-\(UUID().uuidString)")
        try FileManager.default.createDirectory(atPath: root, withIntermediateDirectories: false,
                                                attributes: [.posixPermissions: 0o700])
        defer { try? FileManager.default.removeItem(atPath: root) }
        func fixture(_ suffix: String, marker: Bool = true) throws -> (String, Int32) {
            let dir = (root as NSString).appendingPathComponent("duodesk-touchbar-" + suffix)
            try FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: false,
                                                    attributes: [.posixPermissions: 0o700])
            if !marker { return (dir, -1) }
            let fd = open((dir as NSString).appendingPathComponent(".capture.lock"), O_CREAT | O_EXCL | O_RDWR, 0o600)
            guard fd >= 0 else { throw Failure.check("fixture lock") }
            return (dir, fd)
        }
        let (abandoned, abandonedFD) = try fixture("AAAAAA")
        close(abandonedFD)
        let (unrelated, _) = try fixture("BBBBBB", marker: false)
        let (held, heldFD) = try fixture("CCCCCC")
        guard flock(heldFD, LOCK_EX | LOCK_NB) == 0 else { close(heldFD); throw Failure.check("fixture flock") }
        let outsider = (root as NSString).appendingPathComponent("outside")
        try Data([1, 2, 3]).write(to: URL(fileURLWithPath: outsider))
        try FileManager.default.createSymbolicLink(atPath: (abandoned as NSString).appendingPathComponent("TouchBar.png"),
                                                   withDestinationPath: outsider)
        let task = Process()
        task.executableURL = executable
        task.arguments = [(held as NSString).appendingPathComponent("TouchBar.png"), "--hold"]
        let lock = FileHandle(fileDescriptor: heldFD, closeOnDealloc: true)
        task.standardInput = lock; task.standardOutput = FileHandle.nullDevice; task.standardError = FileHandle.nullDevice
        try task.run()
        try lock.close() // Simulate the host disappearing while its child is still alive.
        TouchBarScreenshotDriver.cleanAbandonedDirectoriesForTesting(in: root)
        guard !FileManager.default.fileExists(atPath: abandoned), FileManager.default.fileExists(atPath: outsider),
              FileManager.default.fileExists(atPath: unrelated), FileManager.default.fileExists(atPath: held) else {
            task.terminate(); throw Failure.check("abandoned cleanup and inherited child lock")
        }
        task.waitUntilExit()
        guard task.terminationStatus == 0 else { throw Failure.check("synthetic held child") }
        TouchBarScreenshotDriver.cleanAbandonedDirectoriesForTesting(in: root)
        guard !FileManager.default.fileExists(atPath: held), FileManager.default.fileExists(atPath: outsider),
              FileManager.default.fileExists(atPath: unrelated) else { throw Failure.check("cleanup after child exit") }
    }

    static func main() async {
        do { try await run() }
        catch { print("TOUCH BAR STILL SOURCE FAIL: \(error)"); exit(1) }
    }
}
