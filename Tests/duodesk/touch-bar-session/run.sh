#!/bin/bash
# Copyright 2026 DUO你电脑 contributors. SPDX-License-Identifier: Apache-2.0
set -euo pipefail
cd "$(dirname "$0")/../../.."
if [[ -f Local/developer-env.sh ]]; then source Local/developer-env.sh; fi
[[ $# -le 2 ]] || { echo "usage: $0 [NEW_OUTPUT_DIRECTORY] [--trust-input-only]" >&2; exit 64; }
if [[ $# -ge 1 ]]; then out="$1"; mkdir "$out"; else out="$PWD/.build/duodesk-touch-bar-session"; mkdir -p "$out"; fi
mode="${2:-}"
[[ -z "$mode" || "$mode" == "--trust-input-only" ]] || { echo "unknown mode" >&2; exit 64; }
python3 - "$out/LoopbackTouchBar.swift" <<'PY'
from pathlib import Path
import sys
source = Path('Tests/duodesk/own-window-capture/LoopbackVideo.swift').read_text()
needle = 'case .frame: decoder.enqueue(payload, isKeyframe: header.isKeyframe)\n                default: break'
assert source.count(needle) == 1
source = source.replace(needle, 'case .frame: decoder.enqueue(payload, isKeyframe: header.isKeyframe)\n                case .touchBarFrame: TouchBarObserver.shared.frame(payload)\n                case .touchBarStatus: TouchBarObserver.shared.status(payload)\n                default: break')
Path(sys.argv[1]).write_text(source)
PY
swiftc -O -emit-library -emit-module -module-name StreamProtocol Sources/StreamProtocol/*.swift \
  -emit-module-path "$out/StreamProtocol.swiftmodule" -o "$out/libStreamProtocol.dylib"
swiftc -swift-version 5 -O -whole-module-optimization -warnings-as-errors -parse-as-library -package-name Sill \
  -Xfrontend -disable-access-control -I "$out" -L "$out" -lStreamProtocol -Xlinker -rpath -Xlinker "$out" \
  Sources/SillHost/*.swift iOSClient/HardwareHEVCDecoder.swift iOSClient/HardwareDecoderRouter.swift \
  "$out/LoopbackTouchBar.swift" Tests/duodesk/touch-bar-session/main.swift -o "$out/check"
if [[ -n "$mode" ]]; then SILL_TEST_LOOPBACK=1 "$out/check" "$mode"; else SILL_TEST_LOOPBACK=1 "$out/check"; fi
