import Foundation
import CoreGraphics

// Checks WindowRestore (Sources/SillHost/WindowRestore.swift; docs/restore-window-frames-plan.md,
// issue #57): a window Sill sized for a device goes back when it stops streaming. First the rule at
// its edges: `keep`, `fitted`, `decide` for every outcome, `homeForStage`, the ledger and the lines.
// Then a model of the coordinator's glue (StreamCoordinator's `fitToViewport`, `select`,
// `restoreFits`, `stageHome`, `shutdownForExit`, and WindowSizer's `resize` and `restore`) against a
// stand-in Mac: random sessions of picks, viewports, restarts, the catalog's resize check, the person
// at the Mac moving, resizing, closing and full-screening windows, apps that clamp to a minimum, snap
// to a grid or apply a size late, the virtual display on and off, the last device leaving and Quit,
// each window's frame held to where the person expects it.
//
// Compiled alone with this file (build.sh): swiftc -O WindowRestore.swift main.swift

var failures = 0
var passes = 0
func check(_ ok: Bool, _ what: @autoclosure () -> String) {
    if ok { passes += 1 } else { failures += 1; if failures <= 40 { print("FAIL: \(what())") } }
}
func eq<T: Equatable>(_ got: T, _ want: T, _ what: String) { check(got == want, "\(what): got \(got), want \(want)") }
func R(_ x: CGFloat, _ y: CGFloat, _ w: CGFloat, _ h: CGFloat) -> CGRect { CGRect(x: x, y: y, width: w, height: h) }
func P(_ x: CGFloat, _ y: CGFloat) -> CGPoint { CGPoint(x: x, y: y) }
func S(_ w: CGFloat, _ h: CGFloat) -> CGSize { CGSize(width: w, height: h) }

// MARK: keep

let area = R(0, 25, 1512, 920)        // a laptop's display below its menu bar, above its Dock
eq(WindowRestore.keep(R(100, 100, 800, 500), in: area), P(100, 100), "keep: inside stays")
eq(WindowRestore.keep(R(900, 100, 800, 500), in: area), P(712, 100), "keep: off the right edge comes left")
eq(WindowRestore.keep(R(100, 600, 800, 500), in: area), P(100, 445), "keep: off the bottom comes up")
eq(WindowRestore.keep(R(-50, 100, 800, 500), in: area), P(0, 100), "keep: off the left edge comes right")
eq(WindowRestore.keep(R(100, 10, 800, 500), in: area), P(100, 25), "keep: under the menu bar comes down")
eq(WindowRestore.keep(R(300, 100, 2000, 500), in: area), P(0, 100), "keep: wider than the area keeps its left edge in it")
eq(WindowRestore.keep(R(100, 300, 800, 1200), in: area), P(100, 25), "keep: taller than the area keeps its top in it")
eq(WindowRestore.keep(R(712, 445, 800, 500), in: area), P(712, 445), "keep: exactly at the right and bottom edges stays")
eq(WindowRestore.keep(R(1400, 900, 800, 500), in: area), P(712, 445), "keep: off two edges comes in on both")
eq(WindowRestore.keep(R(2000, 100, 300, 200), in: R(1512, 0, 1920, 1080)), P(2000, 100), "keep: a second display's area")

// MARK: fitted

let O = R(100, 100, 1200, 800)        // the window as the person had it
let Sz = S(800, 500)                  // what the device's panel asks for
let Sf = R(100, 100, 800, 500)        // where Sill left it
let first = WindowRestore.fitted(nil, before: O, after: Sf, asked: Sz)
eq(first, WindowRestore.Record(original: O, set: Sf, asked: Sz, moved: false), "fitted: the first records where it was")
let refit = WindowRestore.fitted(first, before: Sf, after: R(100, 100, 500, 800), asked: S(500, 800))
eq(refit, WindowRestore.Record(original: O, set: R(100, 100, 500, 800), asked: S(500, 800), moved: false),
   "fitted: a rotation keeps the original, takes the new frame and size asked")
eq(WindowRestore.fitted(first, before: R(102, 98, 800, 500), after: R(102, 98, 640, 400), asked: S(640, 400)).moved, false,
   "fitted: 2 pt from where Sill left it is not a move")
eq(WindowRestore.fitted(first, before: R(102.5, 100, 800, 500), after: R(102.5, 100, 640, 400), asked: S(640, 400)).moved, true,
   "fitted: 2.5 pt across is a move")
eq(WindowRestore.fitted(first, before: R(100, 103, 800, 500), after: R(100, 103, 640, 400), asked: S(640, 400)).moved, true,
   "fitted: 3 pt down is a move")
