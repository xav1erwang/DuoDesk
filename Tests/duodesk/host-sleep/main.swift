// Copyright 2026 DUO你电脑 contributors. SPDX-License-Identifier: Apache-2.0
import Foundation

func check(_ condition: @autoclosure () -> Bool, _ message: String) {
    guard condition() else { fatalError(message) }
}

check(HostSleepPolicy.hold(keepAvailable: true, running: true, synthetic: false, devices: 0, remote: 0) == .available,
      "idle host should stay available")
check(HostSleepPolicy.hold(keepAvailable: false, running: true, synthetic: false, devices: 0, remote: 0) == .none,
      "disabled setting should release the idle hold")
check(HostSleepPolicy.hold(keepAvailable: true, running: false, synthetic: false, devices: 0, remote: 0) == .none,
      "a host that did not start should not prevent sleep")
check(HostSleepPolicy.hold(keepAvailable: true, running: true, synthetic: true, devices: 0, remote: 0) == .none,
      "synthetic host should not prevent idle sleep")
check(HostSleepPolicy.hold(keepAvailable: false, running: true, synthetic: false, devices: 1, remote: 0) == .connected,
      "a local session keeps the existing latency activity")
check(HostSleepPolicy.hold(keepAvailable: true, running: true, synthetic: false, devices: 1, remote: 0) == .remote,
      "a local session preserves idle sleep protection when enabled")
check(HostSleepPolicy.hold(keepAvailable: false, running: true, synthetic: false, devices: 1, remote: 1) == .remote,
      "a remote session retains its existing sleep protection")

func assertions() throws -> String {
    let process = Process()
    let output = Pipe()
    process.executableURL = URL(fileURLWithPath: "/usr/bin/pmset")
    process.arguments = ["-g", "assertions"]
    process.standardOutput = output
    try process.run()
    let data = output.fileHandleForReading.readDataToEndOfFile()
    process.waitUntilExit()
    guard process.terminationStatus == 0, let text = String(data: data, encoding: .utf8) else {
        throw NSError(domain: "HostSleepTest", code: 1)
    }
    return text
}

let reason = "DUO sleep policy test \(ProcessInfo.processInfo.processIdentifier)"
let activity = ProcessInfo.processInfo.beginActivity(options: HostSleepPolicy.options(for: .available)!, reason: reason)
let held = try assertions()
check(held.split(separator: "\n").contains { $0.contains(reason) && $0.contains("PreventUserIdleSystemSleep") },
      "macOS should report an idle-system-sleep assertion")
ProcessInfo.processInfo.endActivity(activity)
let released = try assertions()
check(!released.contains(reason), "the assertion should be removed when the setting is disabled")
print("Host sleep policy: 9 checks passed; system assertion acquired and released")
