// Copyright 2026 DUO你电脑 contributors. SPDX-License-Identifier: Apache-2.0
import Foundation
import StreamProtocol

/// A private display stream's borrowed IOSurface cannot simply be retained beyond its callback
/// without observing its use-count contract. No real backend is enabled until verified.
@MainActor protocol TouchBarCaptureSource: AnyObject {
    /// A capture-only backend stays read-only even when macOS Accessibility is authorized.
    var supportsInput: Bool { get }
    /// These operations must return promptly; capture callbacks may arrive on a separate queue.
    /// In particular, post must never block or call back into StreamServer's network queue:
    /// its admission lock also serializes network-side subscription revocation.
    func start(onFrame: @escaping @Sendable (TouchBarCapturedFrame) -> Void,
               onStopped: @escaping @Sendable () -> Void) throws
    func post(_ touch: TouchBarTouch) -> Bool
    /// Must invalidate the source's held contact even if Accessibility was revoked mid-touch.
    func stop()
}
