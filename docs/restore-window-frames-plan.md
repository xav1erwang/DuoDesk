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
3. Within 2 pt of `original`: already home, nothing to do (`home`; no line).
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

The restore itself is `WindowSizer.restore` (position, size, position through the element kept
from the fit; a window gone is nothing to restore, a `cannotComplete` gets one more try while the
window is listed, a window left off every display is nudged onto the main one), so a window that is
gone, minimized, in full screen or refusing AX is handled as the virtual display's is. Before it,
one AX read of the frame: an app that does not answer it (a beach ball) costs one second at most and
is skipped with a line, instead of up to six seconds of writes on the main actor.

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
  without prompting): a scratch AppKit app of its own makes one window off to one side (behind
  every other window), and a driver compiled with the real `WindowSizer.swift` and
  `WindowRestore.swift` fits it as `fitToViewport` does and restores it as the coordinator does,
  frames before, during and after: a stop (whole frame), a re-fit then a stop, moved (the owner
  app moves its own window) then a stop, resized (the owner resizes it) then a stop, an app minimum
  (the owner's `minSize`), a window that closes, and the stage's home for each. Never one of
  Noah's windows, never a virtual display, never input.
- **Untested, for Noah**, with a Sill.app built from this branch and a device: below, in Results.

## Results

(Filled in as the work lands.)

## Progress

- 2026-10-14: plan written; worktree from origin/main at 985a733.
