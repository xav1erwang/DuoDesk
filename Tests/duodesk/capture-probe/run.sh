#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/../../.."
out="$PWD/.build/duodesk-capture-probe"
mkdir -p "$out"
swiftc -emit-library -emit-module -module-name StreamProtocol Sources/StreamProtocol/Viewport.swift Sources/StreamProtocol/StreamMessage.swift \
    -emit-module-path "$out/StreamProtocol.swiftmodule" -o "$out/libStreamProtocol.dylib"
swiftc -O -I "$out" -L "$out" -lStreamProtocol -Xlinker -rpath -Xlinker "$out" \
    Sources/SillHost/VirtualDisplay.swift Sources/SillHost/DisplayRestoreIdentity.swift Sources/SillHost/DuoDesktopDisplay.swift \
    Tests/duodesk/capture-probe/PixelMotionAudit.swift Tests/duodesk/capture-probe/main.swift -o "$out/probe"
if [[ "${1:-}" != "--build-only" ]]; then "$out/probe" "$@"; fi
