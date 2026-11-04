import Foundation
import Security
import SillHostCore
import StreamProtocol

/// Shared observation only; the mutable identity store itself is transferred, never shared.
final class StoreAudit: @unchecked Sendable {
    private let lock = NSLock()
    private var calls: [String] = []
    private var mainReads = 0
    private var writes = 0
    private let mainActorSignal = DispatchSemaphore(value: 0)
    private var keyIsWaiting = false
    private var mainActorResponded = false

    func read(_ name: String) {
        lock.withLock {
            calls.append(name)
            if Thread.isMainThread { mainReads += 1 }
        }
    }
    func write() { lock.withLock { writes += 1 } }
    func waitForMainActor() {
        lock.withLock { keyIsWaiting = true }
        let responded = mainActorSignal.wait(timeout: .now() + 10) == .success
        lock.withLock {
            keyIsWaiting = false
            mainActorResponded = responded
        }
    }
    func acknowledgeWaitingRead() -> Bool {
        lock.withLock {
            guard keyIsWaiting else { return false }
            mainActorSignal.signal()
            return true
        }
    }
    var mainActorWasResponsive: Bool { lock.withLock { mainActorResponded } }
    var snapshot: (calls: [String], mainReads: Int, writes: Int) {
        lock.withLock { (calls, mainReads, writes) }
    }
}

final class StartupStore: IdentityStore {
    enum Failure: Sendable { case key, recognition, trust, policy, save }
    let seed: HostIdentity
    let audit: StoreAudit
    let failure: Failure?
    let slowKey: Bool
    var record: Data?
    var devices: [PairedDevice]
    var summary: String { "in the startup fixture" }
    var testDirectory: URL? { nil }

    init(seed: HostIdentity, audit: StoreAudit, devices: [PairedDevice], record: Data?,
         failure: Failure? = nil, slowKey: Bool = false) {
        self.seed = seed; self.audit = audit; self.devices = devices; self.record = record
        self.failure = failure; self.slowKey = slowKey
    }
    func loadOrCreateKey() throws -> SecKey {
        audit.read("key")
        // Models the synchronous system authorization wait without touching any real keychain.
        if slowKey { audit.waitForMainActor() }
        if failure == .key { throw IdentityStoreError("key unavailable") }
        return seed.remote.privateKey
    }
    func loadOrCreateRecognitionKey() throws -> Data {
        audit.read("recognition")
        if failure == .recognition { throw IdentityStoreError("recognition unavailable") }
        return seed.recognitionKey
    }
    func loadPaired() throws -> [PairedDevice] {
        audit.read("trust")
        if failure == .trust { throw IdentityStoreError("trust unavailable") }
        return devices
    }
    func savePaired(_ value: [PairedDevice]) throws { audit.write(); devices = value }
    func loadRequirePairing() throws -> Data? {
        audit.read("policy")
        if failure == .policy { throw IdentityStoreError("policy unavailable") }
        return record
    }
    func saveRequirePairing(_ value: Data) throws {
        audit.write()
        if failure == .save { throw IdentityStoreError("save unavailable") }
        record = value
    }
}

