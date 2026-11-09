// Copyright 2026 DUO你电脑 contributors. SPDX-License-Identifier: Apache-2.0
import SwiftUI
import StreamProtocol

struct PictureQualityPicker: View {
    let title: LocalizedStringResource
    @Binding var bitrate: Int

    var body: some View {
        Picker(selection: $bitrate) {
            ForEach(DuoQualityLabels.presets) { preset in
                Text(DuoQualityLabels.name(forBitrate: preset.rawValue)).tag(preset.rawValue)
            }
        } label: {
            Text(title)
        }
    }
}
