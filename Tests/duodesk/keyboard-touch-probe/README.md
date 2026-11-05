# Keyboard touch checks

These simulator fixtures use the production control deck and modifier state. Input is collected in
memory; no Mac is connected and no system input is posted.

`python3 Tests/duodesk/keyboard-touch-probe/build.py` builds the UIKit control check. Install the
resulting app on a simulator and launch `com.duodesk.tests.KeyboardTouch`; its report records the
hit-tested keys, immediate touch delivery, cancellation, repeat and accessibility behavior.

`ruby Tests/duodesk/keyboard-touch-probe/project.rb` generates the UI-test project (requires the
`xcodeproj` Ruby gem). Run its `KeyboardTouch` scheme on a simulator. The fixture sends Command's
touch-down and touch-up programmatically; XCTest taps the production W and Command buttons, and a
stand-in trackpad. This checks routing and state but does not simulate simultaneous physical touches
or verify a real Duo, network, or Mac window.
