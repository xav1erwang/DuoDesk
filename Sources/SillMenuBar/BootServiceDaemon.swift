// Copyright 2026 DUO你电脑 contributors. SPDX-License-Identifier: Apache-2.0
import Foundation
import Security
import SystemConfiguration
import SillHostCore
import StreamProtocol

struct BootServiceRecord: Codable {
    var ownerUID: uid_t
    var identity: BootIdentity

    static func read() throws -> BootServiceRecord? {
        let fd = open(BootService.identityURL.path, O_RDONLY | O_NOFOLLOW | O_CLOEXEC)
        if fd < 0, errno == ENOENT { return nil }
        guard fd >= 0 else { throw IdentityStoreError("无法读取开机服务资料。") }
        defer { close(fd) }
        var info = stat()
        guard fstat(fd, &info) == 0, info.st_uid == 0, info.st_mode & S_IFMT == S_IFREG,
              info.st_mode & 0o077 == 0, info.st_nlink == 1, (1...262_144).contains(info.st_size) else {
            throw IdentityStoreError("开机服务资料的权限或大小无效。")
        }
        let handle = FileHandle(fileDescriptor: fd, closeOnDealloc: false)
        let data = try handle.readToEnd() ?? Data()
        let record = try JSONDecoder().decode(Self.self, from: data)
        guard record.ownerUID >= 500 else { throw IdentityStoreError("开机服务所属用户无效。") }
        try record.identity.validate()
        return record
    }

    func write() throws {
        try identity.validate()
        let data = try JSONEncoder().encode(self)
        guard data.count <= 262_144 else { throw IdentityStoreError("开机服务资料过大。") }
        try data.write(to: BootService.identityURL, options: .atomic)
        try FileManager.default.setAttributes([.posixPermissions: 0o600, .ownerAccountID: 0, .groupOwnerAccountID: 0],
                                              ofItemAtPath: BootService.identityURL.path)
    }
}

/// A small root service: authenticated identity storage and installation of a root-owned
/// LoginWindow host. It exposes no command execution, caller-selected paths, or network port.
final class BootServiceDaemon: NSObject, NSXPCListenerDelegate {
    private let listener = NSXPCListener(machServiceName: BootService.machService)
    private let queue = DispatchQueue(label: "duodesk.boot-storage")
    private let requirement: String
    private var record: BootServiceRecord?

    init(startingService: Void) throws {
        guard geteuid() == 0 else { throw IdentityStoreError("开机服务必须由系统启动。") }
        requirement = try BootService.signingRequirement()
        try Self.prepareDirectory()
        record = try BootServiceRecord.read()
        super.init()
        if record != nil { try installLoginHost() }
        listener.delegate = self
    }

    func run() { listener.resume() }

    private static func prepareDirectory() throws {
        let fm = FileManager.default
        if !fm.fileExists(atPath: BootService.directory.path) {
            try fm.createDirectory(at: BootService.directory, withIntermediateDirectories: false,
                                   attributes: [.posixPermissions: 0o700, .ownerAccountID: 0, .groupOwnerAccountID: 0])
        }
        let attributes = try fm.attributesOfItem(atPath: BootService.directory.path)
        guard attributes[.type] as? FileAttributeType == .typeDirectory,
              (attributes[.ownerAccountID] as? NSNumber)?.uint32Value == 0,
              let mode = attributes[.posixPermissions] as? NSNumber, mode.intValue & 0o077 == 0 else {
            throw IdentityStoreError("开机服务目录的权限无效。")
        }
    }

    func listener(_ listener: NSXPCListener, shouldAcceptNewConnection connection: NSXPCConnection) -> Bool {
        let uid = connection.effectiveUserIdentifier
        guard uid == 0 || uid >= 500 else { return false }
        connection.setCodeSigningRequirement(requirement)
        connection.exportedInterface = NSXPCInterface(with: BootServiceProtocol.self)
        connection.exportedObject = BootServicePeer(service: self, uid: uid)
        connection.resume()
        return true
    }

    private func authorize(_ uid: uid_t) throws {
        if let record {
            guard record.ownerUID == uid else { throw IdentityStoreError("开机服务属于这台 Mac 的另一位用户。") }
        } else {
            var consoleUID: uid_t = 0
            _ = SCDynamicStoreCopyConsoleUser(nil, &consoleUID, nil)
            guard consoleUID >= 500, uid == consoleUID else { throw IdentityStoreError("请在当前 Mac 用户会话中启用开机服务。") }
        }
    }

    fileprivate func read(uid: uid_t, reply: @escaping (Data?, String?) -> Void) {
        queue.async { [self] in
            do {
                if uid != 0 { try authorize(uid) }
                reply(try record.map { try JSONEncoder().encode($0.identity) }, nil)
            } catch { reply(nil, "\(error)") }
        }
    }

    fileprivate func configure(_ data: Data, uid: uid_t, reply: @escaping (String?) -> Void) {
        queue.async { [self] in
            do {
                try authorize(uid)
                guard data.count <= 262_144 else { throw IdentityStoreError("开机服务资料过大。") }
                let identity = try JSONDecoder().decode(BootIdentity.self, from: data)
                try identity.validate()
                if let record {
                    guard identity.fingerprint == record.identity.fingerprint,
                          identity.recognitionKey == record.identity.recognitionKey else {
                        throw IdentityStoreError("开机服务与当前 Mac 的身份不一致。")
                    }
                    // A configure request can have been queued before a newer pairing change.
                    // Once initialized, only updateTrust may replace the protected trust list.
                } else {
                    let next = BootServiceRecord(ownerUID: uid, identity: identity)
                    try next.write()
                    record = next
                }
                try installLoginHost()
                reply(nil)
            } catch { reply("\(error)") }
        }
    }

