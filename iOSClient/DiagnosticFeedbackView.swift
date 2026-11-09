// Copyright 2026 DUO你电脑 contributors. SPDX-License-Identifier: Apache-2.0
import SwiftUI
import UniformTypeIdentifiers
import StreamProtocol

struct DiagnosticFeedbackView: View {
    @Environment(\.dismiss) private var dismiss
    @State private var description = ""
    @State private var preparing = false
    @State private var exporting = false
    @State private var document: DiagnosticLogDocument?
    @State private var failure: String?

    var body: some View {
        NavigationStack {
            Form {
                Section("问题描述（选填）") {
                    TextEditor(text: $description)
                        .frame(minHeight: 120)
                        .accessibilityLabel("问题描述（选填）")
                }
                Section {
                    Button("采集日志", action: capture).disabled(preparing)
                    if preparing { ProgressView().accessibilityLabel("正在采集日志") }
                    if let failure { Text(failure).foregroundStyle(.red) }
                }
            }
            .navigationTitle("用户反馈")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    PanelCloseButton(label: "关闭") { dismiss() }
                }
            }
        }
        .readsAppearance()
        .fileExporter(isPresented: $exporting, document: document, contentType: .json,
                      defaultFilename: "DUO-logs") { result in
            if case .failure(let error) = result { failure = error.localizedDescription }
        }
    }

    private func capture() {
        preparing = true
        failure = nil
        Task {
            let report = await DuoDiagnostics.shared.capture(description: description)
            do {
                document = DiagnosticLogDocument(data: try report.data())
                exporting = true
            } catch { failure = error.localizedDescription }
            preparing = false
        }
    }
}

struct DiagnosticLogDocument: FileDocument {
    static let readableContentTypes: [UTType] = [.json]
    let data: Data

    init(data: Data) { self.data = data }
    init(configuration: ReadConfiguration) throws {
        guard let data = configuration.file.regularFileContents else { throw CocoaError(.fileReadCorruptFile) }
        self.data = data
    }
    func fileWrapper(configuration: WriteConfiguration) throws -> FileWrapper {
        FileWrapper(regularFileWithContents: data)
    }
}
