// Copyright 2026 DUO你电脑 contributors. SPDX-License-Identifier: Apache-2.0
import Foundation
import StreamProtocol

func check(_ condition: @autoclosure () -> Bool, _ message: String) {
    guard condition() else { fatalError(message) }
}

let portrait = DuoStreamPolicy.nativeFullDisplay(width: 2007, height: 2853, landscape: false)!
let landscape = DuoStreamPolicy.nativeFullDisplay(width: 2007, height: 2853, landscape: true)!
let upper = DuoStreamPolicy.nativeUpperDisplay(width: 2007, height: 2853)!
check(portrait == DuoDesktopResolution(width: 2007, height: 2853), "portrait uses the whole native inner screen")
check(portrait.encodedWidth == 2008 && portrait.encodedHeight == 2854, "portrait canvas rounds up")
check(portrait.acceptsPaddedEncoded(width: 2008, height: 2854), "portrait accepts its padded canvas")
check(landscape == DuoDesktopResolution(width: 2853, height: 2007), "landscape follows screen orientation")
check(landscape.encodedWidth == 2854 && landscape.encodedHeight == 2008, "landscape canvas rounds up")
check(landscape.acceptsPaddedEncoded(width: 2854, height: 2008), "landscape accepts its padded canvas")
check(upper == DuoDesktopResolution(width: 2007, height: 1427), "ordinary mode retains the original upper-screen target")
check(!portrait.acceptsPaddedEncoded(width: upper.encodedWidth, height: upper.encodedHeight),
      "an upper-half frame cannot be mistaken for full-screen native video")
check(DuoStreamPolicy.nativeFullDisplay(width: .nan, height: 2853, landscape: false) == nil, "non-finite rejected")
check(DuoStreamPolicy.nativeFullDisplay(width: 2007, height: 8193, landscape: false) == nil, "oversized rejected")
check(DuoStreamPolicy.nativeFullDisplay(width: 0, height: 2853, landscape: false) == nil, "empty rejected")
print("Clean image geometry: 11 checks passed; no real device or desktop stream")
