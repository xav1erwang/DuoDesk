#!/bin/bash
# Copyright 2026 DUO你电脑 contributors. SPDX-License-Identifier: Apache-2.0
# Owned AVFoundation window with an injected suspension before one receiver enqueue.
set -euo pipefail
cd "$(dirname "$0")/../../.."
if [[ -f Local/developer-env.sh ]]; then source Local/developer-env.sh; fi
out="$PWD/.build/duodesk-presenter-epoch-flush"
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
source = source.replace(needle, 'await ReceiverFault.gate.beforeFlush(remove)\n                ' + needle)
Path(sys.argv[1]).write_text(source)
PY
swiftc -O -emit-library -emit-module -module-name StreamProtocol \
  Sources/StreamProtocol/Viewport.swift Sources/StreamProtocol/StreamMessage.swift Sources/StreamProtocol/VideoDecodeBacklog.swift \
  -emit-module-path "$out/StreamProtocol.swiftmodule" -o "$out/libStreamProtocol.dylib"
swiftc -swift-version 5 -O -whole-module-optimization -warnings-as-errors -parse-as-library -package-name Sill \
  -Xfrontend -disable-access-control -I "$out" -L "$out" -lStreamProtocol -Xlinker -rpath -Xlinker "$out" \
  iOSClient/HardwareHEVCDecoder.swift iOSClient/HardwareDecoderRouter.swift "$out/HardwareVideoPresenter-held.swift" \
  Tests/duodesk/presenter-epoch-flush/main.swift -o "$out/check"
if [[ "${1:-}" != "--build-only" ]]; then "$out/check" "$@"; fi
