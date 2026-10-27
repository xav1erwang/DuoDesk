// Copyright 2026 DUO你电脑 contributors. SPDX-License-Identifier: Apache-2.0
// ScreenCaptureKit metadata decoding only; no screen capture or permission request.
import CoreGraphics
import Foundation

let expected = CGRect(x: 20, y: 30, width: 300, height: 200)
let representation = CGRectCreateDictionaryRepresentation(expected)
guard WindowCapture.diagnosticRect(representation as NSDictionary) == expected,
      WindowCapture.diagnosticRect(NSValue(rect: expected)) == expected,
      WindowCapture.diagnosticRect(["bad": 1]) == nil else {
    fputs("CAPTURE METADATA UNIT CHECK FAILED\n", stderr); exit(1)
}
print("CAPTURE METADATA UNIT CHECK PASS: dictionary, NSValue and malformed rectangle")
