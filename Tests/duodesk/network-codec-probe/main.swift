// Test-only native Mac receiver: production TLS, HEVC decoder and video presenter.
// Receiver device keys and server replies stay in memory, outside the keychain and logs.
// Pairing input comes from a private file; the installed host uses its normal pairing flow.
import AppKit
import AVFoundation
import CoreMedia
import Network
import Security
import StreamProtocol

enum ProbeError: Error { case failed(String) }
let native = DuoDesktopResolution(width: 2007, height: 1427)
let networkQueue = DispatchQueue(label: "duodesk.network-codec-probe", qos: .userInteractive)

final class Measurement: @unchecked Sendable {
    let lock = NSLock()
    var began = 0.0
    var firstImage: Double?
    var measuredFrom = Double.infinity
    var decoded = 0
    var received = 0
    var rtts: [Double] = []
    var failures: [String] = []
    var inputSent: Double?
    var inputSentUnix: Double?
    var firstInputQueuedUnix: Double?
    var mouseDownQueuedUnix: Double?
    var inputSubmitCount = 0
    var fixtureKeysSent = false
    var inputImageRoundTripMs: Double?
    var inputImageDecodedUnix: Double?
    var darkMarkerObserved = false
    var markerDiagnosticPrinted = false
    var desktopWasActive = false
    var windowPickSent = false
    var streamResets = 0
    var invalidatedImages = 0
    var lastImageGeneration: UInt64?
    var waitForRestoreReset = false
    var startOnFreshImage = false
    var requiredImageGeneration: UInt64 = 0
    var rateRestored = false
    var firstWireEpoch: UInt64?
    var activeWireEpoch: UInt64?
    var heldModifierEpoch: UInt64?
    var inputEpochsSent = false
    var dryInputConfirmed = false
    func failure(_ text: String) { lock.lock(); failures.append(text); lock.unlock() }
}
let measurement = Measurement()

final class ConnectionAttempt: @unchecked Sendable {
    let lock = NSLock()
    var answered = false
    func take() -> Bool {
        lock.withLock { if answered { return false }; answered = true; return true }
    }
    var pending: Bool { lock.withLock { !answered } }
}

func connect(host: String, port: Int, identity: RemoteIdentity, pin: Data?, alpn: String) async throws -> NWConnection {
    guard pin != nil || alpn == RemoteTLS.pairingALPN else {
        throw ProbeError.failed("video sessions require the authenticated pairing pin")
    }
    let tls = DeviceTLS.options(identity: identity, alpn: alpn, pin: pin, queue: networkQueue)
    // Diagnostic ciphers retain TLS 1.3 and the production pairing/session trust policy. Never
    // change production cipher policy based on a failing link without a reproducible cause.
    if let choice = ProcessInfo.processInfo.environment["DUODESK_PROBE_TLS_CIPHER"] {
        let suite: tls_ciphersuite_t
        switch choice {
        case "aes128": suite = .AES_128_GCM_SHA256
        case "aes256": suite = .AES_256_GCM_SHA384
        case "chacha20": suite = .CHACHA20_POLY1305_SHA256
        default: throw ProbeError.failed("unsupported TLS diagnostic cipher")
        }
        sec_protocol_options_append_tls_ciphersuite(tls.securityProtocolOptions, suite)
    }
    let parameters: NWParameters
    // Match the app: pairing proofs stay on one TLS/TCP connection; only video sessions use QUIC.
    if CommandLine.arguments.contains("--quic"), alpn == RemoteTLS.sessionALPN {
        let options = RemoteTLS.quicOptions(identity: identity.tls, role: .client(alpn: alpn), queue: networkQueue) { peer, negotiated in
            peer == pin && negotiated == alpn
        }
        parameters = RemoteTLS.quicParameters(options: options)
    } else { parameters = RemoteTLS.parameters(tls: tls, dialing: true) }
    let connection = NWConnection(host: NWEndpoint.Host(host), port: NWEndpoint.Port(rawValue: UInt16(port))!, using: parameters)
    return try await withCheckedThrowingContinuation { continuation in
        let attempt = ConnectionAttempt()
        @Sendable func finish(_ result: Result<NWConnection, Error>) {
            guard attempt.take() else { return }
            connection.stateUpdateHandler = nil
            continuation.resume(with: result)
        }
        connection.stateUpdateHandler = { state in
            switch state {
            case .ready:
                guard RemoteTLS.negotiatedALPN(connection) == alpn,
                      let actual = RemoteTLS.peerFingerprint(connection), pin == nil || actual == pin else {
                    finish(.failure(ProbeError.failed("ready peer pin or ALPN mismatch"))); connection.cancel(); return
                }
                if let metadata = RemoteTLS.securityMetadata(connection) {
                    let version = sec_protocol_metadata_get_negotiated_tls_protocol_version(metadata).rawValue
                    let suite = sec_protocol_metadata_get_negotiated_tls_ciphersuite(metadata).rawValue
                    print(String(format: "Network probe TLS: version=0x%04x, cipher=0x%04x", version, suite))
                }
                if connection.metadata(definition: NWProtocolQUIC.definition) != nil { print("Network probe transport: QUIC") }
                finish(.success(connection))
            case .failed(let error), .waiting(let error):
                finish(.failure(error)); connection.cancel()
            case .cancelled: finish(.failure(ProbeError.failed("connection cancelled")))
            default: break
            }
        }
        connection.start(queue: networkQueue)
        networkQueue.asyncAfter(deadline: .now() + 12) {
            guard attempt.pending else { return }
            finish(.failure(ProbeError.failed("TLS timeout"))); connection.cancel()
        }
    }
}

