// Copyright 2026 DUO你电脑 contributors. SPDX-License-Identifier: Apache-2.0
import Foundation
import StreamProtocol

func check(_ condition: @autoclosure () -> Bool, _ message: String) {
    guard condition() else { fatalError(message) }
}

check(ExtendedDesktopPolicy.permits(available: true, connectedCount: 1, registered: true),
      "one registered device can request an available extension")
check(!ExtendedDesktopPolicy.permits(available: false, connectedCount: 1, registered: true),
      "an unavailable host never starts an extension")
check(!ExtendedDesktopPolicy.permits(available: true, connectedCount: 2, registered: true),
      "a shared pipeline cannot silently change another viewer's display")
check(!ExtendedDesktopPolicy.permits(available: true, connectedCount: 1, registered: false),
      "an unregistered connection cannot request a display")

let upper = DuoDesktopResolution(width: 1878, height: 1335)
let full = DuoDesktopResolution(width: 2007, height: 2853)
let first = UUID(), next = UUID()
check(ExtendedDesktopPolicy.isCurrent(capturedID: nil, capturedSize: upper, currentIDs: [], currentSize: upper),
      "an unchanged mirror request stays current")
check(!ExtendedDesktopPolicy.isCurrent(capturedID: nil, capturedSize: upper, currentIDs: [first], currentSize: full),
      "a pending mirror cannot consume an extension request as a mirror")
check(ExtendedDesktopPolicy.isCurrent(capturedID: first, capturedSize: full, currentIDs: [first], currentSize: full),
      "the same extension attempt stays current")
check(!ExtendedDesktopPolicy.isCurrent(capturedID: first, capturedSize: full, currentIDs: [next], currentSize: full),
      "a newer attempt invalidates a suspended old one, even at the same size")
check(!ExtendedDesktopPolicy.isCurrent(capturedID: first, capturedSize: full, currentIDs: [], currentSize: upper),
      "returning to mirror invalidates the in-flight extension")
check(!ExtendedDesktopPolicy.isCurrent(capturedID: first, capturedSize: full, currentIDs: [first, next], currentSize: full),
      "multiple simultaneous extension requests do not select one arbitrarily")
print("Extended-desktop admission and switch fencing: 10 checks passed")
