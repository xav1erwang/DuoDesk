// Copyright 2026 DUO你电脑 contributors. SPDX-License-Identifier: Apache-2.0
import Foundation

/// Kind 23 on the probe ALPN only. No catalog, display preparation or control session is opened.
public struct LocalPathProbeReply: Codable, Sendable {
    public static let generation = 1
    public static let txtKey = "lp"
    public let version: Int
    public let launchID: String

    public init(launchID: String) {
        version = Self.generation
        self.launchID = launchID
    }
}
