// Copyright 2026 DUO你电脑 contributors. SPDX-License-Identifier: Apache-2.0
import SwiftUI

struct ConnectionProgressView: View {
    var body: some View {
        Text("正在连接")
            .font(.callout.weight(.medium))
            .tracking(0.5)
            .foregroundStyle(.primary)
            .padding(.horizontal, 26)
            .padding(.vertical, 13)
            .background(.ultraThinMaterial, in: .capsule)
            .overlay {
                Capsule().strokeBorder(.primary.opacity(0.05), lineWidth: 0.5)
            }
            .shadow(color: .black.opacity(0.04), radius: 18, y: 6)
    }
}
