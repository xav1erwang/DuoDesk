#!/bin/bash
# Copyright 2026 DUO你电脑 contributors. SPDX-License-Identifier: Apache-2.0
# Synthetic native-size video, hardware HEVC, local QUIC and an owned AVFoundation window.
set -euo pipefail
cd "$(dirname "$0")/../../.."
if [[ -f Local/developer-env.sh ]]; then source Local/developer-env.sh; fi
out="$PWD/.build/duodesk-presenter-epoch-integrated"
mkdir -p "$out"
python3 - "$out/HardwareVideoPresenter-held.swift" <<'PY'
from pathlib import Path
import sys
source = Path('iOSClient/HardwareVideoPresenter.swift').read_text()
needle = 'let result = try await receiver.enqueue(ready)'
assert source.count(needle) == 1
source = source.replace(needle, 'try await ReceiverFault.gate.beforeEnqueue(sequence)\n                ' + needle)
needle = 'await receiver.flush(removingDisplayedImage: remove)'
assert source.count(needle) == 1
source = source.replace(needle, 'await ReceiverFault.gate.flushed()\n                ' + needle)
Path(sys.argv[1]).write_text(source)
PY
swiftc -O -emit-library -emit-module -module-name StreamProtocol Sources/StreamProtocol/*.swift \
  -emit-module-path "$out/StreamProtocol.swiftmodule" -o "$out/libStreamProtocol.dylib"
swiftc -swift-version 5 -O -whole-module-optimization -warnings-as-errors -parse-as-library -package-name Sill \
  -Xfrontend -disable-access-control -I "$out" -L "$out" -lStreamProtocol -Xlinker -rpath -Xlinker "$out" \
  Sources/SillHost/*.swift iOSClient/HardwareHEVCDecoder.swift iOSClient/HardwareDecoderRouter.swift \
  "$out/HardwareVideoPresenter-held.swift" Tests/duodesk/own-window-capture/LoopbackVideo.swift \
  Tests/duodesk/presenter-epoch-integrated/main.swift -o "$out/check"
if [[ "${1:-}" != "--build-only" ]]; then SILL_TEST_LOOPBACK=1 "$out/check" "$@"; fi
