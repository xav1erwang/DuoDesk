import AppKit
import ApplicationServices
import CoreGraphics
import ScreenCaptureKit

/// Keep the visible desktops with their physical monitors while WindowServer replaces a mirror
/// endpoint. Only windows visible at the start are recorded; hidden/minimized windows are not raised.
@MainActor
final class DesktopWindowHandoff {
    private struct Window {
        var placement: WindowSizer.Placement
        let displayID: CGDirectDisplayID
        let originalFullscreen: Bool
        var normalHome: CGRect?
    }
    private let sourceID: CGDirectDisplayID
    private let homes: [CGDirectDisplayID: CGRect]
    private let sizer = WindowSizer()
    private var windows: [Window] = []

    enum Failure: LocalizedError {
        case windowUnavailable
        var errorDescription: String? { "Mac 暂时无法保留所选显示器的窗口，请稍后重新连接。" }
    }

    init(sourceID: CGDirectDisplayID, homes: [CGDirectDisplayID: CGRect]) {
        self.sourceID = sourceID; self.homes = homes
    }

    func record() async throws {
        let content = try await SCShareableContent.excludingDesktopWindows(true, onScreenWindowsOnly: true)
        for window in content.windows where window.isOnScreen && window.windowLayer == 0
            && window.frame.width >= 40 && window.frame.height >= 40
            && window.owningApplication != nil
            && window.owningApplication?.processID != ProcessInfo.processInfo.processIdentifier
            && visible(window.windowID) {
            guard let liveFrame = WindowSizer.liveBounds(of: window.windowID),
                  let home = homes.max(by: { $0.value.intersection(liveFrame).area < $1.value.intersection(liveFrame).area }),
                  home.value.intersection(liveFrame).area > 0 else { continue }
            guard let matched = sizer.placement(for: window) else {
                // System overlays and some borderless windows have no AX window. They cannot
                // be repositioned by this handoff and must not prevent the desktop from streaming.
                continue
            }
            // Stage Manager can expose a scaled preview under the real window's title and ID.
            // Its AX element describes the full window, so moving it cannot move this preview.
            if Self.isScaledPreview(liveFrame, accessibilityFrame: matched.originalFrame) { continue }
            // AX geometry can lag a just-restored mirror. Save the actual WindowServer frame,
            // or a fast reconnect can treat the former virtual bounds as the window's home.
            let placement = matched.homed(at: liveFrame)
            // Some apps retain AXFullScreen while reporting a normal on-screen window after a
            // display transition. A fullscreen handoff needs both the flag and the actual canvas.
            let full = WindowSizer.isFullScreen(placement.element) && near(liveFrame, home.value)
            var movable = DarwinBoolean(false), fullscreenWritable = DarwinBoolean(false)
            AXUIElementIsAttributeSettable(placement.element, kAXPositionAttribute as CFString, &movable)
            AXUIElementIsAttributeSettable(placement.element, "AXFullScreen" as CFString, &fullscreenWritable)
            guard movable.boolValue || (full && fullscreenWritable.boolValue) else { continue }
            windows.append(Window(placement: placement, displayID: home.key, originalFullscreen: full,
                                  normalHome: full ? nil : placement.originalFrame))
        }
        print("Duo desktop handoff recorded \(windows.count) visible windows; selected display \(sourceID)")
    }

    /// The mirror's bounds can differ from the saved physical origin (macOS aligns adjoining
    /// edges after a resize). Map relative to the actual endpoint, never change the system main.
    func apply(captureID: CGDirectDisplayID) async throws {
        if windows.contains(where: \.originalFullscreen) {
            // A normal mode change resizes an existing fullscreen Space asynchronously. Give it
            // the next layout turn before deciding that a cross-display handoff is necessary.
            try await Task.sleep(for: .milliseconds(180))
        }
        try await applyRecordedWindows { index in
            try await self.applyWindow(at: index, captureID: captureID)
        }
    }

    private func applyRecordedWindows(_ operation: (Int) async throws -> Void) async throws {
        for index in windows.indices {
            try Task.checkCancellation()
            do {
                try await operation(index)
            } catch {
                // A utility window on another monitor can refuse AX writes. Keep trying to
                // preserve it, but do not discard an otherwise ready selected desktop for it.
                guard windows[index].displayID != sourceID, !(error is CancellationError) else { throw error }
                let item = windows[index]
                print("Duo window handoff skipped outside selected display: pid \(item.placement.pid), window \(item.placement.windowID)")
            }
        }
    }