let movedOnce = WindowRestore.fitted(first, before: R(300, 200, 800, 500), after: R(300, 200, 640, 400), asked: S(640, 400))
let afterMove = WindowRestore.fitted(movedOnce, before: R(300, 200, 640, 400), after: R(300, 200, 800, 500), asked: Sz)
eq(afterMove.moved, true, "fitted: a move stays noted through a later fit in place")
eq(afterMove.original, O, "fitted: the original survives every later fit")
eq(WindowRestore.fitted(first, before: R(100, 100, 1000, 700), after: Sf, asked: Sz),
   WindowRestore.Record(original: O, set: Sf, asked: Sz, moved: false),
   "fitted: a resize on the Mac that a re-fit undid is forgotten (no move)")

// MARK: decide

let rec = first
func decide(_ r: WindowRestore.Record, _ current: CGRect?, fullScreen: Bool = false, area a: CGRect? = area) -> WindowRestore.Decision {
    WindowRestore.decide(r, current: current, fullScreen: fullScreen, area: a)
}
eq(decide(rec, nil), .gone, "decide: no frame is gone")
eq(decide(rec, nil, fullScreen: true), .gone, "decide: gone before full screen")
eq(decide(rec, Sf, fullScreen: true), .leave(.fullScreen), "decide: full screen is left as it is")
eq(decide(rec, O, fullScreen: true), .leave(.fullScreen), "decide: full screen, even at the original frame")
eq(decide(rec, O), .home, "decide: at the original frame is home")
eq(decide(rec, R(102, 98, 1198, 802)), .home, "decide: within 2 pt of the original is home")
eq(decide(rec, Sf), .restore(O, whole: true), "decide: where Sill left it goes back whole")
eq(decide(rec, R(102, 102, 798, 502)), .restore(O, whole: true), "decide: within 2 pt of where Sill left it goes back whole")
eq(decide(rec, R(103, 100, 800, 500)), .restore(R(103, 100, 1200, 800), whole: false),
   "decide: moved 3 pt keeps its place and gets its size back")
eq(decide(rec, R(900, 300, 800, 500)), .restore(R(312, 145, 1200, 800), whole: false),
   "decide: moved near the corner: its size back, kept on the display")
eq(decide(rec, R(900, 300, 800, 500), area: nil), .restore(R(900, 300, 1200, 800), whole: false),
   "decide: no area, no nudge")
eq(decide(rec, R(1600, 200, 800, 500), area: R(1512, 0, 1920, 1080)), .restore(R(1600, 200, 1200, 800), whole: false),
   "decide: moved to the second display keeps to it")
eq(decide(rec, R(100, 100, 803, 500)), .leave(.resized), "decide: 3 pt wider than Sill left it was resized on the Mac")
eq(decide(rec, R(100, 100, 800, 497)), .leave(.resized), "decide: 3 pt shorter was resized on the Mac")
eq(decide(rec, R(100, 100, 1000, 700)), .leave(.resized), "decide: resized on the Mac is left alone")
eq(decide(rec, R(300, 300, 1200, 800)), .leave(.resized), "decide: its own size by hand elsewhere is the person's")
// An app that applies a size after answering the write read back its old frame: at the asked size it
// is Sill's all the same.
let lagging = WindowRestore.fitted(nil, before: O, after: O, asked: Sz)
eq(decide(lagging, Sf), .restore(O, whole: true), "decide: a late app at the asked size goes back whole")
eq(decide(lagging, R(400, 300, 800, 500)), .restore(R(312, 145, 1200, 800), whole: false), "decide: a late app, moved")
eq(decide(lagging, O), .settle(O), "decide: a late app stopped before it showed Sill's size: its frame written again")
eq(decide(lagging, R(101, 99, 1199, 801)), .settle(O), "decide: settled within 2 pt of the original too")
eq(decide(WindowRestore.fitted(nil, before: O, after: O, asked: S(1202, 798)), O), .home,
   "decide: asked within 2 pt of its own size: home, nothing to settle")
eq(decide(WindowRestore.fitted(nil, before: O, after: R(100, 100, 1203, 800), asked: Sz), O), .home,
   "decide: a read-back that showed a change: home is home")
eq(decide(WindowRestore.fitted(lagging, before: Sf, after: Sf, asked: S(640, 400)), O), .home,
   "decide: back at its own frame after a fit that showed: the person's (home)")
