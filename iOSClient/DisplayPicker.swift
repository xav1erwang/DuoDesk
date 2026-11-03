import SwiftUI
import StreamProtocol

struct DisplayPicker: View {
    @ObservedObject var client: StreamClient
    @State private var choice: UInt32?

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(spacing: 24) {
                    DisplayArrangementCanvas(displays: client.remoteDisplays, previews: client.displayThumbnails,
                                             selected: choice, select: { choice = $0 })
                        .frame(height: 240)
                    VStack(spacing: 8) {
                        ForEach(client.remoteDisplays) { display in
                            Button {
                                choice = display.id
                            } label: {
                                HStack(spacing: 12) {
                                    Image(systemName: choice == display.id ? "checkmark.circle.fill" : "circle")
                                        .foregroundStyle(choice == display.id ? Color.accentColor : .secondary)
                                    VStack(alignment: .leading, spacing: 3) {
                                        Text(display.name).foregroundStyle(.primary)
                                        Text("\(display.pixelWidth.formatted(.number.grouping(.never))) × \(display.pixelHeight.formatted(.number.grouping(.never)))")
                                            .font(.caption.monospacedDigit()).foregroundStyle(.secondary)
                                    }
                                    Spacer(minLength: 0)
                                    if display.isMain { Text("主显示器").font(.caption).foregroundStyle(.secondary) }
                                }
                                .padding(12)
                                .frame(maxWidth: .infinity, minHeight: 44)
                                .background(.quaternary, in: .rect(cornerRadius: 12))
                                .contentShape(.rect)
                            }
                            .buttonStyle(.plain)
                            .accessibilityAddTraits(choice == display.id ? [.isSelected] : [])
                        }
                    }
                    Button(client.awaitingDisplaySelection ? "开始串流" : "切换显示器") {
                        if let choice { client.chooseDisplay(choice) }
                    }
                    .buttonStyle(.borderedProminent)
                    .controlSize(.large)
                    .disabled(!client.remoteDisplays.contains(where: { $0.id == choice }))
                }
                .padding(20)
            }
            .navigationTitle("选择显示器")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("取消") {
                        if client.awaitingDisplaySelection { client.disconnect() }
                        else { client.displayPickerPresented = false }
                    }
                }
            }
        }
        .preferredColorScheme(.dark)
        .interactiveDismissDisabled(client.awaitingDisplaySelection)
        .presentationDetents([.medium, .large])
        .onAppear { resetChoice() }
        .onChange(of: client.remoteDisplays) { _, displays in
            if !displays.contains(where: { $0.id == choice }) { resetChoice() }
        }
    }

    private func resetChoice() {
        choice = client.remoteDisplays.first(where: { $0.id == client.selectedDisplayID })?.id
            ?? client.remoteDisplays.first(where: \.isMain)?.id ?? client.remoteDisplays.first?.id
    }
}

private struct DisplayArrangementCanvas: View {
    let displays: [RemoteDisplayInfo]
    let previews: [UInt32: UIImage]
    let selected: UInt32?
    let select: (UInt32) -> Void

    var body: some View {
        GeometryReader { geometry in
            let frames = RemoteDisplayInfo.arrangement(displays, in: geometry.size)
            ZStack {
                ForEach(displays) { display in
                    if let frame = frames[display.id] {
                        Button { select(display.id) } label: {
                            DisplayPreview(display: display, image: previews[display.id], selected: selected == display.id)
                        }
                        .buttonStyle(.plain)
                        .frame(width: frame.width, height: frame.height)
                        .position(x: frame.midX, y: frame.midY)
                        .accessibilityLabel(display.name + (display.isMain ? "，主显示器" : ""))
                        .accessibilityAddTraits(selected == display.id ? [.isSelected] : [])
                    }
                }
            }
        }
    }
}

private struct DisplayPreview: View {
    let display: RemoteDisplayInfo
    let image: UIImage?
    let selected: Bool

    var body: some View {
        ZStack {
            Color.black
            if let image {
                Image(uiImage: image).resizable().scaledToFit()
            } else {
                ProgressView().controlSize(.small)
            }
            if display.isMain {
                VStack {
                    HStack {
                        Text("主显示器").font(.caption2.weight(.semibold))
                            .padding(.horizontal, 5).padding(.vertical, 2)
                            .background(.ultraThinMaterial, in: .capsule)
                        Spacer(minLength: 0)
                    }
                    Spacer(minLength: 0)
                }
                .padding(5)
            }
        }
        .clipShape(.rect(cornerRadius: 8))
        .overlay {
            RoundedRectangle(cornerRadius: 8)
                .strokeBorder(selected ? Color.accentColor : .white.opacity(0.35), lineWidth: selected ? 3 : 1)
        }
    }
}
