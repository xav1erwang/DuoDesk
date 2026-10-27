// Copyright 2026 DUO你电脑 contributors. SPDX-License-Identifier: Apache-2.0
// Queue-stall evidence uses the real StreamServer without starting its listener or capturing pixels.
import Foundation
import StreamProtocol

final class Releases: @unchecked Sendable {
    private let lock = NSLock()
    private var value = 0
    func note() { lock.withLock { value += 1 } }
    var count: Int { lock.withLock { value } }
}

@inline(never)
func enqueueOldBroadcast(_ server: StreamServer, releases: Releases, count: Int, bytes: Int) {
    for index in 0..<count {
        autoreleasepool {
            let memory = UnsafeMutableRawPointer.allocate(byteCount: bytes, alignment: 16)
            memory.initializeMemory(as: UInt8.self, repeating: UInt8(index % 251), count: bytes)
            let payload = Data(bytesNoCopy: memory, count: bytes, deallocator: .custom { pointer, _ in
                pointer.deallocate(); releases.note()
            })
            server.broadcast(StreamMessage(kind: .frame, timestamp: Double(index), isKeyframe: false, payload: payload))
        }
    }
}

@inline(never)
func enqueueBounded(_ server: StreamServer, releases: Releases, count: Int, bytes: Int, token: UUID) {
    for index in 0..<count {
        autoreleasepool {
            let memory = UnsafeMutableRawPointer.allocate(byteCount: bytes, alignment: 16)
            memory.initializeMemory(as: UInt8.self, repeating: UInt8(index % 251), count: bytes)
            let payload = Data(bytesNoCopy: memory, count: bytes, deallocator: .custom { pointer, _ in
                pointer.deallocate(); releases.note()
            })
            server.broadcastEncodedFrame(payload, keyframe: index == 0, parameters: nil, timestamp: Double(index), token: token)
        }
    }
}

@main
struct Check {
    static func main() throws {
        var failures = 0, checks = 0
        func check(_ name: String, _ condition: Bool) {
            checks += 1; if !condition { failures += 1 }
            print("\(condition ? "PASS" : "FAIL") \(name)")
        }
        func packet(_ value: UInt8, key: Bool, ps: Data? = nil) -> EncodedVideoMailbox.Packet {
            .init(data: Data([value]), parameters: ps, isKeyframe: key)
        }
        let first = UUID(), second = UUID()
        var mailbox = EncodedVideoMailbox()
        mailbox.reset(to: first)
        let a = mailbox.offer(packet(1, key: false), token: first)
        let b = mailbox.offer(packet(2, key: false), token: first)
        let delta = mailbox.take(token: first)
        check("a stalled queue schedules only one drain", a.schedule && !b.schedule && b.dropped)
        check("newest delta after loss is marked as dependent", delta?.data == Data([2]) && delta?.lostBefore == true)
        check("drained mailbox releases its slot", mailbox.pending == nil && !mailbox.scheduled)
        let parameters = Data([9])
        _ = mailbox.offer(packet(3, key: true, ps: parameters), token: first)
        let ignored = mailbox.offer(packet(4, key: false), token: first)
        let key = mailbox.take(token: first)
        check("pending keyframe and parameter sets survive a later delta", ignored.dropped && key?.data == Data([3]) && key?.parameters == parameters)
        check("dropped tail asks for recovery after keyframe", key?.lostAfter == true && key?.lostBefore == false)
        _ = mailbox.offer(packet(5, key: true), token: first)
        _ = mailbox.offer(packet(6, key: false), token: first)
        _ = mailbox.offer(packet(7, key: true, ps: parameters), token: first)
        let newestKey = mailbox.take(token: first)
        check("newer keyframe supersedes discarded dependency chain", newestKey?.data == Data([7]) && newestKey?.lostAfter == false && newestKey?.lostBefore == false)
        _ = mailbox.offer(packet(8, key: false), token: first)
        mailbox.reset(to: second)
        let fresh = mailbox.offer(packet(9, key: true), token: second)
        let stale = mailbox.offer(packet(10, key: false), token: first)
        check("old encoder cannot replace new stream", fresh.schedule && stale.stale && mailbox.pending?.data == Data([9]))
        check("old queued drain cannot consume new stream", mailbox.take(token: first) == nil && mailbox.take(token: second)?.data == Data([9]))
        mailbox.reset(to: nil)
        check("stopped stream rejects all old frames", mailbox.offer(packet(11, key: true), token: second).stale)

        let server = try StreamServer(advertise: false, testHooks: false)
        let gate = DispatchSemaphore(value: 0), entered = DispatchSemaphore(value: 0)
        server.queue.async { entered.signal(); gate.wait() }
        guard entered.wait(timeout: .now() + 3) == .success else { print("FAIL queue gate"); exit(1) }
        let releases = Releases(), count = 64, bytes = 128 * 1024
        enqueueOldBroadcast(server, releases: releases, count: count, bytes: bytes)
        let releasedWhileStalled = releases.count
        gate.signal()
        server.queue.sync { }
        check("generic broadcast does not retain original payload in its queued closure", releasedWhileStalled == count)

        var epoch = VideoStreamEpoch()
        server.beginVideoStream(first, reset: epoch.nextReset())
        server.queue.sync { }
        let held = DispatchSemaphore(value: 0), ready = DispatchSemaphore(value: 0)
        server.queue.async { ready.signal(); held.wait() }
        guard ready.wait(timeout: .now() + 3) == .success else { print("FAIL queue gate"); exit(1) }
        let boundedReleases = Releases()
        enqueueBounded(server, releases: boundedReleases, count: count, bytes: bytes, token: first)
        let pending = server.videoIngressLock.withLock { server.videoIngress.pending }
        let pendingScheduled = server.videoIngressLock.withLock { server.videoIngress.scheduled }
        check("64 encoded frames retain only one waiting packet", pendingScheduled && pending?.data.count == bytes + StreamMessage.headerLength)
        check("bounded path releases all original payloads during stall", boundedReleases.count == count)
        check("the first keyframe stays queued and its dropped tail is flagged", pending?.isKeyframe == true && pending?.lostAfter == true && pending?.data[StreamMessage.headerLength] == 0)
        server.beginVideoStream(second, reset: epoch.nextReset())
        server.broadcastEncodedFrame(Data([99]), keyframe: true, parameters: nil, timestamp: 99, token: second)
        server.broadcastEncodedFrame(Data([88]), keyframe: false, parameters: nil, timestamp: 100, token: first)
        let newer = server.videoIngressLock.withLock { server.videoIngress.pending }
        check("new generation retains its frame despite a late old callback", newer?.data[StreamMessage.headerLength] == 99 && newer?.lostAfter == false)
        held.signal()
        server.queue.sync { }
        check("old drain and reset cannot consume the new generation", server.videoToken == second && server.videoIngressLock.withLock { server.videoIngress.pending == nil })
        print("\(checks) checks; \(failures) failures; listenerNotStarted=true; no screen capture")
        if failures > 0 { exit(1) }
    }
}
