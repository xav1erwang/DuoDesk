// Copyright 2026 DUO你电脑 contributors. SPDX-License-Identifier: Apache-2.0
import Combine
import Foundation
import Network
import StreamProtocol
import UIKit

/// Owns the independent Touch Bar decoder and the subscription for the visible keyboard.
/// No source is invented: an older or unsupported Mac leaves the strip unavailable.
@MainActor final class DuoTouchBarClient: ObservableObject {
    @Published private(set) var status = TouchBarStatus(availability: .unavailable)
    let video: HEVCDisplayView
    private let inbox: DuoTouchBarInbox
    private let transmit: (StreamMessageKind, Data) -> Void
    private var connection: NWConnection?
    private var visible = false
    private var parameters: Data?
    private var pendingMove: TouchBarTouch?
    private var moveTimer: DispatchWorkItem?

    init(inbox: DuoTouchBarInbox, transmit: @escaping (StreamMessageKind, Data) -> Void) {
        self.inbox = inbox; self.transmit = transmit
        video = HEVCDisplayView(frame: .zero)
        inbox.attach(status: { [weak self] status, source in self?.receive(status, from: source) },
                     frame: { [weak self] frame, source in self?.receive(frame, from: source) })
        video.onKeyframeNeeded = { [weak self] in self?.requestRefresh() }
        video.onDecoderFailure = { [weak self] _ in self?.decoderFailed() }
    }

    /// Only the caller's currently authenticated session can be supplied here. A move to a new
    /// connection starts a fresh subscription and cannot reuse the old connection's image.
    func setConnection(_ connection: NWConnection?) {
        guard self.connection !== connection else { return }
        clear()
        self.connection = connection
        if visible, connection != nil { subscribe(true) }
    }

    func setVisible(_ visible: Bool) {
        guard self.visible != visible else { return }
        self.visible = visible
        if connection != nil { subscribe(visible) }
        if !visible { clear() }
    }

    private func subscribe(_ watching: Bool) {
        transmit(.touchBarSubscription, Wire.encode(TouchBarSubscription(watching: watching)))
    }

    private func receive(_ next: TouchBarStatus, from source: NWConnection) {
        guard visible, connection === source, next.isValid else { return }
        let old = status.surface, new = next.surface
        let changed = old?.id != new?.id || old?.encodedWidth != new?.encodedWidth
            || old?.encodedHeight != new?.encodedHeight || old?.pixelWidth != new?.pixelWidth
            || old?.pixelHeight != new?.pixelHeight
        if changed {
            pendingMove = nil; moveTimer?.cancel(); moveTimer = nil
            parameters = nil
            video.requireTouchBarSurface(new)
        }
        status = next
        // The bounded inbox drops a pending frame whenever a newer status wins. That can happen
        // even when only input capability changed and the source UUID stayed the same. Request
        // the actual latest frame after every live status so a now-static bar cannot stay stale.
        // The host coalesces and rate-limits these requests across subscribers.
        if new != nil { requestRefresh() }
    }

    private func receive(_ frame: TouchBarKeyframe, from source: NWConnection) {
        guard visible, connection === source, let surface = status.surface,
              surface.id == frame.surfaceID else { return }
        let encodedParameters = frame.parameters.encoded()
        if parameters != encodedParameters {
            parameters = encodedParameters
            video.apply(frame.parameters)
        }
        video.enqueue(frame.accessUnit, isKeyframe: true)
    }

    /// Called after a rehost too: a static bar needs a fresh image after the renderer resets.
    func requestRefresh() {
        guard visible, connection != nil, let surface = status.surface else { return }
        transmit(.touchBarRefresh, TouchBarRefresh(surfaceID: surface.id).encoded)
    }

    func send(_ touch: TouchBarTouch) {
        guard visible, connection != nil, touch.isValid, let surface = status.surface,
              surface.id == touch.surfaceID else { return }
        if touch.phase == .began || touch.phase == .moved {
            guard surface.acceptsInput, video.hasCurrentImage else { return }
        }
        if touch.phase == .moved {
            pendingMove = touch
            guard moveTimer == nil else { return }
            let work = DispatchWorkItem { [weak self] in self?.flushMove() }
            moveTimer = work
            DispatchQueue.main.asyncAfter(deadline: .now() + 1.0 / 120.0, execute: work)
        } else {
            flushMove()
            transmit(.touchBarTouch, Wire.encode(touch))
        }
    }

    private func flushMove() {
        moveTimer?.cancel(); moveTimer = nil
        guard let move = pendingMove else { return }
        pendingMove = nil
        guard visible, connection != nil, status.surface?.id == move.surfaceID,
              status.surface?.acceptsInput == true, video.hasCurrentImage else { return }
        transmit(.touchBarTouch, Wire.encode(move))
    }

    private func decoderFailed() {
        if visible, connection != nil { subscribe(false) }
        clear()
    }

    private func clear() {
        inbox.invalidate()
        pendingMove = nil; moveTimer?.cancel(); moveTimer = nil
        parameters = nil
        if status.surface != nil { video.requireTouchBarSurface(nil) }
        status = TouchBarStatus(availability: .unavailable)
    }
}
