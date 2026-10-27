// Copyright 2026 DUO你电脑 contributors. SPDX-License-Identifier: Apache-2.0
/// Window restoration can block in Accessibility. Restore the desktop first so the process's
/// shutdown watchdog cannot exit while that unrelated work still holds the display configuration.
enum ShutdownRestoreOrder {
    static func run(display: () -> Void, windows: () -> Void, stage: () -> Void) {
        display()
        windows()
        stage()
    }
}