eq(decide(lagging, R(100, 100, 803, 500)), .leave(.resized), "decide: a late app off both the read-back and the asked size")
// An app with a minimum took more than asked: what it read back is Sill's.
let clamped = WindowRestore.fitted(nil, before: O, after: R(100, 100, 900, 600), asked: Sz)
eq(decide(clamped, R(100, 100, 900, 600)), .restore(O, whole: true), "decide: a minimum read back goes back whole")
eq(decide(clamped, R(100, 100, 800, 500)), .restore(O, whole: true), "decide: the asked size of a clamped app is still Sill's")
// Moved at a later fit: whole no longer, even where Sill last left it.
let noted = WindowRestore.Record(original: O, set: Sf, asked: Sz, moved: true)
eq(decide(noted, Sf), .restore(R(100, 100, 1200, 800), whole: false), "decide: a noted move keeps its place where Sill left it")
eq(decide(noted, R(200, 200, 800, 500)), .restore(R(200, 145, 1200, 800), whole: false), "decide: a noted move, moved again")
// A size the app refused (it read back its own): a move is all that is left, and the person's.
let refused = WindowRestore.fitted(nil, before: O, after: O, asked: S(1200, 800))
eq(decide(refused, R(150, 120, 1200, 800)), .home, "decide: its own size where it was moved is home")
eq(decide(refused, R(0, 0, 1200, 800)), .restore(R(0, 25, 1200, 800), whole: false),
   "decide: its own size under the menu bar comes down (the area)")
// Sill nudged it and the app kept its size: back to the original place.
let nudged = WindowRestore.fitted(nil, before: R(900, 100, 600, 400), after: R(712, 100, 600, 400), asked: S(800, 500))
eq(decide(nudged, R(712, 100, 600, 400)), .restore(R(900, 100, 600, 400), whole: true), "decide: a nudge Sill made is undone")

// MARK: homeForStage

eq(WindowRestore.homeForStage(.restore(O, whole: true)), O, "homeForStage: the original")
eq(WindowRestore.homeForStage(.restore(R(5, 6, 7, 8), whole: false)), R(5, 6, 7, 8), "homeForStage: its own size where it was moved")
eq(WindowRestore.homeForStage(.home), nil, "homeForStage: already home: as found")
eq(WindowRestore.homeForStage(.settle(O)), O, "homeForStage: settled: the original")
eq(WindowRestore.homeForStage(.leave(.resized)), nil, "homeForStage: resized: as found")
eq(WindowRestore.homeForStage(.leave(.fullScreen)), nil, "homeForStage: full screen: as found")
eq(WindowRestore.homeForStage(.gone), nil, "homeForStage: gone")

// MARK: The ledger

do {
    var ledger = WindowRestore.Ledger<String>()
    check(ledger.isEmpty, "ledger: empty at first")
    ledger.fitted(7, handle: "seven", before: O, after: Sf, asked: Sz)
    eq(ledger.record(7), first, "ledger: the first fit's record")
    check(!ledger.isEmpty, "ledger: not empty after a fit")
    ledger.fitted(7, handle: "seven again", before: Sf, after: R(100, 100, 500, 800), asked: S(500, 800))
    eq(ledger.entries[7]?.handle, "seven", "ledger: a re-fit keeps the first fit's handle")
    eq(ledger.record(7)?.original, O, "ledger: a re-fit keeps the original")
    eq(ledger.record(7)?.set, R(100, 100, 500, 800), "ledger: a re-fit takes the new frame")
    ledger.fitted(9, handle: "nine", before: R(0, 25, 400, 300), after: R(0, 25, 500, 400), asked: S(500, 400))
    ledger.fitted(3, handle: "three", before: R(10, 30, 400, 300), after: R(10, 30, 500, 400), asked: S(500, 400))
    let out = ledger.stopping(keeping: 7)
    eq(out.map(\.id), [3, 9], "ledger: stopping returns every window but the one kept, in ID order")
    eq(out.map(\.entry.handle), ["three", "nine"], "ledger: with their handles")
    eq(ledger.record(3), nil, "ledger: a stopped window is taken out")
    check(ledger.record(7) != nil, "ledger: the kept window stays")
    eq(ledger.stopping(keeping: 7).count, 0, "ledger: nothing more to stop")
    eq(ledger.stopping(keeping: 42).map(\.id), [7], "ledger: keeping a window it does not have stops every one")
    check(ledger.isEmpty, "ledger: empty after the last stop")
    ledger.fitted(5, handle: "five", before: O, after: Sf, asked: Sz)
    eq(ledger.take(5)?.handle, "five", "ledger: take hands over the entry")
    check(ledger.take(5) == nil, "ledger: taken once")
    check(ledger.isEmpty, "ledger: empty after take")
    ledger.fitted(5, handle: "five, later", before: Sf, after: R(100, 100, 640, 400), asked: S(640, 400))
    eq(ledger.record(5)?.original, Sf, "ledger: after take, a fit starts afresh from where it was")
    eq(ledger.entries[5]?.handle, "five, later", "ledger: with the new handle")
    eq(ledger.stopping(keeping: nil).map(\.id), [5], "ledger: keeping nothing stops every one")
    // In window ID order whatever order the dictionary keeps (its seed is random per process).
    for id in [41, 7, 300, 12, 9, 1024, 2, 77, 5, 64, 1, 900] as [CGWindowID] {
        ledger.fitted(id, handle: "w\(id)", before: O, after: Sf, asked: Sz)
    }
    eq(ledger.stopping(keeping: 77).map(\.id), [1, 2, 5, 7, 9, 12, 41, 64, 300, 900, 1024], "ledger: stopping in window ID order")
    eq(ledger.stopping(keeping: nil).map(\.id), [77], "ledger: then the one kept")
}

