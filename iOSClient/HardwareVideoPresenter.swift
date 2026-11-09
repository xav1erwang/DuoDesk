// Copyright 2026 DUO你电脑 contributors. SPDX-License-Identifier: Apache-2.0
import AVFoundation
import CoreMedia
import StreamProtocol

/// The receiver belongs to one actor. Enqueue waits for its internal capacity; the small stream
/// keeps only recent images while it waits. Reset can reenter that actor to flush a suspended
/// enqueue, so a hidden/slow display cannot hold a generation change or grow an unbounded queue.
final class HardwareVideoPresenter: @unchecked Sendable {
    private final class Fence: @unchecked Sendable {
        let lock = NSLock()
        var minimum: UInt64 = 0
        var revision: UInt64 = 0
        var ready: (generation: UInt64, revision: UInt64)?
        var lastDropLog = -Double.infinity
        func accepts(_ token: UInt64) -> Bool {
            lock.lock(); defer { lock.unlock() }; return token >= minimum
        }
        func accepts(_ token: UInt64, revision: UInt64) -> Bool {
            lock.lock(); defer { lock.unlock() }; return token >= minimum && self.revision == revision
        }
        func markReady(_ token: UInt64, revision: UInt64) -> Bool {
            lock.lock(); defer { lock.unlock() }
            guard token >= minimum, self.revision == revision else { return false }
            ready = (token, revision); return true
        }
        func isReady(_ token: UInt64, revision: UInt64? = nil) -> Bool {
            lock.lock(); defer { lock.unlock() }
            return token >= minimum && ready?.generation == token && ready?.revision == self.revision
                && (revision == nil || revision == self.revision)
        }
    }
    private struct Event: @unchecked Sendable {
        let image: CMSampleBuffer
        let generation: UInt64
        let revision: UInt64
        let permit: VideoOutputPermit?
    }
    private let events: AsyncStream<Event>.Continuation
    private let worker: Task<Void, Never>
    private let fence: Fence
    private let pump: Pump

