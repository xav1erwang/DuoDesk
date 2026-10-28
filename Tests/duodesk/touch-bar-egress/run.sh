#!/bin/bash
# Copyright 2026 DUO你电脑 contributors. SPDX-License-Identifier: Apache-2.0
set -euo pipefail
cd "$(dirname "$0")/../../.."
if [[ -f Local/developer-env.sh ]]; then source Local/developer-env.sh; fi
out="$PWD/.build/duodesk-touch-bar-egress"
mkdir -p "$out"
python3 - "$out/LoopbackTouchBar.swift" <<'PY'
from pathlib import Path
import sys
source = Path('Tests/duodesk/own-window-capture/LoopbackVideo.swift').read_text()
needle = 'case .frame: decoder.enqueue(payload, isKeyframe: header.isKeyframe)\n                default: break'
assert source.count(needle) == 1
source = source.replace(needle, 'case .frame: decoder.enqueue(payload, isKeyframe: header.isKeyframe)\n                case .touchBarFrame: TouchBarObserver.shared.receive(payload)\n                default: break')
Path(sys.argv[1]).write_text(source)
PY
swiftc -O -emit-library -emit-module -module-name StreamProtocol Sources/StreamProtocol/*.swift \
  -emit-module-path "$out/StreamProtocol.swiftmodule" -o "$out/libStreamProtocol.dylib"
swiftc -swift-version 5 -O -whole-module-optimization -warnings-as-errors -parse-as-library -package-name Sill \
  -Xfrontend -disable-access-control -I "$out" -L "$out" -lStreamProtocol -Xlinker -rpath -Xlinker "$out" \
  Sources/SillHost/*.swift iOSClient/HardwareHEVCDecoder.swift iOSClient/HardwareDecoderRouter.swift \
  "$out/LoopbackTouchBar.swift" Tests/duodesk/touch-bar-egress/main.swift -o "$out/check"
SILL_TEST_LOOPBACK=1 "$out/check"
