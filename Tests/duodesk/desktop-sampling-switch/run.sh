#!/bin/bash
# Copyright 2026 DUO你电脑 contributors. SPDX-License-Identifier: Apache-2.0
# A read-only current mode stands in for virtual/physical state; all writes are intercepted.
set -euo pipefail
cd "$(dirname "$0")/../../.."
if [[ -f Local/developer-env.sh ]]; then source Local/developer-env.sh; fi
[[ $# -eq 1 ]] || { printf 'usage: %s NEW_OUTPUT_DIRECTORY\n' "$0" >&2; exit 64; }
out="$1"
mkdir "$out"
swiftc -O -emit-library -emit-module -module-name StreamProtocol Sources/StreamProtocol/*.swift \
  -emit-module-path "$out/StreamProtocol.swiftmodule" -o "$out/libStreamProtocol.dylib"
swiftc -O -parse-as-library -D DUO_DISPLAY_RESTORE_TESTING -I "$out" -L "$out" -lStreamProtocol -Xlinker -rpath -Xlinker "$out" \
  Sources/SillHost/VirtualDisplay.swift Sources/SillHost/DisplayRestoreIdentity.swift Sources/SillHost/DisplayRecoveryStore.swift \
  Sources/SillHost/DuoDesktopDisplay.swift Sources/SillHost/DesktopWindowHandoff.swift Sources/SillHost/WindowSizer.swift Sources/SillHost/WindowRestore.swift Tests/duodesk/desktop-sampling-switch/main.swift -o "$out/check"
"$out/check"
