import Foundation
import QuartzCore
import VideoToolbox
import CoreMedia
import StreamProtocol

/// HEVC encoder tuned for low latency: real time, no B-frames, keyframes on demand.
///
/// Threading, by hand and deliberately:
/// - `encode()` is called on the capture queue (and `requestKeyframe()` on the network queue or the
///   main actor). It never touches VideoToolbox itself and never waits: the frame is let in, or
///   waits in a one-slot mailbox, and it returns, so ScreenCaptureKit is never blocked by the
///   encoder. A newer frame replaces an older waiting one.
/// - `encodeQueue` (serial) hands frames to VideoToolbox one after another, in the order they were
///   let in (each is queued on it under the lock that let it in), so timestamps only go forward and
///   a requested keyframe goes with the next frame in.
///   One frame is inside VT at a time: the next goes in when the last came back, and a frame that
///   finds the place taken waits in the mailbox, where a newer one replaces it (`EncoderMailbox`,
///   which keeps this bookkeeping and is checked on its own). Latency beats quality: a frame the
///   encoder has no room for waits in the mailbox, never inside VT behind another. Two inside at
///   once was measured against the hardware's slow state and dropped (CLAUDE.md, "The 33 fps
///   plateau").
/// - A watchdog on its own queue declares the session dead when a frame has been inside VT
///   `hangAfter` seconds without an output. The owner is told (`onHung`); DuoDesk ends that
///   production session instead of falling back to software. Upstream observed two causes:
///   - Stuck. 2026-09-22 the Mac's hardware encoder wedged system-wide for about three hours: a
///     fresh session in a fresh process never returned a single frame. With the old direct call
///     that froze the capture queue, then `stopCapture`, then every later source switch.
///   - Busy. 2026-09-24, twice: the iOS Simulator's screen recorder runs its hardware session at
///     the encoder firmware's priority 80, a real-time session like this one at 0, and the one
///     encoder engine served the recorder while this session's frame waited 1.8 s and 8.6 s. Both
///     frames came back, and fresh sessions answered at once. The kernel's AppleAVE2 log showed it
///     (CLAUDE.md, "Frozen stream").
///   A session given up on reports on its way out whether its stalled frame ever came back
///   (`deinit`): a busy encoder hands it back, a stuck one never does.
/// - The hardware's slow state (CLAUDE.md, "The 33 fps plateau"): a session fed sparse frames for
///   about a second can settle at ~29 ms a frame instead of 9–16 and stay there through any motion
///   that follows (34 fps out of 57 captured at 3024×1964). When a stream's session does
///   (`EncoderSlowState`), the stream gets a new one in place (`replacesSlowSessions`): made on a
///   queue of its own while the old one goes on, taken at the next hand-over with a forced keyframe
///   (whose parameter sets go out with it), and the old one, holding no frame by then, completed
///   first (so its last output reaches `onEncoded` before the new session's keyframe) and
///   invalidated.
///   The mailbox, its frame ids, the watchdog and the capture carry on: a new session never counts
///   against a frame's clock, and one that hangs is a hang like any other.
final class HEVCEncoder {
    let width: Int
    let height: Int
    let software: Bool
    /// A probe's session: no counters and no lines, so a re-check while streaming leaves the
    /// stats line (whose `enc.out` is the menu's encoded fps) and the log as they were.
    let quiet: Bool
    /// Increases with every encoder this process creates, so the owner can tell an encoder made
    /// before some moment from one made after it (`latestSerial` then).
    let serial: Int
    private let fps: Int
    private let bitrate: Int
    private let prioritizeSpeed: Bool
    /// The session frames go into. It changes only in `submit`, on `encodeQueue`, when a new one
    /// replaces it; read there and in `deinit`.
    private var session: VTCompressionSession?

    /// Called on VideoToolbox's callback thread with one access unit (length-prefixed NALs).
    var onEncoded: ((_ data: Data, _ isKeyframe: Bool, _ parameterSets: ParameterSets?) -> Void)?
    /// VideoToolbox hand-over to callback arrival, in milliseconds; no cross-host clock comparison.
    var onEncodeLatency: ((Double) -> Void)?
    /// The session stopped returning frames. Called once, on the watchdog's queue. The encoder is
    /// dead afterwards: it drops every further frame.
    var onHung: (() -> Void)?
    /// For a session given up on (the watchdog, or `abandon`) with a frame still inside: called on a
    /// utility queue once VideoToolbox has let go of that frame, with the seconds since it went in.
    /// Never called while the frame stays inside, which is what a stuck encoder does. Set it before
    /// the encoder is released.
    var onStalledFrameBack: ((TimeInterval) -> Void)?
    /// TEST ONLY (EncoderProbe's SILL_TEST_PROBE_HOLD): every frame waits this long on
    /// `encodeQueue` before it goes in, as in a starved encoder (tens of ms), a busy one (seconds)
    /// or a stuck one (for good).
    var testHoldEachFrame: TimeInterval = 0

