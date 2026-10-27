// Copyright 2026 DUO你电脑 contributors. SPDX-License-Identifier: Apache-2.0
import AppKit

setbuf(stdout, nil)
let app = NSApplication.shared
app.setActivationPolicy(.regular)
let delegate = MainActor.assumeIsolated { DocumentWorkload() }
app.delegate = delegate
app.run()
