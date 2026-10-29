#!/bin/bash
# Copyright 2026 DUO你电脑 contributors. SPDX-License-Identifier: Apache-2.0
set -euo pipefail
cd "$(dirname "$0")/../../.."
if [[ -f Local/developer-env.sh ]]; then source Local/developer-env.sh; fi
[[ $# -ge 1 && $# -le 2 ]] || { echo "usage: $0 NEW_OUTPUT_DIRECTORY [--mode-only]" >&2; exit 64; }
out="$1"
mode="${2:-}"
[[ -z "$mode" || "$mode" == "--mode-only" ]] || { echo "unknown mode" >&2; exit 64; }
mkdir "$out"
swiftc -O -emit-library -emit-module -module-name StreamProtocol Sources/StreamProtocol/*.swift \
  -emit-module-path "$out/StreamProtocol.swiftmodule" -o "$out/libStreamProtocol.dylib"
common=(-swift-version 5 -O -whole-module-optimization -warnings-as-errors -parse-as-library -package-name Sill \
  -Xfrontend -disable-access-control -I "$out" -L "$out" -lStreamProtocol -Xlinker -rpath -Xlinker "$out")
swiftc "${common[@]}" Sources/SillHost/*.swift Tests/duodesk/native-higher-resolution/main.swift -o "$out/mode-check"
"$out/mode-check"
if [[ "$mode" == "--mode-only" ]]; then exit 0; fi
swiftc "${common[@]}" Sources/SillHost/HEVCEncoder.swift Sources/SillHost/EncoderMailbox.swift \
  Sources/SillHost/EncoderSlowState.swift Sources/SillHost/Stats.swift iOSClient/HardwareHEVCDecoder.swift \
  iOSClient/HardwareDecoderRouter.swift Tests/duodesk/native-higher-resolution/hardware.swift -o "$out/hardware-check"
"$out/hardware-check"
