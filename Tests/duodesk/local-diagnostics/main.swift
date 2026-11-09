// Copyright 2026 DUO你电脑 contributors. SPDX-License-Identifier: Apache-2.0
import Foundation

func check(_ value: @autoclosure () -> Bool, _ message: String) {
    precondition(value(), message)
}

let root = FileManager.default.temporaryDirectory.appending(path: "duo-diagnostics-\(UUID())")
let suite = "duo-diagnostics-test-\(UUID())"
let defaults = UserDefaults(suiteName: suite)!
defer {
    try? FileManager.default.removeItem(at: root)
    defaults.removePersistentDomain(forName: suite)
}
let logs = DuoDiagnostics(directory: root, enabled: false, defaults: defaults)
logs.record("must-not-be-recorded")
var report = await logs.capture(description: "无法发现 Mac")
check(report.log.isEmpty && !report.loggingEnabled, "disabled recorder wrote a line")
check(!FileManager.default.fileExists(atPath: root.path), "disabled recorder created a file")
check(report.userDescription == "无法发现 Mac", "description was not preserved")
logs.setEnabled(true)
logs.record("first-enabled-line")
report = await logs.capture(description: "")
check(report.log.contains("first-enabled-line"), "enabled log did not reach capture")
check(report.loggingEnabled && report.storageError == nil, "normal capture reported failure")
let encoded = try JSONSerialization.jsonObject(with: report.data()) as! [String: Any]
check(encoded["log"] as? String == report.log, "export did not preserve log")
check(encoded["capturedAt"] is String, "export lacks capture time")
logs.setEnabled(false)
logs.record("after-disable")
report = await logs.capture(description: "")
check(!report.log.contains("after-disable") && report.log.contains("first-enabled-line"), "disable lost old logs or recorded new ones")
check(!DuoDiagnostics(directory: root, defaults: defaults).isEnabled, "toggle did not survive relaunch")
logs.setEnabled(true)
for n in 0..<1_100 { logs.record("\(n):" + String(repeating: "x", count: 4_200)) }
logs.record("newest-kept-line")
report = await logs.capture(description: "导出说明")
check(report.log.contains("newest-kept-line"), "rotation lost newest lines")
check(!report.log.contains("first-enabled-line"), "rotation kept unbounded history")
let files = try FileManager.default.contentsOfDirectory(at: root, includingPropertiesForKeys: [.fileSizeKey])
check(Set(files.map(\.lastPathComponent)) == ["recent.log", "previous.log"], "unexpected log files")
for file in files {
    let bytes = try file.resourceValues(forKeys: [.fileSizeKey]).fileSize!
    check(bytes <= 2_000_000, "log exceeds rotation cap")
}
let bad = DuoDiagnostics(directory: root.appending(path: "recent.log/subdir"), enabled: true, defaults: defaults)
bad.record("unwritable")
let failed = await bad.capture(description: "still-exportable")
check(failed.storageError != nil, "write failure disappeared")
_ = try failed.data()
print("Local diagnostics: toggle, persistence, recent export, rotation and storage errors passed")
