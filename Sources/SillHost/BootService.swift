// Copyright 2026 DUO你电脑 contributors. SPDX-License-Identifier: Apache-2.0
import Foundation
import Security
import ServiceManagement
import StreamProtocol

@objc package protocol BootServiceProtocol {
    func readIdentity(reply: @escaping (Data?, String?) -> Void)
    func configure(_ identity: Data, reply: @escaping (String?) -> Void)
    func updateTrust(_ devices: Data, reply: @escaping (String?) -> Void)
    func deactivate(reply: @escaping (String?) -> Void)
}

package enum BootService {
    package static let daemonPlist = "com.duodesk.host.boot.plist"
    package static let sessionPlist = "com.duodesk.host.session.plist"
    package static let machService = "com.duodesk.host.boot"
    package static let loginLabel = "com.duodesk.host.login-window"
    package static let directory = URL(fileURLWithPath: "/Library/Application Support/DUO你电脑", isDirectory: true)
    package static var identityURL: URL { directory.appendingPathComponent("identity.json") }
    package static var loginApp: URL { directory.appendingPathComponent("LoginHost.app", isDirectory: true) }
    package static var loginPlist: URL { URL(fileURLWithPath: "/Library/LaunchAgents/\(loginLabel).plist") }

    /// XPC checks the signature of every message, rather than trusting a reusable process ID.
    /// Ad-hoc builds cannot install a privileged service with a stable peer identity.
    package static func signingRequirement() throws -> String {
        var code: SecCode?
        var staticCode: SecStaticCode?
        var information: CFDictionary?
        guard SecCodeCopySelf([], &code) == errSecSuccess, let code,
              SecCodeCopyStaticCode(code, [], &staticCode) == errSecSuccess, let staticCode,
              SecCodeCopySigningInformation(staticCode, SecCSFlags(rawValue: kSecCSSigningInformation), &information) == errSecSuccess,
              let info = information as? [String: Any],
              let team = info[kSecCodeInfoTeamIdentifier as String] as? String,
              team.count == 10, team.allSatisfy({ $0.isASCII && ($0.isUppercase || $0.isNumber) }) else {
            throw IdentityStoreError("开机服务需要使用稳定的 Apple 签名构建。")
        }
        return "anchor apple generic and identifier \"com.duodesk.host\" and certificate leaf[subject.OU] = \"\(team)\""
    }

    package static var enabled: Bool { SMAppService.daemon(plistName: daemonPlist).status == .enabled }
}

/// Sent only over authenticated local XPC; persisted by root in a private system directory.
/// It keeps the same TLS identity and recognition key across login-window/user-session handoff.
package struct BootIdentity: Codable, Sendable {
    package var privateKey: Data
    package var recognitionKey: Data
    package var paired: [PairedDevice]

    package init(privateKey: Data, recognitionKey: Data, paired: [PairedDevice]) {
        self.privateKey = privateKey
        self.recognitionKey = recognitionKey
        self.paired = paired
    }

    package func validate() throws {
        guard privateKey.count <= 256, recognitionKey.count == 32,
              let key = RemoteKey.importPrivate(privateKey), HostIdentity(privateKey: key, recognitionKey: recognitionKey) != nil,
              paired.count <= 256, paired.allSatisfy({ $0.fingerprintData != nil }),
              Set(paired.map(\.fingerprint)).count == paired.count else {
            throw IdentityStoreError("开机服务的身份或配对资料无效。")
        }
    }

    package var fingerprint: Data? { RemoteKey.importPrivate(privateKey).flatMap { RemoteIdentity(privateKey: $0)?.fingerprint } }
}

/// The login-window host cannot create identities, pair devices, or widen access.
package final class BootIdentityStore: IdentityStore {
    private let identity: BootIdentity
    package init(_ identity: BootIdentity) throws { try identity.validate(); self.identity = identity }
    package var summary: String { "in the protected boot service" }
    package var testDirectory: URL? { nil }
    package func loadOrCreateKey() throws -> SecKey {
        guard let key = RemoteKey.importPrivate(identity.privateKey) else { throw IdentityStoreError("开机服务密钥无效。") }
        return key
    }
    package func loadOrCreateRecognitionKey() throws -> Data { identity.recognitionKey }
    package func loadPaired() throws -> [PairedDevice] { identity.paired }
    package func loadRequirePairing() throws -> Data? { RequirePairingValue.on }
    package func savePaired(_ devices: [PairedDevice]) throws { throw IdentityStoreError("请登录 Mac 后修改配对。") }
    package func saveRequirePairing(_ record: Data) throws { throw IdentityStoreError("登录窗口必须要求配对。") }
}

