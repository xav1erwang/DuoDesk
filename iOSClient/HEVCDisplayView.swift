// Modified for DUO你电脑, 2026. See NOTICE for upstream attribution.
import UIKit
import AVFoundation
import Combine
import CoreMedia
import SwiftUI
import StreamProtocol

/// Presents IOSurface backed frames produced by the verified hardware HEVC decoder.
final class HEVCDisplayView: UIView {
    override class var layerClass: AnyClass { AVSampleBufferDisplayLayer.self }
    private var displayLayer: AVSampleBufferDisplayLayer { layer as! AVSampleBufferDisplayLayer }

    var onNativeDisplaySize: ((DuoNativeDisplayMetrics) -> Void)?
    var onDecoderFailure: ((String) -> Void)?
    var onKeyframeNeeded: (() -> Void)?
    private var displayedGeneration: UInt64?
    var hasCurrentImage: Bool {
        guard let token = displayedGeneration else { return false }
        return window != nil && hardwareDecoder.isCurrent(token) && videoPresenter.isReady(token)
    }
    /// Taken on main with a touch, checked on the network queue before it is sent. Captures the
    /// thread-safe decoder and token only, so queued input never reads UIKit from another thread.
    func makeInputFence() -> @Sendable () -> Bool {
        let decoder = hardwareDecoder
        guard let token = displayedGeneration, decoder.isCurrent(token) else { return { false } }
        let presentation = videoPresenter.makeInputFence(token)
        return { decoder.isCurrent(token) && presentation() }
    }
    private lazy var videoPresenter: HardwareVideoPresenter = HardwareVideoPresenter(renderer: displayLayer.sampleBufferRenderer, onFirstImage: { [weak self] size, token in
        Task { @MainActor [weak self] in
            guard let self, self.hardwareDecoder.isCurrent(token), self.videoPresenter.isReady(token) else { return }
            self.displayedGeneration = token
            self.pointerVideoSize = size
            self.onVideoSize?(size)
            self.placeCursor()
            self.onVideoSizeForPointer?(size)
        }
    }, onFailure: { [weak self] message, token, revision in
        Task { @MainActor [weak self] in
            guard let self, self.hardwareDecoder.isCurrent(token),
                  self.videoPresenter.isCurrentSurface(token, revision: revision) else { return }
            self.onDecoderFailure?(message)
        }
    })
    private lazy var hardwareDecoder: HardwareHEVCDecoder = {
        let presenter = videoPresenter
        return HardwareHEVCDecoder(onFormat: { _, token in
            presenter.reset(token)
        }, onSample: { sample, token in
            presenter.enqueue(sample, generation: token)
        }, onFailure: { [weak self] message, token in
            Task { @MainActor [weak self] in
                guard let self, self.hardwareDecoder.isCurrent(token) else { return }
                self.onDecoderFailure?(message)
            }
        }, onNeedsKeyframe: { [weak self] token in
            Task { @MainActor [weak self] in
                guard let self, self.hardwareDecoder.isCurrent(token) else { return }
                self.onKeyframeNeeded?()
            }
        })
    }()

    func requireNativeResolution(_ resolution: DuoDesktopResolution?) {
        let token = hardwareDecoder.require(resolution)
        videoPresenter.reset(token)
    }

    private func reportNativeDisplaySize() {
        guard let window, let screen = window.windowScene?.screen else { return }
        let windowPixels = [window.bounds.width * screen.nativeScale, window.bounds.height * screen.nativeScale].sorted()
        let native = [screen.nativeBounds.width, screen.nativeBounds.height].sorted()
        // A fold briefly reports the new hinge with the old scene metrics. Do not cache that
        // transient outer-display size as the inner display's native resolution.
        guard abs(windowPixels[0] - native[0]) < 2, abs(windowPixels[1] - native[1]) < 2 else { return }
        onNativeDisplaySize?(DuoNativeDisplayMetrics(pixels: screen.nativeBounds.size, windowSize: window.bounds.size))
    }

    /// The streamed frame's pixel size, reported on main whenever new parameter sets arrive.
    /// Input needs it: touches are normalized against the video, not against this view.
    var onVideoSize: ((CGSize) -> Void)?
    /// The same event, fired on main right after `onVideoSize`. `StreamClient` owns `onVideoSize`
    /// (it feeds `videoSize`); `StreamView` owns this one and tells the client's pointer on it
    /// (`StreamClient.pointerFrameChanged`). Two hooks instead of a chain, so re-hosting after a
    /// rotation cannot stack closures.
    var onVideoSizeForPointer: ((CGSize) -> Void)?

