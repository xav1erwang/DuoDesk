#!/bin/bash
# Copyright 2026 DUO你电脑 contributors. SPDX-License-Identifier: Apache-2.0
# Fake capture runner and synthetic child only; never launches real screen capture.
set -euo pipefail
cd "$(dirname "$0")/../../.."
if [[ -f Local/developer-env.sh ]]; then source Local/developer-env.sh; fi
[[ $# -eq 1 ]] || { echo "usage: $0 NEW_OUTPUT_DIRECTORY" >&2; exit 64; }
out="$1"
mkdir "$out"
swiftc -O -emit-library -emit-module -module-name StreamProtocol \
  Sources/StreamProtocol/StreamMessage.swift Sources/StreamProtocol/TouchBar.swift \
  -emit-module-path "$out/StreamProtocol.swiftmodule" -o "$out/libStreamProtocol.dylib"
swiftc -O Tests/duodesk/touch-bar-screenshot/SyntheticChild.swift -o "$out/synthetic-child"
swiftc -swift-version 5 -O -whole-module-optimization -warnings-as-errors -parse-as-library \
  -D DUO_TOUCH_BAR_STILL_TESTING -I "$out" -L "$out" -lStreamProtocol -Xlinker -rpath -Xlinker "$PWD/$out" \
  Sources/SillHost/TouchBarCapturedFrame.swift Sources/SillHost/TouchBarCaptureSource.swift \
  Sources/SillHost/TouchBarSurfaceCopier.swift Sources/SillHost/TouchBarReadOnlySource.swift \
  Sources/SillHost/TouchBarScreenshotDriver.swift Tests/duodesk/touch-bar-screenshot/main.swift -o "$out/check"
"$out/check" "$PWD/$out/synthetic-child"
