// Native rendering fixture: compiles the production DisplayPicker view, with no network or Mac input.
import SwiftUI
import UIKit
import StreamProtocol

@MainActor final class StreamClient: ObservableObject {
    @Published var remoteDisplays: [RemoteDisplayInfo] = [
        .init(id: 3, name: "Mi Monitor", isMain: false, x: -1920, y: 0, width: 1920, height: 1080, pixelWidth: 3840, pixelHeight: 2160),
        .init(id: 5, name: "MAG 274U E16M", isMain: true, x: 0, y: 0, width: 1920, height: 1080, pixelWidth: 3840, pixelHeight: 2160)
    ]
    @Published var displayThumbnails: [UInt32: UIImage] = [:]
    @Published var selectedDisplayID: UInt32? = nil
    @Published var awaitingDisplaySelection = true
    @Published var displayPickerPresented = true
    init() {
        for (id, color) in [(UInt32(3), UIColor.systemIndigo), (UInt32(5), UIColor.systemTeal)] {
            displayThumbnails[id] = UIGraphicsImageRenderer(size: CGSize(width: 480, height: 270)).image { context in
                color.setFill(); context.fill(CGRect(x: 0, y: 0, width: 480, height: 270))
                UIColor.white.withAlphaComponent(0.85).setFill()
                context.fill(CGRect(x: 0, y: 0, width: 480, height: 14))
                context.fill(CGRect(x: 60, y: 45, width: 260, height: 165))
            }
        }
    }
    func chooseDisplay(_ id: UInt32) { selectedDisplayID = id; awaitingDisplaySelection = false; displayPickerPresented = false; print("FIXTURE selected \(id)") }
    func disconnect() { print("FIXTURE cancel"); displayPickerPresented = false }
}

@main struct PickerFixture: App {
    @StateObject private var client = StreamClient()
    var body: some Scene {
        WindowGroup {
            VStack {
                Text("Selected: \(client.selectedDisplayID.map(String.init) ?? "none")").accessibilityIdentifier("selection-result")
                Button("显示器") { client.displayPickerPresented = true }
            }
            .sheet(isPresented: $client.displayPickerPresented) { DisplayPicker(client: client) }
        }
    }
}
