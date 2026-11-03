// Copyright 2026 DUO你电脑 contributors. SPDX-License-Identifier: Apache-2.0
import Foundation

/// A nil CoreGraphics stream can be transient while a new desktop is settling. Retry once, and
/// only while the exact desktop request and its display are still current. Other errors retain
/// their existing failure handling; this never lowers resolution or changes a display mode.
@MainActor
enum CaptureStartupRetry {
    static func isStreamUnavailable(_ error: any Error) -> Bool {
        let failure = error as NSError
        return failure.domain == "CoreGraphicsErrorDomain" && failure.code == 1003
    }

    static func run(enabled: Bool, isCurrent: () -> Bool, canRetry: () -> Bool,
                    wait: () async throws -> Void = { try await Task.sleep(for: .milliseconds(300)) },
                    attempt: () async throws -> Void) async throws {
        guard isCurrent() else { throw CancellationError() }
        do {
            try await attempt()
        } catch {
            guard enabled, isStreamUnavailable(error), isCurrent(), canRetry() else { throw error }
            print("Capture startup: CoreGraphics stream unavailable; retrying once.")
            try await wait()
            guard isCurrent(), canRetry() else { throw error }
            try await attempt()
        }
        // A newer choice can arrive while either asynchronous attempt is starting. Its caller
        // must stop the now-stale stream instead of publishing it as the active desktop.
        guard isCurrent() else { throw CancellationError() }
    }
}
