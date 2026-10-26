// Copyright 2026 DUO你电脑 contributors. SPDX-License-Identifier: Apache-2.0
// Read-only WindowServer Space diagnostics, for this probe's own NSWindow only.
// ABI references (declarations, not implementation):
// https://github.com/Hammerspoon/hammerspoon/blob/master/extensions/spaces/private.h
// https://github.com/asmvik/yabai/blob/master/src/misc/extern.h
import AppKit
import Darwin
import Foundation

@MainActor
final class DisplaySpaceAudit {
    struct Failure: LocalizedError {
        let message: String
        var errorDescription: String? { message }
    }
    struct Observation {
        let spaces: [UInt64]
        let expectedDisplayUUID: String
        let owners: [String]
        let currentSpace: UInt64
        var ownsExpectedDisplay: Bool {
            !spaces.isEmpty && owners.count == spaces.count && owners.allSatisfy {
                $0.caseInsensitiveCompare(expectedDisplayUUID) == .orderedSame
            }
        }
    }
    private typealias MainConnection = @convention(c) () -> Int32
    private typealias CopyWindowSpaces = @convention(c) (Int32, Int32, CFArray) -> Unmanaged<CFArray>?
    private typealias CopySpaceDisplay = @convention(c) (Int32, UInt64) -> Unmanaged<CFString>?
    private typealias CurrentSpace = @convention(c) (Int32, CFString) -> UInt64
    private typealias DisplayUUID = @convention(c) (CGDirectDisplayID) -> Unmanaged<CFUUID>?
    private let connection: Int32
    private let copyWindowSpaces: CopyWindowSpaces
    private let copySpaceDisplay: CopySpaceDisplay
    private let currentSpace: CurrentSpace
    private let displayUUID: DisplayUUID
    private var observations: [[String: Any]] = []
    private(set) var originalSpaces: [UInt64] = []
    private let output: URL

    init() throws {
        guard ProcessInfo.processInfo.operatingSystemVersion.majorVersion == 27 else {
            throw Failure(message: "Space audit ABI is scoped to macOS 27")
        }
        func symbol<T>(_ name: String, as type: T.Type) throws -> T {
            guard let address = dlsym(UnsafeMutableRawPointer(bitPattern: -2), name) else {
                throw Failure(message: "Read-only Space symbol unavailable: \(name)")
            }
            return unsafeBitCast(address, to: type)
        }
        let main = try symbol("CGSMainConnectionID", as: MainConnection.self)
        copyWindowSpaces = try symbol("CGSCopySpacesForWindows", as: CopyWindowSpaces.self)
        copySpaceDisplay = try symbol("CGSCopyManagedDisplayForSpace", as: CopySpaceDisplay.self)
        currentSpace = try symbol("CGSManagedDisplayGetCurrentSpace", as: CurrentSpace.self)
        displayUUID = try symbol("CGDisplayCreateUUIDFromDisplayID", as: DisplayUUID.self)
        connection = main()
        output = URL(fileURLWithPath: ProcessInfo.processInfo.environment["DUODESK_DISPLAY_SPACE_REPORT"]
                     ?? "Temp/AirAcceptance-20261026/display-spaces.json")
    }

    @discardableResult
    func record(_ phase: String, window: NSWindow, expectedDisplay: CGDirectDisplayID) throws -> Observation {
        guard window.windowNumber > 0,
              let uuid = displayUUID(expectedDisplay)?.takeRetainedValue(),
              let array = copyWindowSpaces(connection, 0x7, [NSNumber(value: window.windowNumber)] as CFArray)?.takeRetainedValue(),
              let numbers = array as? [NSNumber], !numbers.isEmpty else {
            throw Failure(message: "Space audit could not read the owned window or expected display")
        }
        let expectedUUID = CFUUIDCreateString(nil, uuid) as String
        let spaces = numbers.map(\.uint64Value).sorted()
        let owners = try spaces.map { id -> String in
            guard let owner = copySpaceDisplay(connection, id)?.takeRetainedValue() else {
                throw Failure(message: "Space \(id) has no readable display owner")
            }
            return owner as String
        }
        let observation = Observation(spaces: spaces, expectedDisplayUUID: expectedUUID, owners: owners,
                                      currentSpace: currentSpace(connection, expectedUUID as CFString))
        if observations.isEmpty { originalSpaces = spaces }
        let bounds = ownWindowBounds(window)
        observations.append(["phase": phase, "expectedDisplayID": expectedDisplay,
                             "expectedDisplayUUID": expectedUUID, "windowID": window.windowNumber,
                             "spaceIDs": spaces, "spaceDisplayUUIDs": owners,
                             "currentSpaceOnExpectedDisplay": observation.currentSpace,
                             "spaceIDsPreserved": spaces == originalSpaces,
                             "spaceBelongsToExpectedDisplay": observation.ownsExpectedDisplay,
                             "windowFullscreen": window.styleMask.contains(.fullScreen),
                             "windowOnActiveSpace": window.isOnActiveSpace,
                             "windowBounds": bounds.map { [$0.minX, $0.minY, $0.width, $0.height] } ?? []])
        print("Space audit \(phase): window spaces=\(spaces), target current=\(observation.currentSpace), ownsTarget=\(observation.ownsExpectedDisplay), active=\(window.isOnActiveSpace)")
        return observation
    }

    func finish(passed: Bool, cleanupRestored: Bool, error: String? = nil) throws {
        let restored = observations.last { ["restored", "failure-restored"].contains($0["phase"] as? String ?? "") }
        let restoredSpaceActive: Any = restored.map {
            ($0["spaceIDsPreserved"] as? Bool == true) && ($0["spaceBelongsToExpectedDisplay"] as? Bool == true)
                && ($0["windowOnActiveSpace"] as? Bool == true)
        } ?? NSNull()
        let report: [String: Any] = ["passed": passed, "displayConfigurationRestored": cleanupRestored,
                                   "originalFullscreenSpaceRestoredAndActive": restoredSpaceActive,
                                   "error": error ?? "", "observations": observations,
                                   "spaceAPIsReadOnly": true, "captureOrInputStarted": false,
                                   "performanceAcceptance": false]
        let data = try JSONSerialization.data(withJSONObject: report, options: [.prettyPrinted, .sortedKeys])
        try FileManager.default.createDirectory(at: output.deletingLastPathComponent(), withIntermediateDirectories: true)
        try data.write(to: output, options: .atomic)
        print("Space audit report: \(output.path)")
    }
}
