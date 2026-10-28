// Copyright 2026 DUO你电脑 contributors. SPDX-License-Identifier: Apache-2.0
import SwiftUI
import UIKit
import StreamProtocol

/// Hosts the separately owned video layer without copying frames through SwiftUI. The caller owns
/// the surface subscription and sends the overlay's events over that same paired session.
struct DuoTouchBarRemoteView: UIViewRepresentable {
    let video: HEVCDisplayView
    let surface: TouchBarSurface
    let canBegin: () -> Bool
    let send: (TouchBarTouch) -> Void
    var onAttach: () -> Void = { }

    func makeUIView(context: Context) -> DuoTouchBarContainer {
        let container = DuoTouchBarContainer(video: video)
        configure(container)
        return container
    }

    func updateUIView(_ container: DuoTouchBarContainer, context: Context) { configure(container) }

    static func dismantleUIView(_ container: DuoTouchBarContainer, coordinator: ()) {
        container.touch.cancelContact()
    }

    private func configure(_ container: DuoTouchBarContainer) {
        container.onAttach = onAttach
        container.setVideo(video)
        container.setInputAvailable(surface.acceptsInput)
        container.touch.configure(surface: surface, canBegin: { video.hasCurrentImage && canBegin() }, send: send)
    }
}

final class DuoTouchBarContainer: UIView {
    private(set) var video: HEVCDisplayView
    let touch = DuoTouchBarTouchView()
    var onAttach: (() -> Void)?
    private let readOnlyLabel: UILabel = {
        let label = UILabel()
        label.text = String(localized: "只读", comment: "Touch Bar video is available but does not accept touches")
        label.font = .preferredFont(forTextStyle: .caption2)
        label.adjustsFontForContentSizeCategory = true
        label.textColor = .white.withAlphaComponent(0.85)
        label.textAlignment = .center
        label.isAccessibilityElement = false // The touch surface announces the same state.
        label.isHidden = true
        return label
    }()

    init(video: HEVCDisplayView) {
        self.video = video
        super.init(frame: .zero)
        clipsToBounds = true
        addSubview(video)
        addSubview(touch)
        addSubview(readOnlyLabel)
    }
    required init?(coder: NSCoder) { fatalError() }

    func setVideo(_ replacement: HEVCDisplayView) {
        guard video !== replacement else { return }
        // A gesture made on the old image must never continue against a newly hosted decoder.
        touch.cancelContact()
        video.removeFromSuperview()
        video = replacement
        insertSubview(replacement, belowSubview: touch)
        setNeedsLayout()
    }

    func setInputAvailable(_ available: Bool) {
        guard readOnlyLabel.isHidden != available else { return }
        readOnlyLabel.isHidden = available
        setNeedsLayout()
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        // Keep the indicator beside the picture so no real Touch Bar controls are covered.
        let labelWidth = readOnlyLabel.isHidden ? 0 : min(bounds.width / 4, ceil(readOnlyLabel.intrinsicContentSize.width) + 16)
        let rightToLeft = effectiveUserInterfaceLayoutDirection == .rightToLeft
        readOnlyLabel.frame = CGRect(x: rightToLeft ? bounds.maxX - labelWidth : bounds.minX,
                                     y: bounds.minY, width: labelWidth, height: bounds.height)
        let content = CGRect(x: bounds.minX + (rightToLeft ? 0 : labelWidth), y: bounds.minY,
                             width: max(0, bounds.width - labelWidth), height: bounds.height)
        video.frame = content
        touch.frame = content
    }

    override func didMoveToWindow() {
        super.didMoveToWindow()
        if window != nil { onAttach?() }
    }
}
