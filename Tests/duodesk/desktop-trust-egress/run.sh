#!/bin/bash
# Copyright 2026 DUO你电脑 contributors. SPDX-License-Identifier: Apache-2.0
set -euo pipefail
cd "$(dirname "$0")/../../.."
if [[ -f Local/developer-env.sh ]]; then source Local/developer-env.sh; fi
[[ $# -ge 1 && $# -le 2 ]] || { echo "usage: $0 NEW_OUTPUT_DIRECTORY [--quic|--remote-internet]" >&2; exit 64; }
out="$1"
mode="${2:-}"
[[ -z "$mode" || "$mode" == "--quic" || "$mode" == "--remote-internet" ]] || { echo "unknown mode" >&2; exit 64; }
mkdir "$out"
python3 - "$out/LoopbackVideo.swift" "$mode" <<'PY'
from pathlib import Path
import sys
source = Path('Tests/duodesk/own-window-capture/LoopbackVideo.swift').read_text()
replacements = {
    'trust.update { $0.paired[device.fingerprint] = "Own local test" }': '''trust.update {
            if ProcessInfo.processInfo.environment["DUO_TEST_UNPAIRED"] == "1" { $0.requirePairing = false }
            else { $0.paired[device.fingerprint] = "Own local test" }
            if ProcessInfo.processInfo.environment["DUO_TEST_REMOTE"] == "1" { $0.remoteAccess = true; $0.internetAccess = true }
        }'''
}
if sys.argv[2] == '':
    replacements.update({
        'RemoteTLS.quicOptions(identity: device.tls': 'RemoteTLS.options(identity: device.tls',
        'RemoteTLS.quicParameters(options: options)': 'RemoteTLS.parameters(tls: options, dialing: true)',
        'connection.metadata(definition: NWProtocolQUIC.definition) != nil': 'connection.metadata(definition: NWProtocolTLS.definition) != nil',
        'OWN LOOPBACK QUIC READY:': 'OWN LOOPBACK TCP READY:'
    })
if sys.argv[2] == '--remote-internet':
    replacements.update({
        'final class LoopbackVideo: @unchecked Sendable {': '''private final class FixturePort: @unchecked Sendable {
    private let lock = NSLock()
    private var port: UInt16?
    var value: UInt16? { lock.withLock { port } }
    func set(_ value: UInt16) { lock.withLock { port = value } }
}
final class LoopbackVideo: @unchecked Sendable {''',
        'private let server: StreamServer\n': 'private let server: StreamServer\n    private var fixtureRemote: RemoteServer?\n',
        '        server.start()\n': '''        let fixturePort = FixturePort()
        let fixtureRemote = RemoteServer(server: server, identity: host, trust: trust)
        fixtureRemote.onListener = { if case .listening(let port) = $0 { fixturePort.set(UInt16(port)) } }
        fixtureRemote.set(wanted: true, port: 0)
        server.start()
''',
        'if let ready = server.port { port = ready; break }': 'if let ready = fixturePort.value { port = ready; break }',
        'let loop = LoopbackVideo(server: server, connection: connection, decoder: decoder, state: state)': 'let loop = LoopbackVideo(server: server, connection: connection, decoder: decoder, state: state)\n        loop.fixtureRemote = fixtureRemote',
        'state.stop(); reader?.cancel(); reader = nil; connection.cancel()': 'state.stop(); fixtureRemote?.set(wanted: false, port: 0); fixtureRemote = nil; reader?.cancel(); reader = nil; connection.cancel()'
    })
for before, after in replacements.items():
    assert source.count(before) == 1
    source = source.replace(before, after)
Path(sys.argv[1]).write_text(source)
PY
swiftc -O -emit-library -emit-module -module-name StreamProtocol Sources/StreamProtocol/*.swift \
  -emit-module-path "$out/StreamProtocol.swiftmodule" -o "$out/libStreamProtocol.dylib"
swiftc -swift-version 5 -O -whole-module-optimization -warnings-as-errors -parse-as-library -package-name Sill \
  -D DUO_DESKTOP_TRUST_TESTING -Xfrontend -disable-access-control -I "$out" -L "$out" -lStreamProtocol \
  -Xlinker -rpath -Xlinker "$out" Sources/SillHost/*.swift iOSClient/HardwareHEVCDecoder.swift \
  "$out/LoopbackVideo.swift" Tests/duodesk/desktop-trust-egress/main.swift -o "$out/check"
SILL_TEST_LOOPBACK=1 SILL_TEST_REMOTE_ORIGIN="$([[ "$mode" == --remote-internet ]] && echo internet || echo loopback)" \
  DUO_TEST_QUIC="$([[ -n "$mode" ]] && echo 1 || echo 0)" DUO_TEST_REMOTE="$([[ "$mode" == --remote-internet ]] && echo 1 || echo 0)" "$out/check"
