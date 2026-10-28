#!/bin/bash
# Copyright 2026 DUO你电脑 contributors. SPDX-License-Identifier: Apache-2.0
set -euo pipefail
cd "$(dirname "$0")/../../.."
if [[ -f Local/developer-env.sh ]]; then source Local/developer-env.sh; fi
out="$PWD/.build/duodesk-touch-bar-codec-probe"
mkdir -p "$out"
swiftc -O -emit-library -emit-module -module-name StreamProtocol \
  Sources/StreamProtocol/Viewport.swift Sources/StreamProtocol/StreamMessage.swift \
  -emit-module-path "$out/StreamProtocol.swiftmodule" -o "$out/libStreamProtocol.dylib"
swiftc -O -package-name Sill -I "$out" -L "$out" -lStreamProtocol -Xlinker -rpath -Xlinker "$out" \
  Sources/SillHost/HEVCEncoder.swift Sources/SillHost/EncoderMailbox.swift Sources/SillHost/EncoderSlowState.swift \
  Sources/SillHost/Stats.swift Tests/duodesk/touch-bar-codec-probe/main.swift -o "$out/probe"
"$out/probe"
