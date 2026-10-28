#!/bin/bash
# Copyright 2026 DUO你电脑 contributors. SPDX-License-Identifier: Apache-2.0
# Build only: this command never launches the diagnostic or invokes the private runtime.
set -euo pipefail
cd "$(dirname "$0")/../../.."
if [[ -f Local/developer-env.sh ]]; then source Local/developer-env.sh; fi
out="$PWD/.build/duodesk-touch-bar-virtual-probe"
mkdir -p "$out"
swiftc -O -emit-library -emit-module -module-name StreamProtocol \
  Sources/StreamProtocol/StreamMessage.swift Sources/StreamProtocol/TouchBar.swift \
  -emit-module-path "$out/StreamProtocol.swiftmodule" -o "$out/libStreamProtocol.dylib"
swiftc -swift-version 5 -O -whole-module-optimization -warnings-as-errors -parse-as-library \
  -I "$out" -L "$out" -lStreamProtocol -Xlinker -rpath -Xlinker "$out" \
  Sources/SillHost/TouchBarCapturedFrame.swift Sources/SillHost/TouchBarCaptureSource.swift \
  Sources/SillHost/TouchBarSurfaceCopier.swift Sources/SillHost/TouchBarReadOnlySource.swift \
  Sources/SillHost/TouchBarVirtualDriver.swift Tests/duodesk/touch-bar-virtual-probe/main.swift -o "$out/probe"
echo "Built $out/probe; no diagnostic started."
