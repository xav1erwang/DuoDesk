#!/bin/bash
# Copyright 2026 DUO你电脑 contributors. SPDX-License-Identifier: Apache-2.0
# Isolated policy check; no capture, display change, network or simulator.
set -euo pipefail
cd "$(dirname "$0")/../../.."
if [[ -f Local/developer-env.sh ]]; then source Local/developer-env.sh; fi
out="$PWD/.build/duodesk-frame-rate-policy"
mkdir -p "$out"
swiftc -emit-library -emit-module -module-name StreamProtocol Sources/StreamProtocol/Input.swift Sources/StreamProtocol/Viewport.swift Sources/StreamProtocol/StreamMessage.swift Sources/StreamProtocol/VideoDecodeBacklog.swift Sources/StreamProtocol/VideoStreamEpoch.swift \
  -emit-module-path "$out/StreamProtocol.swiftmodule" -o "$out/libStreamProtocol.dylib"
swiftc -I "$out" -L "$out" -lStreamProtocol -Xlinker -rpath -Xlinker "$out" \
  iOSClient/DuoControlModel.swift iOSClient/KeyChords.swift Tests/duodesk/frame-rate-policy/main.swift -o "$out/check"
"$out/check"
