#!/bin/bash
# Copyright 2026 DUO你电脑 contributors. SPDX-License-Identifier: Apache-2.0
set -euo pipefail
cd "$(dirname "$0")/../../.."
if [[ -f Local/developer-env.sh ]]; then source Local/developer-env.sh; fi
if [[ $# -ne 1 || -e "$1" ]]; then
    echo "usage: $0 NEW_OUTPUT_DIRECTORY" >&2
    exit 64
fi
out="$1"
mkdir -p "$out"
swiftc -O -emit-library -emit-module -module-name StreamProtocol Sources/StreamProtocol/*.swift \
  -emit-module-path "$out/StreamProtocol.swiftmodule" -o "$out/libStreamProtocol.dylib"
swiftc -O -D DUO_DISPLAY_RESTORE_TESTING -I "$out" -L "$out" -lStreamProtocol -Xlinker -rpath -Xlinker "$out" \
  Sources/SillHost/VirtualDisplay.swift Sources/SillHost/DisplayRestoreIdentity.swift \
  Sources/SillHost/DisplayRecoveryStore.swift Sources/SillHost/DuoDesktopDisplay.swift Sources/SillHost/DesktopWindowHandoff.swift Sources/SillHost/WindowSizer.swift Sources/SillHost/WindowRestore.swift \
  Tests/duodesk/display-rejected-restore/main.swift -o "$out/check"
"$out/check"
