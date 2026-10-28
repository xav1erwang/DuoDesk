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

let bytes = Data([0, 1, 2, 253, 254, 255])
let media = TouchBarMedia(surfaceID: first, bytes: bytes)!
check(TouchBarMedia(encoded: media.encoded) == media, "media wire round trip")
check(TouchBarMedia(encoded: media.encoded.prefix(16)) == nil, "empty media refused")
check(TouchBarMedia(encoded: Data(repeating: 0, count: 17 + TouchBarProtocol.maximumEncodedBytes)) == nil,
      "oversized media refused")
check(TouchBarMedia(surfaceID: first, bytes: Data()) == nil, "empty access unit refused")

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