@main
struct IdentityStartupChecks {
    @MainActor
    static func main() async {
        var checks = 0
        func check(_ condition: @autoclosure () -> Bool, _ description: String) {
            checks += 1
            precondition(condition(), description)
        }
        let seedStore = MemoryIdentityStore()
        let seedRemote = RemoteAccess(store: seedStore)
        guard let seed = seedRemote.identity,
              seedRemote.saveRequirePairing(true) == nil,
              let signedOn = try? seedStore.loadRequirePairing(),
              seedRemote.saveRequirePairing(false) == nil,
              let signedOff = try? seedStore.loadRequirePairing() else {
            fatalError("Could not make an in-memory test identity")
        }
        let device = PairedDevice(fingerprint: Base64URL.encode(Data(repeating: 3, count: 32)),
                                  name: "Duo fixture", model: nil, pairedAt: 1, method: "qr")
        let expectedPrefixes = [RemoteIdentity.shortName(Data(repeating: 3, count: 32))]
        let audit = StoreAudit()
        let pulse = Task { @MainActor in
            while !Task.isCancelled {
                if audit.acknowledgeWaitingRead() { return }
                try? await Task.sleep(for: .milliseconds(5))
            }
        }
        let remote = await RemoteAccess.load(store: StartupStore(seed: seed, audit: audit, devices: [device],
                                                                  record: signedOff, slowKey: true))
        pulse.cancel()
        check(audit.mainActorWasResponsive, "a blocked identity read must leave the main actor responsive")
        check(audit.snapshot.mainReads == 0, "every startup store read stays off the main thread")
        check(audit.snapshot.calls == ["key", "recognition", "trust", "policy"], "identity and initial policy both preload")
        check(remote.identity?.fingerprint == seed.fingerprint && remote.identity?.macID == seed.macID,
              "bootstrap preserves the host key and existing pins")
        check(remote.pairedPrefixes == expectedPrefixes, "bootstrap preserves the existing trusted key")
        check(remote.identityProblem == nil, "a readable store remains available")
        check(!remote.storedRequirePairing(), "a valid host-signed policy survives startup")
        check(audit.snapshot.calls.count == 4, "the app's first policy lookup cannot block on a second read")
        check(audit.snapshot.writes == 0, "startup never rewrites identities, trust or policy")

        for failure in [StartupStore.Failure.key, .recognition, .trust] {
            let failedAudit = StoreAudit()
            let failed = await RemoteAccess.load(store: StartupStore(seed: seed, audit: failedAudit, devices: [device],
                                                                      record: signedOff, failure: failure))
            check(failed.identity == nil && failed.identityProblem != nil && failed.pairedPrefixes.isEmpty,
                  "an unreadable identity or trust list closes access")
            check(failed.storedRequirePairing(), "failed bootstrap never opens unpaired access")
            check(failed.saveRequirePairing(false) != nil && failedAudit.snapshot.writes == 0,
                  "failed bootstrap cannot overwrite the store")
            check(failedAudit.snapshot.mainReads == 0, "failure handling must also stay off the main thread")
            check(failedAudit.snapshot.calls.filter { $0 == "key" }.count == 1,
                  "a read failure must not silently create a replacement identity")
        }

        let policyAudit = StoreAudit()
        let unreadablePolicy = await RemoteAccess.load(store: StartupStore(seed: seed, audit: policyAudit, devices: [device],
                                                                            record: signedOff, failure: .policy))
        check(unreadablePolicy.identity?.fingerprint == seed.fingerprint && unreadablePolicy.pairedPrefixes == expectedPrefixes,
              "a policy failure retains the valid host and paired devices")
        check(unreadablePolicy.storedRequirePairing(), "an unreadable policy requires pairing")
        check(policyAudit.snapshot.mainReads == 0 && policyAudit.snapshot.writes == 0,
              "policy failure never blocks UI or rewrites the policy")

        for record in [nil, Data("0".utf8)] as [Data?] {
            let safe = await RemoteAccess.load(store: StartupStore(seed: seed, audit: StoreAudit(), devices: [device], record: record))
            check(safe.storedRequirePairing(), "a missing or unsigned policy requires pairing")
        }
        let changed = await RemoteAccess.load(store: StartupStore(seed: seed, audit: StoreAudit(), devices: [device], record: signedOff))
        check(changed.saveRequirePairing(true) == nil && changed.storedRequirePairing(),
              "a user change supersedes the preloaded policy before its first read")
        let denied = await RemoteAccess.load(store: StartupStore(seed: seed, audit: StoreAudit(), devices: [device],
                                                                  record: signedOn, failure: .save))
        check(denied.saveRequirePairing(false) != nil && denied.storedRequirePairing(),
              "a denied save cannot disable pairing")
        print("Identity startup: \(checks) checks passed; main actor acknowledged the blocked identity read")
    }
}
