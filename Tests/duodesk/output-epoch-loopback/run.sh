#!/bin/bash
# Copyright 2026 DUO你电脑 contributors. SPDX-License-Identifier: Apache-2.0
# Native-size synthetic video through hardware HEVC and local QUIC; no capture, input or UI.
set -euo pipefail
cd "$(dirname "$0")/../../.."
if [[ -f Local/developer-env.sh ]]; then source Local/developer-env.sh; fi
out="$PWD/.build/duodesk-output-epoch-loopback"
mkdir -p "$out"
python3 - "$out/HardwareHEVCDecoder-paused.swift" <<'PY'
from pathlib import Path
import sys
source = Path('iOSClient/HardwareHEVCDecoder.swift').read_text()
needle = 'if canOutput(token) { onSample(sample, token, flight.outputPermit) }'
replacement = 'if canOutput(token) { EpochFault.beforeRouter(); onSample(sample, token, flight.outputPermit) }'
assert source.count(needle) == 1
Path(sys.argv[1]).write_text(source.replace(needle, replacement))
PY
swiftc -O -emit-library -emit-module -module-name StreamProtocol Sources/StreamProtocol/*.swift \
  -emit-module-path "$out/StreamProtocol.swiftmodule" -o "$out/libStreamProtocol.dylib"
swiftc -swift-version 5 -O -whole-module-optimization -warnings-as-errors -parse-as-library -package-name Sill \
  -Xfrontend -disable-access-control -I "$out" -L "$out" -lStreamProtocol -Xlinker -rpath -Xlinker "$out" \
  Sources/SillHost/*.swift "$out/HardwareHEVCDecoder-paused.swift" iOSClient/HardwareDecoderRouter.swift \
  Tests/duodesk/own-window-capture/LoopbackVideo.swift Tests/duodesk/output-epoch-loopback/main.swift -o "$out/check"
if [[ "${1:-}" != "--build-only" ]]; then SILL_TEST_LOOPBACK=1 "$out/check" "$@"; fi