// MARK: The lines

let safari = WindowRestore.name(app: "Safari", title: "Apple Developer")
eq(safari, "Safari — Apple Developer", "name: app and title")
eq(WindowRestore.name(app: "Finder", title: ""), "Finder", "name: an untitled window is its app")
eq(WindowRestore.text(R(212, 95, 1280, 800)), "(212,95,1280×800)", "text: a frame as the stage writes it")
eq(WindowRestore.text(R(-1512, 24.4, 1280.6, 800)), "(-1512,24,1281×800)", "text: rounded, a display to the left")
eq(WindowRestore.line(.gone, name: safari, current: nil, done: false), nil, "line: none for a window gone")
eq(WindowRestore.line(.home, name: safari, current: O, done: false), nil, "line: none for a window already home")
eq(WindowRestore.line(.settle(O), name: safari, current: O, done: true), nil, "line: none for a window settled where it was")
eq(WindowRestore.line(.leave(.fullScreen), name: safari, current: R(0, 0, 1512, 982), done: false),
   "Left Safari — Apple Developer as it is: it is full screen", "line: full screen")
eq(WindowRestore.line(.leave(.resized), name: safari, current: R(300, 300, 1000, 700), done: false),
   "Left Safari — Apple Developer at (300,300,1000×700): it was resized on the Mac", "line: resized")
eq(WindowRestore.line(.restore(O, whole: true), name: safari, current: Sf, done: true),
   "Restored Safari — Apple Developer to (100,100,1200×800)", "line: restored whole, in the stage's words")
eq(WindowRestore.line(.restore(R(312, 145, 1200, 800), whole: false), name: safari, current: R(900, 300, 800, 500), done: true),
   "Restored Safari — Apple Developer to (312,145,1200×800), its own size where it was moved", "line: restored, moved")
eq(WindowRestore.line(.restore(O, whole: true), name: safari, current: Sf, done: false),
   "Could not restore Safari — Apple Developer to (100,100,1200×800)", "line: a restore that failed")
eq(WindowRestore.notAnsweringLine(name: safari), "Could not restore Safari — Apple Developer: it is not answering Accessibility",
   "line: an app that does not answer")

let unitPasses = passes
let unitFailures = failures
print("window-restore: the rule, \(unitPasses + unitFailures) cases, \(unitFailures) failed")

// MARK: The model: the coordinator's glue against a stand-in Mac

/// A seeded generator, so a failing session can be run again.
struct RNG {
    var s: UInt64
    mutating func next() -> UInt64 {
        s &+= 0x9E3779B97F4A7C15
        var z = s
        z = (z ^ (z >> 30)) &* 0xBF58476D1CE4E5B9
        z = (z ^ (z >> 27)) &* 0x94D049BB133111EB
        return z ^ (z >> 31)
    }
    mutating func int(_ n: Int) -> Int { Int(next() % UInt64(n)) }
    mutating func range(_ lo: Int, _ hi: Int) -> CGFloat { CGFloat(lo + int(hi - lo + 1)) }
    mutating func chance(_ p: Double) -> Bool { Double(next() % 1_000_000) / 1_000_000 < p }
}

/// How an app takes a size: its minimum, a grid it snaps down to, and whether it applies a size only
/// after answering the write (Accessibility then reads the old one until it does).
struct AppKind { var minSize: CGSize; var grid: CGFloat; var late: Bool }

struct Win {
    var frame: CGRect
    var app: AppKind
    var closed = false
    var fullScreen = false
    var beforeFullScreen: CGRect = .zero
    var pendingSize: CGSize?
}