    private actor Pump {
        let receiver: AVSampleBufferVideoRenderer.Receiver
        let synchronizer: AVSampleBufferRenderSynchronizer
        let fence: Fence
        let onFirstImage: @Sendable (CGSize, UInt64) -> Void
        let onFailure: @Sendable (String, UInt64, UInt64) -> Void
        var generation: UInt64 = 0
        var revision: UInt64 = 0
        var lastSequence: Int64 = -1
        var hasImage = false
        var enqueuing = false
        var flushing = false
        var pendingImageRemoval = false
        var flushWaiters: [CheckedContinuation<Void, Never>] = []
        var lastSubmittedPermit: VideoOutputPermit?
        var stopped = false
        var received = 0

        init(receiver: sending AVSampleBufferVideoRenderer.Receiver,
             synchronizer: sending AVSampleBufferRenderSynchronizer, fence: Fence,
             onFirstImage: @escaping @Sendable (CGSize, UInt64) -> Void,
             onFailure: @escaping @Sendable (String, UInt64, UInt64) -> Void) {
            self.receiver = receiver
            self.synchronizer = synchronizer
            self.fence = fence; self.onFirstImage = onFirstImage; self.onFailure = onFailure
        }

        func reset(_ token: UInt64, revision: UInt64) async {
            guard !stopped, token >= generation, revision > self.revision, fence.accepts(token, revision: revision) else { return }
            self.revision = revision
            generation = token; lastSequence = -1
            hasImage = false; lastSubmittedPermit = nil
            // enqueue and flush inherit this actor's isolation in SDK 27. Flush deliberately
            // cancels a suspended enqueue and clears a renderer invalidated before its first
            // image (for example while the display picker or another app was in front).
            await flushReceiver(removingDisplayedImage: true)
        }

        /// A revoked backlog epoch can leave an old enqueue suspended even though the generation
        /// remains current. Flush that receiver operation without removing the displayed image.
        /// A delayed notification must not flush a later epoch that has already been submitted.
        func invalidateOutput(_ permit: VideoOutputPermit, generation token: UInt64) async {
            guard !stopped, generation == token, lastSubmittedPermit === permit, !permit.isValid else { return }
            lastSubmittedPermit = nil
            await flushReceiver(removingDisplayedImage: false)
        }

        /// A reset arriving during a keep-image flush must still clear the displayed image. Keep
        /// new samples waiting until that stronger request has also completed.
        private func flushReceiver(removingDisplayedImage: Bool) async {
            if flushing {
                if removingDisplayedImage { pendingImageRemoval = true }
                return
            }
            flushing = true
            var remove = removingDisplayedImage
            repeat {
                pendingImageRemoval = false
                await receiver.flush(removingDisplayedImage: remove)
                remove = pendingImageRemoval
            } while remove
            finishFlush()
        }

        private func waitForFlush() async {
            guard flushing, !stopped else { return }
            await withCheckedContinuation { flushWaiters.append($0) }
        }

        private func releaseFlushWaiters() {
            let waiting = flushWaiters; flushWaiters.removeAll(keepingCapacity: true)
            waiting.forEach { $0.resume() }
        }

        private func finishFlush() {
            flushing = false
            releaseFlushWaiters()
        }

        func present(_ event: Event) async {
            let token = event.generation, image = event.image
            let eventRevision = event.revision
            guard !stopped, event.permit?.isValid != false,
                  token >= generation, fence.accepts(token, revision: eventRevision) else { return }
            if eventRevision > revision { await reset(token, revision: eventRevision) }
            if flushing { await waitForFlush() }
            guard !stopped, !flushing, !enqueuing, token == generation, eventRevision == revision,
                  event.permit?.isValid != false, fence.accepts(token, revision: eventRevision) else { return }
            let sequence = CMSampleBufferGetPresentationTimeStamp(image).value
            guard sequence > lastSequence else { return }
            received += 1
            if received % 120 == 0 {
                print("Video presenter: received=\(received), sequence=\(sequence), previous=\(lastSequence), clock=\(synchronizer.currentTime().seconds), rate=\(synchronizer.rate)")
            }
            var timing = CMSampleTimingInfo(duration: CMTime(value: 1, timescale: 120),
                                           presentationTimeStamp: synchronizer.currentTime(), decodeTimeStamp: .invalid)
            var copy: CMSampleBuffer?
            guard CMSampleBufferCreateCopyWithNewTiming(allocator: nil, sampleBuffer: image,
                sampleTimingEntryCount: 1, sampleTimingArray: &timing, sampleBufferOut: &copy) == noErr,
                let copy else { onFailure("无法准备视频画面，请重新连接。", token, eventRevision); return }
            guard let attachments = CMSampleBufferGetSampleAttachmentsArray(copy, createIfNecessary: true),
                  CFArrayGetCount(attachments) > 0 else {
                onFailure("无法准备视频画面，请重新连接。", token, eventRevision); return
            }
            let attributes = unsafeBitCast(CFArrayGetValueAtIndex(attachments, 0), to: CFMutableDictionary.self)
            CFDictionarySetValue(attributes, Unmanaged.passUnretained(kCMSampleAttachmentKey_DisplayImmediately).toOpaque(),
                                 Unmanaged.passUnretained(kCFBooleanTrue).toOpaque())
            let imageSize = CMSampleBufferGetImageBuffer(image).map {
                CGSize(width: CVPixelBufferGetWidth($0), height: CVPixelBufferGetHeight($0))
            }
            let ready = CMReadySampleBuffer<CMSampleBuffer.DynamicContent>(unsafeBuffer: copy)
            guard event.permit?.isValid != false else { return }
            lastSubmittedPermit = event.permit
            enqueuing = true
            defer { enqueuing = false }
            for attempt in 0...1 {
                guard !stopped, token == generation, eventRevision == revision,
                      event.permit?.isValid != false, fence.accepts(token, revision: eventRevision) else { return }
                do {
                    let result = try await receiver.enqueue(ready)
                    guard !stopped, token == generation, eventRevision == revision,
                          event.permit?.isValid != false, fence.accepts(token, revision: eventRevision) else { return }
                    switch result {
                    case .enqueued:
                        let first = !hasImage
                        lastSequence = sequence; hasImage = true
                        if fence.markReady(token, revision: eventRevision), first, let imageSize {
                            onFirstImage(imageSize, token)
                            print("Video presenter: first decoded image queued for generation \(token)")
                        }
                    case .cancelledDueToFlushRequiredToResume(let error):
                        print("Video presenter: flush required, generation \(token), revision \(eventRevision), attempt \(attempt): \(error as NSError)")
                        guard attempt == 0 else {
                            onFailure("视频呈现失败，请重新连接。", token, eventRevision)
                            return
                        }
                        // The renderer explicitly requests a reset, rather than a new network
                        // connection. Our samples are already decoded, so this same current image
                        // can be submitted again after the flush without waiting for a keyframe.
                        await flushReceiver(removingDisplayedImage: false)
                        if flushing { await waitForFlush() }
                        continue
                    case .enqueuedWithDecodeFailures(let errors):
                        print("Video presenter: decode failures, generation \(token): \(errors.map { String(describing: $0 as NSError) })")
                        onFailure("视频呈现失败，请重新连接。", token, eventRevision)
                    case .cancelledDueToError(let error):
                        print("Video presenter: enqueue error, generation \(token), revision \(eventRevision): \(error as NSError)")
                        onFailure("视频呈现失败，请重新连接。", token, eventRevision)
                    case .cancelledDueToFlush: break
                    @unknown default:
                        print("Video presenter: unrecognized enqueue result, generation \(token): \(result)")
                        onFailure("视频呈现失败，请重新连接。", token, eventRevision)
                    }
                } catch is CancellationError {
                    // The owning worker was stopped. No image or failure escapes a cancelled task.
                } catch {
                    if !stopped, token == generation, eventRevision == revision, event.permit?.isValid != false,
                       fence.accepts(token, revision: eventRevision) {
                        print("Video presenter: enqueue threw, generation \(token), revision \(eventRevision): \(error as NSError)")
                        onFailure("视频呈现失败，请重新连接。", token, eventRevision)
                    }
                }
                return
            }
        }

        func run(_ stream: AsyncStream<Event>) async {
            for await event in stream {
                if Task.isCancelled { break }
                await present(event)
            }
            await stop()
        }

        func stop() async {
            stopped = true
            releaseFlushWaiters()
            await flushReceiver(removingDisplayedImage: true)
            hasImage = false
        }
    }

