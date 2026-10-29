#!/bin/bash
# Copyright 2026 DUO你电脑 contributors. SPDX-License-Identifier: Apache-2.0
set -euo pipefail
cd "$(dirname "$0")/../../.."
if [[ -f Local/developer-env.sh ]]; then source Local/developer-env.sh; fi
[[ $# == 1 ]] || { echo "usage: $0 NEW_OUTPUT_DIRECTORY" >&2; exit 64; }
out="$1"
mkdir "$out"
swiftc -O -emit-library -emit-module -module-name StreamProtocol \
  Sources/StreamProtocol/StreamMessage.swift Sources/StreamProtocol/TouchBar.swift \
  -emit-module-path "$out/StreamProtocol.swiftmodule" -o "$out/libStreamProtocol.dylib"
swiftc -swift-version 5 -O -whole-module-optimization -warnings-as-errors -parse-as-library \
  -I "$out" -L "$out" -lStreamProtocol -Xlinker -rpath -Xlinker "$out" \
  Sources/SillHost/TouchBarCapturedFrame.swift Sources/SillHost/TouchBarCaptureSource.swift \
  Sources/SillHost/TouchBarSurfaceCopier.swift Sources/SillHost/TouchBarReadOnlySource.swift \
  Sources/SillHost/TouchBarVirtualInput.swift Sources/SillHost/TouchBarVirtualDriver.swift \
  Tests/duodesk/touch-bar-virtual-interaction/main.swift -o "$out/check"
"$out/check"
