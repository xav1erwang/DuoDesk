# A hardware keyboard and trackpad on the device — the plan

2026-10-14. Branch `hardware-keyboard` (worktree `/Users/noah/Downloads/winstream-hardware-keys`)
from origin/main at 985a733; line numbers are at 985a733. Issues #67 and #68. Device app only; no
wire change, nothing on the Mac changes. The triage that led here, with file:line evidence for each
cause, is `~/Downloads/sill-handoff/triage/2026-10-13-open-items.md`.

**Noah's request (2026-10-14, as the workflow relayed it):** "Work on the keyboard and trackpad
change (#67 and #68 together)". The workflow's brief: Esc through a key command, hardware keys
forwarded whenever a keyboard is attached (a pure rule with a check), and trackpad and mouse-wheel
scrolling over the stream.

## The problem

**#67, Esc never reaches the Mac** (puckdoug: iPad Pro 13" M4, iPadOS 27.0.1, Magic Keyboard). His
own log shows 22 `in.text` and no `in.key` while he pressed Esc: the iPad never sent it. The Mac
would take it (usage 0x29 is key 53, KeyStrokes.swift:195). The device forwards Esc only from
`pressesBegan` (InputOverlay.swift:462; `ForwardedKeys.keyUsages` has 0x29, KeyChords.swift:109),
and iPadOS does not hand a hardware Escape to `pressesBegan` of a text-input first responder (the
iPadOS 27 simulator never did either: docs/remote-access-plan.md R12, commit 5468bdc). UIKit's
header says why a key command can still get it: `wantsPriorityOverSystemBehavior` "indicates
whether the key command should execute if it conflicts with focus or text-editing system
commands". Sill already uses such a command for Esc where a field has the keyboard (`EscapeKey`,
AddMacCard.swift:303). Sideways there is no on-screen esc at all (only the portrait key row has one),
and an iPad on a Magic Keyboard is always sideways.

**#68 (b), typing needs the Keyboard button.** Keys and text reach the Mac only while the stream's
input view (`InputOverlayView`, a `UIKeyInput`) is first responder (InputOverlay.swift:343, 375–394,
462–479). Only the Keyboard button, a restore after Settings, the Menus pull-down or the tour, or
DEBUG `-SillKeyboard 1` make it so. A new session, a rotation (the other layout's input view is a new
view) and Pair This iPad… all leave it down, and with nothing first responder iPadOS's own File ›
Close takes ⌘W and closes Sill's window (docs/menu-bar-plan.md, "Why the device never registers the
Mac's shortcuts as key commands": while the input view is first responder it wins every key,
⌘W included).

**#68 (a), two-finger trackpad scrolling does nothing.** A Magic Keyboard's trackpad and a mouse
wheel deliver scroll events, which only a pan recognizer with `allowedScrollTypesMask` receives. The
stream's pan is fingers-only with the mask at none (InputOverlay.swift:83–88). The pointer, clicks
and drags already work (`touchesBegan` takes `.indirectPointer` touches, InputOverlay.swift:289).
The Mac already takes both kinds of scroll: phased gestures with momentum, and bare wheel deltas
(InputInjector.swift:237–262).

## The design

### 1. Esc through a key command

- `InputOverlayView.keyCommands`: Esc (`UIKeyCommand.inputEscape`) with each of the sixteen
  combinations of ⌃, ⌥, ⇧ and ⌘, each with `wantsPriorityOverSystemBehavior = true`, no title (so
  none is listed in iPadOS's shortcut overlay or the menu bar). Only while the view is first
  responder and no `EscapeKey` is on screen (the tour, the pairing overlay, the Settings panel, the
  Add a Mac card): then the key goes to that view's own Esc, as before. A leaf view is in the
  responder chain only while it is first responder, so the commands are out of the way whenever the
  overlay does not take keys; the two conditions say so again in `keyCommands` and in
  `canPerformAction`.
- The action sends the key down and up through the path a forwarded hardware key takes
  (`ForwardedKeys`), carrying the command's modifiers: down with them, up with the modifier keys down
  on the Mac. A key command gives no key-up, so the up follows the down at once (a tap; holding Esc
  repeats it, as UIKit repeats a held key's command).
- **Both channels, one key press.** A device that delivers the press to `pressesBegan` as well must
  not send Esc twice (`ForwardedKeys`, pure, checked in `key-strokes`):
  - the press came first: Esc is down on the Mac through it (`down` has it), so the key command
    sends nothing and the press's own up follows;
  - the key command came first: the press whose timestamp is not after the command's (the same key
    press; a later press has a later timestamp) is swallowed, and so is its up, never passed on to
    the text system.
- **DEBUG, which channel delivered it.** Every hardware key the overlay sees prints one line, as
  Noah needs on a device: `hwkey: usage 41 down via keyCommand (shift): to the Mac`, `hwkey: usage 41
  down via pressesBegan: to the Mac`, `hwkey: usage 4 down via pressesBegan: the text system's`,
  `hwkey: usage 41 down via pressesBegan: the key command sent it`. With `-SillKeyProbe 1` the
  GameController keyboard's own handler prints `hwkey: usage 41 down via GameController` too, so a
  key iPadOS gives to neither UIKit channel still shows (the next fix would then be a GameController
  path).
- **The Settings panel's Done** keeps `.keyboardShortcut(.cancelAction)` (⌘. and Esc where SwiftUI
  gets it) and gains `EscapeKey(action: close)`, the priority command the tour and the pairing
  overlay use (HostSettingsPanel.swift:190), since SwiftUI's shortcut does not ask for priority.
