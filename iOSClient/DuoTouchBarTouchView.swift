// Copyright 2026 DUO你电脑 contributors. SPDX-License-Identifier: Apache-2.0
import UIKit
import StreamProtocol

/// Direct-touch overlay for a real, independently decoded Touch Bar surface. It never interprets
/// controls from pixels: the server receives normalized locations and decides what they mean.
final class DuoTouchBarTouchView: UIView {
    private var surface: TouchBarSurface?
    private var canBegin: () -> Bool = { false }
    private var send: (TouchBarTouch) -> Void = { _ in }
    private var active: ObjectIdentifier?
    private var last: TouchBarTouch?

    override init(frame: CGRect) {
        super.init(frame: frame)
        isMultipleTouchEnabled = false
        isAccessibilityElement = true
        accessibilityLabel = "Mac Touch Bar"
        accessibilityIdentifier = "duo.touchbar.surface"
    }
    required init?(coder: NSCoder) { fatalError() }

    /// Content rectangle inside the aspect-fit encoded image, with any even-alignment padding
    /// excluded. Begin must land inside it; a drag may leave it and is clamped to the last edge.
    static func contentRect(in bounds: CGRect, surface: TouchBarSurface) -> CGRect? {
        guard surface.isValid, bounds.width.isFinite, bounds.height.isFinite,
              bounds.width > 0, bounds.height > 0 else { return nil }
        let scale = min(bounds.width / CGFloat(surface.encodedWidth), bounds.height / CGFloat(surface.encodedHeight))
        guard scale.isFinite, scale > 0 else { return nil }
        let width = CGFloat(surface.encodedWidth) * scale, height = CGFloat(surface.encodedHeight) * scale
        return CGRect(x: bounds.minX + (bounds.width - width) / 2,
                      y: bounds.minY + (bounds.height - height) / 2,
                      width: CGFloat(surface.pixelWidth) * scale, height: CGFloat(surface.pixelHeight) * scale)
    }

    private func point(_ location: CGPoint, in surface: TouchBarSurface, clamping: Bool) -> CGPoint? {
        guard location.x.isFinite, location.y.isFinite, let rect = Self.contentRect(in: bounds, surface: surface),
              rect.width > 0, rect.height > 0, clamping || rect.contains(location) else { return nil }
        return CGPoint(x: min(1, max(0, (location.x - rect.minX) / rect.width)),
                       y: min(1, max(0, (location.y - rect.minY) / rect.height)))
    }

    func configure(surface: TouchBarSurface, canBegin: @escaping () -> Bool,
                   send: @escaping (TouchBarTouch) -> Void) {
        if self.surface != surface || !surface.acceptsInput || !canBegin() { cancelContact() }
        self.surface = surface; self.canBegin = canBegin; self.send = send
        accessibilityValue = surface.acceptsInput ? nil : "只读"
        accessibilityHint = surface.acceptsInput ? "直接触摸 Mac 的 Touch Bar 控件" : "仅显示画面，暂不支持触摸控制"
        accessibilityTraits = surface.acceptsInput ? [.allowsDirectInteraction] : [.image]
    }

    override func touchesBegan(_ touches: Set<UITouch>, with event: UIEvent?) {
        guard active == nil, let touch = touches.first, let surface, surface.acceptsInput, canBegin(),
              let p = point(touch.location(in: self), in: surface, clamping: false) else { return }
        active = ObjectIdentifier(touch)
        let message = TouchBarTouch(surfaceID: surface.id, phase: .began, x: p.x, y: p.y)
        last = message; send(message)
    }

    override func touchesMoved(_ touches: Set<UITouch>, with event: UIEvent?) {
        guard let touch = touches.first(where: { ObjectIdentifier($0) == active }), let surface else { return }
        guard canBegin(), let p = point(touch.location(in: self), in: surface, clamping: true) else { cancelContact(); return }
        let message = TouchBarTouch(surfaceID: surface.id, phase: .moved, x: p.x, y: p.y)
        last = message; send(message)
    }

    override func touchesEnded(_ touches: Set<UITouch>, with event: UIEvent?) {
        guard let touch = touches.first(where: { ObjectIdentifier($0) == active }), let surface else { return }
        guard canBegin(), let p = point(touch.location(in: self), in: surface, clamping: true) else { cancelContact(); return }
        active = nil; last = nil
        send(TouchBarTouch(surfaceID: surface.id, phase: .ended, x: p.x, y: p.y))
    }

    override func touchesCancelled(_ touches: Set<UITouch>, with event: UIEvent?) {
        if touches.contains(where: { ObjectIdentifier($0) == active }) { cancelContact() }
    }

    override func willMove(toWindow newWindow: UIWindow?) {
        if newWindow == nil { cancelContact() }
        super.willMove(toWindow: newWindow)
    }

    func cancelContact() {
        defer { active = nil; last = nil }
        guard let last else { return }
        send(TouchBarTouch(surfaceID: last.surfaceID, phase: .cancelled, x: last.x, y: last.y))
    }
}
