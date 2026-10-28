// Copyright 2026 DUO你电脑 contributors. SPDX-License-Identifier: Apache-2.0
// Exercises /dev/stdout plumbing without capturing any screen.
import Foundation

let bytes = Data([0x89, 0x50, 0x4e, 0x47, 1, 2, 3, 4])
do { try bytes.write(to: URL(fileURLWithPath: "/dev/stdout")) }
catch { exit(1) }
