"""Mutants of Sources/SillHost/WindowRestore.swift (docs/restore-window-frames-plan.md, issue #57): each
changes it in one place, is compiled with the check by build.sh and must make it fail. A mutant that does
not compile is not caught (it would prove nothing). usage: mutants.py ROOT"""
import os, subprocess, sys, tempfile
ROOT = sys.argv[1]; HERE = os.path.dirname(os.path.abspath(__file__))
F = os.path.join(ROOT, "Sources/SillHost/WindowRestore.swift")
MUTANTS = [
    # fitted: the first fit and the later ones.
    ("W1 the first fit records where Sill left it", "return Record(original: before, set: after, asked: asked, moved: false)",
     "return Record(original: after, set: after, asked: asked, moved: false)"),
    ("W2 the first fit counts as a move", "return Record(original: before, set: after, asked: asked, moved: false)",
     "return Record(original: before, set: after, asked: asked, moved: true)"),
    ("W3 a re-fit takes a new original", "        r.set = after\n        r.asked = asked\n", "        r.original = before\n        r.set = after\n        r.asked = asked\n"),
    ("W4 a move never noted", "        if !same(before.origin, r.set.origin) { r.moved = true }\n", ""),
    ("W5 a move forgotten at a later fit", "if !same(before.origin, r.set.origin) { r.moved = true }", "r.moved = !same(before.origin, r.set.origin)"),
    ("W6 a move judged by the size", "if !same(before.origin, r.set.origin) { r.moved = true }", "if !same(before.size, r.set.size) { r.moved = true }"),
    ("W7 the read-back not kept at a re-fit", "        r.set = after\n", ""),
    ("W8 the size asked not kept at a re-fit", "        r.asked = asked\n", ""),
    # decide.
    ("W9 gone is home", "guard let current else { return .gone }", "guard let current else { return .home }"),
    ("W10 full screen not left", "        if fullScreen { return .leave(.fullScreen) }\n", ""),
    ("W11 never home", "        if same(current, r.original) {\n", "        if false {\n"),
    ("W12 never settled", "            if !same(r.asked, r.original.size), same(r.set.size, r.original.size) { return .settle(r.original) }\n", ""),
    ("W13 always settled", "            if !same(r.asked, r.original.size), same(r.set.size, r.original.size) { return .settle(r.original) }\n            return .home\n",
     "            return .settle(r.original)\n"),
    ("W14 settled whatever was read back", "if !same(r.asked, r.original.size), same(r.set.size, r.original.size) { return .settle(r.original) }",
     "if !same(r.asked, r.original.size) { return .settle(r.original) }"),
    ("W15 the size asked ignored", "guard same(current.size, r.set.size) || same(current.size, r.asked) else", "guard same(current.size, r.set.size) else"),
    ("W16 the size read back ignored", "guard same(current.size, r.set.size) || same(current.size, r.asked) else", "guard same(current.size, r.asked) else"),
    ("W17 resized on the Mac restored anyway", "else { return .leave(.resized) }", "else { return .restore(r.original, whole: true) }"),
    ("W18 a noted move ignored", "if !r.moved, same(current.origin, r.set.origin) { return .restore(r.original, whole: true) }",
     "if same(current.origin, r.set.origin) { return .restore(r.original, whole: true) }"),
    ("W19 a move since the last fit ignored", "if !r.moved, same(current.origin, r.set.origin) { return .restore(r.original, whole: true) }",
     "if !r.moved { return .restore(r.original, whole: true) }"),
    ("W20 a moved window sent back to its old place", "var target = CGRect(origin: current.origin, size: r.original.size)", "var target = r.original"),
    ("W21 a moved window keeps Sill's size", "var target = CGRect(origin: current.origin, size: r.original.size)", "var target = current"),
    ("W22 a moved window not kept on its display", "        if let area { target.origin = keep(target, in: area) }\n", ""),
    ("W23 a moved target already reached written anyway", "return same(target, current) ? .home : .restore(target, whole: false)", "return .restore(target, whole: false)"),
    ("W24 a move restored as whole", "return same(target, current) ? .home : .restore(target, whole: false)", "return same(target, current) ? .home : .restore(target, whole: true)"),
    # keep.
    ("W25 keep: the right edge ignored", "        if frame.maxX > area.maxX { origin.x = area.maxX - frame.width }\n", ""),
    ("W26 keep: the bottom ignored", "        if frame.maxY > area.maxY { origin.y = area.maxY - frame.height }\n", ""),
    ("W27 keep: the left edge ignored", "        origin.x = max(origin.x, area.minX)\n", ""),
    ("W28 keep: the top ignored", "        origin.y = max(origin.y, area.minY)\n", ""),
    ("W29 keep: the far edges win over the top-left",
     "        if frame.maxX > area.maxX { origin.x = area.maxX - frame.width }\n        if frame.maxY > area.maxY { origin.y = area.maxY - frame.height }\n        origin.x = max(origin.x, area.minX)\n        origin.y = max(origin.y, area.minY)\n",
     "        origin.x = max(origin.x, area.minX)\n        origin.y = max(origin.y, area.minY)\n        if frame.maxX > area.maxX { origin.x = area.maxX - frame.width }\n        if frame.maxY > area.maxY { origin.y = area.maxY - frame.height }\n"),
    # the tolerance.
    ("W30 no tolerance", "static let tolerance: CGFloat = 2", "static let tolerance: CGFloat = 0"),
    ("W31 a wider tolerance", "static let tolerance: CGFloat = 2", "static let tolerance: CGFloat = 3"),
    ("W32 points compared strictly", "static func same(_ a: CGPoint, _ b: CGPoint) -> Bool { abs(a.x - b.x) <= tolerance && abs(a.y - b.y) <= tolerance }",
     "static func same(_ a: CGPoint, _ b: CGPoint) -> Bool { abs(a.x - b.x) < tolerance && abs(a.y - b.y) < tolerance }"),
    ("W33 sizes compared strictly", "static func same(_ a: CGSize, _ b: CGSize) -> Bool { abs(a.width - b.width) <= tolerance && abs(a.height - b.height) <= tolerance }",
     "static func same(_ a: CGSize, _ b: CGSize) -> Bool { abs(a.width - b.width) < tolerance && abs(a.height - b.height) < tolerance }"),
    ("W34 a frame compared by its origin alone", "static func same(_ a: CGRect, _ b: CGRect) -> Bool { same(a.origin, b.origin) && same(a.size, b.size) }",
     "static func same(_ a: CGRect, _ b: CGRect) -> Bool { same(a.origin, b.origin) }"),
    # homeForStage.
    ("W35 the stage takes a restored window as found", "        case .restore(let frame, _), .settle(let frame): return frame\n        case .gone, .home, .leave: return nil\n",
     "        case .settle(let frame): return frame\n        case .restore, .gone, .home, .leave: return nil\n"),
    ("W36 the stage takes a settled window as found", "        case .restore(let frame, _), .settle(let frame): return frame\n        case .gone, .home, .leave: return nil\n",
     "        case .restore(let frame, _): return frame\n        case .settle, .gone, .home, .leave: return nil\n"),
    # the ledger.
    ("W37 a re-fit takes the newest handle", "handle: old?.handle ?? handle)", "handle: handle)"),
    ("W38 a re-fit starts a new record", "entries[id] = Entry(record: WindowRestore.fitted(old?.record, before:", "entries[id] = Entry(record: WindowRestore.fitted(nil, before:"),
    ("W39 stopping stops the window kept", "let ids = entries.keys.filter { $0 != keep }.sorted()", "let ids = entries.keys.sorted()"),
    ("W40 stopping stops nothing", "let ids = entries.keys.filter { $0 != keep }.sorted()", "let ids = entries.keys.filter { _ in false }.sorted()"),
    ("W41 stopping in the dictionary's order", "let ids = entries.keys.filter { $0 != keep }.sorted()", "let ids = Array(entries.keys.filter { $0 != keep })"),
    ("W42 stopping leaves the record", "for id in ids { if let e = entries.removeValue(forKey: id) { out.append((id, e)) } }",
     "for id in ids { if let e = entries[id] { out.append((id, e)) } }"),
    ("W43 take leaves the record", "mutating func take(_ id: CGWindowID) -> Entry? { entries.removeValue(forKey: id) }",
     "mutating func take(_ id: CGWindowID) -> Entry? { entries[id] }"),
    # fit: WindowSizer.resize's sequence.
    ("F0 a window in full screen fitted", "        if a.isFullScreen(w) { return .fullScreen }\n", ""),
    ("F1 the asked frame never nudged onto its display", "if to != from, a.setPosition(w, to) == .done { nudgedFrom = from }",
     "if false, a.setPosition(w, to) == .done { nudgedFrom = from }"),
    ("F2 a refused size keeps its nudge",
     "            if let nudgedFrom { _ = a.setPosition(w, nudgedFrom) }\n            return .refused(code)\n",
     "            return .refused(code)\n"),
    ("F3 the frame before taken from the window server though Accessibility answers", "let before = read ?? fallback", "let before = fallback"),
    ("F4 the size the app took never nudged onto its display", "if to != took.origin, a.setPosition(w, to) == .done {",
     "if false, a.setPosition(w, to) == .done {"),
    ("F5 after a second nudge, the frame before it", "return .fitted(before: before, after: a.frame(w) ?? CGRect(origin: to, size: took.size))",
     "return .fitted(before: before, after: took)"),
    ("F6 the size the app took ignored", "        return .fitted(before: before, after: took)\n",
     "        return .fitted(before: before, after: CGRect(origin: took.origin, size: size))\n"),
    ("F7 a refused size recorded", "            return .refused(code)\n", "            return .fitted(before: before, after: before)\n"),
    # stop: each window restoreFits puts back.
    ("S1 a listed window with no frame taken for gone", "if a.isListed(w) { return Stopped(id: id, decision: nil",
     "if false { return Stopped(id: id, decision: nil"),
    ("S2 a window gone taken as not answering", "return Stopped(id: id, decision: .gone, done: false, line: nil)",
     "return Stopped(id: id, decision: nil, done: false, line: notAnsweringLine(name: name))"),
    ("S3 a settled window not written again",
     "        case .restore(let frame, _), .settle(let frame): done = a.put(w, at: frame)\n        case .gone, .home, .leave: break\n",
     "        case .restore(let frame, _): done = a.put(w, at: frame)\n        case .settle, .gone, .home, .leave: break\n"),
    ("S4 a window to restore not moved",
     "        case .restore(let frame, _), .settle(let frame): done = a.put(w, at: frame)\n        case .gone, .home, .leave: break\n",
     "        case .settle(let frame): done = a.put(w, at: frame)\n        case .restore, .gone, .home, .leave: break\n"),
    ("S5 a move that failed taken as done", "done = a.put(w, at: frame)", "_ = a.put(w, at: frame); done = true"),
    ("S6 the stop blind to full screen", "let d = decide(r, current: current, fullScreen: a.isFullScreen(w), area: a.visibleArea(around: current))",
     "let d = decide(r, current: current, fullScreen: false, area: a.visibleArea(around: current))"),
    ("S7 the stop with no display's area", "let d = decide(r, current: current, fullScreen: a.isFullScreen(w), area: a.visibleArea(around: current))",
     "let d = decide(r, current: current, fullScreen: a.isFullScreen(w), area: nil)"),
    ("S8 the line without the frame now", "line: line(d, name: name, current: current, done: done)", "line: line(d, name: name, current: nil, done: done)"),
    ("S9 the stage's way home blind to full screen",
     "return homeForStage(decide(r, current: current, fullScreen: a.isFullScreen(w), area: a.visibleArea(around: current)))",
     "return homeForStage(decide(r, current: current, fullScreen: false, area: a.visibleArea(around: current)))"),
    ("S10 the staged window put back too", "for (id, entry) in stopping(keeping: keep) where id != staged {", "for (id, entry) in stopping(keeping: keep) {"),
    ("S11 the window kept put back too", "for (id, entry) in stopping(keeping: keep) where id != staged {", "for (id, entry) in stopping(keeping: nil) where id != staged {"),
    # the lines.
    ("W44 an untitled window's name with a dash", "title.isEmpty ? app : \"\\(app) — \\(title)\"", "\"\\(app) — \\(title)\""),
    ("W45 the frame with a decimal", "String(format: \"(%.0f,%.0f,%.0f×%.0f)\"", "String(format: \"(%.1f,%.0f,%.0f×%.0f)\""),
    ("W46 a failed restore said Restored", "            guard done else { return \"Could not restore \\(name) to \\(text(frame))\" }\n", ""),
    ("W47 a settled window gets a line", "        case .gone, .home, .settle:\n            return nil\n",
     "        case .gone, .home:\n            return nil\n        case .settle(let frame):\n            return \"Restored \\(name) to \\(text(frame))\"\n"),
    ("W48 a moved restore in whole's words",
     "return whole ? \"Restored \\(name) to \\(text(frame))\" : \"Restored \\(name) to \\(text(frame)), its own size where it was moved\"",
     "return \"Restored \\(name) to \\(text(frame))\""),
]
caught = 0
for name, old, new in MUTANTS:
    src = open(F).read()
    if src.count(old) != 1:
        print(f"{name}: NOT APPLIED (pattern found {src.count(old)} times)"); continue
    with tempfile.TemporaryDirectory() as t:
        mf = os.path.join(t, "WindowRestore.swift"); open(mf, "w").write(src.replace(old, new, 1))
        exe = os.path.join(t, "c")
        subprocess.run([os.path.join(HERE, "build.sh"), ROOT, exe, mf], capture_output=True, text=True)
        if not os.path.exists(exe): print(f"{name}: did not compile (not caught)"); continue
        r = subprocess.run([exe], capture_output=True, text=True, timeout=600)
        failed = [l for l in r.stdout.splitlines() if l.startswith("FAIL")]
        if r.returncode != 0:
            caught += 1
            print(f"{name}: caught ({failed[0][:110] if failed else f'exit status {r.returncode}'})")
        else:
            print(f"{name}: NOT CAUGHT")
print(f"mutants caught: {caught} of {len(MUTANTS)}")
sys.exit(0 if caught == len(MUTANTS) else 1)
