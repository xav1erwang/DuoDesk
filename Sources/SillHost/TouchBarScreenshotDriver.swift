// Copyright 2026 DUO你电脑 contributors. SPDX-License-Identifier: Apache-2.0
import ApplicationServices
import CoreGraphics
import CoreMedia
import CoreVideo
import CryptoKit
import Darwin
import Foundation
import ImageIO
import IOSurface
import StreamProtocol

/// A still capture completes once; cancellation must not wait for the child to exit.
protocol TouchBarStillTask: AnyObject, Sendable { func cancel() }
protocol TouchBarStillRunner: Sendable {
    func start(completion: @escaping @Sendable (Result<Data, Error>) -> Void) throws -> any TouchBarStillTask
}

private enum TouchBarScreenshotFailure: Error {
    case recordingUnavailable, output, process, invalidImage, busy
}

/// The child writes to an already unlinked 0600 file through /dev/stdout. No screenshot pathname
/// survives a crash. The bytes are read only after child exit and are never logged or persisted.
private final class TouchBarScreenshotCommand: TouchBarStillTask, @unchecked Sendable {
    private static let maximumBytes = 8 * 1024 * 1024
    private let process: Process
    private init(_ process: Process) { self.process = process }

    static func system(completion: @escaping @Sendable (Result<Data, Error>) -> Void) throws -> TouchBarScreenshotCommand {
        // A test-injected driver gate cannot authorize a real system capture.
        guard CGPreflightScreenCaptureAccess() else { throw TouchBarScreenshotFailure.recordingUnavailable }
        return try launch(executable: URL(fileURLWithPath: "/usr/sbin/screencapture"),
                          arguments: ["-b", "-x", "-T", "0", "-t", "png", "/dev/stdout"], completion: completion)
    }

    #if DUO_TOUCH_BAR_STILL_TESTING
    /// Only the test build may exercise the process plumbing with its own synthetic executable.
    static func synthetic(executable: URL, completion: @escaping @Sendable (Result<Data, Error>) -> Void) throws -> TouchBarScreenshotCommand {
        guard executable.path != "/usr/sbin/screencapture" else { throw TouchBarScreenshotFailure.process }
        return try launch(executable: executable, arguments: [], completion: completion)
    }
    #endif

    private static func launch(executable: URL, arguments: [String],
                               completion: @escaping @Sendable (Result<Data, Error>) -> Void) throws -> TouchBarScreenshotCommand {
        var name = Array((NSTemporaryDirectory() + "duo-touchbar-XXXXXX").utf8CString)
        let fd = name.withUnsafeMutableBufferPointer { mkstemp($0.baseAddress!) }
        guard fd >= 0 else { throw TouchBarScreenshotFailure.output }
        guard fchmod(fd, 0o600) == 0 else {
            _ = name.withUnsafeBufferPointer { unlink($0.baseAddress!) }
            close(fd); throw TouchBarScreenshotFailure.output
        }
        guard name.withUnsafeBufferPointer({ unlink($0.baseAddress!) }) == 0 else {
            close(fd); throw TouchBarScreenshotFailure.output
        }
        let output = FileHandle(fileDescriptor: fd, closeOnDealloc: true)
        let process = Process()
        process.executableURL = executable; process.arguments = arguments
        process.standardInput = FileHandle.nullDevice
        process.standardOutput = output
        process.standardError = FileHandle.nullDevice
        process.qualityOfService = .utility
        process.terminationHandler = { task in
            defer { try? output.close() }
            guard task.terminationReason == .exit, task.terminationStatus == 0 else {
                completion(.failure(TouchBarScreenshotFailure.process)); return
            }
            do { completion(.success(try readOutput(fd))) }
            catch { completion(.failure(error)) }
        }
        do { try process.run() }
        catch { process.terminationHandler = nil; try? output.close(); throw error }
        return TouchBarScreenshotCommand(process)
    }

    private static func readOutput(_ fd: Int32) throws -> Data {
        var info = stat()
        guard fstat(fd, &info) == 0, info.st_size > 0, info.st_size <= maximumBytes else {
            throw TouchBarScreenshotFailure.output
        }
        let count = Int(info.st_size)
        var result = Data(count: count)
        try result.withUnsafeMutableBytes { bytes in
            guard let base = bytes.baseAddress else { throw TouchBarScreenshotFailure.output }
            var offset = 0
            while offset < count {
                let n = pread(fd, base.advanced(by: offset), count - offset, off_t(offset))
                if n < 0 && errno == EINTR { continue }
                guard n > 0 else { throw TouchBarScreenshotFailure.output }
                offset += n
            }
        }
        return result
    }

    func cancel() { if process.isRunning { process.terminate() } }
}

