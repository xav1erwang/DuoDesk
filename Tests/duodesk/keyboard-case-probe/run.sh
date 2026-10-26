#!/bin/bash
# Copyright 2026 DUO你电脑 contributors. SPDX-License-Identifier: Apache-2.0
set -euo pipefail
cd "$(dirname "$0")/../../.."
out="$PWD/.build/duodesk-keyboard-case-probe"
mkdir -p "$out"
swiftc -emit-library -emit-module -module-name StreamProtocol Sources/StreamProtocol/*.swift \
    -emit-module-path "$out/StreamProtocol.swiftmodule" -o "$out/libStreamProtocol.dylib"
flags=(-swift-version 5)
if [[ "${1:-}" == "--legacy" ]]; then flags+=(-D DUO_LEGACY_CAPS); fi
swiftc -package-name sill -I "$out" -L "$out" -lStreamProtocol -Xlinker -rpath -Xlinker "$out" \
    "${flags[@]}" iOSClient/DuoControlModel.swift iOSClient/KeyChords.swift Sources/SillHost/KeyStrokes.swift \
    Tests/duodesk/keyboard-case-probe/main.swift -o "$out/checks"
"$out/checks"
