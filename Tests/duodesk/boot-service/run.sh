#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/../../.."
out="$PWD/.build/duodesk-boot-service"
mkdir -p "$out"
swiftc -emit-library -emit-module -module-name StreamProtocol Sources/StreamProtocol/*.swift \
    -emit-module-path "$out/StreamProtocol.swiftmodule" -o "$out/libStreamProtocol.dylib"
swiftc -parse-as-library -package-name DuoDeskChecks -I "$out" -L "$out" -lStreamProtocol \
    -Xlinker -rpath -Xlinker "$out" Sources/SillHost/HostIdentity.swift \
    Sources/SillHost/BootService.swift Sources/SillHost/LoginWindowPolicy.swift \
    Tests/duodesk/boot-service/main.swift -o "$out/checks"
"$out/checks"
