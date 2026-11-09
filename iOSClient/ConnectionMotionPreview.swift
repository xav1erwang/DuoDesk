// Copyright 2026 DUO你电脑 contributors. SPDX-License-Identifier: Apache-2.0
#if DEBUG
import SwiftUI

/// Native visual preview, selected with -DuoConnectionPreview 1; never opens a connection.
struct ConnectionMotionPreview: View {
    @State private var preparing = true

    var body: some View {
        NavigationStack {
            Text("DUO你电脑")
                .font(.title2.weight(.medium))
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .background(Palette.panel)
                .toolbar {
                    ToolbarItem(placement: .topBarLeading) {
                        DiscoveryRefreshButton(refreshing: true, enabled: true, action: {})
                            .frame(width: 44, height: 44)
                    }
                }
        }
        .overlay { ConnectionTransitionView(preparing: preparing, ready: !preparing) }
        .task {
            do { try await Task.sleep(for: .seconds(6)) } catch { return }
            preparing = false
        }
    }
}

#Preview {
    ConnectionMotionPreview()
}
#endif