private struct SystemTouchBarStillRunner: TouchBarStillRunner {
    func start(completion: @escaping @Sendable (Result<Data, Error>) -> Void) throws -> any TouchBarStillTask {
        try TouchBarScreenshotCommand.system(completion: completion)
    }
}

private final class TouchBarScreenshotSlot: @unchecked Sendable {
    private let lock = NSLock()
    private var busy = false
    func acquire() -> Bool { lock.withLock { guard !busy else { return false }; busy = true; return true } }
    func release() { lock.withLock { busy = false } }
}

/// A read-only fallback using Apple's documented `screencapture -b` still-image option. It has
/// one child at a time and publishes only changed, valid bar-shaped pixels. A stuck child owns
/// the single global slot until it really exits. No input or permission-request API is used.
/// This has not yet been validated on a physical Touch Bar; the host reports read-only if it runs.
final class TouchBarScreenshotDriver: TouchBarSurfaceDriver, @unchecked Sendable {
    private static let slot = TouchBarScreenshotSlot()
    private let queue = DispatchQueue(label: "duodesk.touchbar.screenshot", qos: .utility)
    private let lock = NSLock()
    private let recordingAllowed: @Sendable () -> Bool
    private let runner: any TouchBarStillRunner
    private let interval: TimeInterval
    private let timeout: TimeInterval
    private var active: UUID?
    private var slotOwner: UUID?
    private var keepAlive: TouchBarScreenshotDriver?
    private var running: (token: UUID, request: UUID, task: any TouchBarStillTask)? // queue only
    private var lastPixels: (width: Int, height: Int, digest: SHA256.Digest)? // queue only
    var isQuiescent: Bool { lock.withLock { slotOwner == nil } }

    init(recordingAllowed: @escaping @Sendable () -> Bool = { CGPreflightScreenCaptureAccess() },
         runner: any TouchBarStillRunner = SystemTouchBarStillRunner(),
         interval: TimeInterval = 0.1, timeout: TimeInterval = 3) {
        self.recordingAllowed = recordingAllowed; self.runner = runner
        self.interval = interval; self.timeout = timeout
    }

    func start(onSurface: @escaping @Sendable (IOSurfaceRef, CMTime) -> Void,
               onStopped: @escaping @Sendable () -> Void) throws {
        guard recordingAllowed() else { throw TouchBarScreenshotFailure.recordingUnavailable }
        guard Self.slot.acquire() else { throw TouchBarScreenshotFailure.busy }
        let token = UUID()
        let admitted = lock.withLock { () -> Bool in
            guard active == nil, slotOwner == nil else { return false }
            active = token; slotOwner = token; keepAlive = self; return true
        }
        guard admitted else { Self.slot.release(); throw TouchBarScreenshotFailure.busy }
        queue.async { [self] in capture(token, onSurface: onSurface, onStopped: onStopped) }
    }

    func stop() {
        let token = lock.withLock { () -> UUID? in let token = active; active = nil; return token }
        guard let token else { return }
        queue.async { [self] in
            if running?.token == token { running?.task.cancel() }
            else { releaseSlot(token) }
        }
    }

    private func isActive(_ token: UUID) -> Bool { lock.withLock { active == token } }
    private func takeActive(_ token: UUID) -> Bool {
        lock.withLock { guard active == token else { return false }; active = nil; return true }
    }
    private func releaseSlot(_ token: UUID) {
        let release = lock.withLock { () -> Bool in
            guard slotOwner == token else { return false }
            slotOwner = nil; keepAlive = nil; return true
        }
        if release { lastPixels = nil; Self.slot.release() }
    }

    private func capture(_ token: UUID, onSurface: @escaping @Sendable (IOSurfaceRef, CMTime) -> Void,
                         onStopped: @escaping @Sendable () -> Void) {
        guard isActive(token) else { releaseSlot(token); return }
        guard recordingAllowed() else {
            let notify = takeActive(token); releaseSlot(token); if notify { onStopped() }; return
        }
        let request = UUID(), started = ProcessInfo.processInfo.systemUptime
        do {
            let task = try runner.start { [weak self] result in
                self?.queue.async { [weak self] in
                    self?.completed(token, request: request, started: started, result: result,
                                    onSurface: onSurface, onStopped: onStopped)
                }
            }
            running = (token, request, task)
            queue.asyncAfter(deadline: .now() + timeout) { [weak self] in
                guard let self, self.running?.token == token, self.running?.request == request else { return }
                let notify = self.takeActive(token)
                self.running?.task.cancel()
                if notify { onStopped() }
                // The slot remains occupied until the child actually exits and calls completion.
            }
        } catch {
            let notify = takeActive(token); releaseSlot(token); if notify { onStopped() }
        }
    }

