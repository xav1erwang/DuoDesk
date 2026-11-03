import SwiftUI
import StreamProtocol

struct DisplayPicker: View {
    @ObservedObject var client: StreamClient

    var body: some View {
        NavigationStack {
            ScrollView {
                DisplayArrangementCanvas(displays: client.remoteDisplays, previews: client.displayThumbnails,
                                         selected: client.selectedDisplayID, select: client.chooseDisplay)
                    .frame(height: 280)
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
                            DisplayPreview(image: previews[display.id], selected: selected == display.id)
                        }
                        .buttonStyle(.plain)
                        .frame(width: frame.width, height: frame.height)
                        .overlay(alignment: .topLeading) {
                            VStack(alignment: .leading, spacing: 3) {
                                Text(display.name).font(.subheadline.weight(.medium)).lineLimit(1)
                                    .minimumScaleFactor(0.75)
                                if display.isMain {
                                    Text("主显示器").font(.caption2.weight(.medium)).foregroundStyle(.secondary)
                                }
                            }
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .alignmentGuide(.top) { $0[.bottom] + 8 }
                            .allowsHitTesting(false)
                        }
                        .position(x: frame.midX, y: frame.midY)
                        .accessibilityLabel(display.name + (display.isMain ? "，主显示器" : ""))
                        .accessibilityIdentifier("display-\(display.id)")
                        .accessibilityAddTraits(selected == display.id ? [.isSelected] : [])
                    }
                }
            }
        }
    }
}

private struct DisplayPreview: View {
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
        }
        .clipShape(.rect(cornerRadius: 8))
        .overlay {
            RoundedRectangle(cornerRadius: 8)
                .strokeBorder(selected ? Color.accentColor : .white.opacity(0.35), lineWidth: selected ? 3 : 1)
        }
    }
}