    private func applyWindow(at index: Int, captureID: CGDirectDisplayID) async throws {
        let item = windows[index]
        let selected = item.displayID == sourceID
        if !selected { AXUIElementSetMessagingTimeout(item.placement.element, 0.2) }
        defer { if !selected { AXUIElementSetMessagingTimeout(item.placement.element, 1.0) } }
        guard let current = WindowSizer.liveBounds(of: item.placement.windowID) else { return }
        // A display change can send a previously normal window into Stage Manager's strip.
        // Re-read its live geometry here: the frame saved by record() predates that transition.
        if systemOwnsPlacement(frame: current, element: item.placement.element) {
            print("Duo window handoff: system manages preview for window \(item.placement.windowID)")
            return
        }
        let destination = CGDisplayBounds(item.displayID == sourceID ? captureID : item.displayID)
        guard destination.width > 0, destination.height > 0 else { throw Failure.windowUnavailable }
        if item.displayID != sourceID, near(current, item.placement.originalFrame),
           visible(item.placement.windowID) { return }
        if item.originalFullscreen, WindowSizer.isFullScreen(item.placement.element),
           near(current, destination), visible(item.placement.windowID) { return }
        if !item.originalFullscreen, reachable(current, on: destination),
           visible(item.placement.windowID) { return }

        print("Duo window handoff: pid \(item.placement.pid), window \(item.placement.windowID), source \(item.displayID), original \(item.placement.originalFrame), current \(String(describing: current)), target \(destination), fullscreen \(item.originalFullscreen)/\(WindowSizer.isFullScreen(item.placement.element))")

        if WindowSizer.isFullScreen(item.placement.element) {
            let fullBounds = current
            try setFullscreen(item.placement.element, false)
            try await waitForNormal(item.placement, fullBounds: fullBounds)
            if windows[index].normalHome == nil, let normal = WindowSizer.liveBounds(of: item.placement.windowID),
               let original = homes[item.displayID] {
                windows[index].normalHome = CGRect(x: original.minX + normal.minX - fullBounds.minX,
                                                   y: original.minY + normal.minY - fullBounds.minY,
                                                   width: normal.width, height: normal.height)
            }
        }
        guard let home = homes[item.displayID],
              let normal = windows[index].normalHome ?? WindowSizer.liveBounds(of: item.placement.windowID) else { throw Failure.windowUnavailable }
        let wanted = item.displayID == sourceID
            ? fit(CGRect(x: destination.minX + normal.minX - home.minX,
                         y: destination.minY + normal.minY - home.minY,
                         width: normal.width, height: normal.height), in: destination)
            : normal
        let result = move(item.placement, to: wanted)
        guard result != .apiDisabled else { throw Failure.windowUnavailable }
        // Fixed-size windows can reject AXSize while accepting AXPosition. Judge the
        // resulting reachable frame, rather than treating that size refusal as data loss.
        do {
            try await wait(attempts: selected ? 80 : 16) {
                guard let frame = WindowSizer.liveBounds(of: item.placement.windowID) else { return false }
                return self.visible(item.placement.windowID) && self.reachable(frame, on: destination)
            }
        } catch {
            if error is CancellationError { throw error }
            if let frame = WindowSizer.liveBounds(of: item.placement.windowID),
               systemOwnsPlacement(frame: frame, element: item.placement.element) { return }
            throw error
        }
        if let frame = WindowSizer.liveBounds(of: item.placement.windowID),
           systemOwnsPlacement(frame: frame, element: item.placement.element) { return }
        if item.originalFullscreen {
            try setFullscreen(item.placement.element, true)
            try await wait {
                WindowSizer.isFullScreen(item.placement.element)
                    && WindowSizer.liveBounds(of: item.placement.windowID).map { self.near($0, destination) } == true
                    && self.visible(item.placement.windowID)
            }
        }
    }

