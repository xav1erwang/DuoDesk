#!/bin/bash
# Copyright 2026 DUO你电脑 contributors. SPDX-License-Identifier: Apache-2.0
# Production callback state regression, without recording or a system permission request.
set -euo pipefail
cd "$(dirname "$0")/../../.."
swift build -c release --product SillMenuBar
bin="$(swift build -c release --product SillMenuBar --show-bin-path)"
package_name="$(swift package show-dependencies --format json | python3 -c 'import json,sys; print(json.load(sys.stdin)["identity"])')"
out="$PWD/.build/duodesk-capture-lifecycle-probe"
mkdir -p "$out"
if [ -f "$bin/SillHostCore.o" ]; then
    modules="$bin"
    protocol_objects=("$bin/StreamProtocol.o")
else
    modules="$bin/Modules"
    protocol_objects=("$bin/StreamProtocol.build/"*.o)
fi
# Only the test compilation can access private state, to drive the real delegate entry points.
# Compile the unmodified host sources in the same test module: importing private stored-property
# offsets from a release module triggers an LLVM verifier error in Swift 6.4. Keep the host's
# Swift 5 language mode, production visibility, installation and security settings unchanged.
swiftc -swift-version 5 -warnings-as-errors -parse-as-library -whole-module-optimization \
    -module-name SillHostCore -Xfrontend -disable-access-control -package-name "$package_name" -I "$modules" \
    Sources/SillHost/*.swift Tests/duodesk/capture-lifecycle-probe/main.swift \
    "${protocol_objects[@]}" -o "$out/checks"
if [[ "${1:-}" != "--build-only" ]]; then SILL_TEST_LOOPBACK=1 "$out/checks"; fi