    // MARK: The pointer sprite
    //
    // The Mac's cursor is never in the video (the host captures without it), so every pointer the
    // device shows is this sprite, in the Mac's live shape (kind 14). It is one of two things
    // (docs/pointer-visibility-plan.md, "What the device draws"; `StreamClient.renderPointer` decides):
    // the Mac's own pointer, while the Mac or another device moved it last, placed where kind 26
    // says it is and moved at the rate those reports come; or this device's own, for the portrait
    // trackpad (and the Pencil, with Q2's flip), placed at touch rate rather than a network round
    // trip behind, which is where the Mac's cursor in the video would be. All of it main thread.

    private let cursorLayer = HEVCDisplayView.makeCursorLayer()
    /// Where the sprite's tip is, a fraction of the video frame, or nil when hidden: what
    /// `StreamClient.renderPointer` last handed over.
    private var pointer: CGPoint?
    /// Main-thread copy of the frame size the layer draws. `apply` runs on the network queue and
    /// hops here with it; `clear` zeroes it. Zero hides the sprite: there is no frame to point into.
    private var pointerVideoSize: CGSize = .zero
    /// Stacking inside this view's layer, which is the video layer: sibling sublayers draw in
    /// zPosition order, so the sprite sits above the picture whatever the display layer adds
    /// underneath, and the DEBUG readout sits above the sprite.
    private static let cursorZ: CGFloat = 100
    private static let hudZ: CGFloat = 200

    #if DEBUG
    /// The `-SillHUD 1` readout and its subscriptions to the client. nil unless that argument is set.
    private var hud: DiagnosticsHUDView?
    private var hudSubscriptions = Set<AnyCancellable>()
    #endif

    /// Where `resizeAspect` actually draws a `videoSize` frame inside `bounds`: the same letterboxed
    /// rect the layer uses, which is what maps a touch to a fraction of the frame.
    /// Returns `.zero` while the video size is unknown, so callers can tell "no video" from "top left".
    static func videoRect(in bounds: CGRect, videoSize: CGSize) -> CGRect {
        guard videoSize.width > 0, videoSize.height > 0, bounds.width > 0, bounds.height > 0 else { return .zero }
        let scale = min(bounds.width / videoSize.width, bounds.height / videoSize.height)
        let size = CGSize(width: videoSize.width * scale, height: videoSize.height * scale)
        return CGRect(x: bounds.minX + (bounds.width - size.width) / 2,
                      y: bounds.minY + (bounds.height - size.height) / 2,
                      width: size.width, height: size.height)
    }

    override init(frame: CGRect) {
        super.init(frame: frame)
        backgroundColor = .black
        displayLayer.videoGravity = .resizeAspect
        layer.addSublayer(cursorLayer)
    }
    required init?(coder: NSCoder) { fatalError() }

    /// AVFoundation's renderer counters, not enqueued/received frames or the panel's maximum Hz.
    @MainActor
    func presentationMetrics() async -> (total: Int, dropped: Int)? {
        guard #available(iOS 17.4, *) else { return nil }
        guard let metrics = await displayLayer.sampleBufferRenderer.videoPerformanceMetrics else { return nil }
        return (metrics.totalNumberOfFrames, metrics.numberOfDroppedFrames)
    }

    override func didMoveToWindow() {
        super.didMoveToWindow()
        presentationHierarchyChanged()
        reportNativeDisplaySize()
        // A standalone layer renders at 1× unless told otherwise; the arrow should be crisp.
        if let scale = window?.screen.scale { cursorLayer.contentsScale = scale }
    }

