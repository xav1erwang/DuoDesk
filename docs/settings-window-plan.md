# The Settings window on a small screen: the plan

2026-10-14. Branch `settings-window-height` (worktree `/Users/noah/Downloads/winstream-settings-height`,
PR #74) from origin/main at 985a733; line numbers are at 985a733. Issue #59 (rosstex, a 14-inch MacBook Pro
on macOS 26.6.2, Sill 0.5.1 (563)): "The Remote Access settings on Mac are too tall and cannot be
resized." Mac app only: no wire change, nothing on the iOS side, the CLI untouched.

## The problem, measured

The Settings window is as tall as the selected pane's whole content, whatever the screen.

- `SettingsWindowController` makes an `NSWindow(contentViewController:)` of an `NSTabViewController`
  in toolbar style, without `.resizable` (SettingsWindow.swift:43-44). Each tab is an
  `NSHostingController` with `sizingOptions = [.preferredContentSize]` (SettingsWindow.swift:89-92)
  around a grouped `Form` 520 pt wide with no height limit (SettingsPanes.swift:27-28).
- A scratch AppKit probe of the same setup on this Mac (macOS 27.0.1, not committed) showed how the
  height is set. AppKit gives the selected pane's view a constraint named
  `NSViewController.preferredContentSize.height`, the pane's height equal to the hosting
  controller's `preferredContentSize` (SwiftUI's ideal size: the whole Form), at priority 501, just
  over the window's own 500 for keeping its size. Auto Layout then sets the window's frame in the
  display cycle (`NSWindow(NSConstraintBasedLayoutInternal)` calling `setFrame(_:display:)`),
  keeping its top-left corner. A 40-row pane made a 1,653 pt window and a 50-row one 2,028 pt, its
  bottom 1,128 pt below the screen. AppKit's own `constrainFrameRect(_:to:)` shortens only
  resizable windows, and it is not on this path anyway.
- The constraint follows growth live (a switch turned on), and every tab switch makes a new one
  at that tab's full height. In the probe it did not follow shrinking: its pane (a `ForEach` over a
  count) made shorter, or a SwiftUI height limit lowered while it showed, left the window at its old
  height. Sill's own Remote Access pane did shrink the window when the internet switch went off
  (Results), so this varies with the pane; the cap below does not depend on it.
- The panes' natural heights (the previews at 985a733, pixels ÷ 2): Remote Access 700 to 703 pt
  with Tailscale and the other VPNs' rows, 754 with a port warning, 949 to 983 with "Allow
  connections from the internet" on; General 738; Streaming 474; Devices up to 435; Permissions
  275; Virtual Display 231. In the live window in test pattern mode (Results): General 727,
  Streaming 568, Remote Access 327 off and 909 on with the internet switch and this Mac's
  addresses. The window adds the title bar and the toolbar: 80 pt in Sill's window (88 in the
  probe's, whose toolbar differed).
- The screens: this Mac's 14-inch display at its default scaling is 1,512 × 982 pt, 949 pt under
  the menu bar (33 pt on macOS 27, measured; the Dock hidden here). A Dock at the bottom takes
  some 70 pt more. The scalings with larger text make the screen 878, 745 or 665 pt tall before
  the menu bar and the Dock. So the Remote Access pane with the internet switch on (about 1,060 pt
  with its window) fits no 14-inch screen, the General pane (807) none with larger text, and
  rosstex's 951 pt window none with the Dock showing.

## The design

### The cap: one constraint the window controller owns

`SettingsWindowController` adds one `NSLayoutConstraint` to the window's content view (the tab
controller's view): its height at most the limit for the window's screen, at priority 750
(`.defaultHigh`), over AppKit's 501 and the window's 500. The panes are grouped Forms, which scroll
when given less than their content. The probe, with the same setup and this constraint:

| Step | Window frame | The pane shows | Its content |
|---|---|---|---|
| shown on the 40-row pane, cap 600 | 688 | 600 | 1,565 (scrolls) |
| a 6-row pane | 378 | 290 | 290 |
| that pane grown to 50 rows | 688 | 600 | 1,940 (scrolls) |
| cap lowered to 400 while it shows | 488 | 400 | 1,940 |
| cap raised to 800 | 888 | 800 | 1,940 |
| the 40-row pane, then a 4-row one | 888, then 303 | 800, then 215 | 1,565, then 215 |

