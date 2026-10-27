#!/bin/bash
# Copyright 2026 DUO你电脑 contributors. SPDX-License-Identifier: Apache-2.0
# One real WindowServer handoff using owned virtual displays; no capture/input grant.
set -euo pipefail
cd "$(dirname "$0")/../../.."
out="$PWD/.build/duodesk-display-handoff-probe"
mkdir -p "$out"
swiftc -emit-library -emit-module -module-name StreamProtocol Sources/StreamProtocol/Viewport.swift Sources/StreamProtocol/StreamMessage.swift \
    -emit-module-path "$out/StreamProtocol.swiftmodule" -o "$out/libStreamProtocol.dylib"
swiftc -I "$out" -L "$out" -lStreamProtocol -Xlinker -rpath -Xlinker "$out" \
    Sources/SillHost/VirtualDisplay.swift Sources/SillHost/DisplayRestoreIdentity.swift Sources/SillHost/DisplayRecoveryStore.swift Sources/SillHost/DuoDesktopDisplay.swift \
    Tests/duodesk/display-handoff-probe/main.swift -o "$out/probe"
if [[ "${1:-}" != "--build-only" ]]; then "$out/probe"; fi
