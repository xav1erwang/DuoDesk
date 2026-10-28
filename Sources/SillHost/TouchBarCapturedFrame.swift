// Copyright 2026 DUO你电脑 contributors. SPDX-License-Identifier: Apache-2.0
import CoreMedia
import CoreVideo

/// The source owns this buffer for as long as the hardware encoder may use it.
struct TouchBarCapturedFrame: @unchecked Sendable {
    let pixels: CVPixelBuffer
    let contentWidth: Int
    let contentHeight: Int
    let pts: CMTime
}
