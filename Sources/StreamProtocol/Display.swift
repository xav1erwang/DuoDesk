import Foundation
import CoreGraphics

/// A selectable Mac desktop, in the Mac's arrangement coordinates (points, y down).
public struct RemoteDisplayInfo: Codable, Hashable, Identifiable, Sendable {
    public var id: UInt32
    public var name: String
    public var isMain: Bool
    public var x: Double
    public var y: Double
    public var width: Double
    public var height: Double
    public var pixelWidth: Int
    public var pixelHeight: Int

    public init(id: UInt32, name: String, isMain: Bool, x: Double, y: Double,
                width: Double, height: Double, pixelWidth: Int, pixelHeight: Int) {
        self.id = id; self.name = name; self.isMain = isMain
        self.x = x; self.y = y; self.width = width; self.height = height
        self.pixelWidth = pixelWidth; self.pixelHeight = pixelHeight
    }

    public var frame: CGRect { CGRect(x: x, y: y, width: width, height: height) }
    public var isValid: Bool {
        id != 0 && !name.isEmpty && name.utf8.count <= 512
            && x.isFinite && y.isFinite && abs(x) <= 131072 && abs(y) <= 131072
            && width.isFinite && height.isFinite && (1...32768).contains(width) && (1...32768).contains(height)
            && (1...32768).contains(pixelWidth) && (1...32768).contains(pixelHeight)
    }

    /// Keep the main desktop at the center while preserving every display's relative position,
    /// dimensions and aspect. The canvas grows symmetrically around the main display.
    public static func arrangement(_ displays: [Self], in size: CGSize, inset: CGFloat = 12) -> [UInt32: CGRect] {
        let valid = displays.filter(\.isValid)
        guard size.width > inset * 2, size.height > inset * 2,
              let main = valid.first(where: \.isMain) ?? valid.first,
              Set(valid.map(\.id)).count == valid.count else { return [:] }
        let center = CGPoint(x: main.frame.midX, y: main.frame.midY)
        let rx = valid.map { max(abs($0.frame.minX - center.x), abs($0.frame.maxX - center.x)) }.max() ?? 1
        let ry = valid.map { max(abs($0.frame.minY - center.y), abs($0.frame.maxY - center.y)) }.max() ?? 1
        let scale = min((size.width - inset * 2) / (rx * 2), (size.height - inset * 2) / (ry * 2))
        var frames: [UInt32: CGRect] = [:]
        for display in valid {
            let frame = display.frame
            let x = size.width / 2 + (frame.minX - center.x) * scale
            let y = size.height / 2 + (frame.minY - center.y) * scale
            frames[display.id] = CGRect(x: x, y: y, width: frame.width * scale, height: frame.height * scale)
        }
        return frames
    }
}
