import Foundation
import CoreGraphics

/// A window Sill sized for a device goes back when it stops streaming (issue #57;
/// docs/restore-window-frames-plan.md). Pure: frames in, decisions out. The coordinator reads the
/// frames and moves the windows (StreamCoordinator's `fitToViewport` and `restoreFits`, through
/// WindowSizer); `Tests/checks/window-restore` checks this file alone.
///
/// In regular mode (Virtual Display off) Aa resizes the real window to the device's panel at the
/// text scale it asks for. The first fit records where the window was; when the window stops
/// streaming (another window or the Desktop picked, the last device gone, a stream that ended, Quit,
/// a signal) it goes back there, unless the person at the Mac has made it their own since: moved,
/// it keeps its new place and gets its own size back; resized, it is left alone. A window put on the
/// virtual display takes the frame it would have gone back to as its way home (`homeForStage`).
///
/// Frames are global CG points with a top-left origin, as Accessibility and the window server give
/// them.
enum WindowRestore {
    /// How far apart two frames, sizes or points may be and still be the same: Accessibility and the
    /// window server round differently, and an app may land a point off what it was asked.
    static let tolerance: CGFloat = 2

    /// One window Sill has sized.
    struct Record: Equatable {
        /// The frame before Sill first touched it (Accessibility's, read just before the first resize).
        var original: CGRect
        /// The frame Sill last left it at, as the app took it (read back after the resize: an app
        /// enforces a minimum, snaps to a grid, keeps the window on screen).
        var set: CGRect
        /// The size Sill last asked for: an app that applies a size after answering the write reads
        /// back its old one, and is at this size by the time it stops streaming.
        var asked: CGSize
        /// The window was away from where Sill left it when Sill fitted it again (the person at the
        /// Mac moved it, or its app did): from then on it keeps its place when it goes back.
        var moved: Bool
    }

    /// A fit: Sill resized the window from `before` and the app took `after`, asked for `asked`. The
    /// first makes the record; a later one (a rotation, another Aa step, a restart that resized it)
    /// keeps the original frame and notes a move since the last.
    static func fitted(_ r: Record?, before: CGRect, after: CGRect, asked: CGSize) -> Record {
        guard var r else { return Record(original: before, set: after, asked: asked, moved: false) }
        if !same(before.origin, r.set.origin) { r.moved = true }
        r.set = after
        r.asked = asked
        return r
    }

    /// Why a window that stopped streaming is left as it is.
    enum Reason: Equatable {
        /// In a full-screen Space: it refuses moves and sizes, and leaving it is the person's call.
        case fullScreen
        /// Its size is no longer Sill's: resized on the Mac after Sill last fitted it.
        case resized
    }

    /// What becomes of a window when it stops streaming.
    enum Decision: Equatable {
        /// Closed, or its app quit: nothing left to restore.
        case gone
        /// Already where it would go: nothing to do.
        case home
        /// Where it was, as far as can be seen, but Sill's size may still be on its way: an app that
        /// applies a size after answering the write, stopped within that moment, would otherwise
        /// take it after this and keep it. The frame is written again, without a line.
        case settle(CGRect)
        case leave(Reason)
        /// Moved and sized to this frame: the original (`whole`), or its own size where it was moved.
        case restore(CGRect, whole: Bool)
    }

    /// The window `r` describes stops streaming, `current` its frame now (nil: gone), `area` the
    /// visible frame of the display it is on (for a moved window's nudge; nil: none).
    static func decide(_ r: Record, current: CGRect?, fullScreen: Bool, area: CGRect?) -> Decision {
        guard let current else { return .gone }
        if fullScreen { return .leave(.fullScreen) }
        if same(current, r.original) {
            // Sill asked for another size and the app never showed it: on its way, or refused (an app
            // at its minimum). Writing the original again costs nothing in either case.
            if !same(r.asked, r.original.size), same(r.set.size, r.original.size) { return .settle(r.original) }
            return .home
        }
        // Sill's size is the one it read back or the one it asked for; anything else is the person's.
        guard same(current.size, r.set.size) || same(current.size, r.asked) else { return .leave(.resized) }
        if !r.moved, same(current.origin, r.set.origin) { return .restore(r.original, whole: true) }
        // Moved: its own size where it is, kept on its display as a fit keeps it.
        var target = CGRect(origin: current.origin, size: r.original.size)
        if let area { target.origin = keep(target, in: area) }
        return same(target, current) ? .home : .restore(target, whole: false)
    }

