// Copyright 2026 DUO你电脑 contributors. SPDX-License-Identifier: Apache-2.0
import Foundation

/// Product-facing labels; the stored bitrates and upstream protocol names stay unchanged.
public enum DuoQualityLabels {
    public static func name(forBitrate bitrate: Int) -> LocalizedStringResource {
        return switch QualityPreset(rawValue: bitrate) {
        case .low: "省流"
        case .efficient: "高效"
        case .balanced: "均衡"
        case .high: "高清"
        case .pro: "专业"
        case .ultra: "超清"
        case .extreme: "极致"
        case nil: "\(QualityPreset.mbps(bitrate)) Mbps"
        }
    }

    public static func title(forBitrate bitrate: Int) -> LocalizedStringResource {
        let rate = QualityPreset.mbps(bitrate)
        return switch QualityPreset(rawValue: bitrate) {
        case .low: "省流 — \(rate) Mbps"
        case .efficient: "高效 — \(rate) Mbps"
        case .balanced: "均衡 — \(rate) Mbps"
        case .high: "高清 — \(rate) Mbps"
        case .pro: "专业 — \(rate) Mbps"
        case .ultra: "超清 — \(rate) Mbps"
        case .extreme: "极致 — \(rate) Mbps"
        case nil: "自定义 — \(rate) Mbps"
        }
    }
}
