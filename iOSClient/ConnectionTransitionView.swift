// Copyright 2026 DUO你电脑 contributors. SPDX-License-Identifier: Apache-2.0
import SwiftUI

/// Covers only the picture pane until its first usable image, then reveals that image.
struct ConnectionTransitionView: View {
    let preparing: Bool
    let ready: Bool
    @State private var showing = false
    @State private var revealing = false
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        ZStack {
            if preparing || showing {
                let fading = revealing && !preparing
                ZStack {
                    Color(uiColor: .systemBackground)
                        .opacity(fading ? 0 : 1)
                        .animation(.easeOut(duration: 0.75), value: fading)
                    ConnectionAnimationView()
                        .scaleEffect(fading && !reduceMotion ? 1.24 : 1)
                        .opacity(fading ? 0 : 1)
                        .animation(.easeOut(duration: 0.85), value: fading)
                    ConnectionProgressView()
                        .opacity(fading ? 0 : 1)
                        .blur(radius: fading && !reduceMotion ? 5 : 0)
                        .animation(.easeOut(duration: 0.28), value: fading)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .contentShape(.rect)
                .allowsHitTesting(preparing)
                .accessibilityHidden(!preparing)
            }
        }
        .clipped()
        .task(id: preparing) { await updatePresentation() }
    }

    @MainActor private func updatePresentation() async {
        if preparing {
            showing = true
            revealing = false
            return
        }
        guard showing else { return }
        revealing = true
        do {
            try await Task.sleep(for: .seconds(ready && !reduceMotion ? 0.85 : 0.2))
        } catch { return }
        showing = false
        revealing = false
    }
}
