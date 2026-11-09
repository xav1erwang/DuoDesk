// Copyright 2026 DUO你电脑 contributors. SPDX-License-Identifier: Apache-2.0
import Foundation

public struct DuoDiagnosticReport: Encodable, Sendable {
    public let capturedAt: Date
    public let appVersion: String
    public let build: String
    public let system: String
    public let loggingEnabled: Bool
    public let userDescription: String
    public let log: String
    public let storageError: String?

    public func data() throws -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        encoder.dateEncodingStrategy = .iso8601
        return try encoder.encode(self)
    }
}
