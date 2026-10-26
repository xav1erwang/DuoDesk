#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/../../.."
out="$PWD/.build/duodesk-display-probe"
mkdir -p "$out"
swiftc -emit-library -emit-module -module-name StreamProtocol Sources/StreamProtocol/Viewport.swift Sources/StreamProtocol/StreamMessage.swift \
    -emit-module-path "$out/StreamProtocol.swiftmodule" -o "$out/libStreamProtocol.dylib"
swiftc -I "$out" -L "$out" -lStreamProtocol -Xlinker -rpath -Xlinker "$out" \
    Sources/SillHost/VirtualDisplay.swift Sources/SillHost/DuoDesktopDisplay.swift \
    Tests/duodesk/display-probe/main.swift -o "$out/probe"
"$out/probe" "$@"
