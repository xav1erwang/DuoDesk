#!/bin/bash
# Copyright 2026 DUO你电脑 contributors. SPDX-License-Identifier: Apache-2.0
# Isolated protocol and contact ownership checks; no capture, network or system input.
set -euo pipefail
cd "$(dirname "$0")/../../.."
if [[ -f Local/developer-env.sh ]]; then source Local/developer-env.sh; fi
out="$PWD/.build/duodesk-touch-bar-contract"
mkdir -p "$out"
swiftc -emit-library -emit-module -module-name StreamProtocol \
  Sources/StreamProtocol/StreamMessage.swift Sources/StreamProtocol/Switcher.swift \
  Sources/StreamProtocol/TouchBar.swift -emit-module-path "$out/StreamProtocol.swiftmodule" \
  -o "$out/libStreamProtocol.dylib"
swiftc -I "$out" -L "$out" -lStreamProtocol -Xlinker -rpath -Xlinker "$out" \
  Sources/SillHost/TouchBarTouchGate.swift Tests/duodesk/touch-bar-contract/main.swift -o "$out/check"
"$out/check"