func send(_ kind: StreamMessageKind, payload: Data = Data(), on connection: NWConnection) {
    let message = StreamMessage(kind: kind, timestamp: Date().timeIntervalSince1970, isKeyframe: false, payload: payload)
    let bytes = message.serialized()
    if kind == .input, CommandLine.arguments.contains("--fixture-input") {
        let submitted = Date().timeIntervalSince1970
        measurement.lock.withLock {
            measurement.inputSubmitCount += 1
            if measurement.firstInputQueuedUnix == nil { measurement.firstInputQueuedUnix = submitted }
            if measurement.inputSubmitCount == 2 { measurement.mouseDownQueuedUnix = submitted }
        }
    }
    connection.send(content: bytes, completion: .contentProcessed { error in
        if let error { measurement.failure("send: \(error)") }
        else if kind == .hello || kind == .viewport || kind == .selectSource { print("Network probe: sent \(kind)") }
    })
}

func read(_ count: Int, from connection: NWConnection) async throws -> Data {
    if count == 0 { return Data() }
    return try await withCheckedThrowingContinuation { continuation in
        connection.receive(minimumIncompleteLength: count, maximumLength: count) { data, _, _, error in
            if let data, data.count == count { continuation.resume(returning: data) }
            else { continuation.resume(throwing: error ?? ProbeError.failed("truncated message")) }
        }
    }
}

func message(from connection: NWConnection) async throws -> (StreamHeader, Data) {
    let bytes = try await read(StreamMessage.headerLength, from: connection)
    guard let header = StreamMessage.parseHeader(bytes), header.payloadLength <=
        (header.kind == .frame ? StreamMessage.maxFramePayload : StreamMessage.maxOtherHostPayload) else {
        throw ProbeError.failed("invalid bounded header")
    }
    return (header, try await read(header.payloadLength, from: connection))
}

