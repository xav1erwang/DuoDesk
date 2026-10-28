// Copyright 2026 DUO你电脑 contributors. SPDX-License-Identifier: Apache-2.0
import SwiftUI

/// Keep the video representable structurally stable when an actual source becomes available.
/// Decorative placeholder chrome must never cover the real bar's edge pixels or take touches.
struct TouchBarPictureChrome: ViewModifier {
    let showingPicture: Bool

    func body(content: Content) -> some View {
        let shape = RoundedRectangle(cornerRadius: showingPicture ? 0 : 9)
        content
            .clipShape(shape)
            .overlay(shape.strokeBorder(Color.white.opacity(showingPicture ? 0 : 0.2), lineWidth: 0.5)
                .allowsHitTesting(false))
    }
}