    private weak var presentationWindow: UIWindow?
    private weak var presentationParent: UIView?
    override func didMoveToSuperview() {
        super.didMoveToSuperview()
        presentationHierarchyChanged()
    }
    private func presentationHierarchyChanged() {
        let changed = presentationWindow !== window || presentationParent !== superview
        presentationWindow = window; presentationParent = superview
        guard changed, let token = displayedGeneration, hardwareDecoder.isCurrent(token) else { return }
        videoPresenter.refreshSurface(token)
        #if DEBUG
        print("Video surface rehosted: attached=\(window != nil), generation=\(token)")
        #endif
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        reportNativeDisplaySize()
        placeCursor()   // rotation and letterbox changes move the video rect under it
        #if DEBUG
        if let debugFrame {
            CATransaction.begin()
            CATransaction.setDisableActions(true)
            debugFrame.frame = Self.videoRect(in: bounds, videoSize: pointerVideoSize)
            CATransaction.commit()
        }
        if let hud {
            // Rotation reparents this view into a new SwiftUI host; keep the readout above anything
            // added since and pinned to the new bounds.
            bringSubviewToFront(hud)
            hud.place(in: bounds)
        }
        #endif
    }

    #if DEBUG
    /// Shows the diagnostics readout fed by `client`, when launched with `-SillHUD 1`. Idempotent:
    /// the view is shared across layouts, so every re-host calls this and only the first one counts.
    func attachDiagnostics(to client: StreamClient) {
        guard DiagnosticsHUDView.isEnabled, hud == nil else { return }
        let hud = DiagnosticsHUDView(frame: .zero)
        hud.layer.zPosition = Self.hudZ   // above the pointer sprite
        addSubview(hud)
        self.hud = hud
        // [weak hud]: the view owns the subscriptions, the subscriptions must not own the view.
        Publishers.CombineLatest(client.$linkStats, client.$videoSize)
            .receive(on: DispatchQueue.main)
            .sink { [weak hud] stats, size in hud?.update(stats: stats, videoSize: size) }
            .store(in: &hudSubscriptions)
        setNeedsLayout()
    }
    #endif

    /// Shows the sprite at `p` (a fraction of the video frame) or hides it (nil): the Mac's pointer
    /// or this device's own, whichever `StreamClient.renderPointer` says. Up to 120 times a second.
    /// Main thread.
    func setPointer(_ p: CGPoint?) {
        pointer = p
        placeCursor()
    }

    #if DEBUG
    /// The layout harness (`-SillPointer`): the frame size the sprite needs, as the host's parameter
    /// sets would give it, for a mock that never streams; and a dim rectangle where that frame is
    /// drawn, so a photo shows what the sprite points into (the mock's picture is black).
    func debugFrameSize(_ size: CGSize) {
        pointerVideoSize = size
        if debugFrame == nil {
            let frame = CALayer()
            frame.backgroundColor = UIColor(white: 0.16, alpha: 1).cgColor
            frame.zPosition = Self.cursorZ - 1
            layer.addSublayer(frame)
            debugFrame = frame
        }
        setNeedsLayout()
        placeCursor()
    }

    /// `debugFrameSize`'s rectangle; nil unless the harness asked for it.
    private var debugFrame: CALayer?
    #endif

    /// Gives the sprite the Mac's current cursor image (I-beam, hand, resize…) with its hotspot at
    /// the layer's anchor, or falls back to the built-in arrow when nil. Sizes are Mac points, drawn
    /// 1:1 in device points. Main thread, never animated.
    func setCursorShape(_ shape: StreamClient.CursorShape?) {
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        defer { CATransaction.commit() }
        if let shape, let cg = shape.image.cgImage, shape.size.width > 0, shape.size.height > 0 {
            cursorLayer.path = nil
            cursorLayer.shadowPath = nil
            cursorLayer.shadowOpacity = 0
            cursorLayer.contents = cg
            cursorLayer.contentsGravity = .resize
            cursorLayer.bounds = CGRect(origin: .zero, size: shape.size)
            cursorLayer.anchorPoint = CGPoint(x: shape.hotspot.x / shape.size.width, y: shape.hotspot.y / shape.size.height)
        } else {
            let arrow = Self.arrowPath
            cursorLayer.contents = nil
            cursorLayer.path = arrow
            cursorLayer.shadowPath = arrow
            cursorLayer.shadowOpacity = 0.3
            cursorLayer.bounds = arrow.boundingBox
            cursorLayer.anchorPoint = .zero
        }
        placeCursor()
    }

    /// Puts the sprite's tip on the pointer inside the letterboxed video rect, or hides it when
    /// there is no pointer or no video yet. Never animated: an implicit 0.25 s action on a
    /// standalone layer is exactly the lag the sprite exists to remove. Main thread.
    private func placeCursor() {
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        defer { CATransaction.commit() }
        let rect = Self.videoRect(in: bounds, videoSize: pointerVideoSize)
        guard let p = pointer, rect.width > 0, rect.height > 0 else {
            cursorLayer.isHidden = true
            return
        }
        let x = min(max(p.x, 0), 1), y = min(max(p.y, 0), 1)
        cursorLayer.position = CGPoint(x: rect.minX + x * rect.width, y: rect.minY + y * rect.height)
        cursorLayer.isHidden = false
    }

