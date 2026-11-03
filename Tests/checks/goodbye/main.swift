import Foundation
// H3 (GoodbyePolicy): every row of the plan's §7.3 table, the cleaning of a host's message, and the
// reconnect rule. Compiled with Sources/StreamProtocol and iOSClient/GoodbyePolicy.swift (its
// `import StreamProtocol` dropped).
var failures = 0, checks = 0
func check(_ ok: Bool, _ what: @autoclosure () -> String, line: Int = #line) {
    checks += 1
    if !ok { failures += 1; print("FAIL (line \(line)): \(what())") }
}
typealias O = GoodbyePolicy.Outcome
func out(_ g: Goodbye?, saved: Bool = false, mac: String = "Mac mini", device: String = "iPad") -> O {
    GoodbyePolicy.outcome(g, mac: mac, device: device, saved: saved)
}
func g(_ reason: String, _ message: String? = nil, min: String? = nil, reconnect: Bool? = nil) -> Goodbye {
    Goodbye(reason: reason, message: message, minimumVersion: min, reconnect: reconnect)
}

// No goodbye: the connection just ended.
check(out(nil, saved: true) == O(text: "Mac mini 已断开，能够访问时将自动重新连接。", reconnect: true, remoteAllowed: true, isNotice: false), "none, saved")
check(out(nil) == O(text: "Mac mini 已断开，Mac 恢复后将自动重新连接。", reconnect: true, remoteAllowed: false, isNotice: false), "none, unsaved")
// Today's five, their words and reconnects unchanged.
check(out(g("quit"), saved: true) == O(text: "Mac mini 已退出 DUO你电脑，恢复后这台 iPad 将自动重新连接。", reconnect: true, remoteAllowed: true, isNotice: false), "quit, saved")
check(out(g("quit"), device: "iPhone").text == "Mac mini 已退出 DUO你电脑，恢复后这台 iPhone 将自动重新连接。" && !out(g("quit")).remoteAllowed, "quit, an unsaved iPhone")
check(out(g("removed"), saved: true) == O(text: "Mac mini 已移除这台 iPad，请重新配对后使用。", reconnect: false, remoteAllowed: false, isNotice: false), "removed")
check(out(g("remoteOff"), saved: true) == O(text: "Mac mini 已关闭远程访问。", reconnect: true, remoteAllowed: false, isNotice: false), "remoteOff")
check(out(g("internetOff"), saved: true) == O(text: "Mac mini 已停止接受公网连接，请通过 VPN 连接。", reconnect: true, remoteAllowed: false, isNotice: false), "internetOff")
check(out(g("busy"), saved: true) == O(text: "Mac mini 已连接 8 台设备。", reconnect: true, remoteAllowed: true, isNotice: false), "busy, saved")
check(!out(g("busy")).remoteAllowed, "busy, unsaved: rows only")
// The five ignore a message and reconnect a newer host might add: their rules are this build's.
check(out(g("quit", "x", reconnect: false), saved: true).text.hasPrefix("Mac mini 已退出 DUO你电脑") && out(g("quit", reconnect: false)).reconnect, "quit keeps its rule")
check(!out(g("removed", reconnect: true)).reconnect, "removed never reconnects")
for r in ["quit", "removed", "remoteOff", "internetOff", "busy", "pairingRequired"] { check(!GoodbyePolicy.isNotice(g(r)), "\(r) is not a notice") }
// "pairingRequired" (pairing at home, docs/home-pairing-plan.md §7.6): Require pairing was turned on
// while this unpaired device was connected at home. Its own words and no reconnect, whatever the
// host adds: a tap on the Mac's row asks to pair.
check(out(g("pairingRequired"), saved: true) == O(text: "Mac mini 现在要求设备配对。点按该 Mac 可配对这台 iPad。", reconnect: false,
                                                  remoteAllowed: false, isNotice: false), "pairingRequired")
check(out(g("pairingRequired", "x", reconnect: true), device: "iPhone") == O(text: "Mac mini 现在要求设备配对。点按该 Mac 可配对这台 iPhone。",
                                                                          reconnect: false, remoteAllowed: false, isNotice: false),
      "pairingRequired keeps its rule")
