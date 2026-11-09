// Copyright 2026 DUO你电脑 contributors. SPDX-License-Identifier: Apache-2.0
import SwiftUI

/// A diffuse color field. Only this illustration redraws while the connection prepares.
struct ConnectionAnimationView: View {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.colorScheme) private var scheme
    @Environment(\.scenePhase) private var scenePhase

    var body: some View {
        TimelineView(.animation(minimumInterval: 1.0 / 30,
                                paused: reduceMotion || scenePhase != .active)) { timeline in
            Canvas { context, size in
                let time = reduceMotion ? 0 : timeline.date.timeIntervalSinceReferenceDate / 7
                let colors = [Color(red: 0.47, green: 0.64, blue: 0.95),
                              Color(red: 0.69, green: 0.58, blue: 0.90),
                              Color(red: 0.91, green: 0.64, blue: 0.75),
                              Color(red: 0.48, green: 0.79, blue: 0.81)]
                let bounds = CGRect(origin: .zero, size: size)
                let radius = max(size.width, size.height) * 0.72
                for index in colors.indices {
                    let phase = time + Double(index) * .pi / 2
                    let center = CGPoint(x: size.width * (0.5 + 0.42 * cos(phase)),
                                         y: size.height * (0.5 + 0.38 * sin(phase * 0.8)))
                    let strength = scheme == .dark ? 0.22 : 0.30
                    context.fill(Path(bounds), with: .radialGradient(
                        Gradient(stops: [.init(color: colors[index].opacity(strength), location: 0),
                                         .init(color: colors[index].opacity(strength * 0.35), location: 0.48),
                                         .init(color: .clear, location: 1)]),
                        center: center, startRadius: 0, endRadius: radius))
                }
            }
        }
        .accessibilityHidden(true)
    }
}
