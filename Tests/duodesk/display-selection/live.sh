#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/../../.."
out="$PWD/.build/duodesk-live-display"
mkdir -p "$out"
swiftc -emit-library -emit-module -module-name StreamProtocol Sources/StreamProtocol/*.swift \
  -emit-module-path "$out/StreamProtocol.swiftmodule" -o "$out/libStreamProtocol.dylib"
swiftc Tests/duodesk/display-selection/fixture/main.swift -o "$out/fixture"
swiftc -package-name DuoDesk -I "$out" -L "$out" -lStreamProtocol -Xlinker -rpath -Xlinker "$out" \
  Sources/SillHost/VirtualDisplay.swift Sources/SillHost/DisplayRestoreIdentity.swift Sources/SillHost/DisplayRecoveryStore.swift \
  Sources/SillHost/DuoDesktopDisplay.swift Sources/SillHost/DesktopWindowHandoff.swift Sources/SillHost/WindowSizer.swift Sources/SillHost/WindowRestore.swift Sources/SillHost/ExistingDisplayCapture.swift \
  Sources/SillHost/WindowCatalog.swift Sources/SillHost/Stats.swift Sources/SillHost/InstalledApps.swift \
  Tests/duodesk/display-selection/live/main.swift -o "$out/check"
"$out/check" "$out/fixture" "$@"
