// Copyright 2026 DUO你电脑 contributors. SPDX-License-Identifier: Apache-2.0
import Foundation
import Security
import StreamProtocol

@main
enum BootServiceChecks {
    static func main() throws {
        let key = RemoteKey.generate()!
        let original = HostIdentity(privateKey: key, recognitionKey: Data(repeating: 7, count: 32))!
        let phone = PairedDevice(fingerprint: Base64URL.encode(Data(repeating: 3, count: 32)),
                                 name: "Test phone", model: nil, pairedAt: 1, method: "code")
        let snapshot = BootIdentity(privateKey: RemoteKey.export(key)!, recognitionKey: original.recognitionKey, paired: [phone])
        let decoded = try JSONDecoder().decode(BootIdentity.self, from: JSONEncoder().encode(snapshot))
        try decoded.validate()
        let store = try BootIdentityStore(decoded)
        let restored = HostIdentity(privateKey: try store.loadOrCreateKey(), recognitionKey: try store.loadOrCreateRecognitionKey())!
        precondition(restored.macID == original.macID && restored.fingerprint == original.fingerprint)
        let paired = try store.loadPaired()
        let pairingPolicy = try store.loadRequirePairing()
        precondition(paired == [phone])
        precondition(pairingPolicy == RequirePairingValue.on)
        precondition(store.testDirectory == nil)
        expectFailure { try store.savePaired([]) }
        expectFailure { try store.saveRequirePairing(Data("0".utf8)) }

        var damaged = decoded
        damaged.privateKey = Data(repeating: 0, count: 97)
        expectFailure { try damaged.validate() }
        damaged = decoded
        damaged.recognitionKey = Data(repeating: 0, count: 31)
        expectFailure { try damaged.validate() }
        damaged = decoded
        damaged.paired.append(phone)
        expectFailure { try damaged.validate() }
        damaged = decoded
        damaged.paired[0].fingerprint = "invalid"
        expectFailure { try damaged.validate() }
        damaged = decoded
        damaged.paired = Array(repeating: phone, count: 257)
        expectFailure { try damaged.validate() }

        let allowed: Set<StreamMessageKind> = [.selectSource, .input, .viewport, .ping, .clientStats, .displayPreviewRequest]
        for raw in UInt8.min...UInt8.max {
            let kind = StreamMessageKind(rawValue: raw) ?? .unknown
            precondition(LoginWindowPolicy.permits(kind) == allowed.contains(kind))
        }
        precondition(LoginWindowPolicy.permits(.desktop))
        precondition(LoginWindowPolicy.permits(.none))
        precondition(!LoginWindowPolicy.permits(.window(123)))
        print("Boot service: identity continuity, invalid trust rejection, immutable login store and all 256 message kinds passed.")
    }

    static func expectFailure(_ action: () throws -> Void) {
        do { try action(); preconditionFailure("Expected rejection") } catch { }
    }
}
