// Copyright 2026 DUO你电脑 contributors. SPDX-License-Identifier: Apache-2.0
// Isolated dispatch-timer comparison driven by recorded relative timings. No capture or UI.
import Foundation
import Dispatch

private struct TimerEvent: Codable, Sendable {
    let offset: Double
    let wait: Double
}

private struct Schedule: Codable, Sendable {
    let version: Int
    let scope: String
    let duration: Double
    let rawOffsets: [Double]
    let events: [TimerEvent]
}

private enum Variant: String, CaseIterable, Codable, Sendable {
    case asyncAfter, sourceZero, sourceStrict
}

private struct Trial: Codable, Sendable {
    let index: Int
    let variant: Variant
    let waitMs: Double
    let issueLatenessMs: Double
    let fireLatenessMs: Double
}

private struct VariantSummary: Codable {
    let variant: Variant
    let count: Int
    let waitMsP50: Double?
    let waitMsP95: Double?
    let issueLatenessMsP50: Double?
    let issueLatenessMsP95: Double?
    let fireLatenessMsP50: Double?
    let fireLatenessMsP95: Double?
    let fireLatenessMsP99: Double?
    let earlyCount: Int
}

private struct Report: Codable {
    let scope: String
    let rawExpected: Int
    let rawCompleted: Int
    let eventExpected: Int
    let eventIssued: Int
    let skippedOverlap: Int
    let unexpectedFires: Int
    let pendingAtEnd: Bool
    let variants: [VariantSummary]
    let trials: [Trial]
    var valid: Bool {
        rawExpected == rawCompleted && eventExpected == eventIssued + skippedOverlap &&
        eventIssued == trials.count && unexpectedFires == 0 && !pendingAtEnd
    }
}

private func percentile(_ values: [Double], _ fraction: Double) -> Double? {
    guard !values.isEmpty else { return nil }
    let ordered = values.sorted()
    return ordered[max(0, Int(ceil(Double(ordered.count) * fraction)) - 1)]
}

// Independent per-wait-bucket shuffles balance the three methods over time and by wait length.
private struct Generator {
    var state: UInt64 = 0xb728_76da_3c10_49e5
    mutating func next(_ limit: Int) -> Int {
        state ^= state << 13
        state ^= state >> 7
        state ^= state << 17
        return Int(state % UInt64(limit))
    }
}

private func assignments(_ events: [TimerEvent]) -> [Variant] {
    var rng = Generator()
    var buckets: [Int: [Variant]] = [:]
    return events.map { event in
        let bucket = min(99, Int(event.wait * 1000))
        if buckets[bucket, default: []].isEmpty {
            var choices = Variant.allCases
            for position in stride(from: choices.count - 1, through: 1, by: -1) {
                choices.swapAt(position, rng.next(position + 1))
            }
            buckets[bucket] = choices
        }
        return buckets[bucket]!.removeLast()
    }
}

private enum ScheduleError: Error, CustomStringConvertible {
    case invalid(String)
    var description: String { if case .invalid(let reason) = self { return reason }; return "invalid schedule" }
}

private func validate(_ schedule: Schedule) throws {
    guard schedule.version == 1, schedule.duration.isFinite, schedule.duration > 0,
          schedule.duration <= 30, !schedule.events.isEmpty, schedule.events.count <= 10_000,
          schedule.rawOffsets.count <= 10_000 else { throw ScheduleError.invalid("invalid schedule size or duration") }
    let offsets = schedule.events.map(\.offset)
    guard zip(offsets, offsets.dropFirst()).allSatisfy({ $0 <= $1 }),
          zip(schedule.rawOffsets, schedule.rawOffsets.dropFirst()).allSatisfy({ $0 <= $1 }),
          offsets.allSatisfy({ $0.isFinite && $0 >= -0.1 && $0 <= schedule.duration }),
          schedule.rawOffsets.allSatisfy({ $0.isFinite && $0 >= 0 && $0 <= schedule.duration }),
          schedule.events.allSatisfy({ $0.wait.isFinite && $0.wait >= 0 && $0.wait <= 0.1 })
    else { throw ScheduleError.invalid("invalid or unordered offsets/waits") }
}

private func nanos(_ seconds: Double) -> UInt64 { UInt64((seconds * 1_000_000_000).rounded()) }
private func differenceMs(_ a: UInt64, _ b: UInt64) -> Double { (Double(a) - Double(b)) / 1_000_000 }

