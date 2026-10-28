// Copyright 2026 DUO你电脑 contributors. SPDX-License-Identifier: Apache-2.0
import SwiftUI

/// The picture frame stays structurally stable as the native resolution is negotiated, so it
/// does not replace the video view or its input overlay.
struct DesktopPictureChrome: ViewModifier {
    let native: Bool

    func body(content: Content) -> some View {
        // A native desktop must retain the pixels at all four corners and along the edges.
        // Vary values, not the view hierarchy, when native metrics become available.
        let shape = RoundedRectangle(cornerRadius: native ? 0 : 12, style: .continuous)
        content
            .clipShape(shape)
            .overlay(shape.strokeBorder(Color.white.opacity(native ? 0 : 0.09), lineWidth: 1))
    }
}