/// Used only for infrequent identity operations. Replies are bounded even if the daemon stops.
/// Bootstrap calls run off the main actor; steady streaming never calls this bridge.
package enum BootServiceRPC {
    private final class ResultBox: @unchecked Sendable {
        let lock = NSLock()
        var value: Result<Data?, Error>?
        func finish(_ result: Result<Data?, Error>, semaphore: DispatchSemaphore) {
            lock.lock()
            if value == nil { value = result; semaphore.signal() }
            lock.unlock()
        }
    }

    private static func call(_ invoke: (BootServiceProtocol, @escaping (Data?, String?) -> Void) -> Void) throws -> Data? {
        let connection = NSXPCConnection(machServiceName: BootService.machService, options: .privileged)
        connection.remoteObjectInterface = NSXPCInterface(with: BootServiceProtocol.self)
        connection.setCodeSigningRequirement(try BootService.signingRequirement())
        let semaphore = DispatchSemaphore(value: 0)
        let box = ResultBox()
        let fail: @Sendable (Error) -> Void = { error in box.finish(.failure(error), semaphore: semaphore) }
        connection.invalidationHandler = { fail(IdentityStoreError("开机服务连接已中断。")) }
        connection.interruptionHandler = { fail(IdentityStoreError("开机服务暂时不可用。")) }
        connection.resume()
        defer { connection.invalidate() }
        guard let proxy = connection.remoteObjectProxyWithErrorHandler(fail) as? BootServiceProtocol else {
            throw IdentityStoreError("无法连接开机服务。")
        }
        invoke(proxy) { data, problem in
            box.finish(problem.map { .failure(IdentityStoreError($0)) } ?? .success(data), semaphore: semaphore)
        }
        guard semaphore.wait(timeout: .now() + 8) == .success else { throw IdentityStoreError("开机服务未响应，请在系统设置中确认已允许它运行。") }
        box.lock.lock(); defer { box.lock.unlock() }
        return try box.value!.get()
    }

    package static func read() throws -> BootIdentity? {
        guard let data = try call({ $0.readIdentity(reply: $1) }) else { return nil }
        guard data.count <= 262_144 else { throw IdentityStoreError("开机服务资料过大。") }
        let value = try JSONDecoder().decode(BootIdentity.self, from: data)
        try value.validate()
        return value
    }
    package static func configure(_ identity: BootIdentity) throws {
        try identity.validate()
        let data = try JSONEncoder().encode(identity)
        _ = try call { proxy, reply in proxy.configure(data) { reply(nil, $0) } }
    }
    package static func updateTrust(_ devices: [PairedDevice]) throws {
        let data = try JSONEncoder().encode(devices)
        _ = try call { proxy, reply in proxy.updateTrust(data) { reply(nil, $0) } }
    }
    package static func deactivate() throws {
        _ = try call { proxy, reply in proxy.deactivate { reply(nil, $0) } }
    }
}

/// Persist locally before acknowledging a system-service update. Bootstrap reconciles the
/// protected copy with the keychain, including changes made while the service was unregistered.
package final class BootMirroredIdentityStore: IdentityStore {
    private let local: any IdentityStore
    private var key: SecKey?
    private var recognition: Data?
    package init(local: any IdentityStore) { self.local = local }
    package var summary: String { local.summary }
    package var testDirectory: URL? { nil }
    package func loadOrCreateKey() throws -> SecKey {
        let value = try local.loadOrCreateKey(); key = value; return value
    }
    package func loadOrCreateRecognitionKey() throws -> Data {
        let value = try local.loadOrCreateRecognitionKey(); recognition = value; return value
    }
    package func loadPaired() throws -> [PairedDevice] {
        let devices = try local.loadPaired()
        guard BootService.enabled, let boot = try BootServiceRPC.read() else { return devices }
        guard let key, let recognition, let identity = HostIdentity(privateKey: key, recognitionKey: recognition),
              identity.fingerprint == boot.fingerprint, recognition == boot.recognitionKey else {
            throw IdentityStoreError("开机服务与当前 Mac 的身份不一致，请关闭开机服务后重试。")
        }
        if boot.paired != devices { try BootServiceRPC.updateTrust(devices) }
        return devices
    }
    package func savePaired(_ devices: [PairedDevice]) throws {
        let status = SMAppService.daemon(plistName: BootService.daemonPlist).status
        if status == .requiresApproval {
            throw IdentityStoreError("请先在系统设置中允许开机服务运行，或在 DUO 设置中关闭开机服务，再修改配对。")
        }
        if BootService.enabled, try BootServiceRPC.read() != nil {
            try local.savePaired(devices)
            try BootServiceRPC.updateTrust(devices)
        } else { try local.savePaired(devices) }
    }
    package func loadRequirePairing() throws -> Data? { try local.loadRequirePairing() }
    package func saveRequirePairing(_ record: Data) throws { try local.saveRequirePairing(record) }
}