    fileprivate func updateTrust(_ data: Data, uid: uid_t, reply: @escaping (String?) -> Void) {
        queue.async { [self] in
            do {
                try authorize(uid)
                guard data.count <= 262_144, var next = record else { throw IdentityStoreError("开机服务尚未完成设置。") }
                next.identity.paired = try JSONDecoder().decode([PairedDevice].self, from: data)
                try next.write()
                record = next
                reply(nil)
            } catch { reply("\(error)") }
        }
    }

    fileprivate func deactivate(uid: uid_t, reply: @escaping (String?) -> Void) {
        queue.async { [self] in
            do {
                try authorize(uid)
                let fm = FileManager.default
                if fm.fileExists(atPath: BootService.loginPlist.path) { try fm.removeItem(at: BootService.loginPlist) }
                // This API is restricted to the owner GUI; no login-window host is active there.
                for url in [BootService.identityURL, BootService.loginApp] where fm.fileExists(atPath: url.path) {
                    try fm.removeItem(at: url)
                }
                record = nil
                reply(nil)
            } catch { reply("\(error)") }
        }
    }

    private func validateCode(at url: URL) throws {
        var code: SecStaticCode?
        var required: SecRequirement?
        guard SecRequirementCreateWithString(requirement as CFString, [], &required) == errSecSuccess,
              SecStaticCodeCreateWithPath(url as CFURL, [], &code) == errSecSuccess, let code, let required,
              SecStaticCodeCheckValidity(code, SecCSFlags(rawValue: kSecCSStrictValidate | kSecCSCheckAllArchitectures), required) == errSecSuccess else {
            throw IdentityStoreError("开机服务的应用签名验证失败。")
        }
    }

    private func installLoginHost() throws {
        let fm = FileManager.default
        let staged = BootService.directory.appendingPathComponent("LoginHost.staging.app", isDirectory: true)
        if fm.fileExists(atPath: staged.path) { try fm.removeItem(at: staged) }
        defer { try? fm.removeItem(at: staged) }
        try fm.copyItem(at: Bundle.main.bundleURL, to: staged)
        // Verify the private destination after the copy, eliminating source replacement races.
        // No symlink in the copied tree may point back to a user-writable executable/resource.
        guard let files = fm.enumerator(at: staged, includingPropertiesForKeys: [.isSymbolicLinkKey]) else {
            throw IdentityStoreError("无法检查登录窗口服务。")
        }
        for case let file as URL in files {
            guard try file.resourceValues(forKeys: [.isSymbolicLinkKey]).isSymbolicLink != true else {
                throw IdentityStoreError("登录窗口服务不能包含符号链接。")
            }
            try fm.setAttributes([.ownerAccountID: 0, .groupOwnerAccountID: 0], ofItemAtPath: file.path)
        }
        try fm.setAttributes([.ownerAccountID: 0, .groupOwnerAccountID: 0, .posixPermissions: 0o700], ofItemAtPath: staged.path)
        try validateCode(at: staged)
        let previous = BootService.directory.appendingPathComponent("LoginHost.previous.app", isDirectory: true)
        if fm.fileExists(atPath: previous.path) { try fm.removeItem(at: previous) }
        if fm.fileExists(atPath: BootService.loginApp.path) { try fm.moveItem(at: BootService.loginApp, to: previous) }
        do { try fm.moveItem(at: staged, to: BootService.loginApp) }
        catch {
            if fm.fileExists(atPath: previous.path) { try? fm.moveItem(at: previous, to: BootService.loginApp) }
            throw error
        }
        try? fm.removeItem(at: previous)
        let plist: [String: Any] = [
            "Label": BootService.loginLabel,
            "AssociatedBundleIdentifiers": ["com.duodesk.host"],
            "LimitLoadToSessionType": ["LoginWindow"],
            "ProgramArguments": [BootService.loginApp.appendingPathComponent("Contents/MacOS/DuoDeskHost").path, "--login-window-host"],
            "RunAtLoad": true,
            "KeepAlive": ["SuccessfulExit": false],
            "ThrottleInterval": 5,
            "ProcessType": "Interactive"
        ]
        let data = try PropertyListSerialization.data(fromPropertyList: plist, format: .xml, options: 0)
        try data.write(to: BootService.loginPlist, options: .atomic)
        try fm.setAttributes([.ownerAccountID: 0, .groupOwnerAccountID: 0, .posixPermissions: 0o644], ofItemAtPath: BootService.loginPlist.path)
        var uid: uid_t = 0
        _ = SCDynamicStoreCopyConsoleUser(nil, &uid, nil)
        if uid == 0 {
            let process = Process()
            process.executableURL = URL(fileURLWithPath: "/bin/launchctl")
            process.arguments = ["load", "-w", "-S", "LoginWindow", BootService.loginPlist.path]
            process.standardOutput = FileHandle.nullDevice
            process.standardError = FileHandle.nullDevice
            try process.run()
            // launchd also loads the global agent when it creates the LoginWindow session.
        }
    }
}

private final class BootServicePeer: NSObject, BootServiceProtocol {
    let service: BootServiceDaemon
    let uid: uid_t
    init(service: BootServiceDaemon, uid: uid_t) { self.service = service; self.uid = uid }
    func readIdentity(reply: @escaping (Data?, String?) -> Void) { service.read(uid: uid, reply: reply) }
    func configure(_ identity: Data, reply: @escaping (String?) -> Void) { service.configure(identity, uid: uid, reply: reply) }
    func updateTrust(_ devices: Data, reply: @escaping (String?) -> Void) { service.updateTrust(devices, uid: uid, reply: reply) }
    func deactivate(reply: @escaping (String?) -> Void) { service.deactivate(uid: uid, reply: reply) }
}
