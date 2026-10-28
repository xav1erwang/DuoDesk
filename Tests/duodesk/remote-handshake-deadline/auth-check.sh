#!/bin/bash
# Copyright 2026 DUO你电脑 contributors. SPDX-License-Identifier: Apache-2.0
# Targeted real TLS/QUIC checks with temporary in-memory identities and loopback listeners only.
set -euo pipefail
cd "$(dirname "$0")/../../.."
if [[ -f Local/developer-env.sh ]]; then source Local/developer-env.sh; fi
if [[ $# -ne 1 ]]; then echo "usage: $0 NEW_OUTPUT_DIRECTORY" >&2; exit 64; fi
out="$1"
mkdir "$out"
swiftc -O -emit-library -emit-module -module-name StreamProtocol Sources/StreamProtocol/*.swift \
  -emit-module-path "$out/StreamProtocol.swiftmodule" -o "$out/libStreamProtocol.dylib"
swiftc -O -package-name sill -I "$out" -L "$out" -lStreamProtocol -Xlinker -rpath -Xlinker "$out" \
  Sources/SillHost/*.swift iOSClient/DeviceTLS.swift iOSClient/SavedMacs.swift \
  iOSClient/RemoteDialPolicy.swift iOSClient/RemoteConnector.swift \
  Tests/duodesk/quic-admission/main.swift -o "$out/check"
for mode in remote-connector-session remote-connector-tcp-session remote-connector-wrong-pin remote-connector-successor-pin remote-connector-revoked; do
  SILL_TEST_LOOPBACK=1 "$out/check" "$mode" > "$out/$mode.log" 2>&1 || { cat "$out/$mode.log"; exit 1; }
  tail -n 1 "$out/$mode.log"
done
