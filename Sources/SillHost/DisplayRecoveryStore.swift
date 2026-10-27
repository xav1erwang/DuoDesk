// Copyright 2026 DUO你电脑 contributors. SPDX-License-Identifier: Apache-2.0
import Foundation
import Darwin

/// An immutable, write-ahead record. It contains display metadata, never pixels or pairing data.
struct DisplayRecoveryRecord: Codable, Equatable {
    struct Display: Codable, Equatable {
        let id: UInt32
        let identity: DisplayRestoreIdentity
        let modeID: Int32
        let width: Int
        let height: Int
        let pixelWidth: Int
        let pixelHeight: Int
        let refresh: Double
        let originX: Int32
        let originY: Int32
        let mirror: UInt32
    }

    let version: Int
    let token: UUID
    let main: UInt32
    let displays: [Display]

    var isValid: Bool {
        guard version == 1, (1...64).contains(displays.count), main != 0 else { return false }
        let ids = Set(displays.map(\.id))
        guard ids.count == displays.count, !ids.contains(0), ids.contains(main) else { return false }
        return displays.allSatisfy { display in
            (1...65_536).contains(display.width) && (1...65_536).contains(display.height)
                && (1...65_536).contains(display.pixelWidth) && (1...65_536).contains(display.pixelHeight)
                && display.refresh.isFinite && (0...1_000).contains(display.refresh)
                && (display.mirror == 0 || (display.mirror != display.id && ids.contains(display.mirror)))
        }
    }

    /// An interrupted process could have missed an unplug/replacement. A valid unique hardware
    /// serial is required even when the CoreGraphics ID and all other fields still match.
    func alreadyRestored(as current: DisplayRecoveryRecord) -> Bool {
        guard sameState(as: current) else { return false }
        let saved = displays.sorted { $0.id < $1.id }
        let counts = saved.reduce(into: [DisplayRestoreIdentity: Int]()) { $0[$1.identity, default: 0] += 1 }
        return saved.allSatisfy { display in
            display.identity.permitsRestore(current: display.identity, wasOffline: true,
                                            originalMatches: counts[display.identity, default: 0],
                                            onlineMatches: counts[display.identity, default: 0])
        }
    }

    func sameState(as current: DisplayRecoveryRecord) -> Bool {
        isValid && current.isValid && main == current.main
            && displays.sorted { $0.id < $1.id } == current.displays.sorted { $0.id < $1.id }
    }
}

/// The exact single-display mode we intend to set, written before the CoreGraphics transaction.
/// A later process may undo it only if the complete current state still matches and the display is
/// independently identifiable. This deliberately excludes mirror and multi-display transactions.
struct DisplayRecoveryIntent: Codable, Equatable {
    let version: Int
    let expected: DisplayRecoveryRecord

    func isValid(for original: DisplayRecoveryRecord) -> Bool {
        guard version == 1, original.isValid, expected.isValid, expected.token == original.token,
              original.displays.count == 1, expected.displays.count == 1,
              original.main == expected.main else { return false }
        let before = original.displays[0], after = expected.displays[0]
        guard before.id == original.main, after.id == before.id, before.identity == after.identity,
              before.mirror == 0, after.mirror == 0,
              before.originX == 0, before.originY == 0, after.originX == 0, after.originY == 0,
              before.refresh > 0, before.refresh == after.refresh else { return false }
        return before.modeID != after.modeID || before.width != after.width || before.height != after.height
            || before.pixelWidth != after.pixelWidth || before.pixelHeight != after.pixelHeight
    }

    func permitsReplay(original: DisplayRecoveryRecord, current: DisplayRecoveryRecord) -> Bool {
        isValid(for: original) && expected.alreadyRestored(as: current)
    }
}

/// One host at a time may own a recovery directory. Records are published without replacement,
/// with the file flushed before the directory entry is created. A failed read is never 'missing'.
final class DisplayRecoveryStore {
    enum Failure: Error { case unavailable, busy, invalidRecord, changedRecord }
    static let defaultDirectory = FileManager.default.homeDirectoryForCurrentUser
        .appendingPathComponent("Library/Application Support/DUO你电脑/DisplayRecovery", isDirectory: true)

    private let directoryFD: Int32
    private let lockFD: Int32
    private static let recordName = "pending-display.json"
    private static let intentName = "pending-display-intent.json"
    private static let maxBytes = 65_536