// All mutable state is accessed on `target`. Only finalReport crosses the queue, after semaphore wait.
private final class Experiment: @unchecked Sendable {
    private struct Pending {
        let index: Int
        let variant: Variant
        let waitMs: Double
        let issueLatenessMs: Double
        let due: UInt64
    }
    private enum Action: Sendable {
        case raw(Double)
        case timer(Int, TimerEvent, Variant)
        var offset: Double {
            switch self { case .raw(let offset): return offset; case .timer(_, let event, _): return event.offset }
        }
        var order: Int { if case .raw = self { return 0 }; return 1 }
    }
    private let target = DispatchQueue(label: "duodesk.timer-comparison.target", qos: .userInteractive)
    private let scheduler = DispatchQueue(label: "duodesk.timer-comparison.scheduler", qos: .userInteractive)
    private let completed = DispatchSemaphore(value: 0)
    private let schedule: Schedule
    private let selected: [Variant]
    private var zeroTimer: DispatchSourceTimer!
    private var strictTimer: DispatchSourceTimer!
    // Driver state is touched only on `scheduler` after setup. It represents external callback
    // arrivals, and uses one strict source to avoid asyncAfter's own timer coalescing in the driver.
    private var driver: DispatchSourceTimer!
    private var actions: [Action] = []
    private var driverIndex = 0
    private var base: UInt64 = 0
    private var end: UInt64 = 0
    private var pending: Pending?
    private var rawCompleted = 0
    private var issued = 0
    private var skipped = 0
    private var unexpected = 0
    private var trials: [Trial] = []
    private var ended = false
    private(set) var finalReport: Report?

    init(schedule: Schedule) {
        self.schedule = schedule
        self.selected = assignments(schedule.events)
    }

    func run() throws -> Report {
        zeroTimer = DispatchSource.makeTimerSource(queue: target)
        strictTimer = DispatchSource.makeTimerSource(flags: .strict, queue: target)
        zeroTimer.setEventHandler { [weak self] in self?.fired(.sourceZero) }
        strictTimer.setEventHandler { [weak self] in self?.fired(.sourceStrict) }
        zeroTimer.schedule(deadline: .distantFuture)
        strictTimer.schedule(deadline: .distantFuture)
        zeroTimer.resume()
        strictTimer.resume()

        base = DispatchTime.now().uptimeNanoseconds + nanos(0.4)
        end = base + nanos(schedule.duration + 1.0)
        actions = schedule.rawOffsets.map { Action.raw($0) }
        actions.append(contentsOf: schedule.events.enumerated().map { Action.timer($0.offset, $0.element, selected[$0.offset]) })
        actions.sort { $0.offset == $1.offset ? $0.order < $1.order : $0.offset < $1.offset }
        driver = DispatchSource.makeTimerSource(flags: .strict, queue: scheduler)
        driver.setEventHandler { [weak self] in self?.drive() }
        driver.schedule(deadline: DispatchTime(uptimeNanoseconds: planned(actions[0])), repeating: .never,
                        leeway: .nanoseconds(0))
        driver.resume()
        guard completed.wait(timeout: .now() + schedule.duration + 5.0) == .success,
              let report = finalReport else { throw ScheduleError.invalid("experiment timed out") }
        return report
    }

    private func planned(_ action: Action) -> UInt64 {
        base + nanos(action.offset + 0.1) - nanos(0.1)
    }

    private func drive() {
        let now = DispatchTime.now().uptimeNanoseconds
        while driverIndex < actions.count && planned(actions[driverIndex]) <= now {
            let action = actions[driverIndex]
            let at = planned(action)
            driverIndex += 1
            target.async { [self] in
                guard !ended else { return }
                switch action {
                case .raw:
                    // Fixed synthetic queue work, not a model of ScreenCaptureKit or GPU processing.
                    let stop = DispatchTime.now().uptimeNanoseconds + nanos(0.00003)
                    while DispatchTime.now().uptimeNanoseconds < stop { }
                    rawCompleted += 1
                case .timer(let index, let event, let variant):
                    issue(index: index, event: event, variant: variant, planned: at)
                }
            }
        }
        if driverIndex < actions.count {
            driver.schedule(deadline: DispatchTime(uptimeNanoseconds: planned(actions[driverIndex])),
                            repeating: .never, leeway: .nanoseconds(0))
        } else if now < end {
            driver.schedule(deadline: DispatchTime(uptimeNanoseconds: end), repeating: .never, leeway: .nanoseconds(0))
        } else {
            driver.cancel()
            target.async { [self] in finish() }
        }
    }

    private func issue(index: Int, event: TimerEvent, variant: Variant, planned: UInt64) {
        guard pending == nil else { skipped += 1; return }
        let now = DispatchTime.now().uptimeNanoseconds
        let due = now + nanos(event.wait)
        pending = Pending(index: index, variant: variant, waitMs: event.wait * 1000,
                          issueLatenessMs: differenceMs(now, planned), due: due)
        issued += 1
        let deadline = DispatchTime(uptimeNanoseconds: due)
        switch variant {
        case .asyncAfter:
            target.asyncAfter(deadline: deadline) { [weak self] in self?.fired(.asyncAfter) }
        case .sourceZero:
            zeroTimer.schedule(deadline: deadline, repeating: .never, leeway: .nanoseconds(0))
        case .sourceStrict:
            strictTimer.schedule(deadline: deadline, repeating: .never, leeway: .nanoseconds(0))
        }
    }