    private func completed(_ token: UUID, request: UUID, started: TimeInterval, result: Result<Data, Error>,
                           onSurface: @escaping @Sendable (IOSurfaceRef, CMTime) -> Void,
                           onStopped: @escaping @Sendable () -> Void) {
        guard running?.token == token, running?.request == request else { return }
        running = nil
        guard isActive(token) else { releaseSlot(token); return }
        guard recordingAllowed(), case .success(let bytes) = result,
              let decoded = Self.decode(bytes) else {
            let notify = takeActive(token); releaseSlot(token); if notify { onStopped() }; return
        }
        let width = CVPixelBufferGetWidth(decoded.buffer), height = CVPixelBufferGetHeight(decoded.buffer)
        if lastPixels?.width != width || lastPixels?.height != height || lastPixels?.digest != decoded.digest {
            lastPixels = (width, height, decoded.digest)
            guard let surface = CVPixelBufferGetIOSurface(decoded.buffer)?.takeUnretainedValue() else {
                let notify = takeActive(token); releaseSlot(token); if notify { onStopped() }; return
            }
            let pts = CMClockGetTime(CMClockGetHostTimeClock())
            withExtendedLifetime(decoded.buffer) { onSurface(surface, pts) }
        }
        guard isActive(token) else { releaseSlot(token); return }
        let delay = max(0, interval - (ProcessInfo.processInfo.systemUptime - started))
        queue.asyncAfter(deadline: .now() + delay) { [weak self] in
            self?.capture(token, onSurface: onSurface, onStopped: onStopped)
        }
    }

    /// Image I/O parses the still PNG; the independent video stream still requires hardware HEVC
    /// encoding and decoding. No image is resized, and the top-left source pixel stays top-left.
    private static func decode(_ data: Data) -> (buffer: CVPixelBuffer, digest: SHA256.Digest)? {
        guard data.count > 8, data.count <= 8 * 1024 * 1024,
              data.starts(with: [0x89, 0x50, 0x4e, 0x47, 0x0d, 0x0a, 0x1a, 0x0a]),
              let source = CGImageSourceCreateWithData(data as CFData, nil), CGImageSourceGetCount(source) == 1,
              let info = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any],
              let width = (info[kCGImagePropertyPixelWidth] as? NSNumber)?.intValue,
              let height = (info[kCGImagePropertyPixelHeight] as? NSNumber)?.intValue,
              width > 0, height > 0, width <= 8191, height <= 2047, width >= height * 4,
              let image = CGImageSourceCreateImageAtIndex(source, 0, nil),
              image.width == width, image.height == height else { return nil }
        let ew = (width + 1) & ~1, eh = (height + 1) & ~1
        guard TouchBarSurface(id: UUID(), pixelWidth: width, pixelHeight: height,
                              encodedWidth: ew, encodedHeight: eh, acceptsInput: false).isValid else { return nil }
        var buffer: CVPixelBuffer?
        let attributes: [CFString: Any] = [kCVPixelBufferIOSurfacePropertiesKey: [:],
                                           kCVPixelBufferMetalCompatibilityKey: true]
        guard CVPixelBufferCreate(nil, width, height, kCVPixelFormatType_32BGRA,
                                  attributes as CFDictionary, &buffer) == kCVReturnSuccess, let buffer,
              CVPixelBufferLockBaseAddress(buffer, []) == kCVReturnSuccess else { return nil }
        defer { CVPixelBufferUnlockBaseAddress(buffer, []) }
        guard let base = CVPixelBufferGetBaseAddress(buffer) else { return nil }
        let stride = CVPixelBufferGetBytesPerRow(buffer)
        guard stride >= width * 4, stride <= Int.max / height else { return nil }
        memset(base, 0, stride * height)
        guard let context = CGContext(data: base, width: width, height: height, bitsPerComponent: 8,
                                      bytesPerRow: stride, space: CGColorSpaceCreateDeviceRGB(),
                                      bitmapInfo: CGImageAlphaInfo.premultipliedFirst.rawValue |
                                                  CGBitmapInfo.byteOrder32Little.rawValue) else { return nil }
        context.interpolationQuality = .none
        context.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
        let digest = SHA256.hash(data: Data(bytesNoCopy: base, count: stride * height, deallocator: .none))
        return (buffer, digest)
    }

    #if DUO_TOUCH_BAR_STILL_TESTING
    static func syntheticCommand(executable: URL,
                                 completion: @escaping @Sendable (Result<Data, Error>) -> Void) throws -> any TouchBarStillTask {
        try TouchBarScreenshotCommand.synthetic(executable: executable, completion: completion)
    }
    static func systemCommand(completion: @escaping @Sendable (Result<Data, Error>) -> Void) throws -> any TouchBarStillTask {
        try TouchBarScreenshotCommand.system(completion: completion)
    }
    #endif
}