    init(renderer: AVSampleBufferVideoRenderer, onFirstImage: @escaping @Sendable (CGSize, UInt64) -> Void,
         onFailure: @escaping @Sendable (String, UInt64, UInt64) -> Void) {
        let (stream, continuation) = AsyncStream<Event>.makeStream(bufferingPolicy: .bufferingNewest(2))
        events = continuation
        let fence = Fence()
        self.fence = fence
        let synchronizer = AVSampleBufferRenderSynchronizer()
        synchronizer.delaysRateChangeUntilHasSufficientMediaData = false
        let receiver = synchronizer.sampleBufferReceiver(adding: renderer)
        synchronizer.setRate(1, time: .zero)
        let pump = Pump(receiver: receiver, synchronizer: synchronizer, fence: fence,
                        onFirstImage: onFirstImage, onFailure: onFailure)
        self.pump = pump
        worker = Task.detached(priority: .userInitiated) {
            await pump.run(stream)
        }
    }

    deinit {
        fence.lock.lock(); fence.revision &+= 1; fence.ready = nil; fence.lock.unlock()
        events.finish(); worker.cancel()
    }
    func reset(_ generation: UInt64) {
        fence.lock.lock()
        if generation > fence.minimum {
            fence.minimum = generation; fence.revision &+= 1; fence.ready = nil
        }
        let revision = fence.revision
        fence.lock.unlock()
        Task { [pump] in await pump.reset(generation, revision: revision) }
    }
    /// UIKit may rehost the same video view without changing the codec generation. Flush the
    /// previous surface's suspended enqueue and fence its images and queued input immediately.
    func refreshSurface(_ generation: UInt64) {
        fence.lock.lock()
        guard generation >= fence.minimum else { fence.lock.unlock(); return }
        fence.revision &+= 1; fence.ready = nil
        let revision = fence.revision
        fence.lock.unlock()
        Task { [pump] in await pump.reset(generation, revision: revision) }
    }
    func isReady(_ generation: UInt64) -> Bool { fence.isReady(generation) }
    /// Recheck a queued failure on the UI executor: a rehost can supersede it without changing
    /// the decoder generation, even before the replacement surface has its first image.
    func isCurrentSurface(_ generation: UInt64, revision: UInt64) -> Bool {
        fence.accepts(generation, revision: revision)
    }
    func makeInputFence(_ generation: UInt64) -> @Sendable () -> Bool {
        fence.lock.lock(); let revision = fence.revision; fence.lock.unlock()
        return { [fence] in fence.isReady(generation, revision: revision) }
    }
    func invalidateOutput(_ permit: VideoOutputPermit, generation: UInt64) {
        Task { [pump] in await pump.invalidateOutput(permit, generation: generation) }
    }
    func enqueue(_ image: CMSampleBuffer, generation: UInt64, permit: VideoOutputPermit? = nil) {
        var reportDrop = false
        let admit = { [self] in
            fence.lock.lock()
            guard generation >= fence.minimum else { fence.lock.unlock(); return }
            let result = events.yield(Event(image: image, generation: generation, revision: fence.revision, permit: permit))
            let now = ProcessInfo.processInfo.systemUptime
            if case .dropped = result, now - fence.lastDropLog >= 1 {
                fence.lastDropLog = now; reportDrop = true
            }
            fence.lock.unlock()
        }
        if let permit { permit.admit(admit) } else { admit() }
        if reportDrop {
            print("Video presentation queue full: discarded an obsolete decoded image")
        }
    }
}
