// Copyright 2026 DUO你电脑 contributors. SPDX-License-Identifier: Apache-2.0
import AppKit
import SwiftUI
import UniformTypeIdentifiers
import StreamProtocol

@MainActor
final class FeedbackWindowController: NSWindowController {
    static let shared = FeedbackWindowController()

    private init() {
        let window = NSWindow(contentViewController: NSHostingController(rootView: DiagnosticFeedbackView()))
        window.title = "用户反馈"
        window.styleMask = [.titled, .closable]
        window.isReleasedWhenClosed = false
        super.init(window: window)
        window.center()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("not from a nib") }

    func show() {
        guard let window else { return }
        WindowPlacement.bringForward(window)
    }

    @objc func open(_ sender: Any?) { show() }
}

struct DiagnosticFeedbackView: View {
    @State private var description = ""
    @State private var preparing = false
    @State private var exporting = false
    @State private var document: DiagnosticLogDocument?
    @State private var failure: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("问题描述（选填）")
            TextEditor(text: $description)
                .font(.body)
                .frame(height: 120)
                .overlay(RoundedRectangle(cornerRadius: 6).stroke(.separator))
                .accessibilityLabel("问题描述（选填）")
            if let failure {
                Text(failure).font(.callout).foregroundStyle(.red)
            }
            HStack {
                Spacer()
                if preparing { ProgressView().controlSize(.small) }
                Button("采集日志", action: capture)
                    .keyboardShortcut(.defaultAction)
                    .disabled(preparing)
            }
        }
        .padding(20)
        .frame(width: 400)
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