    private static let serialLock = NSLock()
    private static var lastSerial = 0
    /// The serial of the newest encoder created so far.
    static var latestSerial: Int { serialLock.lock(); defer { serialLock.unlock() }; return lastSerial }

    // Guarded by `lock`.
    private let lock = NSLock()
    /// The frame inside VideoToolbox, the one waiting behind it, whether the session is dead, and
    /// what the next frame to go in carries (its timestamp, a requested keyframe).
    private var mailbox = EncoderMailbox<(CVPixelBuffer, CMTime)>()
    /// Consecutive recovery keyframes requested after a dropped frame (bounded, see `submit`).
    private var forcedRetries = 0
    /// Most recent captured frame. ScreenCaptureKit only delivers frames when the window repaints,
    /// so a client that connects while the window is static would otherwise never get a keyframe.
    private var lastFrame: CVPixelBuffer?
    private var lastFrameAt: CFTimeInterval = 0
    /// The watchdog gave up on this session (not `abandon`): its deinit says whether the frame came back.
    private var hungReported = false
    /// Watches the stream's session for the slow state; nil when it is never replaced (a quiet probe,
    /// the software encoder, or `replacesSlowSessions` off). The launch probe has one, and its one
    /// frame never meets the rule.
    private var slowState: EncoderSlowState?
    /// A new session, made and prepared, that the next frame handed over goes into.
    private var replacement: VTCompressionSession?

    private let encodeQueue = DispatchQueue(label: "sill.encode", qos: .userInteractive)
    /// The watchdog must not share `encodeQueue`: when VideoToolbox hangs, it hangs *inside*
    /// `submit` on that queue, and a timer queued behind it would never fire (seen in the self-test).
    /// A keyframe request's second look (`keyframeCheck`) runs here for the same reason.
    private let watchdogQueue = DispatchQueue(label: "sill.encode.watchdog", qos: .utility)
    private var watchdog: DispatchSourceTimer?
    static let hangAfter: CFTimeInterval = 1.5
    /// A hardware stream session that settles in the slow state is replaced (`EncoderSlowState`).
    /// Measured alone on the engine (CLAUDE.md, "The 33 fps plateau"): the resumed motion ran at
    /// 57 fps against 34 without it. False keeps each session for the stream's life.
    static let replacesSlowSessions = true
    /// `replacesSlowSessions`, unless TEST ONLY `SILL_TEST_ENCODER_RECYCLE=1` or `0` says otherwise for
    /// this process (an A/B from one binary), which it says once, when the first hardware session
    /// that is not a quiet probe's is made (in a host, the launch probe's).
    static let replacingSlowSessions: Bool = {
        guard let value = ProcessInfo.processInfo.environment["SILL_TEST_ENCODER_RECYCLE"], let n = Int(value) else {
            return replacesSlowSessions
        }
        print("TEST: a hardware stream session settled in the slow state is \(n != 0 ? "replaced" : "kept") (SILL_TEST_ENCODER_RECYCLE=\(value))")
        return n != 0
    }()

    init(width: Int, height: Int, fps: Int, bitrate: Int, prioritizeSpeed: Bool, software: Bool = false,
         quiet: Bool = false) throws {
        self.width = width
        self.height = height
        self.software = software
        self.quiet = quiet
        self.fps = fps
        self.bitrate = bitrate
        self.prioritizeSpeed = prioritizeSpeed
        Self.serialLock.lock(); Self.lastSerial += 1; serial = Self.lastSerial; Self.serialLock.unlock()
        session = try Self.makeSession(width: width, height: height, fps: fps, bitrate: bitrate, prioritizeSpeed: prioritizeSpeed,
                                       software: software)
        if !software, !quiet, Self.replacingSlowSessions { slowState = EncoderSlowState(now: CACurrentMediaTime()) }

        let t = DispatchSource.makeTimerSource(queue: watchdogQueue)
        t.schedule(deadline: .now() + 0.5, repeating: 0.5, leeway: .milliseconds(100))
        t.setEventHandler { [weak self] in self?.checkWatchdog() }
        t.resume()
        watchdog = t
    }

