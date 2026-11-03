// Copyright 2026 DUO你电脑 contributors. SPDX-License-Identifier: Apache-2.0
import Foundation
import StreamProtocol

func check(_ condition: @autoclosure () -> Bool, _ message: String) {
    guard condition() else { fatalError(message) }
}

// The installed host previously failed while detaching its resized virtual display. A clean-mode
// round trip must keep the same requested native desktop and therefore not request that resize.
for (w, h, expected) in [(1878.0, 2670.0, DuoDesktopResolution(width: 1878, height: 1335)),
                         (2007.0, 2853.0, DuoDesktopResolution(width: 2007, height: 1427))] {
    let normal = DuoStreamPolicy.stableDesktopRequest(width: w, height: h, cleanImage: false)
    let clean = DuoStreamPolicy.stableDesktopRequest(width: w, height: h, cleanImage: true)
    let rotated = DuoStreamPolicy.stableDesktopRequest(width: h, height: w, cleanImage: true)
    check(normal == expected, "normal desktop must remain at native upper-display dimensions")
    check(clean == normal, "entering clean mode must not request a different Mac desktop")
    check(rotated == normal, "orientation must not silently change the established request")
    var previous = normal
    var resizeRequests = 0
    for mode in [true, false, true, false] {
        let next = DuoStreamPolicy.stableDesktopRequest(width: w, height: h, cleanImage: mode)
        if next != previous { resizeRequests += 1 }
        previous = next
    }
    check(resizeRequests == 0, "repeated clean-mode switches must not request a desktop resize")
}
check(DuoStreamPolicy.stableDesktopRequest(width: .nan, height: 2670, cleanImage: true) == nil,
      "invalid screen metrics must be rejected")

let portrait = CGSize(width: 669, height: 951)
let landscape = CGSize(width: 951, height: 669)
let desktop = CGSize(width: 1878, height: 1336)
check(DuoCleanImageLayout.shouldRotate(panel: portrait, video: desktop, nativeDesktop: true),
      "an upright Duo turns its landscape desktop to use more of the screen")
check(!DuoCleanImageLayout.shouldRotate(panel: landscape, video: desktop, nativeDesktop: true),
      "a landscape Duo keeps its already wide desktop upright")
check(!DuoCleanImageLayout.shouldRotate(panel: portrait, video: desktop, nativeDesktop: false),
      "non-native streams keep their existing orientation")
check(!DuoCleanImageLayout.shouldRotate(panel: CGSize(width: 100, height: 101),
                                        video: CGSize(width: 101, height: 100), nativeDesktop: true),
      "a nearly square frame does not rotate for a negligible improvement")
check(!DuoCleanImageLayout.shouldRotate(panel: .zero, video: desktop, nativeDesktop: true),
      "unknown panel size does not rotate")
check(!DuoCleanImageLayout.shouldRotate(panel: portrait, video: CGSize(width: CGFloat.nan, height: 100), nativeDesktop: true),
      "invalid video dimensions do not rotate")
let unrotatedCoverage = (portrait.width / (desktop.width / desktop.height)) / portrait.height
let rotatedCoverage = (portrait.width * (desktop.width / desktop.height)) / portrait.height
check(unrotatedCoverage < 0.51 && rotatedCoverage > 0.98 && rotatedCoverage <= 1,
      "the representative Duo desktop remains complete and uses nearly the whole upright screen when turned")

let extendedPortrait = DuoNativeDisplayMetrics(pixels: CGSize(width: 1878, height: 2670),
                                               windowSize: CGSize(width: 669, height: 951),
                                               renderPixels: CGSize(width: 2007, height: 2853))
check(DuoStreamPolicy.extendedDisplay(metrics: extendedPortrait) == DuoDesktopResolution(width: 2007, height: 2853),
      "extended portrait uses the larger render canvas at full height")
var extendedLandscape = extendedPortrait
extendedLandscape.windowSize = CGSize(width: 951, height: 669)
extendedLandscape.renderPixels = CGSize(width: 2853, height: 2007)
check(DuoStreamPolicy.extendedDisplay(metrics: extendedLandscape) == DuoDesktopResolution(width: 2853, height: 2007),
      "extended landscape preserves the complete render canvas")
var noRender = extendedPortrait
noRender.renderPixels = nil
check(DuoStreamPolicy.extendedDisplay(metrics: noRender) == nil,
      "an extension waits for the render canvas instead of silently using fewer pixels")
var invalidRender = extendedPortrait
invalidRender.renderPixels = CGSize(width: CGFloat.nan, height: 2853)
check(DuoStreamPolicy.extendedDisplay(metrics: invalidRender) == nil,
      "invalid render metrics cannot create an undersized extended display")