/// The Mac: two displays, the windows, and Accessibility's view of them.
struct Mac {
    static let displays = [R(0, 0, 1512, 982), R(1512, 0, 1920, 1080)]
    static let visible = [R(0, 25, 1512, 920), R(1512, 25, 1920, 1055)]
    static let virtualDisplay = R(6000, 0, 2400, 2400)
    var wins: [CGWindowID: Win] = [:]

    /// WindowSizer.visibleArea: the display holding most of the rect (the first on a tie).
    static func area(around r: CGRect) -> CGRect {
        func overlap(_ a: CGRect) -> CGFloat { let i = a.intersection(r); return i.isNull ? 0 : i.width * i.height }
        var best = visible[0]
        for a in visible.dropFirst() where overlap(a) > overlap(best) { best = a }
        return best
    }
    static func takes(_ app: AppKind, _ s: CGSize) -> CGSize {
        var w = max(s.width, app.minSize.width), h = max(s.height, app.minSize.height)
        if app.grid > 1 { w = (w / app.grid).rounded(.down) * app.grid; h = (h / app.grid).rounded(.down) * app.grid }
        return S(max(w, app.minSize.width), max(h, app.minSize.height))
    }
    /// Accessibility's frame: nil for a window gone; a late app's old size until it applies.
    func ax(_ id: CGWindowID) -> CGRect? {
        guard let w = wins[id], !w.closed else { return nil }
        return w.frame
    }
    mutating func setPosition(_ id: CGWindowID, _ p: CGPoint) -> Bool {
        guard let w = wins[id], !w.closed, !w.fullScreen else { return false }
        wins[id]!.frame.origin = p
        return true
    }
    mutating func setSize(_ id: CGWindowID, _ s: CGSize) -> Bool {
        guard let w = wins[id], !w.closed, !w.fullScreen else { return false }
        let took = Self.takes(w.app, s)
        if w.app.late { wins[id]!.pendingSize = took } else { wins[id]!.frame.size = took }
        return true
    }
    mutating func applyLate() {
        for (id, w) in wins where w.pendingSize != nil {
            if !w.closed { wins[id]!.frame.size = w.pendingSize! }
            wins[id]!.pendingSize = nil
        }
    }
}

enum Source: Equatable { case none, desktop, window(CGWindowID) }

/// What the person at the Mac expects of one window through a spell of Sill's fits.
struct Spell { var original: CGRect; var moved = false; var resizedSinceFit = false }

struct Model {
    var mac = Mac()
    let seed: UInt64
    var rng: RNG
    var ledger = WindowRestore.Ledger<CGWindowID>()
    var active: Source = .none
    var panel: CGSize? = nil
    var scale: CGFloat? = nil
    var vd = false
    var staged: (id: CGWindowID, home: CGRect)? = nil
    var encoderSize: CGSize? = nil
    var shuttingDown = false
    // The oracle.
    var spells: [CGWindowID: Spell] = [:]
    var expectHome: [CGWindowID: CGRect] = [:]      // a staged window's way home
    var everTouched: Set<CGWindowID> = []
    var personFrame: [CGWindowID: CGRect] = [:]     // a window Sill never touched: where the person left it
    var log: [String] = []
    var seen: [String: Int] = [:]

    init(seed: UInt64) {
        self.seed = seed
        rng = RNG(s: seed)
        let kinds = [AppKind(minSize: S(200, 150), grid: 1, late: false), AppKind(minSize: S(700, 450), grid: 1, late: false),
                     AppKind(minSize: S(300, 200), grid: 7, late: false), AppKind(minSize: S(200, 150), grid: 1, late: true)]
        for id in CGWindowID(1)...CGWindowID(4) {
            let app = kinds[rng.int(kinds.count)]
            let size = Mac.takes(app, S(rng.range(400, 1300), rng.range(300, 860)))
            let a = Mac.visible[rng.int(2)]
            let origin = P(a.minX + rng.range(0, Int(max(0, a.width - size.width))), a.minY + rng.range(0, Int(max(0, a.height - size.height))))
            mac.wins[id] = Win(frame: CGRect(origin: origin, size: size), app: app)
            personFrame[id] = mac.wins[id]!.frame
        }
    }

    mutating func note(_ s: String) { seen[s, default: 0] += 1 }

