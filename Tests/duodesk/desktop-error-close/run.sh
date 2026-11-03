#!/bin/bash
# Copyright 2026 DUO你电脑 contributors. SPDX-License-Identifier: Apache-2.0
# Test-only private access; the synthetic host binds 127.0.0.1 only and sends no input.
set -euo pipefail
cd "$(dirname "$0")/../../.."
if [[ -f Local/developer-env.sh ]]; then source Local/developer-env.sh; fi
if [[ $# -ne 1 || -e "$1" ]]; then
    echo "usage: $0 NEW_OUTPUT_DIRECTORY" >&2
    exit 64
fi
out="$1"
mkdir "$out"
swiftc -O -emit-library -emit-module -module-name StreamProtocol Sources/StreamProtocol/*.swift \
    -emit-module-path "$out/StreamProtocol.swiftmodule" -o "$out/libStreamProtocol.dylib"
swiftc -swift-version 5 -O -parse-as-library -whole-module-optimization \
    -Xfrontend -disable-access-control -package-name Sill -I "$out" -L "$out" -lStreamProtocol \
    -Xlinker -rpath -Xlinker "$out" Sources/SillHost/*.swift \
    Tests/duodesk/desktop-error-close/main.swift -o "$out/check"
SILL_TEST_LOOPBACK=1 "$out/check"