    init(directory: URL) throws {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true,
                                                attributes: [.posixPermissions: 0o700])
        let dir = open(directory.path, O_RDONLY | O_DIRECTORY | O_CLOEXEC | O_NOFOLLOW)
        guard dir >= 0 else { throw Failure.unavailable }
        var info = stat()
        guard fstat(dir, &info) == 0, Self.privateObject(info, kind: S_IFDIR) else {
            close(dir); throw Failure.unavailable
        }
        let lock = openat(dir, ".lock", O_RDWR | O_CREAT | O_CLOEXEC | O_NOFOLLOW, 0o600)
        guard lock >= 0 else { close(dir); throw Failure.unavailable }
        guard fstat(lock, &info) == 0, Self.privateObject(info, kind: S_IFREG) else {
            close(lock); close(dir); throw Failure.unavailable
        }
        guard flock(lock, LOCK_EX | LOCK_NB) == 0 else {
            close(lock); close(dir); throw Failure.busy
        }
        directoryFD = dir
        lockFD = lock
    }

    deinit { close(lockFD); close(directoryFD) }

    private static func privateObject(_ info: stat, kind: mode_t) -> Bool {
        (info.st_mode & S_IFMT) == kind && info.st_uid == geteuid()
            && (info.st_mode & 0o077) == 0
    }

    func load() throws -> DisplayRecoveryRecord? {
        let record: DisplayRecoveryRecord? = try read(name: Self.recordName)
        guard let record else {
            // An orphaned intent can result from an older version or external interference. Never
            // associate it with a new transaction or silently erase it.
            let fd = openat(directoryFD, Self.intentName, O_RDONLY | O_NONBLOCK | O_CLOEXEC | O_NOFOLLOW)
            if fd >= 0 { close(fd); throw Failure.changedRecord }
            guard errno == ENOENT else { throw Failure.unavailable }
            return nil
        }
        guard record.isValid else { throw Failure.invalidRecord }
        return record
    }

    func loadIntent(for original: DisplayRecoveryRecord) throws -> DisplayRecoveryIntent? {
        let intent: DisplayRecoveryIntent? = try read(name: Self.intentName)
        guard let intent else { return nil }
        guard intent.isValid(for: original) else { throw Failure.invalidRecord }
        return intent
    }

    private func read<T: Decodable>(name: String) throws -> T? {
        // A damaged path might be a FIFO; opening it must not wait for a writer.
        let fd = openat(directoryFD, name, O_RDONLY | O_NONBLOCK | O_CLOEXEC | O_NOFOLLOW)
        if fd < 0 {
            if errno == ENOENT { return nil }
            throw Failure.unavailable
        }
        defer { close(fd) }
        var info = stat()
        guard fstat(fd, &info) == 0, Self.privateObject(info, kind: S_IFREG),
              info.st_size > 0, info.st_size <= Self.maxBytes else { throw Failure.invalidRecord }
        var bytes = [UInt8](repeating: 0, count: Int(info.st_size))
        let byteCount = bytes.count
        var offset = 0
        while offset < bytes.count {
            let readCount = bytes.withUnsafeMutableBytes { Darwin.read(fd, $0.baseAddress!.advanced(by: offset), byteCount - offset) }
            if readCount < 0 && errno == EINTR { continue }
            guard readCount > 0 else { throw Failure.unavailable }
            offset += readCount
        }
        var extra: UInt8 = 0
        guard Darwin.read(fd, &extra, 1) == 0,
              let record = try? JSONDecoder().decode(T.self, from: Data(bytes)) else {
            throw Failure.invalidRecord
        }
        return record
    }

    func save(_ record: DisplayRecoveryRecord) throws {
        guard record.isValid else { throw Failure.invalidRecord }
        guard try load() == nil else { throw Failure.changedRecord }
        try publish(record, name: Self.recordName)
    }

    func saveIntent(_ intent: DisplayRecoveryIntent, for original: DisplayRecoveryRecord) throws {
        guard let saved = try load(), saved == original, intent.isValid(for: original) else { throw Failure.changedRecord }
        try publish(intent, name: Self.intentName)
    }

    private func publish<T: Encodable>(_ record: T, name: String) throws {
        let data = try JSONEncoder().encode(record)
        guard data.count <= Self.maxBytes else { throw Failure.invalidRecord }
        let temp = ".pending-\(UUID().uuidString).tmp"
        let fd = openat(directoryFD, temp, O_WRONLY | O_CREAT | O_EXCL | O_CLOEXEC | O_NOFOLLOW, 0o600)
        guard fd >= 0 else { throw Failure.unavailable }
        defer { close(fd); _ = unlinkat(directoryFD, temp, 0) }
        var offset = 0
        try data.withUnsafeBytes { buffer in
            while offset < buffer.count {
                let count = write(fd, buffer.baseAddress!.advanced(by: offset), buffer.count - offset)
                if count < 0 && errno == EINTR { continue }
                guard count > 0 else { throw Failure.unavailable }
                offset += count
            }
        }
        guard fcntl(fd, F_FULLFSYNC) == 0 else { throw Failure.unavailable }
        // linkat fails if another record already exists; never overwrite its evidence.
        guard linkat(directoryFD, temp, directoryFD, name, 0) == 0 else { throw Failure.unavailable }
        guard unlinkat(directoryFD, temp, 0) == 0, fsync(directoryFD) == 0 else { throw Failure.unavailable }
    }

    func remove(token: UUID) throws {
        guard let record = try load() else {
            guard fsync(directoryFD) == 0 else { throw Failure.unavailable }
            return
        }
        guard record.token == token else { throw Failure.changedRecord }
        if try loadIntent(for: record) != nil {
            guard unlinkat(directoryFD, Self.intentName, 0) == 0, fsync(directoryFD) == 0 else { throw Failure.unavailable }
        }
        guard unlinkat(directoryFD, Self.recordName, 0) == 0, fsync(directoryFD) == 0 else { throw Failure.unavailable }
    }
}
