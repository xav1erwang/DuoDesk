import Foundation
import Network
import StreamProtocol

/// A QUIC companion on the TCP door's existing port (UDP and TCP have separate port spaces).
/// The TCP door remains the discovery and compatibility endpoint. This listener owns no session:
/// Door owns admission and each accepted tunnel until its only stream ends.
/// All calls and callbacks run on the server's network queue.
final class QUICDoorListener {
    private let door: Door
    private let queue: DispatchQueue
    private let loopback: Bool
    private let label: String
    private var listener: NWListener?
    private var port: NWEndpoint.Port?
    private var peerToPeer = false
    private var retry: DispatchWorkItem?

    init(door: Door, queue: DispatchQueue, loopback: Bool, label: String) {
        self.door = door; self.queue = queue; self.loopback = loopback; self.label = label
    }

    func set(port: NWEndpoint.Port?, peerToPeer: Bool = false) {
        if self.port == port, self.peerToPeer == peerToPeer, listener != nil { return }
        retry?.cancel(); retry = nil
        listener?.cancel(); listener = nil
        self.port = port; self.peerToPeer = peerToPeer
        if port != nil { start() }
    }

    func retryNow() {
        if port != nil, listener == nil { retry?.cancel(); retry = nil; start() }
    }

    private func start() {
        guard let port, listener == nil else { return }
        let parameters = RemoteTLS.quicParameters(options: door.quicOptions(), peerToPeer: peerToPeer)
        let incoming: NWListener
        do {
            if loopback {
                StreamServer.bindToLoopback(parameters, port: port)
                incoming = try NWListener(using: parameters)
            } else {
                incoming = try NWListener(using: parameters, on: port)
            }
        } catch { failed(error); return }
        listener = incoming
        let acceptsPeerToPeer = peerToPeer
        incoming.newConnectionGroupHandler = { [weak self, weak incoming] group in
            guard let self, let incoming, self.listener === incoming else { group.cancel(); return }
            self.door.accept(group, peerToPeer: acceptsPeerToPeer)
        }
        incoming.stateUpdateHandler = { [weak self, weak incoming] state in
            guard let self, let incoming, self.listener === incoming else { return }
            switch state {
            case .ready:
                print("\(self.label) QUIC: listening on UDP port \(port.rawValue) (mutual TLS 1.3).")
            case .failed(let error):
                incoming.cancel(); self.listener = nil; self.failed(error)
            case .waiting(let error):
                if case .posix(.EADDRINUSE) = error {
                    incoming.cancel(); self.listener = nil; self.failed(error)
                }
            default: break
            }
        }
        incoming.start(queue: queue)
    }

    private func failed(_ error: Error) {
        print("\(label) QUIC could not start (\(error)); retrying in 30 s.")
        retry?.cancel()
        let item = DispatchWorkItem { [weak self] in self?.start() }
        retry = item
        queue.asyncAfter(deadline: .now() + 30, execute: item)
    }
}
