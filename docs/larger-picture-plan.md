# Larger Picture on an iPhone held upright — the plan

2026-10-14. Branch `larger-picture` (worktree `/Users/noah/Downloads/winstream-larger-picture`) from
origin/main at 985a733. Issue #58 (rosstex: "The menu and touchpad take up more than half of the
vertical space on the iOS app. When using Mac apps that rely heavily on scrolling like Notes,
Chrome, etc. they feel tiny on the phone screen."), which Noah answered on 2026-10-12 with a
settings option. The triage of 2026-10-13 (sill-handoff `triage/2026-10-13-open-items.md`, #58)
recommended the design below, and the run that started this branch took it as the default. Device
only: no wire change, nothing on the host, the switch is the device's own and never sent.

## The problem

On a phone held upright (`PhonePortraitLayout`, docs/iphone-portrait-plan.md) the picture is a
fixed 16:10 pane at the top (PhonePortraitLayout.swift: `picture`), 30 % of an 18 Pro Max's
screen: 424×265 pt. Under it come row 1 (Apps, Aa, Keyboard, Desktop, Settings), the thumbnails,
the key row and the trackpad, which takes the rest: 412×389 on the Pro Max. The rows take a fixed
240 pt. Shrinking them buys 25 to 30 pt. The real limit is the software keyboard: it comes up over
the bottom of the screen and must never cover the key row (the plan's keyboard table: 320 pt on the
18 Pro Max, 301 on the 18 Pro and the 17e, 216 on the SE). Below the key row there is only the
trackpad, which the keyboard covers anyway.

## Decision

### In one paragraph

Settings › This iPhone gains **Larger Picture** (off by default; `Sill.largerPicture` in the app's
defaults; shown only on an iPhone without a hinge, where it acts). With it on, a phone held upright
draws the Larger Picture arrangement: the thumbnails' row goes, and the picture gets every point
that keeps the key row 10 pt above the software keyboard: room = container − keyboard − 152 pt
(18 Pro Max 424×265 → 424×422, 15 Pro 377×235 → 377×340, SE 359×224 → 359×279). The trackpad
becomes the keyboard's footprint, so nothing moves when the keyboard comes up; row 1 and the key row
stay where that rule puts them. The picture's frame takes the picture's own shape inside its room,
from the top: a 16:10 window keeps its shape, a taller one gains, and a window the Mac fits to the
room (Aa set, or the virtual display) fills it. The viewport is the whole room, so toggling sends
one new viewport (one restart while the Mac fits the window). The trackpad's vertical span follows
the picture's real shape, so a stroke moves the pointer as far down as across. Windows stay
reachable from Apps (tapping an open app again shows its next window) and from the Mac's Window
menu: the Menus button moves into row 1, after Apps, while the Mac sent menus. Every rect is a pure
function of the screen's size, the keyboard's height and the switch (and the frame and the span
also of the picture's shape), in `PhonePortraitLayout`, checked in `Tests/checks/phone-portrait`.

### The rule

W × H is the stream screen (the screen less its top inset, as before); K the keyboard's height
(below); K' = max(K, 136), so the trackpad keeps its least 120 pt.

1. **The room:** x 8, y 8, W − 16 wide, ⌊H − K' − 152⌋ tall (never below 0). 152 pt is everything
   above the keyboard but the picture: 8 + 8 + 10 + 6 (the margins and row 1's band above), 50
   (row 1), 6 + 10 (its band below and a row gap), 44 (the key row), 10 (the clearance).
2. **Row 1:** 24 pt under the room, as today under the picture; five buttons of (W − 60) ÷ 5, or,
   while the Mac sent its menus, six of (W − 68) ÷ 6: Apps, Menus, Aa, Keyboard, Desktop, Settings
   (the landscape bar's order with the strip gone).
3. **No row 2.** The strip is a row of no height at row 1's band's bottom (for the rules' order).
4. **The key row:** 16 pt under row 1's buttons (its band and a row gap), its bottom 10 pt above the
   keyboard's top.
5. **The trackpad:** from the keyboard's top (H − K') to H − 16, 14 pt from each side: the
   keyboard's footprint.
6. **The frame** for a picture of shape w × h (16:10 before the first frame): as wide as the room
   and ⌊room width × h ÷ w⌋ tall, from the room's top; a shape taller than the room is as tall as
   the room, ⌊room height × w ÷ h⌋ wide and centred across it. Whole points, past a hundredth of a
   point, so a window fitted to the room fills it exactly.
7. **The trackpad's span:** its width × the frame's height ÷ its width, so the pad's width moves the
   pointer the frame's width and the span its height. (Today's arrangement keeps its width ÷ 1.6.)
8. **The ruler** on Aa (of five, or of six while the Mac sent menus), the **drawer** and the
   **Settings panel** under row 1 across its span, the **dim**: today's rules, on the new row 1.
9. **The keyboard's height** K: the software keyboard as Sill's input view shows it (autocorrection
   off: no suggestions bar), estimated from the stream screen's shape and width, since it is only
   known once it shows: a stream screen under 1.9 times as tall as wide is a Home-button iPhone
   (the SE's 375×647 is 1.73, with Display Zoom 320×548 1.71), 216 pt; else one with Face ID (2.0
   and more, zoomed too), 320 pt from 428 pt wide (the Plus and Pro Max sizes), else 301. The
   numbers are docs/iphone-portrait-plan.md's measurements (the 18 Pro Max 320, the 18 Pro and the
   17e 301, the SE's classic 216), which S2 measures again on more phones. On a device with a hinge
   (the iPhone Duo) there is none: its cover's keyboard was never measured, so the switch is hidden
   there and the cover stays as it is (`PhonePortraitLayout.keyboard(for:largerPicture:foldable:)`).

```swift
struct PhonePortraitLayout {        // additions
    static let keyboardClearance: CGFloat = 10
    static let homeButtonKeyboard: CGFloat = 216, faceIDKeyboard: CGFloat = 301, wideKeyboard: CGFloat = 320
    static let wideKeyboardFrom: CGFloat = 428, faceIDShape: CGFloat = 1.9
    let keyboard: CGFloat?                    // Larger Picture's keyboard; nil: today's arrangement
    var largerPicture: Bool
    let buttonsBesideMenus: [CGRect]          // row 1 while the Mac sent menus
    let rulerBesideMenus: CGRect, rulerStepBesideMenus: CGFloat
    init(size: CGSize, keyboard: CGFloat? = nil)
    func pane(video: CGSize) -> CGRect        // the frame, rule 6
    func trackpadSpan(video: CGSize) -> CGFloat
    static func keyboardHeight(for container: CGSize) -> CGFloat
    static func keyboard(for container: CGSize, largerPicture: Bool, foldable: Bool) -> CGFloat?
}
```

### The numbers

From the rule (the prototype is the code: `Tests/checks/phone-portrait` pins these). The container
is the screen less its top inset; "today" is the switch off. The 15 Pro Max and 16 Plus take the 18
Pro Max's keyboard, the Air, 15 Pro and 13 mini the 18 Pro's, until S2 measures them.

| Phone (container) | K | Room (today's picture) | Row 1 | Key row | Trackpad (today) | Panel room (today) | The Desktop's frame |
|---|---|---|---|---|---|---|---|
| 18 Pro Max (440×894) | 320 | 424×422 (424×265), +59 % | 454–504 | 520–564 | 412×304 at 574 (389) | 366 (523) | 424×275 |
| 15 Pro Max, 16 Plus (430×873) | 320 | 414×401 (414×258), +55 % | 433–483 | 499–543 | 402×304 at 553 (375) | 366 (509) | 414×268 |
| Air (420×850) | 301 | 404×397 (404×252), +57 % | 429–479 | 495–539 | 392×285 at 549 (358) | 347 (492) | 404×262 |
| 18 Pro (402×812) | 301 | 386×359 (386×241), +48 % | 391–441 | 457–501 | 374×285 at 511 (331) | 347 (465) | 386×250 |
| 15 Pro, Noah's (393×793) | 301 | 377×340 (377×235), +44 % | 372–422 | 438–482 | 365×285 at 492 (318) | 347 (452) | 377×244 |
| 17e (390×797) | 301 | 374×344 (374×233), +47 % | 376–426 | 442–486 | 362×285 at 496 (324) | 347 (458) | 374×242 |
| 13 mini (375×762) | 301 | 359×309 (359×224), +37 % | 341–391 | 407–451 | 347×285 at 461 (298) | 347 (432) | 359×233 |
| SE (375×647) | 216 | 359×279 (359×224), +24 % | 311–361 | 377–421 | 347×200 at 431 (183) | 262 (317) | 359×233 |
| SE with Display Zoom (320×548) | 216 | 304×180 (304×188), −4 % | 212–262 | 278–322 | 292×200 at 332 (120) | 262 (254) | 277×180 |

The Desktop of a 14-inch MacBook Pro (1512×982 pt, 1.54:1) is a little taller than 16:10, so its
frame gains 10 pt on the Pro Max; a 16:10 window gains nothing until the Mac fits it to the room.
Row 1's six buttons with Menus are 62 pt wide on the Pro Max, 51.2 on the SE, 42 at 320 pt; the
ruler's step is 36 with six on every phone. The panel room with Larger Picture is K + 46 pt (262 on
the SE, the shortest: the compact halves' 259 at 500×710 stays the least, and the panel scrolls
there as it does).

### The views

- **`PortraitStreamScreen.phone`** places `PhoneRows` at the rule's rects in reading order:
  picture, row 1, (the strip, today), the key row, the trackpad. With Larger Picture the strip is
  not declared (VoiceOver: Apps, Menus, Text size, Keyboard, Desktop, Settings, Escape … Shift, the
  trackpad's hint), and the picture's pane is placed at `pane(video: client.videoSize)` (its
  background, corners and stroke follow it; the black around it is the screen's). The pane reports
  no size of its own then: the viewport is the room (`onPanelSize(layout.picture.size)`), so the
  Mac fits a window to all of it. Nothing else changes in the pane (the same `StreamView` and
  `InputOverlay`, so the keyboard's first responder survives the toggle).
- **Row 1** gets the Menus button after Apps while the Mac sent menus (`buttonsBesideMenus`,
  `rulerStepBesideMenus`), fading with the others under the Aa ruler.
- **The trackpad** gets `trackpadSpan(video:)`.
- **`StreamScreen`** reads the switch (`@AppStorage`) and the hinge (`posture.hinge`), asks
  `PhonePortraitLayout.keyboard(for:largerPicture:foldable:)` for the phone's layout, and passes it
  down; the tour learns whether the thumbnails show.
- **`HostSettingsPanel`**, This iPhone: "Larger Picture" before Three-Finger Gestures, with its
  footnote: "Held upright, the picture takes the room of the window thumbnails, down to the
  keyboard. Switch windows with Apps: tap an open app again for its next window. Aa fits a window
  to the picture." Only on an iPhone without a hinge.
- **The tour** (`TourPolicy`): a target for Apps (`TourTarget.apps`, row 1's Apps on a phone);
  without the thumbnails the bar card lights Apps, Aa and Keyboard (Menus between them) and its
  first row is about Apps ("Apps lists the apps on ‹Mac›: tap an open one again for its next
  window."; under VoiceOver "Apps lists the apps on ‹Mac›. Choose an open one again for its next
  window."); its hint "Under the picture, in the row of buttons: Apps, Aa and Keyboard."; the
  laptop card's hint "Under the buttons: the row of keys, then the trackpad.". A card upright is
  placed against the picture's room (`TourPolicy.place`'s new `room`), so it can stand in the black
  under a short picture with its tail at row 1; the picture's card still lights and centres on the
  picture itself. The layout stays `.phone` for the tour's rule (toggling is no turn).
- **DEBUG:** `-Sill.largerPicture 1` (the switch for one run, as `-Sill.trackpadGestures 0`);
  `-SillVideoSize 848x844` (the mock's frame, so the harness can draw a window fitted to the room);
  console lines `keyboard: up, 320 pt tall, its top at 574 pt; the key row 10 pt above it` and
  `trackpad: 412×304 pt, vertical span 410.1 pt` in the phone's arrangement.

## Open questions for Noah (the default is taken unless Noah says otherwise)

1. **What the switch gives up.** Default: **the thumbnails' row** (the triage's recommendation).
   The alternative keeps the thumbnails and lets the keyboard cover the rows under it.
2. **The picture's frame.** Default: **the picture's own shape, at the top of its room,** black
   around it (a 16:10 window as today, a taller one taller). Alternatives: the whole room as the
   frame with bars inside it, or the frame centred in the room or against row 1.
3. **The keyboard's height.** Default: **an estimate from the screen's shape and width** (216, 301,
   320), so the layout never moves. The alternative learns the tallest keyboard the device showed
   (an input method's candidate bar is about 44 pt taller and covers the key row today) and moves
   the layout once, while the keyboard is up.
4. **The Menus button.** Default: **in row 1 after Apps while the Mac sent menus** (six buttons;
   five before the menus come, a moment after connecting). The alternative keeps six places always.
5. **The iPhone Duo's cover.** Default: **unchanged, the switch hidden on the Duo** (its keyboard
   was never measured). The alternative takes the iPhone's 301 pt there.
6. **Off by default.** The alternative turns it on for new installs.
7. **No fit without Aa.** Default: **a window keeps its shape until Aa sets a text size** (or on the
   virtual display), as everywhere today; #70 decides whether the Mac fits windows by default.
8. **The trackpad's span.** Default: **the picture's own shape** with the switch on. The alternative
   keeps the width ÷ 1.6.
9. **The SE with Display Zoom** (320×548). Default: **the keyboard rule** (the picture 180 pt tall
   against 188 without the switch, the key row 10 pt above the keyboard, which today covers it). The
   alternative never makes the picture shorter (2 pt of clearance there).

## Test plan

Hard rules: only this worktree; nothing on Noah's devices, Sill.app, his windows or his keychain;
simulators private (named "Sill larger-picture …"), one at a time, deleted after; `simctl io
screenshot` only (no recording, no XCUITest, no simulator panel); live hosts only `SillHost
--synthetic` with `SILL_TEST_LOOPBACK=1 SILL_TEST_SOFTWARE_ENCODER=1 SILL_TEST_NO_ROUTER=1`, reached
with `-SillConnect 127.0.0.1:P`, each under a minute and killed by PID; DerivedData in the session's
scratchpad.

| # | Check | Pass when |
|---|---|---|
| H1 | iOS Debug and Release for the generic simulator, Debug for a generic device, `CODE_SIGNING_ALLOWED=NO` | `** BUILD SUCCEEDED **`, only the known `StreamClient` capture warning |
| H2 | `Tests/checks/phone-portrait`: today's 165 unchanged; the table above phone by phone (room, rows, trackpad, clearance 10, the trackpad the keyboard's footprint); the estimate (every phone, Display Zoom, the Duo's cover, the switch, the hinge); the frame (16:10, the room's own shape, taller, the Desktop, before a frame, today's arrangement whatever the video); the span; row 1 with six; a grid of widths 300–599, heights to 1,400 and keyboards 216, 301, 320; mutants for each new rule | All pass, every mutant caught |
| H3 | `Tests/checks/tour`: Apps' target, the bar card without thumbnails (targets, rows, VoiceOver rows, hints), the laptop hint, the room's placement (pinned, an oracle, the grid with the Larger Picture screens), mutants | All pass, every mutant caught |
| H4 | `Tests/checks/run-all.sh` | All pass |
| H5 | Harness photos, switch off, at the phone sizes against main's build | Pixel for pixel equal, but for the Settings panel's new row |
| S1 | Harness photos, switch on: 440x894, 402x812, 393x793, 390x797, 375x647 plain, `-SillDrawer 1`, `-SillSettings 1`, `-SillScaleOpen 1`, `-SillVideoSize` a fitted window and a tall one, `-SillTour bar` | Against the table |
| S2 | Live, the normal app with `-Sill.largerPicture 1 -SillKeyboard 1` against a synthetic host, on the 18 Pro Max, 18 Pro, 17e and SE (and the keyboard alone on the Air, 15 Pro, 15 Pro Max) | The keyboard's top where the estimate puts it, the key row ≥ 10 pt above it, the `viewport:` line the room, the `trackpad:` line's span |
| S3 | VoiceOver's order with the strip hidden; the Settings row at accessibility sizes | Apps … Settings, the keys, the trackpad; the row whole |

**Untested, for Noah (P), on the iPhone 15 Pro:** the switch on and off with Notes and Chrome
streaming (a 16:10 window keeps its shape; Aa then fits it to the taller picture; a taller window
gains); the keyboard up and down (the key row stays above it, nothing moves); windows from Apps and
from Menus › Window; the tour on a fresh install with the switch on; VoiceOver's order.

## Results

(Filled in as the work lands.)

## Progress

- 2026-10-14: the plan; `PhonePortraitLayout`'s Larger Picture arrangement drafted (today's 165
  checks pass unchanged).