    /// A session with this encoder's settings, ready for its first frame: the stream's first, and
    /// each one that replaces a session settled in the slow state.
    private static func makeSession(width: Int, height: Int, fps: Int, bitrate: Int, prioritizeSpeed: Bool,
                                    software: Bool) throws -> VTCompressionSession {
        var s: VTCompressionSession?
        var spec: [CFString: Any] = [:]
        if software { spec[kVTVideoEncoderSpecification_EnableHardwareAcceleratedVideoEncoder] = false }
        else { spec[kVTVideoEncoderSpecification_RequireHardwareAcceleratedVideoEncoder] = true }
        let status = VTCompressionSessionCreate(
            allocator: nil, width: Int32(width), height: Int32(height),
            codecType: kCMVideoCodecType_HEVC, encoderSpecification: spec.isEmpty ? nil : spec as CFDictionary,
            imageBufferAttributes: nil, compressedDataAllocator: nil,
            outputCallback: nil, refcon: nil, compressionSessionOut: &s)
        guard status == noErr, let session = s else { throw EncoderError.create(status) }

        func set(_ key: CFString, _ value: CFTypeRef) { VTSessionSetProperty(session, key: key, value: value) }
        func require(_ key: CFString, _ value: CFTypeRef) throws {
            let status = VTSessionSetProperty(session, key: key, value: value)
            guard status == noErr else {
                VTCompressionSessionInvalidate(session)
                throw EncoderError.property(key as String, status)
            }
        }
        try require(kVTCompressionPropertyKey_RealTime, kCFBooleanTrue)
        set(kVTCompressionPropertyKey_ProfileLevel, kVTProfileLevel_HEVC_Main_AutoLevel)
        try require(kVTCompressionPropertyKey_AllowFrameReordering, kCFBooleanFalse) // no B-frames
        // Keyframes are requested on demand (new client, dropped delta, source switch); this is
        // only a safety interval. Longer intervals cut the periodic IDR hitch; 4 s is the value
        // every working stream so far has used.
        set(kVTCompressionPropertyKey_MaxKeyFrameInterval, (fps * 4) as CFNumber)
        try require(kVTCompressionPropertyKey_ExpectedFrameRate, fps as CFNumber)
        set(kVTCompressionPropertyKey_AverageBitRate, bitrate as CFNumber)
        set(kVTCompressionPropertyKey_DataRateLimits, [bitrate / 8, 1] as CFArray)
        if prioritizeSpeed || software, #available(macOS 14.0, *) {
            set(kVTCompressionPropertyKey_PrioritizeEncodingSpeedOverQuality, kCFBooleanTrue)
        }
        let prepared = VTCompressionSessionPrepareToEncodeFrames(session)
        guard prepared == noErr else { VTCompressionSessionInvalidate(session); throw EncoderError.create(prepared) }
        if !software {
            var actual: Unmanaged<CFTypeRef>?
            let queried = VTSessionCopyProperty(session, key: kVTCompressionPropertyKey_UsingHardwareAcceleratedVideoEncoder,
                                                allocator: nil, valueOut: &actual)
            let hardware = (actual?.takeRetainedValue() as? NSNumber)?.boolValue == true
            guard queried == noErr, hardware else {
                VTCompressionSessionInvalidate(session)
                throw EncoderError.create(queried == noErr ? kVTVideoEncoderNotAvailableNowErr : queried)
            }
        }
        return session
    }

    /// The watchdog gave up on this session. The owner checks this after installing an encoder,
    /// because a hang report that arrived mid-switch was ignored (see StreamCoordinator).
    var isDead: Bool { lock.lock(); defer { lock.unlock() }; return mailbox.dead }

    /// Give up on this session quietly: no watchdog report, no `enc.hung`. A probe calls this when
    /// its frame has not come back in time, since the owner already knows. True when that frame
    /// is still inside VideoToolbox (then `onStalledFrameBack` tells when it comes out); false
    /// when it came back just now.
    @discardableResult
    func abandon() -> Bool {
        lock.lock(); let inside = mailbox.giveUp(); lastFrame = nil; let spare = replacement; replacement = nil; lock.unlock()
        watchdog?.cancel()
        if let spare { Self.retire(spare) }
        return inside
    }

    deinit {
        watchdog?.cancel()
        if let spare = replacement { Self.retire(spare) }   // made for the slow state, never used
        guard let session else { return }
        lock.lock()
        // Drain a live session with a frame let in. One given up on with a frame inside VideoToolbox
        // (the watchdog, or a probe's `abandon`) is stalled: a dead session never clears it, and
        // `since` is when that frame went in.
        let teardown = mailbox.teardown
        let report = hungReported && !quiet
        lock.unlock()
        let described = "\(software ? "software" : "hardware") HEVC \(width)×\(height)"
        let back = onStalledFrameBack
        // Never tear a live session down with a frame still inside the hardware encoder. The system
        // log for 2026-09-22 shows every wedge began with a session whose first frame never came
        // back after the session was invalidated under it (the encoder service then logs "Frame
        // POC 0 timed out" every 4 s for good, and two such orphans stalled the hardware for every
        // later session until a reboot). Draining first costs up to a frame's time on a healthy
        // session (a few ms; about 29 ms in the hardware's slow state). A dead session is not
        // drained: that call would never return if the encoder is stuck. Invalidating it can itself
        // block, so none of this runs on the caller's thread.
        //
        // The invalidate waits for a frame still inside (measured 2026-09-25: 17 ms for a 3024×1898
        // frame in flight, whose output handler ran just before it returned; 2026-09-24 the encoder
        // service's own invalidate waited 0.17 s and 7.06 s for the stalled frames, which then
        // completed). So its return is when a stalled frame came back: a busy encoder, not a stuck
        // one, which never lets go and leaves this thread blocked for good.
        DispatchQueue.global(qos: .utility).async {
            if teardown == .drain { VTCompressionSessionCompleteFrames(session, untilPresentationTimeStamp: .invalid) }
            VTCompressionSessionInvalidate(session)
            guard case .stalled(let since) = teardown else { return }
            let seconds = CACurrentMediaTime() - since
            if report {
                print("Encoder (\(described)): the stalled frame came back after \(String(format: "%.1f", seconds)) s; the encoder was busy, not stuck.")
            }
            back?(seconds)
        }
    }

    /// A window with no repaint for this long is still: a keyframe asked for then re-encodes the
    /// last frame, since no captured frame is coming to carry it.
    static let stillAfter: CFTimeInterval = 0.05

    /// Next frame becomes a keyframe (client connected, a delta was dropped, source switched).
    /// While frames are flowing the next captured frame simply carries the flag. When the window is
    /// still (no repaint in the last `stillAfter`) the last frame is re-encoded at once. A request
    /// that comes within `stillAfter` of a repaint is looked at again just after that much time has
    /// passed since the repaint (`keyframeCheck`): the window may have stopped then, and nothing
    /// would carry the flag until it repaints (a device joining, or one whose delta was dropped,
    /// waited with a black or stale picture). The flag, the decision and the re-encode's admission
    /// are one hold of the lock: a repaint that lands meanwhile goes in after the re-encode, never
    /// before it (the older picture would then go into VideoToolbox last and stay on the device
    /// until the next repaint, and `lastFrame` fall back to it).
    func requestKeyframe() {
        lock.lock()
        let request = prepareKeyframeRequestLocked(now: CACurrentMediaTime())
        lock.unlock()
        finishKeyframeRequest(request)
    }

    /// Under `lock`: mark the request before a waiting frame can be handed to VideoToolbox.
    private func prepareKeyframeRequestLocked(now: CFTimeInterval) -> (Admission?, CFTimeInterval?) {
        mailbox.keyframeRequested = true
        var admission: Admission?
        var lookAgainIn: CFTimeInterval?
        if now - lastFrameAt >= Self.stillAfter {
            if let last = lastFrame { admission = admitLocked(last, pts: reencodePTS(), fromCapture: false, now: now) }
        } else {
            lookAgainIn = lastFrameAt + Self.stillAfter + 0.01 - now
        }
        return (admission, lookAgainIn)
    }

    private func finishKeyframeRequest(_ request: (Admission?, CFTimeInterval?)) {
        let (admission, lookAgainIn) = request
        if let admission { count(admission) }
        // The watchdog's queue: never blocked by VideoToolbox, and this takes the lock only briefly.
        if let lookAgainIn { watchdogQueue.asyncAfter(deadline: .now() + lookAgainIn) { [weak self] in self?.keyframeCheck() } }
    }

    /// watchdogQueue, a little over `stillAfter` after the repaint a keyframe request came right
    /// after: the last frame is re-encoded if the flag is still set, no frame is on its way to
    /// VideoToolbox to carry it (on `encodeQueue`, or waiting in the mailbox), and the window has
    /// not repainted since. A repaint since either carried the flag or came before a later request,
    /// which then looks again itself.
    private func keyframeCheck() {
        lock.lock()
        let now = CACurrentMediaTime()
        var admission: Admission?
        if mailbox.keyframeRequested, !mailbox.dead, !mailbox.frameOnItsWay, now - lastFrameAt >= Self.stillAfter,
           let last = lastFrame {
            admission = admitLocked(last, pts: reencodePTS(), fromCapture: false, now: now)
        }
        lock.unlock()
        if let admission { count(admission) }
    }

    /// Capture queue. Returns at once.
    func encode(_ pixelBuffer: CVPixelBuffer, pts: CMTime) {
        lock.lock()
        let now = CACurrentMediaTime()
        if !mailbox.dead { slowState?.captured(at: now) }
        let admission = admitLocked(pixelBuffer, pts: pts, fromCapture: true, now: now)
        lock.unlock()
        count(admission)
    }

    private typealias Admission = EncoderMailbox<(CVPixelBuffer, CMTime)>.Admission

    /// Under `lock`: a new frame goes in, waits in the mailbox, or is dropped. A frame let in is
    /// queued on `encodeQueue` before the lock is released, so the queue's order is the order the
    /// frames were let in, whichever thread let each in (the capture queue, the network queue, the
    /// main actor, VideoToolbox's callback thread): `async` never waits, and the capture queue
    /// still never waits on VideoToolbox.
    private func admitLocked(_ pixelBuffer: CVPixelBuffer, pts: CMTime, fromCapture: Bool, now: CFTimeInterval) -> Admission {
        let admission = mailbox.admit((pixelBuffer, pts), now: now)
        if admission != .dropped {
            lastFrame = pixelBuffer
            // A re-encode of the last frame is not a repaint: it must not make the window look live
            // to the next requestKeyframe, or a retry after a dropped keyframe would do nothing.
            if fromCapture { lastFrameAt = now }
        }
        if case .goesIn(let id) = admission { encodeQueue.async { [weak self] in self?.submit(pixelBuffer, pts: pts, id: id) } }
        return admission
    }

    /// Under `lock`: a re-encode of the last frame is stamped just after the last timestamp handed
    /// to VideoToolbox (`EncoderMailbox.handOver` still moves it past any frame let in before it).
    private func reencodePTS() -> CMTime {
        let lastPTS = mailbox.lastPTS
        return lastPTS.isValid ? CMTimeAdd(lastPTS, CMTime(value: 1, timescale: 1000)) : CMClockGetTime(CMClockGetHostTimeClock())
    }

    /// The counters for an admission, once the lock is released.
    private func count(_ admission: Admission) {
        switch admission {
        case .goesIn: break
        case .waits(let replaced): if replaced { bump("enc.mailboxDrop") }   // newer frame wins
        case .dropped: bump("enc.deadDrop")
        }
    }

    /// encodeQueue: frames go into VideoToolbox one after another, in the order they were let in,
    /// one inside at a time (`EncoderMailbox`).
    private func submit(_ pixelBuffer: CVPixelBuffer, pts requested: CMTime, id: Int) {
        guard var session else { return }
        lock.lock()
        let now = CACurrentMediaTime()
        let handOver = mailbox.handOver(id, pts: requested, now: now)
        // A new session is waiting (the slow state): this frame goes into it. The old one holds no
        // frame now, since this one was let in only once the last came back.
        var retired: VTCompressionSession?
        if handOver != nil, let next = replacement {
            replacement = nil
            retired = session
            session = next
            self.session = next
            slowState?.swapped(at: now)
        }
        lock.unlock()
        guard let handOver else { return }   // a frame queued just before the watchdog gave up
        if let retired {
            // The old session's last output may not have reached `onEncoded` yet: its handler let
            // this frame in (`frameReturned`) before handing its own frame on (`handle`), and the new
            // session calls back on a thread of its own. Should that handler be descheduled for longer
            // than the new keyframe takes (22–30 ms at 3024×1964), the device would get the old
            // delta after the keyframe that flushed its references, and show nothing new until the
            // next keyframe (up to 4 s). Completing the old session first waits for that handler to
            // return (it holds no frame: measured on this Mac's hardware, 0.07–0.13 ms after the
            // handler ends). Never under `lock`, which the handler takes. Were this ever to block
            // for good, this frame's clock, started at its hand-over, still fires the watchdog.
            VTCompressionSessionCompleteFrames(retired, untilPresentationTimeStamp: .invalid)
            Self.retire(retired)
        }
        if handOver.ptsFixed { bump("enc.ptsFixed") }
        // A new session starts with a keyframe anyway; forcing it keeps the retry below for it.
        let forced = handOver.keyframe || retired != nil
        let props: CFDictionary? = forced ? [kVTEncodeFrameOptionKey_ForceKeyFrame: true] as CFDictionary : nil
        let pts = handOver.pts

        if testHoldEachFrame > 0 { Thread.sleep(forTimeInterval: testHoldEachFrame) }
        if id == TestHang.frame, !quiet, !software, TestHang.take() {
            // TEST ONLY (SILL_TEST_ENCODER_HANG): this frame waits here, then goes in late and comes
            // back, as frames did in a busy engine on 2026-09-24. The watchdog fires meanwhile.
            print("TEST: holding frame \(id) of the hardware HEVC \(width)×\(height) session for \(Int(TestHang.hold)) s before it goes in (SILL_TEST_ENCODER_HANG)")
            Thread.sleep(forTimeInterval: TestHang.hold)
        }
        var infoFlags: VTEncodeInfoFlags = []
        let status = VTCompressionSessionEncodeFrame(session, imageBuffer: pixelBuffer, presentationTimeStamp: pts,
                                                     duration: .invalid, frameProperties: props, infoFlagsOut: &infoFlags) { [weak self] status, flags, sampleBuffer in
            guard let self else { return }
            let callbackAt = CACurrentMediaTime()
            // A session the watchdog gave up on may still cough up late output. Its clients have
            // moved on to a new session (new size, new parameter sets): do not copy or forward it.
            let current = self.lock.withLock { !self.mailbox.dead && self.mailbox.inside?.id == id }
            guard current else { return }
            let output: EncodedOutput?
            if status == noErr, !flags.contains(.frameDropped), let sampleBuffer {
                output = self.extract(sampleBuffer)
            } else { output = nil }
            // A successful VT status is not enough: unusable compressed data or unusable
            // keyframe parameters mean a lost frame. Decide this before admitting a dependent frame.
            let failed = output == nil
            let keyframeReady = output.map { $0.isKey && $0.parameterSets != nil } ?? false
            guard self.frameReturned(id, bytes: output?.data.count, failed: failed,
                                     keyframeReady: keyframeReady, callbackAt: callbackAt) else { return }
            guard let output else {
                self.bump("enc.error")
                return
            }
            self.bump("enc.out")
            self.handle(output)
        }
        if status != noErr {
            // Refused outright; the handler may never run. Free the slot ourselves, or the watchdog
            // would call a transient error a hang and drop the stream to the software encoder.
            bump("enc.refused")
            frameReturned(id, bytes: nil, failed: true)
        } else if infoFlags.contains(.frameDropped) {
            // VideoToolbox can report a synchronous drop before returning. The output callback
            // may also arrive; frameReturned accepts the first notice and ignores the duplicate.
            if frameReturned(id, bytes: nil, failed: true) { bump("enc.droppedSync") }
        }
    }

    /// VT callback thread (or `submit` on a refusal): the frame's place is free; the waiting frame,
    /// if there is one, takes it. A dead session or duplicate notice neither forwards output nor
    /// retries a keyframe. A failed frame requests a recovery keyframe, since the receiver cannot
    /// depend on the missing frame's references. A newer waiting image carries the request; when
    /// none is waiting, retry the latest image after the normal stillness check. The request and
    /// hand-over share the lock, so a newer image cannot be overwritten by an older recovery.
    @discardableResult
    private func frameReturned(_ id: Int, bytes: Int?, failed: Bool = false, keyframeReady: Bool = false,
                               callbackAt: CFTimeInterval? = nil) -> Bool {
        lock.lock()
        let now = CACurrentMediaTime()
        // The slow state is judged on frames that came back encoded, timed from their hand-over.
        var event: EncoderSlowState.Event?
        var latency: Double?
        if let bytes, !mailbox.dead, let inside = mailbox.inside, inside.id == id, inside.handed {
            // Keep the hardware slow-state measurement scoped to VT; user-space output copying
            // now finishes before this lock, but it must not make an engine look artificially slow.
            let turnaround = max(0, (callbackAt ?? now) - inside.since)
            latency = turnaround * 1000
            event = slowState?.returned(turnaround: turnaround, bytes: bytes, at: now)
        }
        let outcome = mailbox.returned(id, now: now)
        let accepted: Bool
        switch outcome {
        case .late, .duplicate: accepted = false
        case .freed, .next: accepted = true
        }
        if accepted && !failed && keyframeReady { forcedRetries = 0 }
        var retry: (Admission?, CFTimeInterval?)?
        if accepted && failed {
            if forcedRetries < 3 {
                forcedRetries += 1
                if case .next = outcome {
                    // Already let in, but not submitted: the queued newer image carries this flag.
                    mailbox.keyframeRequested = true
                } else {
                    retry = prepareKeyframeRequestLocked(now: now)
                }
            } else {
                // Stop autonomous retries, but do not resume with a potentially undecodable delta
                // if a new capture arrives or the client explicitly asks for a keyframe later.
                mailbox.keyframeRequested = true
            }
        }
        // Queued before the lock is released, like every frame let in (`admitLocked`).
        if case .next(let (pb, pts), let next) = outcome { encodeQueue.async { [weak self] in self?.submit(pb, pts: pts, id: next) } }
        lock.unlock()
        if let retry { finishKeyframeRequest(retry) }
        if let latency { onEncodeLatency?(latency) }
        if let event { slowStateSays(event) }
        return accepted
    }

    /// watchdogQueue, every 0.5 s. `encodeQueue` may be blocked inside VideoToolbox for good at this
    /// point; that thread is abandoned with the session.
    private func checkWatchdog() {
        lock.lock()
        let hung = mailbox.giveUpIfHung(now: CACurrentMediaTime(), after: Self.hangAfter)
        var spare: VTCompressionSession?
        if hung { hungReported = true; lastFrame = nil; spare = replacement; replacement = nil }   // lastFrame: 8+ MB at Retina size, no longer needed
        lock.unlock()
        guard hung else { return }
        if let spare { Self.retire(spare) }
        watchdog?.cancel()
        bump("enc.hung")
        if !quiet {
            print("Encoder (\(software ? "software" : "hardware") HEVC \(width)×\(height)) returned nothing for \(Int(Self.hangAfter * 1000)) ms: giving up on this session")
        }
        onHung?()
    }

    /// What the slow-state watch asks for, outside the lock: a new session, or the one line saying
    /// how the last one went.
    private func slowStateSays(_ event: EncoderSlowState.Event) {
        switch event {
        case .replace: makeReplacement()
        case .judged(let report): print(Self.describe(report, session: "hardware HEVC \(width)×\(height)"))
        }
    }

    /// A new session with the stream's settings, made on a queue of its own while the old one goes
    /// on (making one takes tens of ms, which must count against no frame's clock); `submit` hands
    /// the next frame to it. One that cannot be made leaves the stream on the old one.
    private func makeReplacement() {
        let (w, h, fps, bitrate, speed) = (width, height, fps, bitrate, prioritizeSpeed)
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            let made = try? HEVCEncoder.makeSession(width: w, height: h, fps: fps, bitrate: bitrate, prioritizeSpeed: speed, software: false)
            guard let self else { if let made { HEVCEncoder.retire(made) }; return }
            self.lock.lock()
            let taken = made != nil && !self.mailbox.dead
            if taken { self.replacement = made } else { self.slowState?.replacementFailed(at: CACurrentMediaTime()) }
            self.lock.unlock()
            if !taken, let made { HEVCEncoder.retire(made) }
        }
    }

    /// A session holding no frame, invalidated off the caller's queue (the call can block).
    private static func retire(_ session: VTCompressionSession) {
        DispatchQueue.global(qos: .utility).async {
            VTCompressionSessionCompleteFrames(session, untilPresentationTimeStamp: .invalid)
            VTCompressionSessionInvalidate(session)
        }
    }

    /// The line a new session's verdict prints, once per new session.
    static func describe(_ r: EncoderSlowState.Report, session: String) -> String {
        func ms(_ t: CFTimeInterval) -> String { "\(Int((t * 1000).rounded())) ms" }
        let size = r.keyframeBytes >= 1_000_000 ? String(format: "%.1f MB", Double(r.keyframeBytes) / 1_000_000)
                                                : "\(Int((Double(r.keyframeBytes) / 1000).rounded())) kB"
        let before = "Encoder (\(session)): frames took \(ms(r.slow.turnaround)) each (\(Int(r.slow.outputFPS.rounded())) fps out of \(Int(r.slow.inputFPS.rounded())) captured)"
        let cost = "a \(size) keyframe, \(ms(r.gap)) between frames"
        guard let t = r.turnaround else {
            return "\(before); a new session took over (\(cost)), and the picture went still before it could be timed."
        }
        if r.noFaster {
            return "\(before); a new session takes \(ms(t)), no faster, so this stream keeps it and gets no other (\(cost))."
        }
        return "\(before); a new session takes \(ms(t)) (\(cost))."
    }

    /// Every counter this encoder keeps goes through here: a quiet one (a probe) keeps none.
    private func bump(_ key: String) {
        if !quiet { Stats.shared.bump(key) }
    }

    private struct EncodedOutput {
        let data: Data
        let isKey: Bool
        let parameterSets: ParameterSets?
        let pts: CMTime
    }

    /// Copy the access unit while it still owns the encoder slot. A keyframe must also carry the
    /// parameter sets the decoder can accept; otherwise the frame cannot recover a still screen.
    private func extract(_ sb: CMSampleBuffer) -> EncodedOutput? {
        guard let block = CMSampleBufferGetDataBuffer(sb) else { return nil }
        let length = CMBlockBufferGetDataLength(block)
        guard length > 0, length <= StreamMessage.maxFramePayload else { return nil }
        var data = Data(count: length)
        let copied = data.withUnsafeMutableBytes { raw -> OSStatus in
            guard let base = raw.baseAddress else { return kCMBlockBufferBadPointerParameterErr }
            return CMBlockBufferCopyDataBytes(block, atOffset: 0, dataLength: length, destination: base)
        }
        guard copied == noErr else { return nil }
        var isKey = true
        if let arr = CMSampleBufferGetSampleAttachmentsArray(sb, createIfNecessary: false) as? [[CFString: Any]],
           let first = arr.first, let notSync = first[kCMSampleAttachmentKey_NotSync] as? Bool {
            isKey = !notSync
        }
        let ps = isKey ? CMSampleBufferGetFormatDescription(sb).flatMap { Self.parameterSets(from: $0) } : nil
        guard !isKey || ps != nil else { return nil }
        return EncodedOutput(data: data, isKey: isKey, parameterSets: ps, pts: CMSampleBufferGetPresentationTimeStamp(sb))
    }

    private func handle(_ output: EncodedOutput) {
        onEncoded?(output.data, output.isKey, output.parameterSets)
    }

    static func parameterSets(from desc: CMFormatDescription) -> ParameterSets? {
        var count = 0
        var nalLen: Int32 = 0
        guard CMVideoFormatDescriptionGetHEVCParameterSetAtIndex(desc, parameterSetIndex: 0, parameterSetPointerOut: nil,
                                                                 parameterSetSizeOut: nil, parameterSetCountOut: &count,
                                                                 nalUnitHeaderLengthOut: &nalLen) == noErr,
              count == 3, nalLen == 4 else { return nil }
        var sets: [Data] = []
        for i in 0..<count {
            var ptr: UnsafePointer<UInt8>?
            var size = 0
            guard CMVideoFormatDescriptionGetHEVCParameterSetAtIndex(desc, parameterSetIndex: i, parameterSetPointerOut: &ptr,
                                                                     parameterSetSizeOut: &size, parameterSetCountOut: nil,
                                                                     nalUnitHeaderLengthOut: nil) == noErr, let ptr,
                  (1...65_535).contains(size) else { return nil }
            sets.append(Data(bytes: ptr, count: size))
        }
        return ParameterSets(nalUnitHeaderLength: Int(nalLen), sets: sets)
    }

    enum EncoderError: Error { case create(OSStatus); case property(String, OSStatus) }

    /// TEST ONLY. `SILL_TEST_ENCODER_HANG=N`: the first N hardware stream sessions of this process
    /// each hold their 90th frame on `encodeQueue` for 3 s before handing it to VideoToolbox (later
    /// frames wait in the mailbox), so the watchdog fires 1.5 s after it went in, the owner falls
    /// back to the software encoder, and the frame then goes in and comes back late, as in a busy
    /// engine (2026-09-24). N = 2 makes the return to the hardware hang once more, for the
    /// re-check's backoff. Probes (quiet) never take one. Read once; nothing else changes without
    /// the variable.
    private enum TestHang {
        static let frame = 90
        static let hold: TimeInterval = 3
        private static let lock = NSLock()
        private static var left = Int(ProcessInfo.processInfo.environment["SILL_TEST_ENCODER_HANG"] ?? "") ?? 0
        static func take() -> Bool {
            lock.lock(); defer { lock.unlock() }
            guard left > 0 else { return false }
            left -= 1
            return true
        }
    }
}
