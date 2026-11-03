// Copyright 2026 DUO你电脑 contributors. SPDX-License-Identifier: Apache-2.0
// The failure is injected before any real display-configuration call.
import Foundation

guard let checks = MainActor.assumeIsolated({ DuoDesktopDisplay.inspectRejectedRestoreForTesting() }),
      checks.count == 2, checks.allSatisfy({ $0 }) else {
    fputs("FAIL: rejected restore must clear only a verified original display state\n", stderr)
    exit(1)
}
print("PASS: rejected configuration with already-restored state clears the stale snapshot")
print("PASS: rejected configuration with a different state retains the snapshot")
print("No display configuration was applied")
