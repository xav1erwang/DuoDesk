// Copyright 2026 DUO你电脑 contributors. SPDX-License-Identifier: Apache-2.0
import CoreVideo

protocol FrameAudit: Sendable {
    var changedFramesPerSecond: Double? { get }
    func inspect(_ image: CVPixelBuffer, at time: Double, onResult: (@Sendable (Int32, Double) -> Void)?)
    func report(from start: Double, seconds: Int) async -> String
    func validate() throws
}
extension PixelMotionAudit: FrameAudit {}