    private func fired(_ variant: Variant) {
        let now = DispatchTime.now().uptimeNanoseconds
        guard !ended, let current = pending, current.variant == variant else { unexpected += 1; return }
        pending = nil
        trials.append(Trial(index: current.index, variant: current.variant, waitMs: current.waitMs,
                            issueLatenessMs: current.issueLatenessMs, fireLatenessMs: differenceMs(now, current.due)))
    }

    private func finish() {
        guard !ended else { return }
        ended = true
        zeroTimer.cancel()
        strictTimer.cancel()
        let summaries = Variant.allCases.map { variant in
            let matching = trials.filter { $0.variant == variant }
            return VariantSummary(variant: variant, count: matching.count,
                waitMsP50: percentile(matching.map(\.waitMs), 0.5), waitMsP95: percentile(matching.map(\.waitMs), 0.95),
                issueLatenessMsP50: percentile(matching.map(\.issueLatenessMs), 0.5),
                issueLatenessMsP95: percentile(matching.map(\.issueLatenessMs), 0.95),
                fireLatenessMsP50: percentile(matching.map(\.fireLatenessMs), 0.5),
                fireLatenessMsP95: percentile(matching.map(\.fireLatenessMs), 0.95),
                fireLatenessMsP99: percentile(matching.map(\.fireLatenessMs), 0.99),
                earlyCount: matching.filter { $0.fireLatenessMs < 0 }.count)
        }
        finalReport = Report(scope: "one isolated timer run using observed offsets and synthetic queue work; no capture, pixels, encoder, network, or FPS measurement",
                             rawExpected: schedule.rawOffsets.count, rawCompleted: rawCompleted,
                             eventExpected: schedule.events.count, eventIssued: issued, skippedOverlap: skipped,
                             unexpectedFires: unexpected, pendingAtEnd: pending != nil, variants: summaries, trials: trials)
        completed.signal()
    }
}

private func selfTest() throws {
    let regular = (0..<18).map { TimerEvent(offset: 0.02 * Double($0), wait: 0.003) }
    let schedule = Schedule(version: 1, scope: "synthetic self-check", duration: 0.55,
                            rawOffsets: (0..<25).map { 0.015 * Double($0) },
                            events: regular + [TimerEvent(offset: 0.40, wait: 0.08), TimerEvent(offset: 0.41, wait: 0.005)])
    try validate(schedule)
    let report = try Experiment(schedule: schedule).run()
    guard report.valid, report.skippedOverlap == 1, report.variants.allSatisfy({ $0.count >= 5 }) else {
        throw ScheduleError.invalid("self-check failed: \(report)")
    }
    let invalid = Schedule(version: 1, scope: "invalid", duration: 1, rawOffsets: [0.5, 0.1], events: regular)
    do { try validate(invalid); throw ScheduleError.invalid("unordered offsets accepted") }
    catch ScheduleError.invalid(let reason) where reason == "invalid or unordered offsets/waits" { }
    print("TIMER COMPARISON SELF-CHECK PASS: all three methods, one overlapping timer rejected, unordered input rejected; no capture")
}

private func main() throws {
    let args = CommandLine.arguments.dropFirst()
    if Array(args) == ["--self-test"] { try selfTest(); return }
    guard args.count == 3, args[args.startIndex + 1] == "--output" else {
        throw ScheduleError.invalid("usage: timer-comparison --self-test | schedule.json --output report.json")
    }
    let input = URL(fileURLWithPath: args[args.startIndex])
    let output = URL(fileURLWithPath: args[args.startIndex + 2])
    guard !FileManager.default.fileExists(atPath: output.path) else { throw ScheduleError.invalid("output already exists") }
    let schedule = try JSONDecoder().decode(Schedule.self, from: Data(contentsOf: input))
    try validate(schedule)
    let report = try Experiment(schedule: schedule).run()
    let encoder = JSONEncoder()
    encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
    try encoder.encode(report).write(to: output, options: .withoutOverwriting)
    for variant in report.variants {
        print("\(variant.variant.rawValue): n=\(variant.count) waitP50=\(variant.waitMsP50 ?? -1)ms waitP95=\(variant.waitMsP95 ?? -1)ms issueLateP95=\(variant.issueLatenessMsP95 ?? -1)ms fireLateP50=\(variant.fireLatenessMsP50 ?? -1)ms fireLateP95=\(variant.fireLatenessMsP95 ?? -1)ms fireLateP99=\(variant.fireLatenessMsP99 ?? -1)ms early=\(variant.earlyCount)")
    }
    print("valid=\(report.valid) raw=\(report.rawCompleted)/\(report.rawExpected) issued=\(report.eventIssued)/\(report.eventExpected) skippedOverlap=\(report.skippedOverlap) unexpectedFires=\(report.unexpectedFires) pendingAtEnd=\(report.pendingAtEnd)")
    guard report.valid else { throw ScheduleError.invalid("incomplete or inconsistent experiment") }
}

do { try main() } catch { fputs("ERROR: \(error)\n", stderr); exit(1) }