    /// Called after physical modes and origins have returned, including the synchronous quit
    /// path. AX talks to the other process's event loop; no nested AppKit run loop is introduced.
    func restore() -> Bool {
        var complete = true
        for item in windows {
            guard WindowSizer.liveBounds(of: item.placement.windowID) != nil,
                  DuoDesktopDisplay.isDisplayOnline(item.displayID) else { continue }
            let element = item.placement.element
            let destination = CGDisplayBounds(item.displayID)
            let home = item.normalHome ?? item.placement.originalFrame
            if let frame = WindowSizer.liveBounds(of: item.placement.windowID),
               systemOwnsPlacement(frame: frame, element: element) {
                // Restore the app's logical frame without asking its transformed sidebar
                // preview to become a full window or bringing the app to the foreground.
                if WindowSizer.frame(of: element).map({ near($0, home) }) != true {
                    _ = move(item.placement, to: home)
                }
                continue
            }
            if !item.originalFullscreen,
               WindowSizer.liveBounds(of: item.placement.windowID).map({ near($0, home) }) == true { continue }
            if item.originalFullscreen, WindowSizer.isFullScreen(element),
               WindowSizer.liveBounds(of: item.placement.windowID).map({ near($0, destination) }) == true,
               visible(item.placement.windowID) { continue }
            if WindowSizer.isFullScreen(element) {
                let fullBounds = WindowSizer.liveBounds(of: item.placement.windowID) ?? destination
                let wasCanvas = WindowRestore.coversDisplay(fullBounds, WindowSizer.displayFrames())
                do { try setFullscreen(element, false) } catch { complete = false; continue }
                guard waitSync({
                    !WindowSizer.isFullScreen(element) && self.visible(item.placement.windowID)
                        && WindowSizer.liveBounds(of: item.placement.windowID).map { !wasCanvas || !self.near($0, fullBounds) } == true
                }) else { complete = false; continue }
            }
            if WindowSizer.liveBounds(of: item.placement.windowID).map({ near($0, home) }) != true {
                _ = move(item.placement, to: home)
                guard waitSync({ WindowSizer.liveBounds(of: item.placement.windowID).map { self.near($0, home) } == true }) else {
                    // An app may enforce its own size or position after a display change. The
                    // selected desktop stays on its original monitor; another screen's utility
                    // window can stay reachable on any original physical monitor.
                    if !item.originalFullscreen,
                       let frame = WindowSizer.liveBounds(of: item.placement.windowID),
                       reachable(frame, on: destination)
                        || (item.displayID != sourceID && homes.keys.contains(where: {
                            DuoDesktopDisplay.isDisplayOnline($0) && reachable(frame, on: CGDisplayBounds($0))
                        })) {
                        continue
                    }
                    print("Duo window restoration pending: pid \(item.placement.pid), window \(item.placement.windowID)")
                    complete = false; continue
                }
            }
            if item.originalFullscreen {
                do { try setFullscreen(element, true) } catch { complete = false; continue }
                complete = waitSync {
                    WindowSizer.isFullScreen(element) && self.visible(item.placement.windowID)
                        && WindowSizer.liveBounds(of: item.placement.windowID).map { self.near($0, destination) } == true
                } && complete
            }
        }
        return complete
    }

