#!/bin/bash
# Copyright 2026 DUO你电脑 contributors. SPDX-License-Identifier: Apache-2.0
set -euo pipefail
cd "$(dirname "$0")/../../.."
if [[ -f Local/developer-env.sh ]]; then source Local/developer-env.sh; fi
[[ $# -eq 1 ]] || { echo "usage: $0 NEW_OUTPUT_DIRECTORY" >&2; exit 64; }
out="$1"
mkdir "$out"
swiftc -O -emit-library -emit-module -module-name StreamProtocol Sources/StreamProtocol/*.swift \
  -emit-module-path "$out/StreamProtocol.swiftmodule" -o "$out/libStreamProtocol.dylib"
swiftc -swift-version 5 -O -whole-module-optimization -warnings-as-errors -parse-as-library -package-name Sill \
  -Xfrontend -disable-access-control -I "$out" -L "$out" -lStreamProtocol -Xlinker -rpath -Xlinker "$out" \
  Sources/SillHost/*.swift iOSClient/HardwareHEVCDecoder.swift Tests/duodesk/own-window-capture/LoopbackVideo.swift \
  Tests/duodesk/native-odd-desktop/loopback.swift -o "$out/check"
SILL_TEST_LOOPBACK=1 "$out/check"