No frame on the way was taller than the cap, and AppKit reported no conflict. Two other places for
the cap failed in the same probe: an `NSHostingController` subclass clamping `preferredContentSize`
(SwiftUI never calls its setter: the subclass saw nothing and the window grew as before), and a
SwiftUI `.frame(maxHeight:)` on the pane (it capped the window at first, but lowered while a pane
showed it left the window tall, the Form centred in it, because the 501 constraint does not follow
shrinking). An `NSWindow` subclass clamping `setFrame` would fight Auto Layout, which sets the frame
from the constraints at every layout pass.

The constraint's constant is `SettingsWindowFit.contentLimit`, set by `refit()`:
- at `show(tab:)` (before and after `WindowPlacement.bringForward`, which may move the window off
  Sill's virtual display),
- on every tab switch (`SettingsTabController.tabView(_:didSelect:)`; the Dock may have changed
  since),
- on `NSApplication.didChangeScreenParametersNotification` (a display added or removed, its
  resolution, the Dock),
- on `windowDidChangeScreen(_:)` (the window dragged to another display).

### The arithmetic: `SettingsWindowFit` (pure, `Tests/checks/settings-window`)

`Sources/SillMenuBar/SettingsWindowFit.swift`, CoreGraphics only:
- `screenIndex(windowOn:screens:)`: the screen whose visible frame bounds the window: the one it is
  on; on none, or on Sill's own virtual display (where a streamed window lives, off the user's
  screens), the first other screen, where `bringForward` puts it.
- `visible(_:testHeight:)`: that screen's `visibleFrame` (under the menu bar, beside the Dock), or,
  TEST ONLY, its top `testHeight` points.
- `contentLimit(visible:chrome:)`: the visible height less the window's chrome (frame height less
  content height, read from the window: the title bar and the toolbar, 80 pt on macOS 27.0.1) and
  a margin of 12 pt above and below, in whole points, never under 200. On this Mac's 949 pt: 845.
- `placed(_:in:)`: where the window goes. Unchanged while it lies within the visible frame top to
  bottom. Its bottom below it (under the Dock, or off the screen): moved up to 12 pt above the
  bottom, or as far as keeps its top inside. Its top above it: moved down to 12 pt under the top,
  or as far as keeps its bottom inside. Taller than the visible frame: its top at the top, so the
  title bar stays reachable. Never resized, never moved sideways.

### The move: only after Sill's own changes