@MainActor
func run() async throws {
    let typed = CommandLine.arguments.contains("--pair-code")
    let keyboardCases = CommandLine.arguments.contains("--keyboard-cases")
    let imeCases = CommandLine.arguments.contains("--ime-cases")
    let shortInputDiagnostic = keyboardCases || imeCases
    let args = CommandLine.arguments.filter { !["--quic", "--pair-code", "--keyboard-cases", "--ime-cases"].contains($0) }
    let mode = args.count >= 4 ? args[3] : nil
    guard !keyboardCases || !imeCases else { throw ProbeError.failed("choose one owned input diagnostic") }
    let imeStatePath = ProcessInfo.processInfo.environment["DUODESK_PROBE_FIXTURE_IME_STATE"]
    let imePID = ProcessInfo.processInfo.environment["DUODESK_PROBE_FIXTURE_PID"].flatMap(Int32.init)
    if imeCases {
        guard mode == "--fixture-input", let imeStatePath, let imePID, imePID > 1,
              FileManager.default.fileExists(atPath: imeStatePath) else {
            throw ProbeError.failed("IME cases require a live owned text fixture and its state file")
        }
    }
    let keyboardEventPath = ProcessInfo.processInfo.environment["DUODESK_PROBE_FIXTURE_EVENTS"]
    if keyboardCases {
        guard mode == "--fixture-input", let keyboardEventPath,
              !FileManager.default.fileExists(atPath: keyboardEventPath) else {
            throw ProbeError.failed("keyboard cases require --fixture-input and a fresh owned fixture event path")
        }
    }
    var diagnosticSentAt: Double?
    var imeReport: [String: Any]?
    let dryInputEpochs = args.count == 5 && mode == "--rate-switch" && args[4] == "--dry-run-input-epochs"
    guard (args.count == 3 || (args.count == 4 && ["--fixture-input", "--window-pick", "--rate-switch", "--gpu-frame-code"].contains(mode ?? "")) || dryInputEpochs),
          let key = RemoteKey.generate(), let identity = RemoteIdentity(privateKey: key) else {
        throw ProbeError.failed("usage: probe HOST PAIR_INPUT_FILE [--pair-code] [--quic] [--fixture-input [--keyboard-cases|--ime-cases]|--window-pick|--rate-switch|--gpu-frame-code]")
    }
    let pair = try ProbePairingInput(path: args[2], typed: typed)
    let frameAudit = mode == "--gpu-frame-code" ? try PixelMotionAudit() : nil
    let pairing = try await connect(host: args[1], port: pair.port, identity: identity, pin: pair.pin, alpn: RemoteTLS.pairingALPN)
    defer { pairing.cancel() }
    guard let pin = RemoteTLS.peerFingerprint(pairing) else { throw ProbeError.failed("pairing peer has no P-256 fingerprint") }
    let proofKey = try pair.proofKey(for: pin)
    let proof = PairingProof.deviceProof(key: proofKey, deviceFingerprint: identity.fingerprint, macFingerprint: pin)
    let deviceName = ProcessInfo.processInfo.environment["DUODESK_PROBE_DEVICE_NAME"] ?? "Native hardware QA"
    send(.pairRequest, payload: Wire.encode(PairRequest(method: pair.method, proof: Base64URL.encode(proof),
                                                       name: deviceName, model: "Mac")), on: pairing)
    let (header, payload) = try await message(from: pairing)
    pairing.cancel()
    guard header.kind == .pairResult, let answer = Wire.decode(PairResult.self, from: payload), answer.ok,
          answer.macID == (pair.expectedMacID ?? MacID.make(fingerprint: pin)),
          let proofText = answer.proof, let macProof = Base64URL.decode(proofText),
          let recognition = answer.recognitionKey.flatMap(Base64URL.decode), recognition.count == 32,
          PairingProof.isValidMacProof(macProof, key: proofKey, macFingerprint: pin, deviceFingerprint: identity.fingerprint) else {
        throw ProbeError.failed("pairing proof rejected")
    }
    print("Network probe: mutual pairing proof verified")
    let session = try await connect(host: args[1], port: pair.port, identity: identity, pin: pin, alpn: RemoteTLS.sessionALPN)
    defer { session.cancel() }
    func sendControl(_ kind: StreamMessageKind, _ payload: Data, epoch supplied: UInt64? = nil) {
        guard !dryInputEpochs || measurement.lock.withLock({ measurement.dryInputConfirmed }) else {
            measurement.failure("host has not confirmed dry-run input; no test input sent"); return
        }
        guard let epoch = supplied ?? measurement.lock.withLock({ measurement.activeWireEpoch }),
              let tagged = VideoControlPayload(epoch: epoch, payload: payload) else {
            measurement.failure("input requires a current video epoch"); return
        }
        send(kind, payload: tagged.encoded, on: session)
    }
    let view = NSView(frame: NSRect(x: 0, y: 0, width: 702, height: 500))
    let layer = AVSampleBufferDisplayLayer()
    layer.videoGravity = .resizeAspect
    view.wantsLayer = true; view.layer = layer
    let window = NSWindow(contentRect: view.frame, styleMask: [.titled, .closable], backing: .buffered, defer: false)
    let screen = NSScreen.screens.max { $0.maximumFramesPerSecond < $1.maximumFramesPerSecond }
    window.title = "DUO Native Hardware QA"; window.contentView = view
    if let screen {
        window.setFrameOrigin(NSPoint(x: screen.visibleFrame.midX - window.frame.width / 2,
                                      y: screen.visibleFrame.midY - window.frame.height / 2))
        print("Network probe presentation panel: \(screen.maximumFramesPerSecond) Hz maximum")
    }
    window.orderFrontRegardless()
    defer { window.orderOut(nil) }
    let markerAudit = mode == "--fixture-input" ? try PixelMotionAudit(fixtureMarker: true) : nil
    let presenter = HardwareVideoPresenter(renderer: layer.sampleBufferRenderer, onFirstImage: { size, _ in
        print("Network probe: native image queued \(size)")
    }, onFailure: { text, _, _ in measurement.failure(text) })
    let decoder = HardwareHEVCDecoder(onFormat: { _, token in presenter.reset(token) }, onSample: { sample, token, permit in
        guard let image = CMSampleBufferGetImageBuffer(sample),
              native.accepts(width: CVPixelBufferGetWidth(image), height: CVPixelBufferGetHeight(image)) else {
            measurement.failure("native canvas mismatch"); return
        }
        presenter.enqueue(sample, generation: token, permit: permit)
        let now = ProcessInfo.processInfo.systemUptime
        let decodedUnix = Date().timeIntervalSince1970
        measurement.lock.lock()
        measurement.lastImageGeneration = token
        if measurement.firstImage == nil {
            measurement.firstImage = now
            if mode != "--rate-switch" { measurement.measuredFrom = now + 2 }
        }
        if measurement.startOnFreshImage, token > measurement.requiredImageGeneration {
            measurement.measuredFrom = now + 2
            measurement.startOnFreshImage = false
            measurement.waitForRestoreReset = false
        }
        let inMeasurement = now >= measurement.measuredFrom && now < measurement.measuredFrom + 30
        if inMeasurement { measurement.decoded += 1 }
        let inspectMarker = markerAudit != nil && measurement.inputImageRoundTripMs == nil
        measurement.lock.unlock()
        if inspectMarker {
            markerAudit?.inspect(image, at: now) { result, decodedAt in
                measurement.lock.withLock {
                    if result == -2 { measurement.failures.append("fixture marker GPU inspection failed"); return }
                    if !measurement.markerDiagnosticPrinted {
                        measurement.markerDiagnosticPrinted = true
                        print("Fixture marker GPU result: \(result) (-1 absent, 1 ready, 2 clicked)")
                    }
                    if measurement.inputSent == nil, result == 1 { measurement.darkMarkerObserved = true }
                    if result == 2, measurement.darkMarkerObserved, let sent = measurement.inputSent, decodedAt >= sent {
                        let latency = (decodedAt - sent) * 1000
                        if latency < measurement.inputImageRoundTripMs ?? .infinity {
                            measurement.inputImageRoundTripMs = latency
                            measurement.inputImageDecodedUnix = decodedUnix
                        }
                    }
                }
            }
        }
        if inMeasurement { frameAudit?.inspect(image, at: now) }
    }, onFailure: { text, _ in measurement.failure(text) }, onNeedsKeyframe: { _ in send(.requestKeyframe, on: session) })
    decoder.require(native)
    defer { decoder.clear() }
    send(.hello, payload: Wire.encode(Hello(appVersion: "0.1.0", build: "4", protocol: SillProtocol.current, device: "Native hardware QA")), on: session)
    send(.viewport, payload: Wire.encode(Viewport(width: 669, height: 475.5, scale: nil, localCursor: true, fps: 120, desktopResolution: native)), on: session)
    send(.selectSource, payload: Wire.encode(StreamSource.desktop), on: session)
    measurement.lock.withLock { measurement.began = ProcessInfo.processInfo.systemUptime }
    let receiver = Task.detached(priority: .high) {
        var videoEpoch = VideoStreamEpoch()
        do {
            while !Task.isCancelled {
                let (header, payload) = try await message(from: session)
                switch header.kind {
                case .streamReset:
                    if videoEpoch.acceptReset(payload) {
                        let old = measurement.lock.withLock { measurement.lastImageGeneration }
                        let token = decoder.clear()
                        presenter.reset(token)
                        let invalidated = old.map { !decoder.isCurrent($0) } ?? false
                        measurement.lock.withLock {
                            if measurement.firstWireEpoch == nil { measurement.firstWireEpoch = videoEpoch.lastValue }
                            measurement.activeWireEpoch = videoEpoch.lastValue
                            if measurement.inputSent == nil { measurement.darkMarkerObserved = false }
                            measurement.streamResets += 1
                            if invalidated { measurement.invalidatedImages += 1 }
                            if measurement.waitForRestoreReset {
                                measurement.requiredImageGeneration = token
                                measurement.startOnFreshImage = true
                            }
                        }
                        print("Network probe: accepted video reset \(videoEpoch.lastValue ?? 0)")
                    }
                case .windowList:
                    if let list = Wire.decode(WindowList.self, from: payload) {
                        if dryInputEpochs, list.inputDryRun != true {
                            measurement.failure("host has not confirmed dry-run input; no test input sent")
                            return
                        }
                        let illegal = measurement.lock.withLock {
                            if list.inputDryRun == true { measurement.dryInputConfirmed = true }
                            if list.active == .desktop { measurement.desktopWasActive = true }
                            return measurement.windowPickSent && measurement.desktopWasActive && list.active != .desktop
                        }
                        if illegal { measurement.failure("window pick replaced the complete native desktop") }
                    }
                case .parameterSets:
                    if let ps = ParameterSets(encoded: payload) { decoder.apply(ps) }
                case .frame:
                    measurement.lock.withLock { measurement.received += 1 }
                    decoder.enqueue(payload, isKeyframe: header.isKeyframe)
                case .pong:
                    if payload.count == 8 {
                        let bits = payload.reduce(UInt64(0)) { ($0 << 8) | UInt64($1) }
                        let ms = (ProcessInfo.processInfo.systemUptime - Double(bitPattern: bits)) * 1000
                        if ms.isFinite, ms >= 0 { measurement.lock.withLock { measurement.rtts.append(ms) } }
                    }
                case .goodbye: measurement.failure("host ended stream"); return
                default: break
                }
            }
        } catch { if !Task.isCancelled { measurement.failure("receive: \(error)") } }
    }
    defer { receiver.cancel() }
    var previousTotal = 0, previousDropped = 0
    var presented = 0
    var shownBaseline: (total: Int, dropped: Int, time: Double)?
    var renderDuration = 0.0
    for second in 1...60 {
        var stamp = ProcessInfo.processInfo.systemUptime.bitPattern.bigEndian
        send(.ping, payload: withUnsafeBytes(of: &stamp) { Data($0) }, on: session)
        try await Task.sleep(for: .seconds(1))
        if second == 15, measurement.lock.withLock({ measurement.firstImage == nil }) {
            measurement.failure("no native desktop image within 15 seconds")
        }
        let measuredFrom = measurement.lock.withLock { measurement.measuredFrom }
        if mode == "--rate-switch", second == 2 {
            if dryInputEpochs, !measurement.lock.withLock({ measurement.dryInputConfirmed }) {
                throw ProbeError.failed("host has not confirmed dry-run input; no test input sent")
            }
            if dryInputEpochs, let epoch = measurement.lock.withLock({ measurement.activeWireEpoch }) {
                measurement.heldModifierEpoch = epoch
                sendControl(.input, Wire.encode(InputEvent.key(hidUsage: 0xE1, down: true, modifiers: 1 << 17)), epoch: epoch)
            }
            send(.viewport, payload: Wire.encode(Viewport(width: 669, height: 475.5, scale: nil, localCursor: true,
                                                          fps: 60, desktopResolution: native)), on: session)
            print("Network probe: requested 60 FPS at unchanged native dimensions")
        }
        if dryInputEpochs, second == 10 {
            let epochs = measurement.lock.withLock { (measurement.firstWireEpoch, measurement.activeWireEpoch) }
            guard let old = epochs.0, let current = epochs.1, old != current,
                  let held = measurement.heldModifierEpoch else { throw ProbeError.failed("input epoch setup did not restart") }
            // Only run this opt-in against an owned --synthetic host with dry-run input logging.
            // Host evidence must show Shift released at the restart, current A and click delivered,
            // but no stale B, untagged C, stale click or stale swipeLeft.
            sendControl(.input, Wire.encode(InputEvent.key(hidUsage: 0xE1, down: false, modifiers: 0)), epoch: held)
            for down in [true, false] {
                sendControl(.input, Wire.encode(InputEvent.key(hidUsage: 0x05, down: down, modifiers: 0)), epoch: old)
                send(.input, payload: Wire.encode(InputEvent.key(hidUsage: 0x06, down: down, modifiers: 0)), on: session)
                sendControl(.input, Wire.encode(InputEvent.key(hidUsage: 0x04, down: down, modifiers: 0)), epoch: current)
            }
            for action: PointerAction in [.leftDown, .leftUp] {
                sendControl(.input, Wire.encode(InputEvent.pointer(action, x: 0.1, y: 0.1)), epoch: old)
                sendControl(.input, Wire.encode(InputEvent.pointer(action, x: 0.5, y: 0.5)), epoch: current)
            }
            sendControl(.gesture, Wire.encode(TrackpadGesture(gesture: TrackpadGesture.swipeLeft, fingers: 3)), epoch: old)
            sendControl(.gesture, Wire.encode(TrackpadGesture(gesture: TrackpadGesture.swipeRight, fingers: 3)), epoch: current)
            measurement.inputEpochsSent = true
            print("Network probe: sent stale, untagged and current inputs to the owned dry-run host")
        }
        if mode == "--rate-switch", second == 5 {
            measurement.lock.withLock { measurement.waitForRestoreReset = true; measurement.rateRestored = true }
            send(.viewport, payload: Wire.encode(Viewport(width: 669, height: 475.5, scale: nil, localCursor: true,
                                                          fps: 120, desktopResolution: native)), on: session)
            print("Network probe: restored 120 FPS; measurement waits for a new stream image")
        }
        if mode == "--fixture-input", ProcessInfo.processInfo.systemUptime >= measuredFrom + 2,
           measurement.lock.withLock({ measurement.inputSent == nil && measurement.darkMarkerObserved }) {
            let point: (Double, Double)
            if imeCases, let imeStatePath, let imePID {
                point = try ProbeIMECases.clickPoint(path: imeStatePath, fixturePID: imePID)
            } else { point = (0.5, 0.5) }
            measurement.lock.withLock {
                measurement.inputSent = ProcessInfo.processInfo.systemUptime
                measurement.inputSentUnix = Date().timeIntervalSince1970
            }
            for action: PointerAction in [.move, .leftDown, .leftUp] {
                sendControl(.input, Wire.encode(InputEvent.pointer(action, x: point.0, y: point.1)))
            }
            print("Network probe: sent the owned fixture click; keyboard check waits for its image response")
        }
        if mode == "--fixture-input", measurement.lock.withLock({ measurement.inputImageRoundTripMs != nil && !measurement.fixtureKeysSent }) {
            if shortInputDiagnostic {
                guard let epoch = measurement.lock.withLock({ measurement.activeWireEpoch }) else {
                    throw ProbeError.failed("keyboard cases require a current native image epoch")
                }
                diagnosticSentAt = Date().timeIntervalSince1970
                if imeCases, let imeStatePath, let imePID {
                    imeReport = try await ProbeIMECases.run(path: imeStatePath, fixturePID: imePID,
                        current: { measurement.lock.withLock { measurement.activeWireEpoch == epoch } },
                        send: { sendControl(.input, Wire.encode($0), epoch: epoch) })
                } else {
                    for test in ProbeKeyboardCases.cases {
                        guard measurement.lock.withLock({ measurement.activeWireEpoch == epoch }) else {
                            throw ProbeError.failed("owned fixture video epoch changed during keyboard cases")
                        }
                        for event in test.events { sendControl(.input, Wire.encode(event), epoch: epoch) }
                        try await Task.sleep(for: .milliseconds(100))
                    }
                }
                print("Network probe: production input diagnostic completed in the clicked owned fixture")
            } else {
                for usage: UInt16 in [0x04, 0x05, 0x06] {
                    sendControl(.input, Wire.encode(InputEvent.key(hidUsage: usage, down: true, modifiers: 0)))
                    sendControl(.input, Wire.encode(InputEvent.key(hidUsage: usage, down: false, modifiers: 0)))
                }
            }
            measurement.lock.withLock { measurement.fixtureKeysSent = true }
            print("Network probe: fixture keyboard events sent after the click image response")
        }
        if shortInputDiagnostic, let diagnosticSentAt, Date().timeIntervalSince1970 - diagnosticSentAt >= 1.0 { break }
        if shortInputDiagnostic, measurement.lock.withLock({
            measurement.inputSentUnix.map { Date().timeIntervalSince1970 - $0 > 5 } == true
                && measurement.inputImageRoundTripMs == nil
        }) { throw ProbeError.failed("owned fixture click image did not respond; no keyboard cases sent") }
        if shortInputDiagnostic, measurement.lock.withLock({
            measurement.firstImage.map { ProcessInfo.processInfo.systemUptime - $0 > 6 } == true
                && !measurement.darkMarkerObserved
        }) { throw ProbeError.failed("owned fixture marker did not appear; no input sent") }
        if mode == "--window-pick", ProcessInfo.processInfo.systemUptime >= measuredFrom + 2,
           !measurement.lock.withLock({ measurement.windowPickSent }) {
            measurement.lock.withLock { measurement.windowPickSent = true }
            // No real app is activated: this regression runs against an owned synthetic host.
            send(.selectSource, payload: Wire.encode(StreamSource.window(UInt32.max)), on: session)
            print("Network probe: requested a window inside the native desktop session")
        }
        if !measurement.lock.withLock({ measurement.failures.isEmpty }) { break }
        if let metrics = await layer.sampleBufferRenderer.videoPerformanceMetrics {
            let total = metrics.totalNumberOfFrames, dropped = metrics.numberOfDroppedFrames
            print("Network probe second \(second): renderer total=\(total), dropped=\(dropped), delta=\(total - previousTotal - dropped + previousDropped)")
            let now = ProcessInfo.processInfo.systemUptime
            if now >= measuredFrom, shownBaseline == nil { shownBaseline = (total, dropped, now) }
            if let baseline = shownBaseline, now - baseline.time >= 30 {
                presented = total - baseline.total - dropped + baseline.dropped
                renderDuration = now - baseline.time
            }
            previousTotal = total; previousDropped = dropped
        }
        if ProcessInfo.processInfo.systemUptime >= measuredFrom + 31 { break }
    }
    let (decoded, rtts, failures, resets, invalidated, rateRestored) = measurement.lock.withLock {
        (measurement.decoded, measurement.rtts.sorted(), measurement.failures,
         measurement.streamResets, measurement.invalidatedImages, measurement.rateRestored)
    }
    let duration = min(30, max(0, ProcessInfo.processInfo.systemUptime - measurement.measuredFrom))
    let fps = duration > 0 ? Double(decoded) / duration : 0
    if let frameAudit {
        print(await frameAudit.report(from: measurement.lock.withLock { measurement.measuredFrom }, seconds: 30))
    }
    var report: [String: Any] = ["nativeWidth": native.encodedWidth, "nativeHeight": native.encodedHeight,
        "durationSeconds": duration, "measurementWindowCompleted": duration >= 30, "decodedFrames": decoded, "decodedFPS": fps,
        "receivedFrames": measurement.lock.withLock { measurement.received },
        "frameCodeAudit": frameAudit != nil, "uniqueDecodedFPS": frameAudit?.changedFramesPerSecond ?? -1,
        "renderedFrames": presented, "renderDurationSeconds": renderDuration,
        "renderedFPS": renderDuration > 0 ? Double(presented) / renderDuration : -1,
        "streamResets": resets,
        "invalidatedImages": invalidated,
        "dryInputEpochTest": dryInputEpochs,
        "inputEpochsSent": measurement.inputEpochsSent,
        "dryRunHostConfirmed": measurement.lock.withLock { measurement.dryInputConfirmed },
        "rateSwitchTest": mode == "--rate-switch",
        "firstDecodedImageMs": measurement.firstImage.map { ($0 - measurement.began) * 1000 } ?? -1,
        "inputToDecodedImageMs": measurement.inputImageRoundTripMs ?? -1,
        "inputSentUnix": measurement.inputSentUnix ?? -1,
        "firstInputQueuedUnix": measurement.firstInputQueuedUnix ?? -1,
        "mouseDownQueuedUnix": measurement.mouseDownQueuedUnix ?? -1,
        "inputImageDecodedUnix": measurement.inputImageDecodedUnix ?? -1,
        "rttMedianMs": rtts.isEmpty ? -1 : rtts[rtts.count / 2], "rttMaxMs": rtts.last ?? -1,
        "hardwareRequired": true, "windowPickTest": measurement.windowPickSent, "failures": failures]
    if shortInputDiagnostic {
        report["inputOnlyDiagnostic"] = true
        report["performanceAcceptance"] = false
        guard let diagnosticSentAt, failures.isEmpty, resets > 0,
              measurement.inputImageRoundTripMs != nil else { throw ProbeError.failed("owned input fixture setup failed") }
        print("INPUT SESSION: " + String(decoding: try JSONSerialization.data(withJSONObject: report, options: [.sortedKeys]), as: UTF8.self))
        if imeCases {
            guard let imeReport else { throw ProbeError.failed("IME fixture report unavailable") }
            report["imeInput"] = imeReport
        } else if let keyboardEventPath {
            report["keyboardInput"] = try ProbeKeyboardCases.validate(path: keyboardEventPath, after: diagnosticSentAt)
        }
        print(String(decoding: try JSONSerialization.data(withJSONObject: report, options: [.sortedKeys]), as: UTF8.self))
        print("Network owned input probe PASS; this is not 120 FPS acceptance")
        return
    }
    print(String(decoding: try JSONSerialization.data(withJSONObject: report, options: [.sortedKeys]), as: UTF8.self))
    try frameAudit?.validate()
    guard duration >= 30, fps >= 119.5, failures.isEmpty, (mode != "--fixture-input" || measurement.inputImageRoundTripMs != nil),
          frameAudit == nil || (frameAudit?.changedFramesPerSecond ?? 0) >= 119.5,
          (mode != "--window-pick" || measurement.windowPickSent),
          resets > 0,
          (!dryInputEpochs || measurement.inputEpochsSent),
          (mode != "--rate-switch" || (rateRestored && resets >= 4 && invalidated >= 2)) else {
        throw ProbeError.failed("hardware network acceptance failed")
    }
    print("Network hardware decode probe PASS; renderer rate reported separately")
}

let app = NSApplication.shared
let receiverActivity = ProcessInfo.processInfo.beginActivity(options: [.userInitiatedAllowingIdleSystemSleep, .latencyCritical],
                                                          reason: "Native hardware video acceptance")
setbuf(stdout, nil)
app.setActivationPolicy(.accessory)
Task { @MainActor in
    do { try await run(); exit(0) }
    catch { print("Network hardware probe FAIL: \(error)"); exit(1) }
}
app.run()
