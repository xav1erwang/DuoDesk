// Copyright 2026 DUO你电脑 contributors. SPDX-License-Identifier: Apache-2.0
import Foundation

func check(_ condition: @autoclosure () -> Bool, _ message: String) {
    guard condition() else { fatalError(message) }
}

// These legacy shapes intentionally know nothing about the new key. Decoding an extension request
// as a legacy viewport would look like a mirror request: the client must gate it on host support.
private struct OldViewport: Decodable {
    var width: Double
    var height: Double
    var desktopResolution: DuoDesktopResolution?
}
private struct OldWindowList: Decodable {
    var macName: String
    var windows: [WindowInfo]
    var active: StreamSource
}

let size = DuoDesktopResolution(width: 2007, height: 2853)
let oldViewport = Viewport(width: 669, height: 951, scale: nil, desktopResolution: size)
let oldViewportData = Wire.encode(oldViewport)
let legacyRoundTrip = Wire.decode(Viewport.self, from: oldViewportData)
check(legacyRoundTrip?.extendedDesktop == nil && legacyRoundTrip?.isValid == true,
      "a legacy viewport still means the existing mirror flow")
check(!String(decoding: oldViewportData, as: UTF8.self).contains("extendedDesktop"),
      "an ordinary viewport does not add the new key")
check(legacyRoundTrip?.recoverableDesktopFailure == nil
      && !String(decoding: oldViewportData, as: UTF8.self).contains("recoverableDesktopFailure"),
      "legacy viewport data does not claim recovery support")
let recovery = Viewport(width: 669, height: 951, scale: nil, desktopResolution: size,
                        recoverableDesktopFailure: true)
let recoveryData = Wire.encode(recovery)
check(Wire.decode(Viewport.self, from: recoveryData)?.recoverableDesktopFailure == true,
      "a new client advertises recovery explicitly")
check(Wire.decode(OldViewport.self, from: recoveryData)?.desktopResolution == size,
      "an old host ignores the recovery capability")

let requestID = UUID()
let extended = Viewport(width: 669, height: 951, scale: nil, desktopResolution: size,
                        extendedDesktop: true, extendedRequestID: requestID)
let payload = Wire.encode(extended)
check(extended.isValid && Wire.decode(Viewport.self, from: payload)?.extendedDesktop == true,
      "a supported host receives the full-size extended request")
check(Wire.decode(OldViewport.self, from: payload)?.desktopResolution == size,
      "older readers ignore the new key, so capability gating is mandatory")
check(!Viewport(width: 1, height: 1, scale: nil, extendedDesktop: true).isValid,
      "an extended request without a display size is invalid")
check(!Viewport(width: 1, height: 1, scale: nil,
                desktopResolution: DuoDesktopResolution(width: 5, height: 5), extendedDesktop: true,
                extendedRequestID: requestID).isValid,
      "an extended request cannot bypass native size validation")
check(!Viewport(width: 1, height: 1, scale: nil, desktopResolution: size, extendedDesktop: true).isValid,
      "an extended request needs an attempt identifier")
check(!Viewport(width: 1, height: 1, scale: nil, desktopResolution: size, extendedRequestID: requestID).isValid,
      "a mirror request cannot carry a stale extension identifier")
let response = DuoExtendedDesktopStatus(requestID: requestID, state: .failed, message: "无法创建扩展显示器")
check(Wire.decode(DuoExtendedDesktopStatus.self, from: Wire.encode(response)) == response,
      "extension responses preserve their attempt identifier and failure")

let oldList = WindowList(macName: "Mac", windows: [], active: .desktop)
let oldListData = Wire.encode(oldList)
check(Wire.decode(WindowList.self, from: oldListData)?.extendedDesktop == nil,
      "an old host does not advertise extension support")
check(Wire.decode(WindowList.self, from: oldListData)?.desktopIssue == nil,
      "an old host has no recoverable mirror issue")
check(Wire.decode(WindowList.self, from: oldListData)?.renderedNativeDesktop == nil,
      "an old host does not advertise render-canvas sizing")
let capable = WindowList(macName: "Mac", windows: [], active: .desktop, extendedDesktop: true)
let capableData = Wire.encode(capable)
check(Wire.decode(WindowList.self, from: capableData)?.extendedDesktop == true,
      "a capable host can advertise extension support")
check(Wire.decode(OldWindowList.self, from: capableData)?.macName == "Mac",
      "an old client can still decode a capable host's window list")
let issue = DuoDesktopIssue(resolution: size, message: "镜像暂不可用，请选择扩展")
let recoveryList = WindowList(macName: "Mac", windows: [], active: .none,
                              extendedDesktop: true, desktopIssue: issue)
let recoveryListData = Wire.encode(recoveryList)
check(Wire.decode(WindowList.self, from: recoveryListData)?.desktopIssue == issue,
      "the recoverable issue retains its exact size and message")
check(Wire.decode(OldWindowList.self, from: recoveryListData)?.active == StreamSource.none,
      "an old client still decodes an issue-bearing list")
let renderedList = WindowList(macName: "Mac", windows: [], active: .desktop, renderedNativeDesktop: true)
let renderedData = Wire.encode(renderedList)
check(Wire.decode(WindowList.self, from: renderedData)?.renderedNativeDesktop == true,
      "a capable host advertises render-canvas sizing")
check(Wire.decode(OldWindowList.self, from: renderedData)?.active == .desktop,
      "an old client ignores the additional sizing capability")
print("Extended-desktop wire compatibility: 21 checks passed")
