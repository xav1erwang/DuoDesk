// Copyright 2026 DUO你电脑 contributors. SPDX-License-Identifier: Apache-2.0
import Foundation
import StreamProtocol

func check(_ condition: @autoclosure () -> Bool, _ message: String) {
    guard condition() else { fatalError(message) }
}

let first = UUID(), second = UUID()
let surface = TouchBarSurface(id: first, pixelWidth: 2008, pixelHeight: 60,
                              encodedWidth: 2008, encodedHeight: 60, acceptsInput: true)
let replacement = TouchBarSurface(id: second, pixelWidth: 2008, pixelHeight: 60,
                                  encodedWidth: 2008, encodedHeight: 60, acceptsInput: true)
check(surface.isValid, "valid bar dimensions")
check(!TouchBarSurface(id: first, pixelWidth: 2009, pixelHeight: 60, encodedWidth: 2008,
                       encodedHeight: 60, acceptsInput: true).isValid, "content larger than encoding")
check(!TouchBarSurface(id: first, pixelWidth: 8192, pixelHeight: 2048, encodedWidth: 8192,
                       encodedHeight: 2048, acceptsInput: true).isValid, "bounded decoder area")
check(!TouchBarSurface(id: first, pixelWidth: 2007, pixelHeight: 60, encodedWidth: 2007,
                       encodedHeight: 60, acceptsInput: true).isValid, "odd encoded dimension")
check(TouchBarStatus(availability: .live, surface: surface).isValid, "live has a surface")
check(!TouchBarStatus(availability: .live).isValid, "live without a surface")
check(!TouchBarStatus(availability: .unavailable, surface: surface).isValid, "unavailable with a stale surface")
let status = TouchBarStatus(availability: .live, surface: surface)
check(Wire.decode(TouchBarStatus.self, from: Wire.encode(status)) == status, "status wire round trip")
let refresh = TouchBarRefresh(surfaceID: first)
check(TouchBarRefresh(encoded: refresh.encoded) == refresh, "refresh wire round trip")
check(TouchBarRefresh(encoded: refresh.encoded.dropLast()) == nil, "truncated refresh rejected")
check(TouchBarRefresh(encoded: refresh.encoded + Data([0])) == nil, "oversized refresh rejected")

let bytes = Data([0, 1, 2, 253, 254, 255])
let media = TouchBarMedia(surfaceID: first, bytes: bytes)!
check(TouchBarMedia(encoded: media.encoded) == media, "media wire round trip")
check(TouchBarMedia(encoded: media.encoded.prefix(16)) == nil, "empty media refused")
check(TouchBarMedia(encoded: Data(repeating: 0, count: 17 + TouchBarProtocol.maximumEncodedBytes)) == nil,
      "oversized media refused")
check(TouchBarMedia(surfaceID: first, bytes: Data()) == nil, "empty access unit refused")
let parameters = ParameterSets(nalUnitHeaderLength: 4, sets: [Data([1, 2]), Data([3]), Data([4, 5, 6])])
let packet = TouchBarKeyframe(surfaceID: first, parameters: parameters, accessUnit: bytes)!
let packetCopy = TouchBarKeyframe(encoded: packet.encoded)
check(packetCopy?.surfaceID == first && packetCopy?.parameters.encoded() == parameters.encoded()
      && packetCopy?.accessUnit == bytes, "self-contained HEVC packet round trip")
check(TouchBarKeyframe(surfaceID: first, parameters: ParameterSets(nalUnitHeaderLength: 3, sets: parameters.sets),
                       accessUnit: bytes) == nil, "wrong NAL length rejected")
check(TouchBarKeyframe(surfaceID: first, parameters: ParameterSets(nalUnitHeaderLength: 4, sets: [Data(), Data([1]), Data([2])]),
                       accessUnit: bytes) == nil, "empty parameter set rejected")