- **For the reporter**: Control-[ reaches the Mac as Control plus the [ key, which iTerm2, zsh's vi
  mode and Zed's vim mode take as Escape (untested on a device).

### 2. Keys reach the Mac whenever a hardware keyboard is attached

**The rule, `HardwareKeyboardPolicy`** (iOSClient/HardwareKeyboardPolicy.swift, pure: Foundation
only; `Tests/checks/hardware-keyboard`). A state machine the stream screen's `InputOverlayProxy` owns
(it outlives a rotation; a new session makes a new one). It knows:
- `attached`: a hardware keyboard is attached (`GCKeyboard.coalesced`, and
  `GCKeyboardDidConnect` and `DidDisconnect`; DEBUG `-SillHardwareKeyboard 1|0` overrides it);
- `takers`: what is open that takes the keyboard for itself or must keep keys from the Mac: the
  Settings panel, the pairing overlay (Pair This iPad… or an outside link), the tour, the Apps
  drawer (its search field), the Menus pull-down. The Add a Mac card is the connect screen's, where
  no input view is on screen;
- `onScreen`: the current input view is in a window (a session's stream screen);
- `hold`: who holds the keyboard now: nobody, the rule (`automatic`, for the hardware keyboard), or
  the person (`own`: the Keyboard button, or a restore of the keyboard they had up).

The automatic hold is wanted when `onScreen && attached && takers.isEmpty`. What it does, event by
event (each returns the actions the proxy performs: `take(automatic:)`, `makeOwn`, `letGo`):
- **A view joins a window** (a session starts, a rotation's other layout, a reconnect's new screen):
  the new view holds nothing yet; it takes the keyboard for the hardware keyboard if wanted. The old
  view's resignation, when it comes, is the old view's and changes nothing here.
- **The keyboard attaches**: taken if wanted. **It detaches**: an automatic hold lets go (the
  person's own keyboard stays: they asked for it).
- **A taker opens**: an automatic hold lets go. (Settings, the tour and the pairing overlay already
  take any keyboard down themselves, `setKeyboard(shown: false)`; the drawer and the Menus pull-down
  never took the person's own, and still do not.) **The last taker closes**: taken if wanted, unless
  the restore of the person's own keyboard (Settings, the tour, Menus over Settings) came first.
- **The Keyboard button**: nobody holds it: the person's own, as today (the software keyboard, or
  iPadOS's small bar when a hardware keyboard is attached). The rule holds it: it becomes the
  person's (the button lights, iPadOS's keyboard views come back). The person holds it: let go, and
  the rule takes it again at once if wanted, so the software keyboard goes and keys still reach the
  Mac.
- **Another responder takes the keyboard** (a text field the rule does not know): not fought; the
  next moment above takes it back.
- **UIKit gives it back by itself** (after a presentation): it counts as whatever this view last
  held.

**The person's own action.** Only the person's own hold is the person's: it lights the Keyboard
button and the key row's keyboard cap, it is what the tour's rule counts as "the keyboard was up"
(busy, StreamScreen.swift:565) and its changes are activity (StreamScreen.swift:321). The automatic
hold is none of these, so a person with a keyboard attached still gets the tour, and the Settings
panel and the tour put back only the person's own keyboard (`keyboardBeforeSettings`,
`tourKeyboardAfter`), the rule the hardware hold.

**No on-screen keyboard for the automatic hold.** While the rule holds the keyboard the input view's
`inputView` is an empty view and its assistant item has no groups, so iPadOS shows no keyboard and
no shortcuts bar over the stream, even if it counts the keyboard as gone (a keyboard folded behind
the iPad) a moment before GameController says so. Typing on a hardware keyboard still reaches
`insertText` and `pressesBegan` (a custom input view changes only what is drawn). The person's own
hold has the system keyboard, as today.

### 3. Trackpad and mouse-wheel scrolling over the stream

Two more pan recognizers on `InputOverlayView`, scroll-only: `maximumNumberOfTouches = 0`,
`allowedTouchTypes = [.indirectPointer]`, refusing every touch in the delegate:
- **`.continuous`** (a trackpad's two fingers, a Magic Mouse): the finger pan's path, at the
  pointer's location: `.scrollGesture(.began)`, a `.scroll` delta per change (fractions of the
  picture, natural sign), `.scrollGesture(.ended)`, then Sill's own coast from the lift's velocity.
  iPadOS hands a pan no momentum of its own (a scroll view decelerates by itself), so this is no
  double coast; if a device shows one, a new scroll gesture stops the coast at its begin, as a new
  finger does.
- **`.discrete`** (a mouse wheel): plain `.scroll` deltas, no phases and no coast, which the Mac
  posts as a wheel's.

The three scroll recognizers never overlap (none begins while another's scroll is open), and the
pointer ones recognize alongside the hover recognizer. Every layout that shows the picture uses this
view: sideways, the portrait halves' picture, the phone's pane, the Duo. The tour, the drawer and the
Settings panel already cover the stream for hit-testing.

## Open questions (the default is taken unless Noah says otherwise)

1. **The Keyboard button with a hardware keyboard attached.** Default: it keeps its meaning for the
   software keyboard and lights only when the person asked for it; the hardware hold leaves it dark.
   Alternative: it lights whenever keys go to the Mac, and turning it off stops them for the session.
2. **The Apps drawer.** Default: while it is open keys go nowhere (they do not go to the Mac behind
   it); its search field takes them when tapped. Alternative: with a keyboard attached the search
   field takes them as the drawer opens ("type to search").
3. **The Menus pull-down.** Default: the hardware hold lets go while it is open (the menu takes the
   arrows and Return itself); the person's own keyboard stays, as today.
4. **Which Esc combinations.** Default: all sixteen, so ⇧Esc, ⌘Esc and ⌥⌘Esc (the Mac's Force Quit
   window) go too. Alternative: Esc alone.
5. **The input view's look during the hardware hold.** Default: no keyboard and no shortcuts bar.
   Alternative: iPadOS's own small bar (with its keyboard button).
6. **The person's own software keyboard across a rotation.** Default: down, as today (only the
   hardware hold comes back). Alternative: carried to the other layout.
7. **⌘W while something else has the keyboard** (Settings, the drawer, Menus, the tour, pairing).
   Default: unchanged, the iPad's File › Close closes Sill's window (docs/menu-bar-plan.md Q8).
   Alternative: remove the iPad's File › Close while a session streams.
8. **The trackpad's coast.** Default: Sill's own, as a finger's. Alternative: none for a trackpad.
9. **The portrait on-screen trackpad.** Default: a hardware trackpad's scroll over it does nothing
   (it scrolls over the picture). Alternative: scroll there too.
10. **The GameController probe.** Default: DEBUG only, behind `-SillKeyProbe 1`.

## Test plan

- **H1** `Tests/checks/hardware-keyboard` (new): `HardwareKeyboardPolicy`'s events, scenario by
  scenario (a session start, a rotation either way round, a reconnect, each taker, the keyboard
  coming and going, the button in each state, a responder taking it, UIKit giving it back), then
  random sessions against a model and the invariants (never an automatic hold with a taker open, no
  keyboard or no view; never the person's own made by the rule; every moment that should take it
  does). Mutants, every one caught; in CI's mutants matrix.
- **H2** `Tests/checks/key-strokes` extended: the key command's Esc (`ForwardedKeys.commanded`) with
  each modifier, after a forwarded ⌘, both orders of the two channels, a repeat, the swallowed press's
  up, and the random sessions with key commands among their events; mutants.
- **H3** Builds: the iOS app Debug and Release for the generic simulator and Debug for a generic
  device (`CODE_SIGNING_ALLOWED=NO`), only the known warnings; `swift build -c release` (no host
  file changes); `Tests/checks/run-all.sh`, all.
- **H4** Harness photos on a private simulator, this branch against main's build, at the Duo's and
  an iPad's sizes, landscape and portrait, with the drawer, the Settings panel and the keyboard
  button lit: identical (also with `-SillHardwareKeyboard 1`, whose hold draws nothing).
- **H5** Live against `SillHost --synthetic` on loopback (`SILL_TEST_LOOPBACK=1
  SILL_TEST_SOFTWARE_ENCODER=1 SILL_TEST_NO_ROUTER=1 SILL_TEST_INPUT_LOG=1`), a private simulator,
  `-SillLive 1`: `-SillInputTest 1` with the overlay's new half (Esc through the key command's own
  action, ⇧Esc, a trackpad scroll with its coast, a wheel), the host's `in.dry` counts and its "Test
  input" lines; with `-SillHardwareKeyboard 1` the automatic hold at the session's start and after a
  rotation (an InputScript step turns the scene), let go while Settings and the tour show (nothing
  sent then), taken again after.
- **H6** If the simulator takes one: a virtual HID keyboard and mouse inside the private simulator
  (TEST ONLY, as `Tests/duorig` posts the Duo's hinge), so UIKit's own routing runs: which channel
  delivers Esc, the automatic hold with GameController's keyboard, no on-screen keyboard, the scroll
  recognizers.
- **H7** The touch rig (`Tests/touchrig`), if it can make indirect scroll events; else say so.

## Untested, for Noah (on an iPad with a Magic Keyboard, a Debug build from this branch)

To be filled in with the results.

## Results

To be filled in.

## Progress

- 2026-10-14: the plan.
