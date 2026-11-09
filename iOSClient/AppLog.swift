// Copyright 2026 DUO你电脑 contributors. SPDX-License-Identifier: Apache-2.0
import StreamProtocol

/// Keep the client's existing console output and an optional local copy for user feedback.
func print(_ items: Any..., separator: String = " ", terminator: String = "\n") {
    let text = items.map { String(describing: $0) }.joined(separator: separator)
    Swift.print(text, terminator: terminator)
    DuoDiagnostics.shared.record(text)
}
