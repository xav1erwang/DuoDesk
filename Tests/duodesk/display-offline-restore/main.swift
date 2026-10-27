// Copyright 2026 DUO你电脑 contributors. SPDX-License-Identifier: Apache-2.0
// Tests the real restoration state with an invalid ID; no display configuration is applied.
import Foundation

let result = MainActor.assumeIsolated { DuoDesktopDisplay.inspectOfflineRestoreForTesting() }
guard let (first, keptAfterFirst, second, keptAfterSecond) = result else {
    fputs("FAIL: read-only display prerequisites unavailable\n", stderr); exit(1)
}
guard !first, keptAfterFirst, !second, keptAfterSecond else {
    fputs("FAIL: missing display should remain pending; first=\(first), retained=\(keptAfterFirst), second=\(second), retainedAgain=\(keptAfterSecond)\n", stderr)
    exit(1)
}
let groups = MainActor.assumeIsolated { DuoDesktopDisplay.inspectPendingMirrorGroupsForTesting() }
guard groups == [[101, 102], [101, 102], [103]] else {
    fputs("FAIL: pending mirror groups did not retain their master and slave together\n", stderr); exit(1)
}
print("PASS: pending mirror groups retain both members and release unrelated restored screens")
print("PASS: unavailable original display remains pending across restore attempts")
let snapshots = MainActor.assumeIsolated { DuoDesktopDisplay.inspectSnapshotStabilityForTesting() }
guard let snapshots, snapshots.count == 10, snapshots.allSatisfy({ $0 }),
      MainActor.assumeIsolated({ DuoDesktopDisplay.inspectLiveSnapshotForTesting() }) else {
    fputs("FAIL: display snapshot stability or read-only live inventory\n", stderr); exit(1)
}
print("PASS: stable snapshot rejects added, removed, moved, mirrored, replaced, duplicate, empty, zero and unreadable displays")
print("PASS: current live display inventory and identity counts are complete and stable")
guard MainActor.assumeIsolated({ DuoDesktopDisplay.inspectSystemMainVerificationForTesting() }) == true else {
    fputs("FAIL: original system main display must remain pending if it changes\n", stderr); exit(1)
}
print("PASS: original system main is verified and a stale unsaved main is ignored")
guard let identityGuards = MainActor.assumeIsolated({ DuoDesktopDisplay.inspectRestoreIdentityGuardForTesting() }),
      identityGuards.count == 6, identityGuards.allSatisfy({ $0 }) else {
    fputs("FAIL: real restore identity guard or intercepted configuration\n", stderr); exit(1)
}
print("PASS: restore rejects changed, serial-less, duplicate and unstable identities, including replacement during restore; unique recovery is permitted with configuration intercepted")
Task { @MainActor in
    guard await DuoDesktopDisplay.inspectBlockedPrepareForTesting() == true else {
        fputs("FAIL: a new native desktop should report pending restoration\n", stderr); exit(1)
    }
    print("PASS: a new native desktop reports pending restoration; no display configuration was applied")
    exit(0)
}
dispatchMain()
