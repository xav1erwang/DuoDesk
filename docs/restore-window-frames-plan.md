# A window Sill sized goes back: the plan

2026-10-14. Branch `restore-window-frames` (worktree `/Users/noah/Downloads/winstream-restore-frames`)
from origin/main at 985a733; line numbers are at 985a733. Issue #57 (rosstex): "disconnecting on the
iOS app doesn't revert apps back to their original shape/size on Mac, so everything is shrunken. It
would be great if the windows fix themselves after disconnecting." The triage of 2026-10-13
(`sill-handoff/triage/2026-10-13-open-items.md`) rated it "do soon" and a prerequisite for fitting by
default (#70). Host only; no wire change, nothing on the device.

## The problem

In regular mode (Virtual Display off) Aa resizes the real Mac window to the device's panel at the
text scale it asks for, through Accessibility:

- `StreamCoordinator.fitToViewport` (StreamCoordinator.swift:1089-1101) runs on every pick
  (select's regular path, 1344), every restart of the same window (a rate change, the encoder
  fallback, the catalog's resize check at 2135-2140) and every new viewport
  (`applyViewportToActiveWindow`, 1107-1128). It does nothing until Aa is first touched (the
  device sends no scale before that).
- `WindowSizer.resize` (WindowSizer.swift:27-68) records nothing: no frame before, no element.
- Nothing puts the window back. The last device leaving clears the viewport and selects `.none`
  (401-418, 1294-1297); Quit and the signals release only the virtual display (`shutdownForExit`,
  1848-1853); a pick of another window just streams the next one. The doc comment says so on
  purpose: "nothing ever restores an earlier size on its own" (1087-1088).

Only the virtual display records and restores: `WindowSizer.placement` and `restore`
(172-193, 212-229), `VirtualStage.prepare` steps (2) and (5) (286-293, 316-319), `releaseWindow`,
`release` and the atexit snapshot (649-673, 708-717).

So a window streamed with Aa at 0.75× on a 1000×710 panel stays 1333×947 on the Mac after the
device goes, and one at 1.5× stays 667×473: "everything is shrunken".

This change reverses that for the windows Sill itself sized: each goes back when it stops streaming.

## The design

### The rule (pure: `Sources/SillHost/WindowRestore.swift`)

For each window Sill fits, a record:

- `original`: the frame before Sill first touched it (Accessibility's frame, read just before the
  first resize: the window server's list can be two seconds stale, AX is live).
- `set`: the frame Sill last left it at, as the app took it (read back after the resize: an app
  enforces a minimum, snaps to a grid, or keeps the window on screen).
- `asked`: the size Sill last asked for. An app that applies a size after answering the write reads
  back its old size (VirtualStage.swift's settle loop has the same caveat); at the stop it is at the
  asked size, which is Sill's doing all the same.
- `moved`: the window was found away from where Sill left it at a later fit (the person at the Mac
  moved it, or its app did).

A fit (`WindowRestore.fitted`): the first makes the record; a later one (a rotation, another Aa
step, a restart that resized) keeps `original`, takes the new `set` and `asked`, and sets `moved`
when the window's origin before this fit is more than 2 pt from the last `set`'s. Once set, `moved`
stays.

When the window stops streaming (`WindowRestore.decide`), from its frame now:

1. No frame (the window closed, its app quit): nothing to do (`gone`).
2. Full screen: left as it is (`leave(.fullScreen)`): a window in a full-screen Space refuses moves
   and sizes, and taking it out of full screen is the person's call in regular mode.
3. Within 2 pt of `original`: already home, nothing to do (`home`; no line). Unless Sill asked for
   another size and the app never showed it (`set`'s size is `original`'s, `asked` is not): then the
   original frame is written again, without a line (`settle`). An app that applies a size after
   answering the write, stopped within that moment (a pick right after a pick, Quit right after a
   fit), would otherwise take Sill's size after the stop and keep it; for an app at its minimum the
   write changes nothing. The check's model found this race (Results).
4. Its size is not Sill's (more than 2 pt from both `set` and `asked`): it was resized after Sill's
   last fit, by the person at the Mac. Left alone, position too (`leave(.resized)`).
5. Its size is Sill's and it has not moved (its origin within 2 pt of `set`'s, `moved` false): the
   whole `original` frame (`restore(original, whole: true)`).
6. Its size is Sill's and it was moved: `original`'s size where it is now, its origin nudged so the
   frame stays in the visible area of the display it is on, as a fit keeps it
   (`restore(…, whole: false)`).
7. A target within 2 pt of where it is: `home`.

A resize on the Mac while the window streams is undone today within about two seconds (the
catalog's resize check restarts the pipeline, 2135-2140, and the restart fits the window again,
1344), so rule 4 mostly sees a resize made in the last two seconds before the stop, or after the
fit that a restart would have redone. Such a re-fit keeps `original`: the window goes back to the
frame it had before Sill first touched it, not to the size the person tried for a moment.

`WindowRestore.Ledger<Handle>` keeps the records by window ID, each with the coordinator's handle
(a `WindowSizer.Placement`: the window's AX element, matched once at the first fit, its pid, app and
title). `stopping(keeping:)` takes out every record but the window that streams next, in window ID
order; `take(_:)` takes one out for the virtual display; `homeForStage` is the frame the stage keeps
as the window's way home. `keep(_:in:)` (moved here from WindowSizer, which calls it) is the one
rule for keeping a frame's top-left reachable inside an area. The log lines are here too, so the
check pins them.

### Where the coordinator calls it

- `fitToViewport`: every resize that went through (the size write accepted) is a fit for the
  ledger, with the frames `WindowSizer.resize` now returns (`WindowSizer.Fit`: the element, the
  frame before and the frame after). A fit after `shuttingDown` does nothing (nothing would restore
  it).
- `select`: after the old pipeline stops and the virtual display has sent a staged window home,
  every fitted window but the one about to stream is restored (`restoreFits(keeping:)`): a pick of
  another window or the Desktop, `select(.none)` when the last device leaves or the stream stops,
  each window's restart keeps its own. Its defer restores every fitted window when nothing streams
  at the end (a window that closed, a stream that failed to start).
- `shutdownForExit` (Sill.app's Quit, and the signals under `HostShutdown.install`): every fitted
  window, after the goodbye, beside the stage's release. `releaseKeysForExit` (the CLI's default
  path at a signal, `HostShutdown.installKeyRelease`): every fitted window too, after the keys.
- The virtual display turned on while a fitted window streams (the restart `restartNeeded` asks
  for): `VirtualStage.prepare(…, home:)` takes the frame the window would have been restored to as
  its placement's `originalFrame`, so the stage's own restore (deselect, switch, last device, Quit,
  the signals, atexit's snapshot, a lost display) puts it there; the record is handed over
  (`take`) only once the stage has it. A staging that fails keeps the record. Turning the virtual
  display off sends the staged window home as before; the regular path then fits it from there,
  a new record whose `original` is that home.

The per-window restore is WindowSizer's, so the coordinator and the live probe run the same code:
`stopDecision` reads the frame (one Accessibility read first: no frame from a window the window
server no longer lists is `gone`; none from one it lists means its app does not answer, a beach
ball, and the window is left with a line after at most a second, instead of up to six seconds of
writes on the main actor), whether it is full screen and the visible area of its display, and asks
WindowRestore; `putBack` writes a `restore` or `settle` through `WindowSizer.restore` (position,
size, position through the element kept from the first fit; a window gone is nothing to restore, a
`cannotComplete` gets one more try while the window is listed, a window left off every display is
nudged onto the main one), so a window that is gone, minimized, in full screen or refusing AX is
handled as the virtual display's is.

One line per window acted on, in the stage's style: "Restored Safari — Apple Developer to
(212,95,1280×800)"; "Restored … to (300,140,1280×800), its own size where it was moved"; "Left … at
(…): it was resized on the Mac"; "Left … as it is: it is full screen"; "Could not restore … to
(…)". None for a window that is gone or already home. `win.restored` counts in the `[1s]` lines
when it happens.

`WindowSizer.resize` also undoes its own nudge when the app refuses the size (it moved the window
first to keep the asked frame on screen, then the size write failed): before, such a window stayed
moved with nothing to say so.

### What does not change

- The Desktop is never fitted, so a Desktop stream (and every synthetic test host's) prints and
  does exactly what it did: the CLI's stdout on a synthetic host is unchanged (H2 below).
- The virtual display's own placement, restore and atexit snapshot: unchanged but for the home it
  is given.
- No wire change, no device change, no setting, nothing stored: the records live in memory for
  the life of the host.

## Open questions, and the default taken for each

1. **A signal in the CLI's default path** (no `--virtual-display`): restore there too? Default:
   yes. `releaseKeysForExit` restores after the keys, so a Ctrl-C of `swift run SillHost` puts a
   window back; it prints one "Restored" line only when a window was fitted, and dies of the signal
   with the same status as before. HostShutdown's comment changes with it.
2. **Full screen at the stop**: leave it, with a line. The window returns to Sill's size when it
   leaves full screen. Alternative: take it out of full screen first, as the virtual display does
   (`leaveFullScreenIfNeeded`); rejected for regular mode, where full screen may be the person's.
3. **Resized on the Mac after the last fit**: leave it entirely, position included (Noah's
   statement of the issue: "if it was resized on the Mac meanwhile, leave it").
4. **Moved**: its own size where it is, kept on its display as a fit keeps it.
5. **A move between fits**: remembered (`moved`), so a rotation after the person moved the window
   does not later send it back to its old place.
6. **A resize on the Mac that a re-fit undid**: forgotten; the original frame is still the way home.
7. **Restore whenever nothing streams the window**: also after a stream that failed to start, a
   capture that stopped, a window picked again after a failed start. Default: yes (select's defer).
8. **Lines**: one per window acted on (restored, left, could not); none when gone or already home.
9. **A re-fit's element**: the first fit's element is kept (an AX element stays valid while its
   window exists); a re-fit matches the window again only to resize it.
10. **A restore that fails**: tried once and forgotten, as the stage does.
11. **A crash or `kill -9`**: no restore. Records are not persisted: a frame applied to a window at
    the next launch, perhaps days later, is worse than none.
12. **Turning the virtual display on with a fitted window**: staged with the frame it would have
    been restored to as its home (above).
13. **The App Store text**: unchanged. "Aa makes text larger or smaller" stays true; the next What's
    New is written from the release notes at release time.
14. **Undo a nudge after a refused size** (`WindowSizer.resize`): yes, at once.

## The test plan

- **The check** `Tests/checks/window-restore` (WindowRestore.swift alone, Foundation and
  CoreGraphics; in CI's run and its mutants matrix): `keep` at every edge; `fitted` first and
  later, `moved` at its 2 pt edge and staying set; `decide` for every outcome at its edges (gone,
  full screen, home, resized against `set` and `asked`, unmoved, moved by origin and by flag, the
  nudge on every edge, no area, a target already reached); the ledger (`stopping` keeps one and
  returns the rest in order, `take`, a re-fit keeping the first handle); `homeForStage` for each
  outcome; every line. Then a model of the coordinator's glue: random sessions of picks, viewports,
  the person moving and resizing windows, apps that clamp, snap or apply late, windows that close
  or go full screen, the virtual display on and off, the last device leaving and Quit, against an
  oracle of where each window must end: every transition the issue names (first fit, re-fit,
  switch away, last device, quit, moved, resized, gone, virtual display on and off). Mutants of
  WindowRestore.swift, every one caught.
- **Builds**: `swift build -c release` (only the known CaptureProbe warning). No iOS file changes.
- **`Tests/checks/run-all.sh`**: all.
- **H2, the CLI's stdout**: origin/main's `SillHost` and this branch's, each built from
  `git archive`, `--synthetic` with `SILL_TEST_LOOPBACK=1 SILL_TEST_SOFTWARE_ENCODER=1
  SILL_TEST_NO_ROUTER=1`: idle 35 s, and a test client picking the Desktop; digits masked, lines
  sorted: identical. Only while no device is connected to Sill.app (no-device.sh), though neither
  touches the hardware encoder.
- **Live, with Accessibility** (only if this shell is trusted, `AXIsProcessTrusted()`, read
  without prompting): `Scripts/restore-probe/run.sh`. An AppKit app of its own (`owner.swift`, a
  bundle that never activates) makes one window at the lower left, behind every other window, and
  a driver compiled with the real `WindowSizer.swift` and `WindowRestore.swift` fits it as
  `fitToViewport` does and restores it as `restoreFits` does, frames before, during and after: a
  stop (whole frame), a rotation's re-fit then a stop, moved (the owner app moves its own window)
  then a stop, moved then re-fitted, resized (the owner resizes it) then a stop, an app minimum
  (the owner's `minSize`), a window that closes, the nudge at the display's edge, a window that
  cannot be resized (its nudge put back), an app that does not answer (`SIGSTOP`), the stage's way
  home worked out, and two windows (a pick, then the last device leaving). The front app is read
  before and after and must not change. Never one of Noah's windows, never a virtual display,
  never input.
- **Untested, for Noah**, with a Sill.app built from this branch and a device: below, in Results.

## Results

All on 2026-10-14, on this Mac (macOS 27.0, M2 Pro, one 1512×982 display), with Sill.app idle and no
device connected (`Scripts/encoder-check/no-device.sh` before each host).

- **The check**, `Tests/checks/window-restore`: 41,391 checks pass in about 4 s: 90 cases of the
  rule at its edges, then the model's 5,000 sessions (20 to 80 steps each). What came up in them:
  10,493 first fits, 5,393 re-fits, 6,417 fits refused (full screen); stops by a switch 4,319, the
  Desktop 1,410, `.none` 2,150, Quit 600, a window gone 252; decisions whole 7,164, moved 726,
  resized 250, full screen 307, home 2, settle 30; 1,702 windows staged with a home and 60 as
  found, 11,332 stage releases, 2,223 restarts by the catalog's resize check. The model asserts
  that every one came up.
- **What the model found.** Its first run failed 12 sessions: a window of an app that applies a
  size after answering the write (the model's `late` app) ended at Sill's size. A stop right after
  a fit (Quit in the model, a pick right after a pick on a real Mac) read the window at its
  original frame, so there was nothing to do, and then the app applied the fit's size. Fixed by
  `settle` (rule 3): the original frame is written again, without a line, when Sill asked for
  another size and the read-back never showed it. Unit cases and mutants W12 to W14 hold it.
- **Mutants**: 48 of 48 caught (`run.sh --mutants`, 3 min 24 s): the first fit, re-fits and moves,
  every decision and its order, the tolerance (0, 3, and strict compares), `keep`'s four edges and
  their order, the stage's way home, the ledger (the handle, the record, stopping's order and
  what it takes out, `take`), and every line.
- **Builds**: `swift build -c release`, only the known CaptureProbe warning; the CLI built again
  from `git archive` of this branch for H2. No iOS file changed, so no iOS build.
- **`Tests/checks/run-all.sh`**: all 41 passed (383 s), `window-restore` among them.
- **H2, the CLI's stdout** (origin/main at 985a733 against this branch, each built from
  `git archive`; `--synthetic` with `SILL_TEST_LOOPBACK=1 SILL_TEST_SOFTWARE_ENCODER=1
  SILL_TEST_NO_ROUTER=1`; two rounds, alternating): idle 35 s identical, masked and sorted (7
  lines each); with `sillclient.py PORT 22 desktop` (about 34 fps of the test pattern on the
  software encoder), identical without the `[Ns]` stats lines, and with them differing only in the
  last partial second's line, which differs the same way between two runs of the same build (base
  against base, new against new). No "Restored", "Left" or "Could not restore" line in any run.
- **Live: not run.** Accessibility was trusted here (`AXIsProcessTrusted()` true, read without
  prompting) and Screen Recording too, but the console session was locked with the display asleep
  (`CGSSessionScreenIsLocked` 1, `CGDisplayIsAsleep`, no input for 7.8 hours). A window the probe
  made then was listed by the window server at about 0.9 of its frame about the display's middle
  (900×632 at (20,328) listed as 811×570 at (93,344)), and Accessibility listed only a placeholder
  for its app (its name at (0,0), size 0): the same unbundled and as a bundle, with and without
  the opening animation, ordered front or back. So `WindowSizer.resize` matched nothing ("no
  Accessibility window matches") and no window could be fitted or put back. The probe is
  `Scripts/restore-probe/run.sh`, built here; it now refuses while the screen is locked (exit 2,
  checked) and is for Noah below. Nothing of Noah's was moved or sized; the diagnosis read window
  bounds only.

### Untested, for Noah

1. `Scripts/restore-probe/run.sh` from Terminal with the Mac unlocked: twelve steps on a window of
   its own at the lower left (about 15 s), ending "restore probe: N passed, 0 failed" and "the
   front app never changed". Step 9 says whether a window that cannot be resized refuses the size
   through Accessibility.
2. With Sill.app from this branch (`Scripts/make-app.sh --install --open`) and the iPad, Virtual
   Display off: stream a window, slide Aa to 1.5×, then pick another window: the first goes back to
   its old frame, Sill.log "Restored ‹app› — ‹title› to (x,y,w×h)". The same after Disconnect, and
   after Quit Sill.
3. Stream, slide Aa, move the window on the Mac, then disconnect: its own size where it is now,
   "…, its own size where it was moved". The same with a rotation of the iPad after the move.
4. Stream, slide Aa, resize the window on the Mac and disconnect within about two seconds (before
   the next fit undoes it): left as it is, "Left … at (…): it was resized on the Mac".
5. Stream, slide Aa, turn Virtual Display on (the Mac's menu or the iPad's panel): the window moves
   to the virtual display; deselect or Quit: it comes back at its old frame, not the size Aa gave it.
6. Stream, slide Aa, full screen from the thumbnail's lights, disconnect: left in full screen, "Left
   … as it is: it is full screen".
7. Apps that size differently: Safari, Terminal (a character grid), VS Code or another Electron app
   (may apply a size late: back at its frame, no line when settled), System Settings (a fixed
   width).
8. Known: after a crash or Force Quit of Sill the window stays at the size Aa gave it.

## Progress

- 2026-10-14: plan written; worktree from origin/main at 985a733.
- 2026-10-14: the rule, the check (90 cases and the model; the late app's race found and fixed
  with `settle`), 48 of 48 mutants, the coordinator, WindowSizer, VirtualStage and HostShutdown,
  CI's mutants matrix (eda1c27).
- 2026-10-14: H2, `run-all.sh`, the probe script (refuses while the screen is locked), docs (this
  plan's Results, CLAUDE.md, docs/DEVELOPMENT.md, README's How it works, site/support.html,
  Tests/checks/README.md) (d804132, abb5b94); a clean `swift build -c release` of abb5b94 from
  `git archive`, only the CaptureProbe warning. Pull request #75, left open for Noah.
