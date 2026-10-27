// Copyright 2026 DUO你电脑 contributors. SPDX-License-Identifier: Apache-2.0
// Storage/crash checks use isolated files only; no display API, pixels or credentials.
import Foundation
import Darwin

let fm = FileManager.default
let args = CommandLine.arguments
func record(serial: UInt32 = 1234, x: Int32 = 0, refresh: Double = 120,
            secondSerial: UInt32? = nil, version: Int = 1) -> DisplayRecoveryRecord {
    func screen(_ id: UInt32, _ serial: UInt32, _ x: Int32) -> DisplayRecoveryRecord.Display {
        .init(id: id, identity: .init(vendor: 42, model: 7, serial: serial, builtIn: false),
              modeID: 9, width: 1004, height: 714, pixelWidth: 2008, pixelHeight: 1428,
              refresh: refresh, originX: x, originY: 0, mirror: 0)
    }
    var screens = [screen(1, serial, x)]
    if let secondSerial { screens.append(screen(2, secondSerial, 1004)) }
    return .init(version: version, token: UUID(), main: 1, displays: screens)
}

func intent(for original: DisplayRecoveryRecord, targetRefresh: Double? = nil,
            targetX: Int32? = nil, targetSerial: UInt32? = nil, changed: Bool = true) -> DisplayRecoveryIntent {
    let old = original.displays[0]
    let target = DisplayRecoveryRecord.Display(id: old.id,
        identity: .init(vendor: old.identity.vendor, model: old.identity.model,
                        serial: targetSerial ?? old.identity.serial, builtIn: old.identity.builtIn),
        modeID: changed ? old.modeID + 1 : old.modeID, width: old.width, height: old.height,
        pixelWidth: old.pixelWidth, pixelHeight: old.pixelHeight,
        refresh: targetRefresh ?? old.refresh, originX: targetX ?? old.originX, originY: old.originY, mirror: old.mirror)
    let expected = DisplayRecoveryRecord(version: 1, token: original.token, main: original.main, displays: [target])
    return DisplayRecoveryIntent(version: 1, expected: expected)
}

