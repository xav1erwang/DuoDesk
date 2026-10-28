#!/bin/bash
# Copyright 2026 DUO你电脑 contributors. SPDX-License-Identifier: Apache-2.0
set -euo pipefail
cd "$(dirname "$0")/../../.."
if [[ -f Local/developer-env.sh ]]; then source Local/developer-env.sh; fi
out="$PWD/.build/duodesk-touch-bar-inbox"
mkdir -p "$out"
swiftc -emit-library -emit-module -module-name StreamProtocol Sources/StreamProtocol/*.swift \
  -emit-module-path "$out/StreamProtocol.swiftmodule" -o "$out/libStreamProtocol.dylib"
swiftc -swift-version 5 -warnings-as-errors -parse-as-library -I "$out" -L "$out" -lStreamProtocol \
  -Xlinker -rpath -Xlinker "$out" iOSClient/DuoTouchBarInbox.swift Tests/duodesk/touch-bar-inbox/main.swift -o "$out/check"
"$out/check"
