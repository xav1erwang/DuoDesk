#!/bin/bash
# Copyright 2026 DUO你电脑 contributors. SPDX-License-Identifier: Apache-2.0
# Builds and runs a loopback-only, silent TCP peer test with ephemeral in-memory identities.
set -euo pipefail
cd "$(dirname "$0")/../../.."
if [[ -f Local/developer-env.sh ]]; then source Local/developer-env.sh; fi
if [[ $# -ne 1 ]]; then echo "usage: $0 NEW_OUTPUT_DIRECTORY" >&2; exit 64; fi
out="$1"
mkdir "$out"
swiftc -O -emit-library -emit-module -module-name StreamProtocol Sources/StreamProtocol/*.swift \
  -emit-module-path "$out/StreamProtocol.swiftmodule" -o "$out/libStreamProtocol.dylib"
swiftc -swift-version 5 -O -warnings-as-errors -parse-as-library -I "$out" -L "$out" -lStreamProtocol \
  -Xlinker -rpath -Xlinker "$out" iOSClient/DeviceTLS.swift iOSClient/SavedMacs.swift \
  iOSClient/RemoteDialPolicy.swift iOSClient/RemoteConnector.swift \
  Tests/duodesk/remote-handshake-deadline/main.swift -o "$out/check"
"$out/check"
