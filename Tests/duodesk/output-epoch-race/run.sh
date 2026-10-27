#!/bin/bash
# Copyright 2026 DUO你电脑 contributors. SPDX-License-Identifier: Apache-2.0
# Inject a pause between the decoder's final ticket check and the router; no codec or network.
set -euo pipefail
cd "$(dirname "$0")/../../.."
if [[ -f Local/developer-env.sh ]]; then source Local/developer-env.sh; fi
out="$PWD/.build/duodesk-output-epoch-race"
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
swiftc -O -emit-library -emit-module -module-name StreamProtocol \
  Sources/StreamProtocol/Viewport.swift Sources/StreamProtocol/StreamMessage.swift Sources/StreamProtocol/VideoDecodeBacklog.swift \
  -emit-module-path "$out/StreamProtocol.swiftmodule" -o "$out/libStreamProtocol.dylib"
swiftc -swift-version 5 -O -whole-module-optimization -warnings-as-errors -package-name Sill \
  -Xfrontend -disable-access-control -I "$out" -L "$out" -lStreamProtocol -Xlinker -rpath -Xlinker "$out" \
  "$out/HardwareHEVCDecoder-paused.swift" iOSClient/HardwareDecoderRouter.swift \
  Tests/duodesk/output-epoch-race/main.swift -o "$out/check"
if [[ "${1:-}" != "--build-only" ]]; then "$out/check" "$@"; fi
