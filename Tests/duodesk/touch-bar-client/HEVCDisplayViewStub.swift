// Copyright 2026 DUO你电脑 contributors. SPDX-License-Identifier: Apache-2.0
// Deliberately synthetic; verifies client routing without decoding or capturing any image.
import UIKit
import StreamProtocol

final class HEVCDisplayView: UIView {
    var hasCurrentImage = true
    var onKeyframeNeeded: (() -> Void)?
    var onDecoderFailure: ((String) -> Void)?
    var requirements: [UUID?] = []
    var frames: [Data] = []
    var parameterApplications = 0
    func requireTouchBarSurface(_ surface: TouchBarSurface?) { requirements.append(surface?.id) }
    func apply(_ parameters: ParameterSets) { parameterApplications += 1 }
    func enqueue(_ data: Data, isKeyframe: Bool) { if isKeyframe { frames.append(data) } }
}
