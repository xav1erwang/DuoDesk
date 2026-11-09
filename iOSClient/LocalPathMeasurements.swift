// Copyright 2026 DUO你电脑 contributors. SPDX-License-Identifier: Apache-2.0
import Foundation

/// Main-queue scheduler and process-local cache. A tap reorders pending work and keeps the
/// active ticket intact. Only refresh, process exit and age discard successful observations.
final class LocalPathMeasurements<Value> {
    struct Ticket: Equatable {
        let macID: String
        fileprivate let generation: UInt64
        fileprivate let id = UUID()
    }
    private struct Entry { let value: Value; let completedAt: TimeInterval }
    static var lifetime: TimeInterval { 5 * 60 * 60 }
    private var generation: UInt64 = 0
    private var entries: [String: Entry] = [:]
    private var retryAfter: [String: TimeInterval] = [:]
    private(set) var pending: [String] = []
    private(set) var active: Ticket?

    func value(for macID: String, now: TimeInterval) -> Value? {
        guard let entry = entries[macID] else { return nil }
        guard now >= entry.completedAt, now - entry.completedAt < Self.lifetime else {
            entries[macID] = nil; return nil
        }
        return entry.value
    }

    func enqueue(_ macID: String, now: TimeInterval, prioritize: Bool = false) {
        guard value(for: macID, now: now) == nil, active?.macID != macID,
              now >= (retryAfter[macID] ?? 0) else { return }
        if let index = pending.firstIndex(of: macID) {
            if prioritize { pending.remove(at: index); pending.insert(macID, at: 0) }
        } else if prioritize { pending.insert(macID, at: 0) }
        else { pending.append(macID) }
    }

    func beginNext() -> Ticket? {
        guard active == nil, !pending.isEmpty else { return nil }
        let ticket = Ticket(macID: pending.removeFirst(), generation: generation)
        active = ticket
        return ticket
    }

    @discardableResult
    func finish(_ ticket: Ticket, value: Value?, now: TimeInterval) -> Bool {
        guard active == ticket, ticket.generation == generation else { return false }
        active = nil
        if let value { entries[ticket.macID] = Entry(value: value, completedAt: now) }
        else { retryAfter[ticket.macID] = now + 30 }
        return true
    }

    func contains(_ macID: String) -> Bool { active?.macID == macID || pending.contains(macID) }

    func remove(_ macID: String) {
        entries[macID] = nil; retryAfter[macID] = nil
        pending.removeAll { $0 == macID }
        if active?.macID == macID { active = nil }
    }

    func suspend() {
        if let active { pending.insert(active.macID, at: 0) }
        active = nil
    }

    func refresh() {
        generation &+= 1
        active = nil; pending.removeAll(); entries.removeAll(); retryAfter.removeAll()
    }

    func nextExpiry(after now: TimeInterval) -> TimeInterval? {
        (entries.values.map { $0.completedAt + Self.lifetime } + Array(retryAfter.values)).filter { $0 > now }.min()
    }
}
