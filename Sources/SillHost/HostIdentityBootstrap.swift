// Modified for DUO你电脑, 2026. See NOTICE for upstream attribution.
import Foundation
import StreamProtocol

/// An identity store has one owner: bootstrap uses it before transferring it to RemoteAccess.
/// Keychain reads can wait for macOS authorization, so the app loads them off the main actor.
struct HostIdentityBootstrap {
    let identity: HostIdentity?
    let problem: String?
    let keyPlace: String
    let store: (any IdentityStore)?
    let paired: [PairedDevice]
    let initialRequirePairing: Bool?

    init(store: any IdentityStore, preloadPairingPolicy: Bool = false) {
        var identity: HostIdentity?
        var problem: String?
        var paired: [PairedDevice] = []
        do {
            let key = try store.loadOrCreateKey()
            let recognition = try store.loadOrCreateRecognitionKey()
            guard let loaded = HostIdentity(privateKey: key, recognitionKey: recognition) else {
                throw IdentityStoreError("the key could not make a TLS identity")
            }
            paired = try store.loadPaired()
            identity = loaded
        } catch {
            problem = "\(error)"
        }
        self.identity = identity
        self.problem = problem
        keyPlace = store is KeychainIdentityStore ? "in the keychain" : store.summary
        // An unreadable trust list must never be replaced with an empty one on the next pairing.
        self.store = identity == nil ? nil : store
        self.paired = paired
        initialRequirePairing = preloadPairingPolicy
            ? Self.readRequirePairing(store: self.store, identity: identity, keyPlace: keyPlace)
            : nil
    }

    /// `sending` transfers this non-Sendable store instead of sharing mutable storage across
    /// actors. Explicit @concurrent also stays off the caller's actor with newer Swift defaults.
    @concurrent
    static func load(store: sending any IdentityStore) async -> sending HostIdentityBootstrap {
        HostIdentityBootstrap(store: store, preloadPairingPolicy: true)
    }

    static func readRequirePairing(store: (any IdentityStore)?, identity: HostIdentity?, keyPlace: String) -> Bool {
        guard let store, let identity else { return true }
        let record: Data?
        do { record = try store.loadRequirePairing() } catch {
            print("Require pairing: couldn’t read it \(keyPlace) (\(error)); pairing stays required.")
            return true
        }
        guard let record else { return true }
        let on = RequirePairingValue.decode(record, macID: identity.macID,
                                            verify: { identity.verifyRecord($0, signature: $1) })
        if on, record != RequirePairingValue.on {
            print("Require pairing: the setting \(keyPlace) isn’t signed by this Mac’s key; pairing stays required.")
        }
        return on
    }
}