let upper = DuoDesktopResolution(width: 1878, height: 1335)
check(DuoExtendedDesktopPolicy.request(hostAdvertised: false, connected: true, alreadyExtended: false,
                                       upper: upper, metrics: extendedPortrait) == nil,
      "an older host never receives an extended request")
check(DuoExtendedDesktopPolicy.request(hostAdvertised: true, connected: false, alreadyExtended: false,
                                       upper: upper, metrics: extendedPortrait) == nil,
      "an extension is not started outside a connection")
check(DuoExtendedDesktopPolicy.request(hostAdvertised: true, connected: true, alreadyExtended: true,
                                       upper: upper, metrics: extendedPortrait) == nil,
      "a second attempt cannot replace the running extension")
check(DuoExtendedDesktopPolicy.request(hostAdvertised: true, connected: true, alreadyExtended: false,
                                       upper: upper, metrics: extendedPortrait)?.height == 2853,
      "a capable host can receive the full display size")
check(DuoExtendedDesktopPolicy.request(hostAdvertised: true, connected: true, alreadyExtended: false,
                                       pathMoving: true, upper: upper, metrics: extendedPortrait) == nil,
      "an extension waits for a pending connection handover to finish")
check(DuoExtendedDesktopPolicy.request(hostAdvertised: true, connected: true, alreadyExtended: false,
                                       connectionDead: true, upper: upper, metrics: extendedPortrait) == nil,
      "an extension cannot start on a dead connection")
let currentID = UUID()
let stale = DuoExtendedDesktopStatus(requestID: UUID(), state: .failed)
let current = DuoExtendedDesktopStatus(requestID: currentID, state: .failed)
check(!DuoExtendedDesktopPolicy.applies(stale, currentRequest: currentID),
      "an old failure cannot cancel a new extension")
check(DuoExtendedDesktopPolicy.applies(current, currentRequest: currentID),
      "a response for the current extension is accepted")
check(!DuoExtendedDesktopPolicy.applies(current, currentRequest: nil),
      "a response after exit cannot affect mirror mode")
let extendedViewport = Viewport(width: 669, height: 951, scale: 1.5, fps: 120,
                                desktopResolution: DuoDesktopResolution(width: 2007, height: 2853),
                                extendedDesktop: true, extendedRequestID: currentID)
let mirrorViewport = DuoExtendedDesktopPolicy.mirrorViewport(extendedViewport, upper: upper)
check(mirrorViewport?.desktopResolution == upper && mirrorViewport?.extendedDesktop == nil
      && mirrorViewport?.extendedRequestID == nil && mirrorViewport?.fps == 120 && mirrorViewport?.scale == 1.5,
      "exit clears the extension before any cached viewport can move to a new connection")
check(DuoExtendedDesktopPolicy.mirrorViewport(nil, upper: upper) == nil,
      "exit does not invent a viewport before the client has sent one")
let issue = DuoDesktopIssue(resolution: upper, message: "  镜像\n暂不可用\u{202E} 请选择扩展  ")
check(DuoExtendedDesktopPolicy.mirrorIssue(issue, expected: upper, extending: false, active: .none)
      == "镜像 暂不可用 请选择扩展", "a matching idle issue is made safe for display")
check(DuoExtendedDesktopPolicy.mirrorIssue(issue, expected: nil, extending: false, active: .none) == nil,
      "an issue without a matching requested size is ignored")
check(DuoExtendedDesktopPolicy.mirrorIssue(issue, expected: DuoDesktopResolution(width: 2007, height: 1427),
                                           extending: false, active: .none) == nil,
      "an old size cannot mask a new request")
check(DuoExtendedDesktopPolicy.mirrorIssue(issue, expected: upper, extending: true, active: .none) == nil,
      "a late mirror issue cannot hide an extension")
check(DuoExtendedDesktopPolicy.mirrorIssue(issue, expected: upper, extending: false, active: .desktop) == nil,
      "an issue cannot cover a live desktop")
let emptyIssue = DuoDesktopIssue(resolution: upper, message: "\n\u{202E} ")
check(DuoExtendedDesktopPolicy.mirrorIssue(emptyIssue, expected: upper, extending: false, active: .none) == nil,
      "an empty issue is ignored")
let longIssue = DuoDesktopIssue(resolution: upper, message: String(repeating: "字", count: 220))
check(DuoExtendedDesktopPolicy.mirrorIssue(longIssue, expected: upper, extending: false, active: .none)?.count == 200,
      "a host's issue cannot expand without bound")
print("Clean-mode stability, fit and extension policy: 38 checks passed; no physical display was changed")
