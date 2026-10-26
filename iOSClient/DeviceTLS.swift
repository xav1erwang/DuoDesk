// Copyright 2026 DUO你电脑 contributors. SPDX-License-Identifier: Apache-2.0
// Extracted from Sill's home client and adapted for DuoDesk. See NOTICE for upstream attribution.
import Foundation
import Network
import Security
import StreamProtocol

/// Every connection this device opens to a Mac speaks TLS through here (§7.2), at home and away:
/// TLS 1.3 from RemoteTLS with this device's certificate, the Mac's key checked against a pin, or
/// any P-256 key where there is none yet (an open door's first connection, an ask, the typed
/// pairing path from afar). Plain TCP remains only for a plain door, which only a DEBUG build ever
/// dials (DiscoveryPolicy.homeDial).
enum DeviceTLS {
    /// The TLS options of one connection: `alpn` is `sill/1` for a session, `sill-pair/1` for
    /// pairing; `pin` the Mac's key, or nil for any P-256 key (a key of another kind matches
    /// nothing). RemoteConnector's dials from afar use them too. `onPinRefused` runs on `queue`
    /// each time `pin` refuses the key that answered (-9808): a connection to a Bonjour service
    /// whose pin fails is never reported as waiting or failed, it goes back to preparing and tries
    /// again (the simulator against a synthetic host with another key, 2026-09-27: "Connecting to…"
    /// for good, no state after `.preparing`), so a dial that must end at a refused pin hears it
    /// here.
    ///
    /// `alsoAccept`: other saved Macs' keys that may answer in the pin's place at this address
    /// (RemoteDialPolicy.successors: a Mac set up again, whose newer record this device holds too);
    /// the caller reads which key completed the handshake off the ready connection.
    static func options(identity: RemoteIdentity, alpn: String, pin: Data?, queue: DispatchQueue,
                        alsoAccept: [Data] = [], onPinRefused: (() -> Void)? = nil) -> NWProtocolTLS.Options {
        RemoteTLS.options(identity: identity.tls, role: .client(alpn: alpn), queue: queue) { fp, negotiated in
            negotiated == alpn && accepts(fp, pin: pin, alsoAccept: alsoAccept, onPinRefused: onPinRefused)
        }
    }

    private static func accepts(_ fingerprint: Data?, pin: Data?, alsoAccept: [Data], onPinRefused: (() -> Void)?) -> Bool {
        guard let pin else { return fingerprint != nil }
        if let fingerprint, fingerprint != pin, alsoAccept.contains(fingerprint) { return true }
        guard fingerprint == pin else { onPinRefused?(); return false }
        return true
    }

    /// The same trust policy on a reliable QUIC stream. A TCP retry keeps the exact same pin;
    /// transport availability can never change which Mac's key the device accepts.
    static func quic(identity: RemoteIdentity, alpn: String, pin: Data?, queue: DispatchQueue,
                     peerToPeer: Bool = false, alsoAccept: [Data] = [], onPinRefused: (() -> Void)? = nil) -> NWParameters {
        let options = RemoteTLS.quicOptions(identity: identity.tls, role: .client(alpn: alpn), queue: queue) { fp, negotiated in
            negotiated == alpn && accepts(fp, pin: pin, alsoAccept: alsoAccept, onPinRefused: onPinRefused)
        }
        return RemoteTLS.quicParameters(options: options, peerToPeer: peerToPeer)
    }

    /// A connection to a Mac's home door: those TLS options over the device's home TCP (no Nagle;
    /// a connect timeout for a pairing dial), the video service class, and peer-to-peer (AWDL) only
    /// for a Direct row (RemoteTLS.parameters). `ipv6Only` for the ask's dial over a row's wired
    /// interface: the cable counts only over IPv6 link-local, at both ends.
    static func home(identity: RemoteIdentity, alpn: String, pin: Data?, peerToPeer: Bool, queue: DispatchQueue,
                     ipv6Only: Bool = false, connectTimeout: Int? = nil, quic: Bool = false,
                     onPinRefused: (() -> Void)? = nil) -> NWParameters {
        let tcp = NWProtocolTCP.Options()
        tcp.noDelay = true
        if let connectTimeout { tcp.connectionTimeout = connectTimeout }
        let params = quic
            ? self.quic(identity: identity, alpn: alpn, pin: pin, queue: queue, peerToPeer: peerToPeer, onPinRefused: onPinRefused)
            : RemoteTLS.parameters(tls: options(identity: identity, alpn: alpn, pin: pin, queue: queue, onPinRefused: onPinRefused),
                                   tcp: tcp, peerToPeer: peerToPeer)
        if ipv6Only, let ip = params.defaultProtocolStack.internetProtocol as? NWProtocolIP.Options { ip.version = .v6 }
        return params
    }

    /// A plain door's connection, as before pairing at home: TCP without Nagle, the interactive
    /// video class, and peer-to-peer only for a Direct row. Only a DEBUG build dials one.
    static func plain(peerToPeer: Bool) -> NWParameters {
        let tcp = NWProtocolTCP.Options()
        tcp.noDelay = true
        let params = NWParameters(tls: nil, tcp: tcp)
        params.includePeerToPeer = peerToPeer
        // Wi-Fi QoS: video + pointer traffic is latency-sensitive; the access point and the radio
        // treat this class (WMM video) with shorter queues than best-effort.
        params.serviceClass = .interactiveVideo
        return params
    }

    /// Parameters that never connect: TLS whose verify block trusts no key, so the handshake ends
    /// before this device sends anything. For a connection of a TLS session should this device's
    /// key be unreadable (it cannot be: the session's first connection was made with it, and the
    /// identity stays in memory): that connection then fails as any failed one does, and nothing
    /// ever goes out in plain.
    static func refusing(peerToPeer: Bool, queue: DispatchQueue) -> NWParameters {
        let tls = NWProtocolTLS.Options()
        sec_protocol_options_set_verify_block(tls.securityProtocolOptions, { _, _, complete in complete(false) }, queue)
        let tcp = NWProtocolTCP.Options()
        tcp.noDelay = true
        return RemoteTLS.parameters(tls: tls, tcp: tcp, peerToPeer: peerToPeer)
    }
}

