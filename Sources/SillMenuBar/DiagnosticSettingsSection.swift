// Copyright 2026 DUO你电脑 contributors. SPDX-License-Identifier: Apache-2.0
import SwiftUI
import StreamProtocol

struct DiagnosticSettingsSection: View {
    @AppStorage(DuoDiagnostics.enabledKey) private var enabled = true

    var body: some View {
        Section {
            Toggle("日志", isOn: $enabled)
            Footnote(DuoDiagnostics.notice)
            Button("采集日志…") { FeedbackWindowController.shared.show() }
        }
        .onChange(of: enabled) { _, value in DuoDiagnostics.shared.setEnabled(value) }
    }
}
