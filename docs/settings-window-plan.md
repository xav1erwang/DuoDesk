# The Settings window on a small screen: the plan

2026-10-14. Branch `settings-window-height` (worktree `/Users/noah/Downloads/winstream-settings-height`)
from origin/main at 985a733; line numbers are at 985a733. Issue #59 (rosstex, a 14-inch MacBook Pro
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
  at that tab's full height, but it does not follow shrinking: a pane that got shorter, or a
  SwiftUI height limit lowered while it showed, left the window at its old height.
- The panes' natural heights (the previews at 985a733, pixels ÷ 2): Remote Access 700 to 703 pt
  with Tailscale and the other VPNs' rows, 754 with a port warning, 949 to 983 with "Allow
  connections from the internet" on; General 738; Streaming 474; Devices up to 435; Permissions
  275; Virtual Display 231. The window adds the title bar and the toolbar, 88 pt in the probe.
- The screens: this Mac's 14-inch display at its default scaling is 1,512 × 982 pt, 949 pt under
  the menu bar (33 pt on macOS 27, measured; the Dock hidden here). A Dock at the bottom takes
  some 70 pt more. The scalings with larger text make the screen 878, 745 or 665 pt tall before
  the menu bar and the Dock. So the Remote Access pane with the internet switch on (1,071 pt with
  its window) fits no 14-inch screen, the General pane (826) none with larger text, and rosstex's
  951 pt window none with the Dock showing.

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
  content height, read from the window: the title bar and the toolbar) and a margin of 12 pt above
  and below, in whole points, never under 200.
- `placed(_:in:)`: where the window goes. Unchanged while it lies within the visible frame top to
  bottom. Its bottom below it (under the Dock, or off the screen): moved up to 12 pt above the
  bottom, or as far as keeps its top inside. Its top above it: moved down to 12 pt under the top,
  or as far as keeps its bottom inside. Taller than the visible frame: its top at the top, so the
  title bar stays reachable. Never resized, never moved sideways.

### The move: only after Sill's own changes

`windowDidResize(_:)` (the layout's resize after a tab switch, a pane that grew, or a new cap) and
`refit()` apply `placed`, but only while the window is visible and no mouse button is down: a
window the user is dragging is never moved under the pointer, and a window the user left partly
off the screen stays there until Sill next changes its size or shows it.

### Hooks (TEST ONLY; the bare SillMenuBar binary)

- `-SillSettingsAfter '<s> <tab>[; <s> <tab> …]'`: opens Settings on that tab s seconds after
  launch, through the menu's own path, and 0.6 s later prints one line with the window's frame, its
  content and chrome, the pane's whole height and what it shows (the Form's scroll view: its
  visible height against its content's), the screen's visible frame and the one used, the limit,
  and the room below the window. A tab is its name or the start of one (`remote`, `general`);
  `close` closes the window.
- `-SillTestScreenHeight <points>`: the cap and the move use the top `<points>` of the screen's
  visible frame, as if the screen were that short with the Dock at its bottom, so the cap shows on
  a large screen.
- `-SillSettingsShot <dir>`: each `-SillSettingsAfter` step also writes the window (its title bar,
  toolbar and pane, as `cacheDisplay` draws them) to `<dir>/settings-<s>s-<tab>.png`.

Sill.app itself ignores all three with one line each, as it does every `-Sill…After` hook
(`DebugHooks.timedHooks`, `AppModel.bundled`).

## Open questions, with the default taken

1. **The margin.** 12 pt above and below a capped window. Alternatives: none (a capped window
   fills the visible frame, as the green button's zoom does), or 20.
2. **Which tabs.** Every tab gets the cap, not only Remote Access: General overflows a 14-inch with
   larger text too.
3. **Resizable.** The window stays fixed in size; the cap decides its height, and the pane scrolls.
   Making it resizable alone would not help (each tab switch sets the height again) and would add a
   saved height to reconcile with every pane's own.
4. **A pane that gets shorter.** Unchanged: the window keeps its taller height until the next tab
   switch (AppKit's constraint follows only growth). A fix needs that constraint, which only AppKit
   names; not done here.
5. **A drag between screens.** The cap follows the window's new screen at once, but the window is
   not moved while it is dragged; one left partly below that screen's visible frame is moved at
   the next tab switch, growth or show.

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

(To come.)

## Progress

- 2026-10-14: the probe (above); this plan.
