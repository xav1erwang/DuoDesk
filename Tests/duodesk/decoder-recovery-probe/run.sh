#!/bin/bash
# Copyright 2026 DUO你电脑 contributors. SPDX-License-Identifier: Apache-2.0
# Drives decoder recovery state in memory; does not start a codec, capture, network, or input.
set -euo pipefail
cd "$(dirname "$0")/../../.."
if [[ -f Local/developer-env.sh ]]; then source Local/developer-env.sh; fi
out="$PWD/.build/duodesk-decoder-recovery-probe"
mkdir -p "$out"
swiftc -O -emit-library -emit-module -module-name StreamProtocol \
  Sources/StreamProtocol/Viewport.swift Sources/StreamProtocol/StreamMessage.swift Sources/StreamProtocol/VideoDecodeBacklog.swift \
  -emit-module-path "$out/StreamProtocol.swiftmodule" -o "$out/libStreamProtocol.dylib"
swiftc -swift-version 5 -O -whole-module-optimization -warnings-as-errors -package-name Sill \
  -Xfrontend -disable-access-control -I "$out" -L "$out" -lStreamProtocol -Xlinker -rpath -Xlinker "$out" \
  iOSClient/HardwareHEVCDecoder.swift Tests/duodesk/decoder-recovery-probe/main.swift -o "$out/check"
"$out/check"
