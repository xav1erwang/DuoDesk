#!/bin/bash
# Copyright 2026 DUO你电脑 contributors. SPDX-License-Identifier: Apache-2.0
set -euo pipefail
cd "$(dirname "$0")/../../.."
if [[ -f Local/developer-env.sh ]]; then source Local/developer-env.sh; fi
if [[ $# -ne 1 || -e "$1" ]]; then echo "usage: $0 NEW_OUTPUT_DIRECTORY" >&2; exit 64; fi
out="$1"
mkdir "$out"
swiftc -O -emit-library -emit-module -module-name StreamProtocol Sources/StreamProtocol/*.swift \
    -emit-module-path "$out/StreamProtocol.swiftmodule" -o "$out/libStreamProtocol.dylib"
swiftc -swift-version 5 -O -parse-as-library -whole-module-optimization -D DUO_DISPLAY_RESTORE_TESTING \
    -Xfrontend -disable-access-control -package-name Sill -I "$out" -L "$out" -lStreamProtocol \
    -Xlinker -rpath -Xlinker "$out" Sources/SillHost/*.swift \
    Tests/duodesk/current-physical-fallback/main.swift -o "$out/check"
"$out/check"
