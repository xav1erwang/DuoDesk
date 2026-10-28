#!/bin/bash
# Copyright 2026 DUO你电脑 contributors. SPDX-License-Identifier: Apache-2.0
# Compile real host callback source in the test module; never start ScreenCaptureKit.
set -euo pipefail
cd "$(dirname "$0")/../../.."
if [[ -f Local/developer-env.sh ]]; then source Local/developer-env.sh; fi
out="$PWD/.build/duodesk-strict-capture-lifecycle"
mkdir -p "$out"
swiftc -O -emit-library -emit-module -module-name StreamProtocol Sources/StreamProtocol/*.swift \
  -emit-module-path "$out/StreamProtocol.swiftmodule" -Xlinker -install_name -Xlinker '@rpath/libStreamProtocol.dylib' \
  -o "$out/libStreamProtocol.dylib"
swiftc -swift-version 5 -O -D DUO_CAPTURE_DIAGNOSTICS -warnings-as-errors -parse-as-library -whole-module-optimization \
  -Xfrontend -disable-access-control -package-name Sill -I "$out" -L "$out" -lStreamProtocol \
  -Xlinker -rpath -Xlinker '@executable_path' Sources/SillHost/*.swift \
  Tests/duodesk/strict-capture-lifecycle/main.swift -o "$out/check"
if [[ "${1:-}" != "--build-only" ]]; then "$out/check"; fi
