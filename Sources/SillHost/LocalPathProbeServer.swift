// Copyright 2026 DUO你电脑 contributors. SPDX-License-Identifier: Apache-2.0
import Foundation
import Network
import StreamProtocol

/// Authenticated echo connections stay outside StreamServer's viewers: they cannot wake a display,
/// change its mode, receive clipboard/catalog/video, post input or disturb an existing viewer.
/// All methods and callbacks run on the server's network queue.
final class LocalPathProbeServer {
    private struct Peer {
        let connection: NWConnection
        let route: ClientRoute
        let permits: () -> Bool
        let ended: () -> Void
        let deadline: DispatchWorkItem
    }
    private let queue: DispatchQueue
    private var peers: [ObjectIdentifier: Peer] = [:]
    var launchID = UUID().uuidString

    init(queue: DispatchQueue) { self.queue = queue }

    func serve(_ connection: NWConnection, route: ClientRoute,
               permits: @escaping () -> Bool, ended: @escaping () -> Void) {
        guard permits() else { connection.cancel(); ended(); return }
        let id = ObjectIdentifier(connection)
        let deadline = DispatchWorkItem { [weak self] in self?.close(id) }
        peers[id] = Peer(connection: connection, route: route, permits: permits, ended: ended, deadline: deadline)
        connection.stateUpdateHandler = { [weak self] state in
            switch state {
            case .failed, .cancelled: self?.close(id)
            default: break
            }
        }
        connection.pathUpdateHandler = { [weak self] _ in
            guard let self, let peer = peers[id], !peer.permits() else { return }
            close(id)
        }
        let reply = StreamMessage(kind: .hello, timestamp: Date().timeIntervalSince1970, isKeyframe: false,
                                  payload: Wire.encode(LocalPathProbeReply(launchID: launchID)))
        connection.send(content: reply.serialized(), completion: .contentProcessed { [weak self] error in
            if error != nil { self?.close(id) }
        })
        read(id)
        queue.asyncAfter(deadline: .now() + 5, execute: deadline)
    }

    func close(where matches: (ClientRoute, NWConnection) -> Bool) {
        let ids = peers.compactMap { matches($0.value.route, $0.value.connection) ? $0.key : nil }
        ids.forEach(close)
    }

    private func close(_ id: ObjectIdentifier) {
        guard let peer = peers.removeValue(forKey: id) else { return }
        peer.deadline.cancel()
        peer.connection.stateUpdateHandler = nil
        peer.connection.pathUpdateHandler = nil
        peer.connection.cancel()
        peer.ended()
    }

    private func read(_ id: ObjectIdentifier) {
        guard let peer = peers[id] else { return }
        let connection = peer.connection
        connection.receive(minimumIncompleteLength: StreamMessage.headerLength, maximumLength: StreamMessage.headerLength) { [weak self] data, _, _, _ in
            guard let self, peers[id] != nil else { return }
            guard peer.permits(), let data, let header = StreamMessage.parseHeader(data),
                  header.kind == .ping, header.payloadLength > 0, header.payloadLength <= 16_384 else {
                close(id); return
            }
            connection.receive(minimumIncompleteLength: header.payloadLength, maximumLength: header.payloadLength) { [weak self] data, _, _, _ in
                guard let self, peers[id] != nil else { return }
                guard peer.permits(), let data, data.count == header.payloadLength else { close(id); return }
                let pong = StreamMessage(kind: .pong, timestamp: header.timestamp, isKeyframe: false, payload: data)
                connection.send(content: pong.serialized(), completion: .contentProcessed { [weak self] error in
                    if error != nil { self?.close(id) }
                })
                read(id)
            }
        }
    }
}