    // WindowSizer.resize, as written: nudge for the asked frame, the size, the read-back, a second nudge.
    mutating func resize(_ id: CGWindowID, to size: CGSize) -> (before: CGRect, after: CGRect)? {
        guard let before = mac.ax(id) else { return nil }
        let a = Mac.area(around: before)
        var nudgedFrom: CGPoint?
        let fitted = WindowRestore.keep(CGRect(origin: before.origin, size: size), in: a)
        if fitted != before.origin, mac.setPosition(id, fitted) { nudgedFrom = before.origin }
        guard mac.setSize(id, size) else {
            if let n = nudgedFrom { _ = mac.setPosition(id, n) }
            return nil
        }
        everTouched.insert(id)
        guard let read = mac.ax(id) else { return nil }
        let again = WindowRestore.keep(read, in: a)
        if again != read.origin { _ = mac.setPosition(id, again) }
        return (before, mac.ax(id)!)
    }

    // WindowSizer.restore: position, size, position.
    mutating func move(_ id: CGWindowID, to f: CGRect) -> Bool {
        guard mac.ax(id) != nil else { return true }
        let ok1 = mac.setPosition(id, f.origin), ok2 = mac.setSize(id, f.size), ok3 = mac.setPosition(id, f.origin)
        everTouched.insert(id)
        return ok1 && ok2 && ok3
    }

    // StreamCoordinator.fitToViewport.
    mutating func fit(_ id: CGWindowID) {
        guard !shuttingDown, let panel, let scale, scale > 0 else { return }
        let target = S((panel.width / scale).rounded(), (panel.height / scale).rounded())
        guard let current = mac.wins[id], !current.closed else { return }
        if abs(current.frame.width - target.width) <= 2, abs(current.frame.height - target.height) <= 2 { return }
        guard let r = resize(id, to: target) else { note("fit refused"); return }
        let had = ledger.record(id) != nil
        ledger.fitted(id, handle: id, before: r.before, after: r.after, asked: target)
        if had { spells[id]?.resizedSinceFit = false; note("re-fit") } else { spells[id] = Spell(original: r.before); note("first fit") }
    }

    /// Where the person expects a window of a spell to end when it stops streaming now.
    func expected(_ id: CGWindowID) -> CGRect? {
        guard let w = mac.wins[id], !w.closed, let spell = spells[id] else { return nil }
        if w.fullScreen || spell.resizedSinceFit { return w.frame }
        guard spell.moved else { return CGRect(origin: spell.original.origin, size: Mac.takes(w.app, spell.original.size)) }
        let target = CGRect(origin: w.frame.origin, size: spell.original.size)
        return CGRect(origin: WindowRestore.keep(target, in: Mac.area(around: w.frame)), size: Mac.takes(w.app, spell.original.size))
    }

    // StreamCoordinator.restoreFits.
    mutating func restoreFits(keeping keep: CGWindowID?, why: String) {
        for (id, entry) in ledger.stopping(keeping: keep) {
            eq(entry.handle, id, "model: a record's handle is its window's")
            if staged?.id == id { note("skipped: staged"); spells[id] = nil; continue }
            let want = expected(id)
            guard let current = mac.ax(id) else { note("stop: gone"); spells[id] = nil; continue }
            let fullScreen = mac.wins[id]!.fullScreen
            let d = WindowRestore.decide(entry.record, current: current, fullScreen: fullScreen, area: Mac.area(around: current))
            switch d {
            case .gone: note("decision: gone")
            case .home: note("decision: home")
            case .settle: note("decision: settle")
            case .leave(.fullScreen): note("decision: full screen")
            case .leave(.resized): note("decision: resized")
            case .restore(_, whole: true): note("decision: whole")
            case .restore(_, whole: false): note("decision: moved")
            }
            if case .restore(let f, _) = d { _ = move(id, to: f) }
            if case .settle(let f) = d { _ = move(id, to: f) }
            mac.applyLate()          // a late app applies the restore's size before anyone looks
            note("stop: \(why)")
            if let want, let now = mac.ax(id) {
                check(WindowRestore.same(now, want), "model seed \(seed): window \(id) stopped (\(why), \(d)) at \(now), the person expects \(want); \(log.suffix(8))")
            }
            spells[id] = nil
        }
    }

    // StreamCoordinator.stageHome and VirtualStage.prepare (step 5's placement, then the move).
    mutating func stage(_ id: CGWindowID) -> Bool {
        guard let w = mac.wins[id], !w.closed, !w.fullScreen, let current = mac.ax(id) else { note("staging failed"); return false }
        var home: CGRect? = nil
        if let r = ledger.record(id) {
            home = WindowRestore.homeForStage(WindowRestore.decide(r, current: current, fullScreen: false, area: Mac.area(around: current)))
            note(home == nil ? "staged: as found" : "staged: with a home")
            expectHome[id] = expected(id)
        } else {
            expectHome[id] = current
        }
        let placementHome = home ?? current
        let size = S((panel.map { $0.width / (scale ?? 1) } ?? current.width).rounded(), (panel.map { $0.height / (scale ?? 1) } ?? current.height).rounded())
        _ = move(id, to: CGRect(origin: Mac.virtualDisplay.origin, size: size))
        mac.applyLate()
        staged = (id, placementHome)
        _ = ledger.take(id)
        spells[id] = nil
        return true
    }

