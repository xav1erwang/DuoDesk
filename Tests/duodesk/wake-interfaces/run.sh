#!/bin/bash
set -euo pipefail
root="$(cd "$(dirname "$0")/../../.." && pwd)"
out="$root/.build/duodesk-wake-interfaces"
mkdir -p "$out"
swiftc -emit-library -emit-module -module-name StreamProtocol "$root"/Sources/StreamProtocol/*.swift \
    -emit-module-path "$out/StreamProtocol.swiftmodule" -o "$out/libStreamProtocol.dylib"
swiftc -I "$out" -L "$out" -lStreamProtocol -Xlinker -rpath -Xlinker "$out" \
    "$root/Sources/SillHost/OriginPolicy.swift" "$root/Sources/SillHost/InterfaceSnapshot.swift" \
    "$root/Sources/SillHost/WakeInterfaces.swift" "$root/Tests/duodesk/wake-interfaces/main.swift" -o "$out/check"
"$out/check"
