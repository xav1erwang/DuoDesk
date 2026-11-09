// Copyright 2026 DUO你电脑 contributors. SPDX-License-Identifier: Apache-2.0
import StreamProtocol

/// The root login host must never launch applications, execute menu commands, create virtual
/// desktops, change settings, or expose clipboard/Touch Bar functions on behalf of a client.
enum LoginWindowPolicy {
    static func permits(_ kind: StreamMessageKind) -> Bool {
        switch kind {
        case .selectSource, .input, .viewport, .ping, .clientStats, .displayPreviewRequest: return true
        default: return false
        }
    }
    static func permits(_ source: StreamSource) -> Bool {
        switch source {
        case .desktop, .none: return true
        case .window: return false
        }
    }
}