    // VirtualStage.releaseWindow.
    mutating func releaseStage() {
        guard let s = staged else { return }
        staged = nil
        if mac.ax(s.id) != nil {
            _ = move(s.id, to: s.home)
            mac.applyLate()
            note("stage released")
            if let want = expectHome[s.id], let now = mac.ax(s.id) {
                check(WindowRestore.same(now, want) || WindowRestore.same(now, CGRect(origin: want.origin, size: Mac.takes(mac.wins[s.id]!.app, want.size))),
                      "model seed \(seed): staged window \(s.id) went home to \(now), expected \(want); \(log.suffix(8))")
            }
        }
        expectHome[s.id] = nil
    }

    // StreamCoordinator.select, the parts that bear on fitted and staged windows.
    mutating func select(_ source: Source) {
        guard !shuttingDown else { return }
        if vd {
            if case .window(let id) = source { if let s = staged, s.id != id { releaseStage() } } else { releaseStage() }
        }
        if case .window(let next) = source {
            restoreFits(keeping: next, why: active == source ? "restart" : (active == .none ? "pick" : "switch"))
        } else {
            restoreFits(keeping: nil, why: source == .desktop ? "desktop" : "none")
        }
        switch source {
        case .none:
            active = .none
        case .desktop:
            active = .desktop
            encoderSize = nil
        case .window(let id):
            guard let w = mac.wins[id], !w.closed else {
                if vd { releaseStage() }
                active = .none
                restoreFits(keeping: nil, why: "window gone")      // the defer
                return
            }
            if vd, staged?.id == id {
                // A re-place on the same display: the stage keeps its home.
            } else if vd, stage(id) {
            } else {
                if vd { releaseStage() }                           // the fallback streams the real window
                fit(id)
            }
            active = .window(id)
            encoderSize = mac.ax(id)?.size
        }
        if active == .none { restoreFits(keeping: nil, why: "nothing streams") }
    }

    mutating func personMove(_ id: CGWindowID) {
        guard var w = mac.wins[id], !w.closed, !w.fullScreen, staged?.id != id else { return }
        let a = Mac.visible[rng.int(2)]
        var p = P(a.minX + rng.range(0, Int(max(0, a.width - 200))), a.minY + rng.range(0, Int(max(0, a.height - 150))))
        // Never within a few points of where Sill left it: there a move and none are the same.
        if let set = ledger.record(id)?.set, abs(p.x - set.minX) <= 4, abs(p.y - set.minY) <= 4 { p.x += 40 }
        if abs(p.x - w.frame.minX) <= 4, abs(p.y - w.frame.minY) <= 4 { p.y += 40 }
        w.frame.origin = p
        mac.wins[id] = w
        if spells[id] != nil { spells[id]!.moved = true }
        if !everTouched.contains(id) { personFrame[id] = w.frame }
        log.append("person moved \(id) to \(p)")
    }

    mutating func personResize(_ id: CGWindowID) {
        guard var w = mac.wins[id], !w.closed, !w.fullScreen, staged?.id != id else { return }
        var s = Mac.takes(w.app, S(rng.range(300, 1400), rng.range(200, 900)))
        // A resize the rule can see: off what Sill left and asked for by more than its tolerance.
        if let r = ledger.record(id) {
            for _ in 0..<4 where WindowRestore.same(s, r.set.size) || WindowRestore.same(s, r.asked) || WindowRestore.same(s, w.frame.size) {
                s = Mac.takes(w.app, S(s.width + 50, s.height + 30))
            }
            if WindowRestore.same(s, r.set.size) || WindowRestore.same(s, r.asked) { return }
        }
        if WindowRestore.same(s, w.frame.size) { return }
        w.frame.size = s
        w.pendingSize = nil
        mac.wins[id] = w
        if spells[id] != nil { spells[id]!.resizedSinceFit = true }
        if !everTouched.contains(id) { personFrame[id] = w.frame }
        log.append("person resized \(id) to \(s)")
    }