    private func setFullscreen(_ element: AXUIElement, _ value: Bool) throws {
        let result = AXUIElementSetAttributeValue(element, "AXFullScreen" as CFString, value ? kCFBooleanTrue : kCFBooleanFalse)
        guard result == .success || result == .invalidUIElement else { throw Failure.windowUnavailable }
    }
    private func move(_ placement: WindowSizer.Placement, to wanted: CGRect) -> AXError {
        guard let actual = WindowSizer.liveBounds(of: placement.windowID) else { return .invalidUIElement }
        // After a mirror rebase AppKit can still cache the old AX frame while WindowServer has
        // moved the actual window. Writing that identical cached value is then a no-op. A one
        // point change invalidates the cache before writing the intended position/size again.
        if let cached = WindowSizer.frame(of: placement.element) {
            if cached.origin == wanted.origin, actual.origin != wanted.origin {
                _ = WindowSizer.setPosition(placement.element, CGPoint(x: wanted.minX + 1, y: wanted.minY))
            }
            if cached.size == wanted.size, actual.size != wanted.size {
                _ = sizer.move(placement, to: CGRect(origin: wanted.origin,
                    size: CGSize(width: wanted.width + 1, height: wanted.height)))
            }
        }
        if actual.size == wanted.size { return WindowSizer.setPosition(placement.element, wanted.origin) }
        return sizer.move(placement, to: wanted)
    }
    private func waitForNormal(_ placement: WindowSizer.Placement, fullBounds: CGRect) async throws {
        let wasCanvas = WindowRestore.coversDisplay(fullBounds, WindowSizer.displayFrames())
        try await wait {
            !WindowSizer.isFullScreen(placement.element) && self.visible(placement.windowID)
                && WindowSizer.liveBounds(of: placement.windowID).map { !wasCanvas || !self.near($0, fullBounds) } == true
        }
    }
    private func wait(attempts: Int = 80, _ condition: () -> Bool) async throws {
        var stable = 0
        for _ in 0..<attempts {
            stable = condition() ? stable + 1 : 0
            if stable >= 4 { return }
            try await Task.sleep(for: .milliseconds(50))
        }
        throw Failure.windowUnavailable
    }
    private func waitSync(_ condition: () -> Bool) -> Bool {
        var stable = 0
        for _ in 0..<60 {
            stable = condition() ? stable + 1 : 0
            if stable >= 3 { return true }
            Thread.sleep(forTimeInterval: 0.025)
        }
        return false
    }
    private func visible(_ id: CGWindowID) -> Bool {
        guard let row = (CGWindowListCopyWindowInfo(.optionIncludingWindow, id) as? [[String: Any]])?.first else { return false }
        return row[kCGWindowIsOnscreen as String] as? Bool == true
    }
    private func near(_ a: CGRect, _ b: CGRect) -> Bool {
        abs(a.minX - b.minX) <= 3 && abs(a.minY - b.minY) <= 3
            && abs(a.width - b.width) <= 3 && abs(a.height - b.height) <= 3
    }
    private func contains(_ container: CGRect, _ rect: CGRect) -> Bool { container.insetBy(dx: -3, dy: -3).contains(rect) }
    nonisolated static func isScaledPreview(_ frame: CGRect, accessibilityFrame: CGRect) -> Bool {
        frame.width > 0 && frame.height > 0 && accessibilityFrame.width > frame.width * 1.5
            && accessibilityFrame.height > frame.height * 1.5
    }
    private func systemOwnsPlacement(frame: CGRect, element: AXUIElement) -> Bool {
        guard let logicalFrame = WindowSizer.frame(of: element) else { return false }
        return Self.isScaledPreview(frame, accessibilityFrame: logicalFrame)
    }
    private func reachable(_ frame: CGRect, on display: CGRect) -> Bool {
        contains(display, CGRect(origin: frame.origin, size: CGSize(width: min(40, frame.width), height: min(28, frame.height))))
    }
    private func fit(_ rect: CGRect, in area: CGRect) -> CGRect {
        let width = min(rect.width, area.width), height = min(rect.height, area.height - 36)
        return CGRect(x: min(max(rect.minX, area.minX), area.maxX - width),
                      y: min(max(rect.minY, area.minY + 28), area.maxY - height - 8), width: width, height: height)
    }

    #if DUO_DISPLAY_RESTORE_TESTING
    /// Exercise refused AX writes without touching windows or display configuration.
    static func inspectRefusedWindowHandoffForTesting() async -> [Bool] {
        let handoff = DesktopWindowHandoff(sourceID: 5, homes: [:])
        let element = AXUIElementCreateApplication(getpid())
        handoff.windows = [4, 5, 4].enumerated().map { index, display in
            Window(placement: WindowSizer.Placement(windowID: UInt32(index), pid: getpid(), element: element,
                originalFrame: .zero, appName: "fixture", title: ""), displayID: UInt32(display),
                originalFullscreen: false, normalHome: .zero)
        }
        var checks: [Bool] = []
        var visited: [Int] = []
        do {
            try await handoff.applyRecordedWindows { index in
                visited.append(index)
                if index == 0 { throw Failure.windowUnavailable }
            }
            checks.append(visited == [0, 1, 2])
        } catch { checks.append(false) }

        visited = []
        do {
            try await handoff.applyRecordedWindows { index in
                visited.append(index)
                if index == 1 { throw Failure.windowUnavailable }
            }
            checks.append(false)
        } catch { checks.append(visited == [0, 1]) }

        visited = []
        do {
            try await handoff.applyRecordedWindows { index in
                visited.append(index)
                throw CancellationError()
            }
            checks.append(false)
        } catch is CancellationError { checks.append(visited == [0]) }
          catch { checks.append(false) }
        return checks
    }
    #endif
}

private extension CGRect { var area: CGFloat { isNull ? 0 : width * height } }
