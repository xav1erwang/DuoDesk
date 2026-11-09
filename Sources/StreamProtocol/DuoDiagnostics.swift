// Copyright 2026 DUO你电脑 contributors. SPDX-License-Identifier: Apache-2.0
import Foundation

/// Local application logs only. This recorder has no networking or upload operations.
public final class DuoDiagnostics: @unchecked Sendable {
    public static let enabledKey = "Duo.recordLogs"
    public static let shared = DuoDiagnostics()
    public static let notice = "DUO你电脑不会将任何数据私自发送到任何服务器，你完全可以断网使用。这个按钮只是将日志保存在本地，如果遇到问题，你可以点击下方的‘采集日志’按钮来查看软件最近的运行日志，方便排错，采集日志会将最新的日志采集为一个文件 至于这个文件如何处置，发送给谁，由你来决定"

    private let queue = DispatchQueue(label: "duodesk.local.logs", qos: .utility)
    private let lock = NSLock()
    private var enabled: Bool
    private var generation: UInt64 = 0
    private let defaults: UserDefaults
    private let file: URL
    private var handle: FileHandle?
    private var size = 0
    private static let limit = 2_000_000

    public var isEnabled: Bool { lock.withLock { enabled } }

    public init(directory: URL? = nil, enabled: Bool? = nil, defaults: UserDefaults = .standard) {
        self.defaults = defaults
        self.enabled = enabled ?? (defaults.object(forKey: Self.enabledKey) as? Bool ?? true)
        let library = FileManager.default.urls(for: .libraryDirectory, in: .userDomainMask).first ?? .temporaryDirectory
        file = (directory ?? library.appending(path: "Logs/DUO你电脑", directoryHint: .isDirectory)).appending(path: "recent.log")
    }

    public func setEnabled(_ value: Bool) {
        lock.withLock {
            if enabled != value { generation &+= 1 }
            enabled = value
        }
        defaults.set(value, forKey: Self.enabledKey)
    }

    public func record(_ text: String) {
        guard let admitted = lock.withLock({ enabled ? generation : nil }) else { return }
        let text = String(text.prefix(4_096))
        let at = Date.now
        queue.async { [self] in
            guard lock.withLock({ enabled && generation == admitted }) else { return }
            do {
                try openIfNeeded()
                let data = Data((at.ISO8601Format() + "  " + text + "\n").utf8)
                if size + data.count > Self.limit {
                    try handle?.close()
                    handle = nil
                    let previous = file.deletingLastPathComponent().appending(path: "previous.log")
                    if FileManager.default.fileExists(atPath: previous.path) { try FileManager.default.removeItem(at: previous) }
                    try FileManager.default.moveItem(at: file, to: previous)
                    size = 0
                    try openIfNeeded()
                }
                try handle?.write(contentsOf: data)
                size += data.count
            } catch {
                // A recording failure is carried in the export, without recursively logging it.
                storageError = error.localizedDescription
            }
        }
    }

    private var storageError: String?

    public func capture(description: String) async -> DuoDiagnosticReport {
        await withCheckedContinuation { continuation in
            queue.async { [self] in
                do { try handle?.synchronize() } catch { storageError = error.localizedDescription }
                let previous = file.deletingLastPathComponent().appending(path: "previous.log")
                let text = [previous, file].compactMap { url -> String? in
                    guard FileManager.default.fileExists(atPath: url.path) else { return nil }
                    do { return try String(contentsOf: url, encoding: .utf8) }
                    catch { storageError = error.localizedDescription; return nil }
                }.joined(separator: "\n")
                continuation.resume(returning: DuoDiagnosticReport(
                    capturedAt: Date.now, appVersion: Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "",
                    build: Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? "",
                    system: ProcessInfo.processInfo.operatingSystemVersionString, loggingEnabled: isEnabled,
                    userDescription: description, log: text, storageError: storageError))
            }
        }
    }

    private func openIfNeeded() throws {
        guard handle == nil else { return }
        try FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true,
                                                attributes: [.posixPermissions: 0o700])
        if !FileManager.default.fileExists(atPath: file.path) {
            guard FileManager.default.createFile(atPath: file.path, contents: nil, attributes: [.posixPermissions: 0o600]) else {
                throw CocoaError(.fileWriteUnknown)
            }
        }
        handle = try FileHandle(forWritingTo: file)
        size = Int(try handle?.seekToEnd() ?? 0)
    }

    deinit { try? handle?.close() }
}