    mutating func toggleFullScreen(_ id: CGWindowID) {
        guard var w = mac.wins[id], !w.closed, staged?.id != id, w.pendingSize == nil else { return }
        if w.fullScreen {
            w.fullScreen = false
            w.frame = w.beforeFullScreen
        } else {
            w.beforeFullScreen = w.frame
            w.fullScreen = true
            w.frame = Mac.displays[Mac.visible.firstIndex(of: Mac.area(around: w.frame)) ?? 0]
        }
        mac.wins[id] = w
        log.append("full screen \(id) \(w.fullScreen)")
    }

    /// The catalog's poll (windowsChanged): a closed streamed window stops; a regular window whose
    /// size left the encoder's restarts, and the restart fits it again.
    mutating func poll() {
        guard case .window(let id) = active else { return }
        guard let w = mac.wins[id], !w.closed else { select(.none); return }
        if staged?.id == id { return }
        if let e = encoderSize, !WindowRestore.same(e, w.frame.size) { note("poll restart"); select(active) }
    }

    mutating func step() {
        mac.applyLate()
        let ids = Array(mac.wins.keys).sorted()
        let id = ids[rng.int(ids.count)]
        switch rng.int(100) {
        case 0..<16:
            log.append("pick \(id)"); select(.window(id))
        case 16..<20:
            log.append("pick desktop"); select(.desktop)
        case 20..<34:
            let panels = [S(1000, 710), S(710, 1000), S(1133, 744), S(386, 241), S(500, 710)]
            let scales: [CGFloat?] = [nil, 0.5, 0.75, 1, 1.25, 1.5]
            panel = panels[rng.int(panels.count)]
            scale = scales[rng.int(scales.count)]
            log.append("viewport \(panel!) at \(scale.map { "\($0)" } ?? "nil")")
            if case .window(let a) = active {
                if vd, staged?.id == a { _ = move(a, to: CGRect(origin: Mac.virtualDisplay.origin, size: S((panel!.width / (scale ?? 1)).rounded(), (panel!.height / (scale ?? 1)).rounded()))) }
                else { fit(a) }       // the encoder keeps its size: the next poll restarts
            }
        case 34..<38:
            log.append("restart"); if active != .none { select(active) }
        case 38..<50:
            poll()
        case 50..<62:
            personMove(id)
        case 62..<70:
            personResize(id)
        case 70..<73:
            log.append("close \(id)")
            if var w = mac.wins[id], !w.closed { w.closed = true; mac.wins[id] = w }
            poll()
        case 73..<77:
            toggleFullScreen(id)
        case 77..<82:
            log.append("virtual display \(vd ? "off" : "on")")
            if vd {
                releaseStage()
                vd = false
                if case .window = active { select(active) }
            } else {
                vd = true
                if case .window = active { select(active) }
            }
        case 82..<88:
            log.append("last device left"); panel = nil; scale = nil
            if active != .none { select(.none) }
        default:
            break
        }
    }

    mutating func quit() {
        log.append("quit")
        shuttingDown = true
        restoreFits(keeping: nil, why: "quit")
        releaseStage()
        check(ledger.isEmpty, "model seed \(seed): records left after Quit")
        check(staged == nil, "model seed \(seed): a window left staged after Quit")
        // A window Sill never touched is where the person left it.
        for (id, w) in mac.wins where !w.closed && !everTouched.contains(id) && !w.fullScreen {
            check(w.frame == personFrame[id], "model seed \(seed): window \(id), never sized, moved from \(personFrame[id]!) to \(w.frame)")
        }
    }
}

let sessions = 5_000
var globalSeen: [String: Int] = [:]
for n in 0..<sessions {
    var m = Model(seed: UInt64(n) &* 7919 &+ 17)
    let steps = 20 + m.rng.int(60)
    for _ in 0..<steps { m.step() }
    m.quit()
    for (k, v) in m.seen { globalSeen[k, default: 0] += v }
}

// Every transition the issue names, and every outcome, came up.
let needed = ["first fit", "re-fit", "fit refused", "stop: switch", "stop: desktop", "stop: none", "stop: quit", "stop: gone", "decision: whole", "decision: moved", "decision: resized", "decision: full screen", "decision: home", "decision: settle",
              "staged: with a home", "staged: as found", "stage released", "poll restart"]
for k in needed { check((globalSeen[k] ?? 0) > 0, "model: never came up: \(k)") }
print("window-restore: the model, \(sessions) sessions: " + needed.map { "\($0) \(globalSeen[$0] ?? 0)" }.joined(separator: ", "))

if failures == 0 {
    print("window-restore: all \(passes) checks passed")
    exit(0)
} else {
    print("window-restore: \(failures) of \(passes + failures) checks FAILED")
    exit(1)
}
