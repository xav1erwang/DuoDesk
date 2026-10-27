#!/bin/bash
# Copyright 2026 DUO你电脑 contributors. SPDX-License-Identifier: Apache-2.0
# Real hardware HEVC with one output callback held by a test-only shim. No screen, input or network.
set -euo pipefail
cd "$(dirname "$0")/../../.."
if [[ -f Local/developer-env.sh ]]; then source Local/developer-env.sh; fi
out="$PWD/.build/duodesk-decoder-stall-probe"
mkdir -p "$out"
python3 - "$out/HardwareHEVCDecoder-fault.swift" <<'PY'
from pathlib import Path
import sys
source = Path('iOSClient/HardwareHEVCDecoder.swift').read_text()
original = 'self?.decoded(image, status: status, flags: flags, flight: flight, pts: pts)'
replacement = 'DecoderFault.hold { [weak self] in self?.decoded(image, status: status, flags: flags, flight: flight, pts: pts) }'
assert source.count(original) == 1
Path(sys.argv[1]).write_text(source.replace(original, replacement))
PY
swiftc -O -emit-library -emit-module -module-name StreamProtocol Sources/StreamProtocol/*.swift \
  -emit-module-path "$out/StreamProtocol.swiftmodule" -o "$out/libStreamProtocol.dylib"
swiftc -swift-version 5 -O -whole-module-optimization -warnings-as-errors -parse-as-library -package-name Sill \
  -Xfrontend -disable-access-control -I "$out" -L "$out" -lStreamProtocol -Xlinker -rpath -Xlinker "$out" \
  Sources/SillHost/*.swift "$out/HardwareHEVCDecoder-fault.swift" \
  Tests/duodesk/decoder-stall-probe/main.swift -o "$out/check"
if [[ "${1:-}" != "--build-only" ]]; then "$out/check" "$@"; fi