    /// The way home the virtual display keeps for a window Sill had fitted when it stages it
    /// (`VirtualStage.prepare(…, home:)`): the frame it would have gone back to had it stopped
    /// streaming now. Nil: the stage takes the window's frame as it finds it (already home, left as
    /// it is, or gone).
    static func homeForStage(_ d: Decision) -> CGRect? {
        switch d {
        case .restore(let frame, _), .settle(let frame): return frame
        case .gone, .home, .leave: return nil
        }
    }

    /// The origin that keeps `frame` inside `area`, moving it as little as possible. A frame bigger
    /// than the area keeps its top-left corner in it, so the title bar stays reachable. A fit's nudge
    /// (WindowSizer.resize) and a moved window's way back.
    static func keep(_ frame: CGRect, in area: CGRect) -> CGPoint {
        var origin = frame.origin
        if frame.maxX > area.maxX { origin.x = area.maxX - frame.width }
        if frame.maxY > area.maxY { origin.y = area.maxY - frame.height }
        origin.x = max(origin.x, area.minX)
        origin.y = max(origin.y, area.minY)
        return origin
    }

    static func same(_ a: CGPoint, _ b: CGPoint) -> Bool { abs(a.x - b.x) <= tolerance && abs(a.y - b.y) <= tolerance }
    static func same(_ a: CGSize, _ b: CGSize) -> Bool { abs(a.width - b.width) <= tolerance && abs(a.height - b.height) <= tolerance }
    static func same(_ a: CGRect, _ b: CGRect) -> Bool { same(a.origin, b.origin) && same(a.size, b.size) }

    // MARK: The windows Sill sized

    /// The records by window ID, each with what the coordinator needs to move the window (`Handle`:
    /// a WindowSizer.Placement there, anything in the check). In memory only: a frame applied at the
    /// next launch, perhaps days later, would be worse than none.
    struct Ledger<Handle> {
        struct Entry {
            var record: Record
            /// The first fit's: an Accessibility element stays valid as long as its window exists.
            let handle: Handle
        }
        private(set) var entries: [CGWindowID: Entry] = [:]

        var isEmpty: Bool { entries.isEmpty }

        func record(_ id: CGWindowID) -> Record? { entries[id]?.record }

        /// A fit of window `id` (see `WindowRestore.fitted`).
        mutating func fitted(_ id: CGWindowID, handle: Handle, before: CGRect, after: CGRect, asked: CGSize) {
            let old = entries[id]
            entries[id] = Entry(record: WindowRestore.fitted(old?.record, before: before, after: after, asked: asked),
                                handle: old?.handle ?? handle)
        }

        /// The windows that stop streaming when `keep` streams next (nil: none streams), taken out
        /// in window ID order, for the coordinator to put back.
        mutating func stopping(keeping keep: CGWindowID?) -> [(id: CGWindowID, entry: Entry)] {
            let ids = entries.keys.filter { $0 != keep }.sorted()
            var out: [(id: CGWindowID, entry: Entry)] = []
            for id in ids { if let e = entries.removeValue(forKey: id) { out.append((id, e)) } }
            return out
        }

        /// Window `id` went onto the virtual display, whose stage now keeps its way home.
        mutating func take(_ id: CGWindowID) -> Entry? { entries.removeValue(forKey: id) }
    }

    // MARK: The log

    /// "Safari — Apple Developer", or the app alone for an untitled window.
    static func name(app: String, title: String) -> String { title.isEmpty ? app : "\(app) — \(title)" }

    /// "(212,95,1280×800)", as the virtual display's lines give a frame.
    static func text(_ r: CGRect) -> String {
        String(format: "(%.0f,%.0f,%.0f×%.0f)", r.minX, r.minY, r.width, r.height)
    }

    /// The coordinator's one line about a window that stopped streaming: what it did, or why not.
    /// Nil when nothing happened as far as can be seen (gone, already home, or settled where it was).
    /// `done`: whether the restore went through.
    static func line(_ d: Decision, name: String, current: CGRect?, done: Bool) -> String? {
        switch d {
        case .gone, .home, .settle:
            return nil
        case .leave(.fullScreen):
            return "Left \(name) as it is: it is full screen"
        case .leave(.resized):
            return "Left \(name) at \(current.map(text) ?? "its frame"): it was resized on the Mac"
        case .restore(let frame, let whole):
            guard done else { return "Could not restore \(name) to \(text(frame))" }
            return whole ? "Restored \(name) to \(text(frame))" : "Restored \(name) to \(text(frame)), its own size where it was moved"
        }
    }

    /// The line for a window whose app does not answer Accessibility at the stop (a beach ball): it
    /// is left where it is rather than have each write wait out its timeout.
    static func notAnsweringLine(name: String) -> String {
        "Could not restore \(name): it is not answering Accessibility"
    }
}