    /// A macOS-style arrow, about 20 pt tall: white, 1 pt black outline, a soft shadow. Its tip is
    /// the hotspot and sits at the layer's origin, so `position` is the point being pointed at.
    static let arrowPath: CGPath = {
        let arrow = CGMutablePath()
        arrow.addLines(between: [
            CGPoint(x: 0, y: 0),        // tip
            CGPoint(x: 0, y: 16.8),     // down the straight left edge
            CGPoint(x: 4.0, y: 12.8),   // in to the tail
            CGPoint(x: 6.8, y: 19.2),   // tail, lower left
            CGPoint(x: 9.6, y: 18.0),   // tail, lower right
            CGPoint(x: 6.9, y: 12.0),   // back up to the head
            CGPoint(x: 12.0, y: 12.0),  // right wing
        ])
        arrow.closeSubpath()
        return arrow
    }()

    private static func makeCursorLayer() -> CAShapeLayer {
        let arrow = arrowPath
        let shape = CAShapeLayer()
        shape.path = arrow
        shape.fillColor = UIColor.white.cgColor
        shape.strokeColor = UIColor.black.cgColor
        shape.lineWidth = 1
        shape.lineJoin = .round        // a mitred 45° tip would poke 1.3 pt past the hotspot
        shape.bounds = arrow.boundingBox
        shape.anchorPoint = .zero
        shape.shadowPath = arrow       // spares Core Animation an offscreen pass to find the shape
        shape.shadowColor = UIColor.black.cgColor
        shape.shadowOpacity = 0.3
        shape.shadowRadius = 1
        shape.shadowOffset = CGSize(width: 0, height: 1)
        shape.zPosition = cursorZ
        shape.isHidden = true
        return shape
    }

    /// VideoToolbox owns decoding; the layer receives only decoded image buffers.
    func apply(_ ps: ParameterSets) { hardwareDecoder.apply(ps) }

    func clear() {
        let token = hardwareDecoder.clear()
        videoPresenter.reset(token)
        Task { @MainActor [weak self] in
            guard let self, self.hardwareDecoder.isCurrent(token) else { return }
            self.pointerVideoSize = .zero
            self.placeCursor()
        }
    }

    func enqueue(_ data: Data, isKeyframe: Bool) {
        hardwareDecoder.enqueue(data, isKeyframe: isKeyframe)
    }

}

struct StreamView: UIViewRepresentable {
    let client: StreamClient

    /// Hosts the client's single display view. SwiftUI may build the new layout's host before it
    /// dismantles the old one, so detach the view from wherever it was first.
    func makeUIView(context: Context) -> HEVCDisplayView {
        let view = client.displayView
        view.removeFromSuperview()
        #if DEBUG
        view.attachDiagnostics(to: client)
        #endif
        wirePointer(view)
        return view
    }

    /// Connects the client's pointer to the sprite, with no SwiftUI in between (a re-render per move
    /// is the lag this avoids). Runs on every re-host, rotation included: the hooks are plain
    /// assignments, so the newest replaces the last instead of stacking. This is the only place that
    /// sets `onPointerChange`. Main thread, like everything the closures touch.
    private func wirePointer(_ view: HEVCDisplayView) {
        let client = self.client
        client.onCursorShapeChange = { [weak view] shape in view?.setCursorShape(shape) }
        view.setCursorShape(client.cursorShape)
        client.onPointerChange = { [weak view] p in view?.setPointer(p) }
        // A new frame size (another source, an Aa resize) changes what a fraction means: this
        // device's own pointer, while it shows, starts again in the middle and the Mac's goes there
        // too (after the tour, while one shows: `pointerFrameChanged`); the Mac's arrow follows the
        // host's next report.
        view.onVideoSizeForPointer = { [weak client] _ in client?.pointerFrameChanged() }
        // Catch up with what the sprite shows now (a pointer set before this view was hosted).
        client.renderPointer()
    }

    func updateUIView(_ uiView: HEVCDisplayView, context: Context) {}
}