if args.count == 3, args[1] == "--hold" || args[1] == "--hold-intent" {
    let directory = URL(fileURLWithPath: args[2], isDirectory: true)
    do {
        let store = try DisplayRecoveryStore(directory: directory)
        let before = record()
        try store.save(before)
        if args[1] == "--hold-intent" { try store.saveIntent(intent(for: before), for: before) }
        guard fm.createFile(atPath: directory.appendingPathComponent("child-ready").path, contents: Data()) else { exit(2) }
        withExtendedLifetime(store) { while true { sleep(1) } }
    } catch { exit(2) }
}
guard args.count == 2 else { fputs("expected a new fixture directory\n", stderr); exit(2) }
let root = URL(fileURLWithPath: args[1], isDirectory: true)
guard !fm.fileExists(atPath: root.path) else { fputs("fixture already exists\n", stderr); exit(2) }
try fm.createDirectory(at: root, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
func directory(_ name: String) -> URL { root.appendingPathComponent(name, isDirectory: true) }
func rejects(_ body: () throws -> Void) -> Bool { do { try body(); return false } catch { return true } }
var failures = 0, checks = 0
func check(_ name: String, _ result: @autoclosure () throws -> Bool) {
    checks += 1
    let passed = (try? result()) == true
    if !passed { failures += 1 }
    print("\(passed ? "PASS" : "FAIL") \(name)")
}

let first = record()
check("valid full native snapshot", first.isValid)
check("same state independently reidentified", first.alreadyRestored(as: record()))
check("user moved a display", !first.alreadyRestored(as: record(x: 1)))
check("exact refresh changed", !first.alreadyRestored(as: record(refresh: 119.9)))
check("serial missing", !record(serial: 0).alreadyRestored(as: record(serial: 0)))
check("sentinel serial", !record(serial: .max).alreadyRestored(as: record(serial: .max)))
check("different physical identity", !first.alreadyRestored(as: record(serial: 5678)))
check("duplicate physical identities", !record(secondSerial: 1234).alreadyRestored(as: record(secondSerial: 1234)))
check("independent unique identities", record(secondSerial: 5678).alreadyRestored(as: record(secondSerial: 5678)))
check("unknown format rejected", !record(version: 2).isValid)

let changed = intent(for: first)
check("single-display intent is valid", changed.isValid(for: first))
check("matching planned state permits replay", changed.permitsReplay(original: first, current: changed.expected))
check("before mutation does not replay", !changed.permitsReplay(original: first, current: first))
check("user position change does not replay", !changed.permitsReplay(original: first, current: record(x: 1)))
check("changed display identity does not replay", !changed.permitsReplay(original: first, current: intent(for: record(serial: 5678)).expected))
let noSerial = record(serial: 0)
check("missing serial never permits replay", !intent(for: noSerial).permitsReplay(original: noSerial, current: intent(for: noSerial).expected))
check("refresh-changing intent rejected", !intent(for: first, targetRefresh: 60).isValid(for: first))
check("position-changing intent rejected", !intent(for: first, targetX: 1).isValid(for: first))
check("identity-changing intent rejected", !intent(for: first, targetSerial: 5678).isValid(for: first))
check("unchanged mode intent rejected", !intent(for: first, changed: false).isValid(for: first))
let multiple = record(secondSerial: 5678)
check("multiple displays never permit replay", !intent(for: multiple).isValid(for: multiple))
check("different transaction cannot reuse intent", !changed.isValid(for: record()))

do {
    let store = try DisplayRecoveryStore(directory: directory("normal"))
    check("initial record absent", try store.load() == nil)
    try store.save(first)
    check("write-ahead record round trips exactly", try store.load() == first)
    check("second session cannot acquire active lease", rejects { _ = try DisplayRecoveryStore(directory: directory("normal")) })
    check("existing record cannot be overwritten", rejects { try store.save(record()) })
    check("failed overwrite preserves first record", try store.load() == first)
    check("wrong token cannot clear a record", rejects { try store.remove(token: UUID()) })
    check("wrong token leaves original intact", try store.load() == first)
    try store.remove(token: first.token)
    check("owner removes record after completion", try store.load() == nil)
} catch { print("FAIL normal storage: \(error)"); failures += 1 }

do {
    let dir = directory("intent")
    let store = try DisplayRecoveryStore(directory: dir)
    try store.save(first)
    try store.saveIntent(changed, for: first)
    check("durable intended state round trips", try store.loadIntent(for: first) == changed)
    check("intent cannot be overwritten", rejects { try store.saveIntent(changed, for: first) })
    check("wrong transaction cannot remove intent", rejects { try store.remove(token: UUID()) })
    check("intent retained with original after rejected removal", try store.load() == first && store.loadIntent(for: first) == changed)
    try store.remove(token: first.token)
    check("successful cleanup removes original and intent", try store.load() == nil && store.loadIntent(for: first) == nil)
} catch { print("FAIL intent storage: \(error)"); failures += 1 }

do {
    let dir = directory("orphan")
    let store = try DisplayRecoveryStore(directory: dir)
    let path = dir.appendingPathComponent("pending-display-intent.json")
    try JSONEncoder().encode(changed).write(to: path)
    try fm.setAttributes([.posixPermissions: 0o600], ofItemAtPath: path.path)
    check("orphan intent blocks new record", rejects { try store.save(first) })
    check("orphan intent preserved", fm.fileExists(atPath: path.path))
} catch { print("FAIL orphan storage: \(error)"); failures += 1 }

do {
    let dir = directory("fifo")
    let store = try DisplayRecoveryStore(directory: dir)
    let path = dir.appendingPathComponent("pending-display-intent.json")
    guard mkfifo(path.path, 0o600) == 0 else { throw DisplayRecoveryStore.Failure.unavailable }
    check("orphan FIFO intent rejects without waiting for a writer", rejects { _ = try store.load() })
    check("orphan FIFO is preserved", fm.fileExists(atPath: path.path))
} catch { print("FAIL fifo intent storage: \(error)"); failures += 1 }

do {
    let dir = directory("bad-intent")
    let store = try DisplayRecoveryStore(directory: dir)
    try store.save(first)
    let path = dir.appendingPathComponent("pending-display-intent.json")
    try Data("bad-intent".utf8).write(to: path)
    try fm.setAttributes([.posixPermissions: 0o600], ofItemAtPath: path.path)
    check("corrupt intent fails closed", rejects { _ = try store.loadIntent(for: first) })
    check("corrupt intent prevents cleanup", rejects { try store.remove(token: first.token) })
    check("corrupt intent and original preserved", try fm.fileExists(atPath: path.path) && store.load() == first)
} catch { print("FAIL corrupt intent storage: \(error)"); failures += 1 }

do {
    let dir = directory("corrupt")
    let store = try DisplayRecoveryStore(directory: dir)
    let path = dir.appendingPathComponent("pending-display.json")
    try Data("not-json".utf8).write(to: path)
    try fm.setAttributes([.posixPermissions: 0o600], ofItemAtPath: path.path)
    check("malformed record fails closed", rejects { _ = try store.load() })
    check("malformed record cannot be replaced", rejects { try store.save(first) })
    check("malformed bytes remain intact", try Data(contentsOf: path) == Data("not-json".utf8))
} catch { print("FAIL corrupt storage: \(error)"); failures += 1 }

do {
    let dir = directory("symlink")
    let store = try DisplayRecoveryStore(directory: dir)
    let target = root.appendingPathComponent("should-not-exist")
    let link = dir.appendingPathComponent("pending-display.json")
    try fm.createSymbolicLink(at: link, withDestinationURL: target)
    check("symlink record rejected", rejects { _ = try store.load() })
    check("symlink record not overwritten", rejects { try store.save(first) })
    check("symlink target not created", !fm.fileExists(atPath: target.path))
} catch { print("FAIL symlink storage: \(error)"); failures += 1 }

do {
    let dir = directory("permissions")
    let store = try DisplayRecoveryStore(directory: dir)
    try store.save(first)
    let path = dir.appendingPathComponent("pending-display.json")
    try fm.setAttributes([.posixPermissions: 0o644], ofItemAtPath: path.path)
    check("non-private record rejected", rejects { _ = try store.load() })
    check("non-private record retained", fm.fileExists(atPath: path.path))
} catch { print("FAIL permissions storage: \(error)"); failures += 1 }

do {
    let dir = directory("crashed-process")
    let child = Process()
    child.executableURL = URL(fileURLWithPath: args[0])
    child.arguments = ["--hold", dir.path]
    try child.run()
    let sentinel = dir.appendingPathComponent("child-ready").path
    for _ in 0..<500 where !fm.fileExists(atPath: sentinel) && child.isRunning { usleep(10_000) }
    guard child.isRunning, fm.fileExists(atPath: sentinel) else {
        if child.isRunning { child.terminate(); child.waitUntilExit() }
        throw DisplayRecoveryStore.Failure.unavailable
    }
    check("other process holds exclusive lease", rejects { _ = try DisplayRecoveryStore(directory: dir) })
    kill(child.processIdentifier, SIGKILL)
    child.waitUntilExit()
    let reopened = try DisplayRecoveryStore(directory: dir)
    let retained = try reopened.load()
    check("hard-killed process releases lease", retained != nil)
    check("hard-killed process leaves full record", retained?.sameState(as: first) == true)
    if let retained { try reopened.remove(token: retained.token) }
} catch { print("FAIL crash storage: \(error)"); failures += 1 }

do {
    let dir = directory("crashed-intent-process")
    let child = Process()
    child.executableURL = URL(fileURLWithPath: args[0])
    child.arguments = ["--hold-intent", dir.path]
    try child.run()
    let sentinel = dir.appendingPathComponent("child-ready").path
    for _ in 0..<500 where !fm.fileExists(atPath: sentinel) && child.isRunning { usleep(10_000) }
    guard child.isRunning, fm.fileExists(atPath: sentinel) else {
        if child.isRunning { child.terminate(); child.waitUntilExit() }
        throw DisplayRecoveryStore.Failure.unavailable
    }
    kill(child.processIdentifier, SIGKILL)
    child.waitUntilExit()
    let reopened = try DisplayRecoveryStore(directory: dir)
    guard let retained = try reopened.load(), let intended = try reopened.loadIntent(for: retained) else {
        throw DisplayRecoveryStore.Failure.invalidRecord
    }
    check("hard-killed process retains both original and intended state", intended.permitsReplay(original: retained, current: intended.expected))
    try reopened.remove(token: retained.token)
} catch { print("FAIL crash intent storage: \(error)"); failures += 1 }

print("\(checks) checks; \(failures) failures")
exit(failures == 0 ? 0 : 1)
