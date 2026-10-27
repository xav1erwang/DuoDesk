#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/../../.."
if [[ -f Local/developer-env.sh ]]; then source Local/developer-env.sh; fi
out="$PWD/.build/duodesk-physical-mode-policy"
mkdir -p "$out"
swiftc -O -emit-library -emit-module -module-name StreamProtocol Sources/StreamProtocol/*.swift \
  -emit-module-path "$out/StreamProtocol.swiftmodule" -o "$out/libStreamProtocol.dylib"
swiftc -O -I "$out" -L "$out" -lStreamProtocol -Xlinker -rpath -Xlinker "$out" \
  Sources/SillHost/VirtualDisplay.swift Sources/SillHost/DisplayRestoreIdentity.swift Sources/SillHost/DisplayRecoveryStore.swift Sources/SillHost/DuoDesktopDisplay.swift \
  Tests/duodesk/physical-mode-policy/main.swift -o "$out/check"
"$out/check"
