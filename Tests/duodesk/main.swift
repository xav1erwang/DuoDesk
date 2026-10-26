import Foundation
import StreamProtocol

var checks = 0
func check(_ condition: @autoclosure () -> Bool, _ message: String) {
    checks += 1
    guard condition() else { fatalError(message) }
}

let modes = DuoControlMode.allCases
check(InputEvent.key(hidUsage: 0xE3, down: false, modifiers: 0).isRelease, "a modifier can be released during restart")
check(InputEvent.pointer(.leftUp, x: 0, y: 0).isRelease && InputEvent.pointer(.rightUp, x: 0, y: 0).isRelease,
      "both pointer releases can finish a drag during restart")
check(!InputEvent.key(hidUsage: 0xE3, down: true, modifiers: 0).isRelease && !InputEvent.text("x").isRelease,
      "typing and key downs never bypass a stale video fence")
check(!InputEvent.pointer(.leftDown, x: 0, y: 0).isRelease && !InputEvent.pointer(.move, x: 0, y: 0).isRelease,
      "clicks and moves never bypass a stale video fence")
var epochSource = VideoStreamEpoch(), epochReceiver = VideoStreamEpoch()
let firstReset = epochSource.nextReset()
check(firstReset == Data([0, 0, 0, 0, 0, 0, 0, 1]), "video reset has a fixed eight-byte network representation")
check(epochReceiver.acceptReset(firstReset), "a fresh stream invalidates the previous picture")
check(!epochReceiver.acceptReset(firstReset), "a keyframe replay cannot invalidate its own fresh picture")
let secondReset = epochSource.nextReset()
check(epochReceiver.acceptReset(secondReset), "same-size encoder replacement has a distinct epoch")
check(!epochReceiver.acceptReset(firstReset), "a late reset cannot clear a newer stream")
for length in [0, 7, 9] {
    check(!epochReceiver.acceptReset(Data(repeating: 1, count: length)), "malformed video reset is ignored")
}
check(!epochReceiver.acceptReset(Data(repeating: 0, count: 8)), "zero is not a reset epoch")
check(epochReceiver.lastValue == 2, "invalid resets cannot alter the accepted epoch")
var wrappingEpoch = VideoStreamEpoch()
check(wrappingEpoch.acceptReset(Data(repeating: 255, count: 8)), "the counter supports its full unsigned range")
check(wrappingEpoch.acceptReset(firstReset), "serial comparison permits a counter wrap")
check(!wrappingEpoch.acceptReset(Data(repeating: 255, count: 8)), "the old side of a wrap remains stale")
let keyJSON = try JSONEncoder().encode(InputEvent.key(hidUsage: 0x04, down: true, modifiers: 0))
let oldInput = VideoControlPayload(epoch: 1, payload: keyJSON)!
let newInput = VideoControlPayload(epoch: 2, payload: keyJSON)!
check(newInput.encoded.prefix(12) == Data([0x44, 0x55, 0x4F, 0x43, 0, 0, 0, 0, 0, 0, 0, 2]), "input names its video on the wire")
check(VideoControlPayload(encoded: newInput.encoded)?.payload == keyJSON, "tagging preserves the original input JSON")
check(epochReceiver.acceptsControl(newInput), "the active video permits its input")
check(!epochReceiver.acceptsControl(oldInput), "an input already travelling over TCP cannot act on the next video")
check(!epochReceiver.acceptsControl(nil), "native input without a video identity is rejected")
check(VideoControlPayload(encoded: keyJSON) == nil, "legacy JSON is distinguishable from tagged input")
check((0...12).allSatisfy { VideoControlPayload(encoded: Data(newInput.encoded.prefix($0))) == nil }, "truncated input prefixes are rejected")
check(VideoControlPayload(epoch: 0, payload: keyJSON) == nil && VideoControlPayload(epoch: 2, payload: Data()) == nil, "empty input and zero epochs are rejected")
var invalidControl = newInput.encoded
invalidControl[0] = 0
check(VideoControlPayload(encoded: invalidControl) == nil, "a corrupted input marker is rejected")
let maximumInput = VideoControlPayload(epoch: .max, payload: keyJSON)!
check(VideoControlPayload(encoded: maximumInput.encoded)?.epoch == .max, "all eight input epoch bytes survive transport")
epochReceiver.reset()
check(!epochReceiver.acceptsControl(newInput), "disconnect removes the host's input authorization")
check(epochReceiver.acceptReset(firstReset), "a new host connection starts a new epoch sequence")
check(InputEvent.pointer(.move, x: .greatestFiniteMagnitude, y: -.greatestFiniteMagnitude).boundedCoordinates == .pointer(.move, x: 1, y: 0), "huge finite coordinates cannot overflow screen geometry")
check(InputEvent.pointer(.leftDown, x: .nan, y: 0.5).boundedCoordinates == nil, "invalid click coordinates never reach the cursor")
check(InputEvent.scroll(x: 1.2, y: -0.2, dx: 0.1, dy: 0.2).boundedCoordinates == .scroll(x: 1, y: 0, dx: 0.1, dy: 0.2), "scroll locations stay in the desktop")
check(InputEvent.scroll(x: 0.5, y: 0.5, dx: .infinity, dy: 0).boundedCoordinates == nil, "invalid scroll discarded")
check(InputEvent.scrollGesture(.ended, x: -1, y: 2).boundedCoordinates == .scrollGesture(.ended, x: 0, y: 1), "gesture endpoints stay bounded")
let hugeWire = Data(#"{"pointer":{"_0":"leftDown","x":1e308,"y":-1e308}}"#.utf8)
let hugeInput = try JSONDecoder().decode(InputEvent.self, from: hugeWire)
check(hugeInput.boundedCoordinates == .pointer(.leftDown, x: 1, y: 0), "finite hostile JSON is safe before logging and activation")

// A transport burst must recover without decoding a delta after its reference was discarded.
var backlog = VideoDecodeBacklog(frameLimit: 2, byteLimit: 100)
check(backlog.admit(bytes: 10, keyframe: false) == nil, "initial delta waits for keyframe")
let keyTicket = backlog.admit(bytes: 60, keyframe: true)!
let deltaTicket = backlog.admit(bytes: 30, keyframe: false)!
check(backlog.admit(bytes: 20, keyframe: false) == nil, "queue byte/frame ceiling rejects a burst")
check(backlog.waitingForKeyframe && !backlog.isCurrent(keyTicket) && !backlog.isCurrent(deltaTicket), "overflow fences queued and in-flight images")
check(backlog.admit(bytes: 1, keyframe: false) == nil, "no delta accepted after a gap")
backlog.complete(keyTicket); backlog.complete(deltaTicket)
check(backlog.frames == 0 && backlog.bytes == 0, "stale work releases all memory slots")
let recoveredTicket = backlog.admit(bytes: 100, keyframe: true)!
check(backlog.isCurrent(recoveredTicket) && !backlog.waitingForKeyframe, "fresh keyframe resumes the same connection")
backlog.complete(recoveredTicket)
let nextTicket = backlog.admit(bytes: 1, keyframe: false)!
backlog.reset()
check(!backlog.isCurrent(nextTicket), "disconnect fences pending work")
backlog.complete(nextTicket)
check(backlog.admit(bytes: Int.max, keyframe: true) == nil && backlog.bytes == 0, "oversized access unit cannot overflow byte accounting")
check(backlog.admit(bytes: 0, keyframe: true) == nil, "empty access unit rejected")
let native = DuoStreamPolicy.nativeUpperDisplay(width: 2007, height: 2853)!
check(native.width == 2007 && native.height == 1427, "native pixels, not 669-point layout size")
check(native.encodedWidth == 2008 && native.encodedHeight == 1428, "NV12 alignment rounds upward")
check(!native.accepts(width: 1512, height: 948), "reject lower resolution")
check(!native.accepts(width: 3024, height: 1898), "reject the Mac's old aspect ratio even at higher resolution")
check(native.accepts(width: 2008, height: 1428), "exact native desktop canvas")
let innerMetrics = DuoNativeDisplayMetrics(pixels: CGSize(width: 2007, height: 2853), windowSize: CGSize(width: 669, height: 951))
let coverMetrics = DuoNativeDisplayMetrics(pixels: CGSize(width: 1398, height: 2034), windowSize: CGSize(width: 466, height: 678))
let innerFrame = CGRect(x: 0, y: 0, width: 669, height: 951)
let innerFold = CGRect(x: 0, y: 455.5, width: 669, height: 40)
check(DuoStreamPolicy.coherentInnerMetrics(innerMetrics, frame: innerFrame, fold: innerFold), "coherent native inner metrics")
check(!DuoStreamPolicy.coherentInnerMetrics(coverMetrics, frame: innerFrame, fold: innerFold), "a fold animation cannot cache old cover pixels as native inner pixels")
check(!DuoStreamPolicy.coherentInnerMetrics(innerMetrics, frame: innerFrame, fold: nil), "hinge alone cannot identify the active display")
check(DuoStreamPolicy.nativeUpperDisplay(width: 2853, height: 2007) == native, "rotation does not change the native desktop")
check(DuoStreamPolicy.nativeUpperDisplay(width: .infinity, height: 2853) == nil, "reject invalid display metrics")
check(!DuoDesktopResolution(width: Int.max, height: 1427).isValid, "untrusted viewport cannot overflow")
check(DuoDesktopResolution(width: 8191, height: 8191).encodedWidth == 8192, "maximum aligned dimension")
let oldViewport = try JSONDecoder().decode(Viewport.self, from: Data(#"{"width":669,"height":475.5,"scale":null,"fps":120}"#.utf8))
check(oldViewport.desktopResolution == nil, "old viewport remains decodable")
let request = Viewport(width: 669, height: 475.5, scale: nil, fps: 120, desktopResolution: native)
let copiedRequest = try JSONDecoder().decode(Viewport.self, from: JSONEncoder().encode(request))
check(copiedRequest == request, "native request survives wire round trip")
check(DuoStreamPolicy.requestedFPS(panelMaximum: 120, lowPower: false) == 120, "public and local routes allow 120")
check(DuoStreamPolicy.requestedFPS(panelMaximum: 120, lowPower: true) == 60, "low power respects the panel limit")
check(DuoStreamPolicy.requestedFPS(panelMaximum: 60, lowPower: false) == 60, "a 60 Hz panel cannot claim 120")
check(DuoStreamPolicy.requestedFPS(panelMaximum: 240, lowPower: false) == 120, "host protocol supports at most 120")
check(modes.count == 3, "three stable control modes")
check(modes.filter(\.hasKeyboard) == [.keyboard, .combined], "keyboard visibility")
check(modes.filter(\.hasTrackpad) == [.trackpad, .combined], "trackpad visibility")
let all = DuoKeyboardLayout.rows.flatMap { $0 }
check(Set(all.map(\.id)).count == all.count, "keyboard IDs stay unique across redraws")
let usages = Set(all.compactMap { key -> UInt16? in if case .key(let usage) = key.action { return usage }; return nil })
for usage: UInt16 in 0x04...0x1D { check(usages.contains(usage), "all 26 letters available") }
for usage: UInt16 in 0x1E...0x38 { check(usages.contains(usage) || usage == 0x32, "number/punctuation/control keys available") }
for usage: UInt16 in 0x3A...0x45 { check(usages.contains(usage), "all function keys available") }
for usage: UInt16 in 0x4F...0x52 { check(usages.contains(usage), "all arrows available") }
for row in DuoKeyboardLayout.rows {
    for width in [548.0, 621.0, 900.0] {
        let widths = DuoKeyboardLayout.widths(for: row, available: width, gap: 4)
        let total = widths.reduce(0, +) + Double(row.count - 1) * 4
        check(abs(total - width) < 0.001, "row fits its available width")
        check(widths.allSatisfy { $0 >= 28 }, "keys keep usable touch targets")
    }
}

let chord = KeyChord.press(0x16, with: [.command, .shift])
check(chord == [.key(hidUsage: 0xE1, down: true, modifiers: 1 << 17),
                .key(hidUsage: 0xE3, down: true, modifiers: (1 << 17) | (1 << 20)),
                .key(hidUsage: 0x16, down: true, modifiers: (1 << 17) | (1 << 20)),
                .key(hidUsage: 0x16, down: false, modifiers: (1 << 17) | (1 << 20)),
                .key(hidUsage: 0xE3, down: false, modifiers: 1 << 17),
                .key(hidUsage: 0xE1, down: false, modifiers: 0)], "Command Shift S releases every held modifier")
let laptop = DuoConsoleGeometry(width: 669, height: 951, foldMinY: 455.5, foldMaxY: 495.5)
check(laptop.pictureHeight == 475.5 && laptop.controlsTop == 495.5, "video uses complete upper half; controls avoid the fold")
let asymmetric = DuoConsoleGeometry(width: 669, height: 951, foldMinY: 420, foldMaxY: 460)
check(asymmetric.pictureHeight == 440 && asymmetric.controlsTop == 460, "use actual hinge, not hardcoded halfway")
let flat = DuoConsoleGeometry(width: 669, height: 951)
check(flat.pictureHeight == 475.5 && flat.controlsTop == 475.5, "flat keeps the laptop layout")
let cover = DuoConsoleGeometry(width: 382, height: 678, cover: true)
check(cover.pictureHeight == 238.75 && cover.controlsTop == 238.75, "cover fits complete desktop and leaves controls")
let invalid = DuoConsoleGeometry(width: 669, height: 951, foldMinY: -1, foldMaxY: 1000)
check(invalid == flat, "invalid fold cannot produce negative frames")

var sampler = DuoFrameRateSampler()
check(sampler.sample(total: 120, dropped: 0, time: 1) == nil, "first renderer snapshot is unknown")
check(sampler.sample(total: 240, dropped: 3, time: 2) == 117, "displayed rate subtracts dropped frames")
check(sampler.sample(total: 300, dropped: 3, time: 2.5) == 120, "rate uses elapsed time")
check(sampler.sample(total: 0, dropped: 0, time: 3) == nil, "renderer reset starts a new window")
check(sampler.sample(total: 0, dropped: 0, time: 4) == 0, "static desktop is zero newly presented frames")
let nativeViewport = Viewport(width: 669, height: 475.5, scale: nil, fps: 120,
                              desktopResolution: DuoDesktopResolution(width: 2007, height: 1427))
check(nativeViewport.isValid, "actual native Duo viewport stays valid")
check(Viewport(width: 0, height: 0, scale: nil, fps: 120).isValid, "legacy rate-only requests remain valid")
let hugeViewport = try JSONDecoder().decode(Viewport.self, from: Data(#"{"width":1e308,"height":1000,"scale":1}"#.utf8))
check(!hugeViewport.isValid, "finite hostile viewport cannot reach integer window logging")
check(!Viewport(width: 669, height: .infinity, scale: nil).isValid, "nonfinite viewport height rejected")
check(!Viewport(width: -1, height: 475.5, scale: nil).isValid, "negative viewport rejected")
check(!Viewport(width: 669, height: 475.5, scale: 1e-308).isValid, "scale division cannot overflow")
check(!Viewport(width: 669, height: 475.5, scale: .infinity).isValid, "nonfinite scale rejected")
check(!Viewport(width: 669, height: 475.5, scale: nil,
                desktopResolution: DuoDesktopResolution(width: 1, height: 1)).isValid, "invalid embedded native size rejected")
print("DUO model: \(checks) checks passed")