`windowDidResize(_:)` (the layout's resize after a tab switch, a pane that grew, or a new cap) and
`refit()` apply `placed`, but only while the window is on screen and no mouse button is down: a
window the user is dragging is never moved under the pointer; a move that falls due then waits for
every button to be released (`placeOnRelease`, a Timer in the common modes looking ten times a
second). A window the user left partly off the screen stays there until Sill next changes its size
or shows it. A new cap lays a window on screen out at once (`layoutIfNeeded`) before it is placed:
placed at its old height and then shortened from the bottom, it would keep no margin above (seen in
the first runs: its top at the top of the visible frame). `show` lays the window out after
`bringForward` and places it then.

### Hooks (TEST ONLY; the bare SillMenuBar binary)

- `-SillSettingsAfter '<s> <tab>[; <s> <tab> …]'`: opens Settings on that tab s seconds after
  launch, through the menu's own path, and 0.6 s later prints one line with the window's frame, its
  content and chrome, the pane's whole height and what it shows (the Form's scroll view: its
  visible height against its content's, and how far it is scrolled), the screen's visible frame
  and the one used, the limit, and the room above and below the window. A tab is its name or the
  start of one (`remote`, `general`); `close` closes the window, `report` prints it as it stands,
  `end` scrolls the pane to its last row, and `height=<points>` sets `-SillTestScreenHeight` (0:
  the screen's own) and posts `NSApplication.didChangeScreenParametersNotification`, so the path a
  real change of display or Dock takes runs.
- `-SillTestScreenHeight <points>`: the cap and the move use the top `<points>` of the screen's
  visible frame, as if the screen were that short with the Dock at its bottom, so the cap shows on
  a large screen.
- `-SillSettingsShot <dir>`: each `-SillSettingsAfter` step also writes the window (its title bar,
  toolbar and pane, as `cacheDisplay` draws them) to `<dir>/settings-<s>s-<tab>.png`.

Sill.app itself ignores all three with one line each, as it does every `-Sill…After` hook
(`DebugHooks.timedHooks` and `windowHooks`, under `AppModel.bundled`).

## Open questions, with the default taken

1. **The margin.** 12 pt above and below a capped window. Alternatives: none (a capped window
   fills the visible frame, as the green button's zoom does), or 20.
2. **Which tabs.** Every tab gets the cap, not only Remote Access: General overflows a 14-inch with
   larger text too.
3. **Resizable.** The window stays fixed in size; the cap decides its height, and the pane scrolls.
   Making it resizable alone would not help (each tab switch sets the height again) and would add a
   saved height to reconcile with every pane's own.
4. **A pane that gets shorter.** Nothing done. Sill's Remote Access pane shrank the window with it
   (Results); the probe's pane did not, so another pane might leave the window taller than its
   content until the next tab switch, as before this change. Forcing it would need AppKit's own
   constraint, which only AppKit names.
5. **A drag between screens.** The cap follows the window's new screen at once (it shortens or
   grows during the drag), but the window is not moved while it is dragged; if the cap changed on
   the way and the window runs off that screen, it is moved once the button is released.
6. **The pairing window** (up to 568 pt of content plus its title bar, a fixed size) would not fit
   the smallest 14-inch scaling with the Dock either. Not part of #59; not changed here.

## Test plan

- The check: every case the issue raises (a 14-inch at its default and larger-text scalings, with
  and without the Dock), an external 4K display at two scalings, a second screen above and to the
  side (its own origin), a window already partly off the screen above and below, the virtual
  display excluded, the test height; then random screens, chromes and frames against the
  properties (the window fits with its margins whenever the screen allows, uses the room to within
  a point, a taller screen never gives less, `placed` is idempotent, never resizes or moves
  sideways, and leaves a window inside alone). Mutants of every rule.
- `swift build -c release`; `Tests/checks/run-all.sh`; the new check's `--mutants`.
- The bare binary with `--synthetic` (no Screen Recording, nothing advertised), test hosts on
  loopback with the software encoder, only while the no-device check passes, Sill.app untouched:
  each tab at this screen's height (natural heights, nothing capped but what overflows 949 pt) and
  with `-SillTestScreenHeight 700` (capped, its bottom 12 pt over the imagined Dock, the Form
  scrolling); Remote Access with Remote Access and the internet switch on (`-SillSetAfter`), the
  tallest pane; a switch from a tall tab to a short one and back; the window reopened after
  `close`; photos of each. A saved frame from before the fix (951 pt tall) restored and capped.
- Previews (`-SillRenderPreviews`) against 985a733's: identical (no pane changes).
- No iOS file changes, so no iOS build is needed for this change; the CLI's output is untouched (no
  host file changes).

## Results

All on this Mac (a 14-inch MacBook Pro at its default scaling, 1,512 × 982 pt, 949 under the menu
bar, the Dock hidden; macOS 27.0.1), 2026-10-14, with the screen locked and nobody at it. Every live
run was the bare `.build/release/SillMenuBar --synthetic` with `SILL_TEST_LOOPBACK=1
SILL_TEST_SOFTWARE_ENCODER=1 SILL_TEST_NO_ROUTER=1` (its doors on 127.0.0.1 alone, remote access on
port 17459 where turned on, Sill.app's 7455 untouched), each started only while
`Scripts/encoder-check/no-device.sh` found no device connected to Sill.app, each under 21 s.
Nothing touched Sill.app, its preferences or the keychain; the bare binary's `SillMenuBar` domain
was emptied after.

- **Builds.** `swift build -c release` from `git archive` of the branch, clean: 85 s, only the old
  CaptureProbe warning, as at 985a733. No iOS, host, CLI, protocol or site file changes (`git
  diff --stat origin/main...`), so no iOS build was needed.
- **Checks.** `Tests/checks/settings-window`: 307,689 checks, 27 of 27 mutants caught (42 s).
  `Tests/checks/run-all.sh`: all 41 passed.
- **Previews.** `-SillRenderPreviews` of the branch's binary and of 985a733's, run from the same
  path: 130 files each, identical byte for byte.
- **Every tab at this screen's height** (limit 845): each at its natural height, nothing capped:
  General 727 (window 807), Devices 281, Streaming 568, Virtual Display 227, Permissions 275,
  Remote Access 327 (off).
- **The tallest pane** (Remote Access on, with the internet switch, this Mac's addresses: 909):
  capped at 845, scrolling, the window 925 pt, 12 pt from the visible frame's bottom and top.
- **A pane that grows past the cap with the window low.** The window placed by a saved frame with
  its top at 600; Remote Access off (407 pt window), then turned on with the internet switch: the
  window capped at 925 and moved up to 12 pt over the bottom (it would have run 325 pt below the
  screen). The same for a tab switch from Virtual Display (307 pt) to Remote Access.
- **The screen changing while it shows** (`height=`, the notification's path): 845, then 596 (700
  pt), 396 (500 pt), back to 845, each time 12 pt from both edges of the frame in use; the window
  shrank and grew while the 909 pt pane showed. General at a 600 pt screen: capped at 496.
- **`-SillTestScreenHeight 700`**: General (727) and Remote Access with the internet switch (909)
  capped at 596 and scrolling, 12 pt from both edges; Devices, Virtual Display and Streaming (568)
  at their natural heights. Close and reopen: capped again.
- **Scrolled to the end** at a 600 pt screen: General scrolled 231 pt (727 − 496) and Streaming 72
  (568 − 496), their last rows in view (`~/Downloads/sill-handoff/settings-window/`).
- **rosstex's window**: a 951 pt frame saved by a version before the fix, restored: capped at 925,
  Remote Access scrolling.
- **A pane that gets shorter**: the internet switch turned off while Remote Access showed: the pane
  909 → 734, the window 925 → 814 (open question 4).
- **Sill.app ignores the hooks.** The same binary in a scratch bundle (its own bundle ID, so
  nothing of Sill.app's preferences was read or written) under `sandbox-exec` with `network-bind`
  denied (a bundle is never a test host, so its doors would not keep to loopback): one "ignored"
  line each for `-SillSettingsAfter`, `-SillTestScreenHeight`, `-SillSettingsShot` (and the old
  `-SillQuitAfter`); no window opened, no photo written, no preferences domain made.
- **Photos** (`-SillSettingsShot`): every tab at its natural height and General and Streaming
  capped at a 600 pt screen, at the top and scrolled to the end, in
  `~/Downloads/sill-handoff/settings-window/`. Those of Remote Access turned on show this Mac's
  Tailscale name and addresses; they were deleted, not kept.

Not verified here: another display (this Mac has one), the Dock showing or changing (the
notification's path was run with `height=`, not by the Dock itself), a drag between screens or a
mouse button held during a resize (no input is posted here), VoiceOver in a capped pane, Sill.app
itself (the bundle's own executable was not run: it would read and write Sill.app's preferences),
and macOS 14 and 15.

## Untested, for Noah

With Sill.app from this branch (`Scripts/make-app.sh --install --open`) on the 14-inch MacBook:
- **U1.** System Settings › Displays at the scaling at the far left (larger text), and the Dock
  showing (System Settings › Desktop & Dock, "Automatically hide and show the Dock" off). Open
  Settings (⌘,) and click every tab: each window fits between the menu bar and the Dock with room
  above and below; General scrolls to Quit Sill; Remote Access, with Remote Access and "Allow
  connections from the internet" on, scrolls to Sleep. At the default scaling Remote Access with
  the internet switch still scrolls a little, and the others show whole.
- **U2.** With Settings open on Remote Access (the internet switch on), change the scaling, then
  the Dock's size, then hide and show it: Settings shortens or grows to fit each time, its bottom
  12 pt over the Dock. If a Dock change shows only at the next tab click, note it (macOS would then
  not announce the Dock's changes as a change of screens).
- **U3.** An external display: drag Settings from the larger screen to the smaller one; it
  shortens on the way; let go with it low on the smaller screen: once the button is up it moves up
  until its bottom clears the Dock. Drag it back: it grows to its pane's own height.
- **U4.** With Settings low on the screen, press and hold the Remote Access tab: the window never
  moves while the button is held, and moves up once it is released if it ran off the screen.
- **U5.** VoiceOver in a capped pane (General, larger text): moving through it reaches Quit Sill,
  the pane scrolling to it.
- **U6.** On macOS 14 or 15, if a Mac with one is at hand: U1.

## Progress

- 2026-10-14: the probe; this plan (3b8c61d). `SettingsWindowFit` and its check (ec0d850); the
  cap, the move and the hooks (f009b09); the check at Sill's measured chrome (367e8c8); a move
  that waits for the buttons, the docs (654d782); the `end` step (c4a39a7). Every result above on
  c4a39a7 (after it only the hooks' messages and the docs changed). PR #74 opened; left open for
  Noah. Then the cap's constant starts at 10,000 pt (no cap) instead of 200 until a screen is
  known, so a Mac with no usable screen (none, or only Sill's virtual display) never gets a 200 pt
  pane; a run of every step kind on it (General and Streaming natural, capped at a 600 pt screen,
  scrolled to the end, back to the screen's own, closed and reopened) gave the same numbers.
