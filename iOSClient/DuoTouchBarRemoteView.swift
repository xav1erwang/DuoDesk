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
        container.setVideo(video)
        container.touch.configure(surface: surface, canBegin: { video.hasCurrentImage && canBegin() }, send: send)
    }
}

final class DuoTouchBarContainer: UIView {
    private(set) var video: HEVCDisplayView
    let touch = DuoTouchBarTouchView()

    init(video: HEVCDisplayView) {
        self.video = video
        super.init(frame: .zero)
        clipsToBounds = true
        addSubview(video)
        addSubview(touch)
    }
    required init?(coder: NSCoder) { fatalError() }

    func setVideo(_ replacement: HEVCDisplayView) {
        guard video !== replacement else { return }
        // A gesture made on the old image must never continue against a newly hosted decoder.
        touch.cancelContact()
        video.removeFromSuperview()
        video = replacement
        insertSubview(replacement, belowSubview: touch)
        replacement.frame = bounds
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        video.frame = bounds
        touch.frame = bounds
    }
}