check(TouchBarKeyframe(surfaceID: first, parameters: parameters,
                       accessUnit: Data(repeating: 0, count: TouchBarProtocol.maximumEncodedBytes)) == nil,
      "combined packet budget enforced")
var badLength = packet.encoded
for index in 16..<20 { badLength[index] = 0xff }
check(TouchBarKeyframe(encoded: badLength) == nil, "malformed parameter length rejected")
var trailingParameter = Data([0, 0, 0, UInt8(parameters.encoded().count + 1)])
trailingParameter.append(parameters.encoded()); trailingParameter.append(0); trailingParameter.append(bytes)
check(TouchBarKeyframe(encoded: TouchBarMedia(surfaceID: first, bytes: trailingParameter)!.encoded) == nil,
      "noncanonical parameter data rejected")
for kind in [StreamMessageKind.touchBarSubscription, .touchBarStatus, .touchBarFrame, .touchBarTouch, .touchBarRefresh] {
    let message = StreamMessage(kind: kind, timestamp: 0, isKeyframe: false, payload: Data()).serialized()
    check(StreamMessage.parseHeader(message)?.kind == kind, "Touch Bar message kind round trip")
}

func touch(_ phase: TouchBarPhase, _ x: Double = 0.3, _ y: Double = 0.6, id: UUID = first) -> TouchBarTouch {
    TouchBarTouch(surfaceID: id, phase: phase, x: x, y: y)
}
var gate = TouchBarTouchGate<String>()
check(gate.accept(touch(.began), from: "a", surface: surface, subscribed: true, paired: false, inputAllowed: true) == nil,
      "unpaired input refused")
check(gate.accept(touch(.began), from: "a", surface: surface, subscribed: false, paired: true, inputAllowed: true) == nil,
      "unsubscribed input refused")
check(gate.accept(touch(.began), from: "a", surface: surface, subscribed: true, paired: true, inputAllowed: false) == nil,
      "untrusted input refused")
check(gate.accept(touch(.began, .nan), from: "a", surface: surface, subscribed: true, paired: true, inputAllowed: true) == nil,
      "non-finite coordinates refused")
check(gate.accept(touch(.began, -0.01), from: "a", surface: surface, subscribed: true, paired: true, inputAllowed: true) == nil,
      "out-of-bounds coordinates refused")
check(gate.accept(touch(.moved), from: "a", surface: surface, subscribed: true, paired: true, inputAllowed: true) == nil,
      "move without begin refused")
check(gate.accept(touch(.began), from: "a", surface: surface, subscribed: true, paired: true, inputAllowed: true) != nil,
      "paired subscriber begins")
check(gate.accept(touch(.began), from: "b", surface: surface, subscribed: true, paired: true, inputAllowed: true) == nil,
      "second peer cannot steal contact")
check(gate.release(for: "b") == nil, "unrelated disconnect cannot release")
check(gate.accept(touch(.moved, 0.7, 0.8), from: "a", surface: surface, subscribed: true, paired: true, inputAllowed: true) != nil,
      "owner moves")
check(gate.accept(touch(.ended, id: first), from: "a", surface: replacement, subscribed: true, paired: true, inputAllowed: true) == nil,
      "old surface cannot control replacement")
let released = gate.release(for: "a")
check(released == touch(.cancelled, 0.7, 0.8), "disconnect releases at last position")
check(gate.release() == nil, "release is idempotent")
check(gate.accept(touch(.began, id: second), from: "b", surface: replacement, subscribed: true, paired: true, inputAllowed: true) != nil,
      "new peer can use replacement after release")
check(gate.accept(touch(.ended, id: second), from: "b", surface: replacement, subscribed: true, paired: true, inputAllowed: true) != nil,
      "owner ends")
check(gate.release() == nil, "ended contact is cleared")
print("TOUCH BAR CONTRACT PASS: bounds, serialization, authorization, ownership, stale surfaces and release; no capture or input injected")
