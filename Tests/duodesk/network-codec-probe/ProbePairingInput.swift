// Copyright 2026 DUO你电脑 contributors. SPDX-License-Identifier: Apache-2.0
import CryptoKit
import Foundation
import StreamProtocol

/// Reads the existing QR input or a typed code from the installed app's normal pairing window.
/// Codes never enter command arguments or logs. Device keys live only in the receiver process.
struct ProbePairingInput {
    let port: Int
    let pin: Data?
    let expectedMacID: String?
    let method: String
    private let code: String?
    private let secret: Data?

    init(path: String, typed: Bool) throws {
        if typed {
            let attributes = try FileManager.default.attributesOfItem(atPath: path)
            guard attributes[.type] as? FileAttributeType == .typeRegular,
                  let mode = attributes[.posixPermissions] as? NSNumber, mode.intValue & 0o077 == 0,
                  let owner = attributes[.ownerAccountID] as? NSNumber, owner.uint32Value == getuid() else {
                throw ProbeError.failed("typed pairing input must be an owned private regular file")
            }
            struct Typed: Decodable { let port: Int; let code: String }
            let input = try JSONDecoder().decode(Typed.self, from: Data(contentsOf: URL(fileURLWithPath: path)))
            guard (1...65535).contains(input.port), case .success(let checked) = PairingCode.check(input.code) else {
                throw ProbeError.failed("typed pairing input has an invalid port or code checksum")
            }
            port = input.port; pin = nil; expectedMacID = nil
            method = PairRequest.code; code = checked; secret = nil
        } else {
            guard case .success(let link) = PairLink.parse(try String(contentsOfFile: path, encoding: .utf8)) else {
                throw ProbeError.failed("invalid QR pairing input")
            }
            port = link.port; pin = link.fingerprint; expectedMacID = link.macID
            method = PairRequest.qr; code = nil; secret = link.secret
        }
    }

    func proofKey(for peer: Data) throws -> SymmetricKey {
        if let code, let key = PairingProof.codeKey(code: code, macFingerprint: peer) { return key }
        if let secret { return PairingProof.qrKey(secret: secret) }
        throw ProbeError.failed("could not derive the pairing proof key")
    }
}
