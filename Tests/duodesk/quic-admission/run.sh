#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/../../.."
out="$PWD/.build/duodesk-quic-admission"
mkdir -p "$out"
swiftc -O -emit-library -emit-module -module-name StreamProtocol Sources/StreamProtocol/*.swift \
    -emit-module-path "$out/StreamProtocol.swiftmodule" -o "$out/libStreamProtocol.dylib"
swiftc -O -package-name sill -I "$out" -L "$out" -lStreamProtocol -Xlinker -rpath -Xlinker "$out" \
    Sources/SillHost/*.swift iOSClient/DeviceTLS.swift iOSClient/SavedMacs.swift \
    iOSClient/RemoteDialPolicy.swift iOSClient/RemoteConnector.swift \
    Tests/duodesk/quic-admission/main.swift -o "$out/checks"
if [[ "${1:-}" == "--build-only" ]]; then exit; fi
for mode in baseline wrong-server-pin wrong-client-pin wrong-alpn idle-budget stream-limit remote-limit remote-connector-session remote-connector-tcp-session remote-connector-revoked; do
    SILL_TEST_LOOPBACK=1 "$out/checks" "$mode" > "$out/$mode.log" 2>&1 || { cat "$out/$mode.log"; exit 1; }
    tail -n 1 "$out/$mode.log"
done
SILL_TEST_LOOPBACK=1 SILL_TEST_BACKOFF_SECONDS=2 "$out/checks" backoff
SILL_TEST_LOOPBACK=1 "$out/checks" backoff-tcp-recovery
SILL_TEST_LOOPBACK=1 SILL_TEST_ORIGIN=internet "$out/checks" home-internet
SILL_TEST_LOOPBACK=1 SILL_TEST_REMOTE_ORIGIN=internet "$out/checks" remote-internet-off
SILL_TEST_LOOPBACK=1 SILL_TEST_REMOTE_ORIGIN=internet "$out/checks" remote-internet-toggle
SILL_TEST_LOOPBACK=1 SILL_TEST_REMOTE_ORIGIN=internet "$out/checks" remote-internet-outbound-toggle
if [[ "${1:-}" != "--loopback-only" ]]; then
    SILL_TEST_SERVICE_TYPE=_silltest._tcp "$out/checks" bonjour
fi