// A reason this build does not know: the Mac's words, a reconnect only when asked.
let later = g("pairAgain", "Pair this iPad with Mac mini again: choose Pair iPhone or iPad… on the Mac.", reconnect: false)
check(out(later, saved: true) == O(text: "Pair this iPad with Mac mini again: choose Pair iPhone or iPad… on the Mac.", reconnect: false, remoteAllowed: true, isNotice: true), "a later reason, reconnect false")
check(out(g("later", "Back soon.", reconnect: true), saved: true) == O(text: "Back soon.", reconnect: true, remoteAllowed: true, isNotice: true), "a later reason, reconnect true")
check(out(g("later", "Back soon.")).reconnect == false, "reconnect nil is false")
check(out(g("later")).text == "Mac mini 已关闭连接，点按该 Mac 可重试。", "no message, no reconnect")
check(out(g("later", reconnect: true)).text == "Mac mini 已关闭连接，能够访问时将自动重新连接。", "no message, reconnect")
check(out(g("")) == O(text: "Mac mini 已关闭连接，点按该 Mac 可重试。", reconnect: false, remoteAllowed: false, isNotice: true), "a kind 22 that did not decode")
check(GoodbyePolicy.isNotice(g("")) && GoodbyePolicy.isNotice(g("Quit")) && GoodbyePolicy.isNotice(later), "notices")
// The host's message, cleaned: one line, no control or bidi characters, at most 300 characters.
check(out(g("x", "Line one\nLine two\u{2028}three\ttab")).text == "Line one Line two three tab", "whitespace becomes one space")
check(out(g("x", "\u{202E}Mac mini\u{202C} says \u{200B}hi\u{0007}")).text == "Mac mini says hi", "bidi, zero-width and control characters go")
check(out(g("x", String(repeating: "a", count: 1000))).text.count == 300, "1,000 characters shown as 300")
check(out(g("x", String(repeating: "é", count: 400))).text.count == 300, "by characters, not bytes")
check(out(g("x", " \n\u{202E}\u{200B} ")).text == "Mac mini 已关闭连接，点按该 Mac 可重试。", "empty after cleaning counts as absent")
check(out(g("x", "")).text == "Mac mini 已关闭连接，点按该 Mac 可重试。", "an empty message counts as absent")
check(out(g("x", "**Update** [here](https://evil.example)")).text == "**Update** [here](https://evil.example)", "kept as plain text (shown verbatim, never as Markdown)")
check(GoodbyePolicy.messageLimit == 300, "the limit")
// "update": the host's words, the App Store link, a reconnect only when asked.
let refusal = g("update", "Update Sill on your iPad to keep using Mac mini. It needs version 1.2 or later.", min: "1.2", reconnect: false)
check(out(refusal, saved: true) == O(text: "Update Sill on your iPad to keep using Mac mini. It needs version 1.2 or later.", reconnect: false,
                                     remoteAllowed: true, storeLink: true, isNotice: true), "update, with its message")
check(GoodbyePolicy.isNotice(refusal), "update is a notice")
check(out(g("update", min: "1.2")).text == "请更新这台 iPad 上的 DUO你电脑，以继续使用 Mac mini。需要 1.2 或更高版本。", "update without a message")
check(out(g("update", min: "v2.0.0"), device: "iPhone").text == "请更新这台 iPhone 上的 DUO你电脑，以继续使用 Mac mini。需要 2.0 或更高版本。", "the version as SillVersion shows it")
check(out(g("update", min: "soon")).text == "请更新这台 iPad 上的 DUO你电脑，以继续使用 Mac mini。", "a minimumVersion that does not parse is left out")
check(out(g("update")).text == "请更新这台 iPad 上的 DUO你电脑，以继续使用 Mac mini。", "no minimumVersion")
check(!out(g("update")).reconnect && !out(g("update", reconnect: false)).reconnect, "update: no reconnect unless asked")
check(out(g("update", reconnect: true), saved: true).reconnect && out(g("update", reconnect: true), saved: true).remoteAllowed, "update with reconnect true (a host bug §3.7 forbids): reconnects")
check(out(g("update", "\u{202E}Update\nnow")).text == "Update now", "update's message cleaned too")
check(out(g("update", " ")).storeLink && out(g("update", " ")).text.hasPrefix("请更新这台 iPad"), "update, message empty after cleaning")
check(!out(later).storeLink && !out(g("quit")).storeLink && !out(nil).storeLink && !out(g("")).storeLink, "only update links the App Store")
print("\(checks) checks, \(failures) failed")
exit(failures == 0 ? 0 : 1)
