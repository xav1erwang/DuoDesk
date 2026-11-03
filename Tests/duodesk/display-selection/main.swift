import Foundation
import CoreGraphics
import StreamProtocol

var checked = 0
func check(_ value: @autoclosure () -> Bool, _ message: String) {
    guard value() else { fatalError(message) }
    checked += 1
}
func screen(_ id: UInt32, _ x: Double, _ y: Double, main: Bool = false) -> RemoteDisplayInfo {
    RemoteDisplayInfo(id: id, name: "Screen \(id)", isMain: main, x: x, y: y,
                      width: 1920, height: 1080, pixelWidth: 3840, pixelHeight: 2160)
}
let main = screen(5, 0, 0, main: true)
let side = screen(3, -1920, 0)
let viewport = Viewport(width: 669, height: 476, scale: nil, fps: 120,
                        desktopResolution: .init(width: 2007, height: 1427), displayID: 3)
check(viewport.isValid, "selected viewport must be valid")
check(Wire.decode(Viewport.self, from: Wire.encode(viewport)) == viewport, "selection and sizing must travel together")
var invalid = viewport; invalid.displayID = 0
check(!invalid.isValid, "null display is not selectable")
let legacy = Wire.decode(Viewport.self, from: Data(#"{"width":500,"height":400}"#.utf8))
check(legacy?.isValid == true && legacy?.displayID == nil, "old viewport remains compatible")
let list = WindowList(macName: "Mac", windows: [], active: .desktop, displays: [side, main], selectedDisplayID: 5, existingDisplayCapture: true)
let decoded = Wire.decode(WindowList.self, from: Wire.encode(list))
check(decoded?.displays == [side, main] && decoded?.selectedDisplayID == 5, "catalog preserves names, primary and arrangement")
check(decoded?.existingDisplayCapture == true, "existing-display capture must be advertised before video")
let old = Wire.decode(WindowList.self, from: Data(#"{"macName":"Mac","windows":[],"active":{"desktop":{}}}"#.utf8))
check(old != nil && old?.displays == nil, "old catalog remains compatible")
check(old?.existingDisplayCapture == nil, "older hosts keep their existing native-size policy")
for size in [CGSize(width: 360, height: 240), CGSize(width: 780, height: 280)] {
    for displays in [[side, main], [main, screen(6, 1920, 0)], [screen(7, 0, -1080), main],
                     [side, main, screen(8, 1920, 0), screen(9, 0, 1080)]] {
        let frames = RemoteDisplayInfo.arrangement(displays, in: size)
        check(frames.count == displays.count, "all connected desktops have one tile")
        check(frames[5]?.midX == size.width / 2 && frames[5]?.midY == size.height / 2, "main must stay centered")
        for display in displays {
            guard let rect = frames[display.id], let primary = frames[5] else { fatalError("missing tile") }
            check(rect.minX >= 11.99 && rect.maxX <= size.width - 11.99 && rect.minY >= 11.99 && rect.maxY <= size.height - 11.99,
                  "arrangement must fit the device")
            check(abs(rect.width / rect.height - 16 / 9.0) < 0.00001, "display previews preserve aspect")
            check((display.x < 0) == (rect.midX < primary.midX), "left-side layout preserved")
            check((display.y < 0) == (rect.midY < primary.midY), "above layout preserved")
        }
    }
}
check(RemoteDisplayInfo.arrangement([main, main], in: CGSize(width: 300, height: 200)).isEmpty, "duplicate IDs rejected")
check(RemoteDisplayInfo.arrangement([], in: CGSize(width: 300, height: 200)).isEmpty, "empty layout is safe")
let jpeg = Data([0xFF, 0xD8, 0xFF, 0xD9])
let blob = ImageBlob.encodeThumbnail(windowID: 5, jpeg: jpeg)
check(ImageBlob.decodeThumbnail(blob)?.windowID == 5 && ImageBlob.decodeThumbnail(blob)?.jpeg == jpeg,
      "display preview identity survives the wire")
check(StreamMessageKind.displayThumbnail.rawValue != StreamMessageKind.thumbnail.rawValue, "display and window previews cannot collide")
print("PASS: \(checked) display protocol and arrangement checks")
