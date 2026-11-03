#!/bin/bash
# Copyright 2026 DUO你电脑 contributors. SPDX-License-Identifier: Apache-2.0
# Test-only private access drives the production coordinator without starting a listener or SCK.
set -euo pipefail
cd "$(dirname "$0")/../../.."
if [[ -f Local/developer-env.sh ]]; then source Local/developer-env.sh; fi
if [[ $# -lt 1 || $# -gt 2 || -e "$1" ]]; then
    echo "usage: $0 NEW_OUTPUT_DIRECTORY [--live-virtual|--failure-only|--launch-only|--retire-only]" >&2
    exit 64
fi
out="$1"
if [[ $# -eq 2 && "$2" != "--live-virtual" && "$2" != "--failure-only" && "$2" != "--launch-only" && "$2" != "--retire-only" ]]; then
    echo "Unknown option: $2" >&2
    exit 64
fi
mkdir "$out"
swiftc -O -emit-library -emit-module -module-name StreamProtocol Sources/StreamProtocol/*.swift \
    -emit-module-path "$out/StreamProtocol.swiftmodule" -o "$out/libStreamProtocol.dylib"
swiftc -swift-version 5 -O -D DUO_DISPLAY_RESTORE_TESTING -parse-as-library -whole-module-optimization \
    -Xfrontend -disable-access-control -package-name Sill -I "$out" -L "$out" -lStreamProtocol \
    -Xlinker -rpath -Xlinker "$out" Sources/SillHost/*.swift \
    Tests/duodesk/extended-switch-race/main.swift -o "$out/check"
"$out/check" "${@:2}"
