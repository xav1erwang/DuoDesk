#!/bin/bash
# Copyright 2026 DUO你电脑 contributors. SPDX-License-Identifier: Apache-2.0
# Hardware codec and QUIC loopback only: synthetic pixel buffers, in-memory identities, no UI.
set -euo pipefail
cd "$(dirname "$0")/../../.."
if [[ -f Local/developer-env.sh ]]; then source Local/developer-env.sh; fi
out="$PWD/.build/duodesk-decoder-recovery-loopback"
mkdir -p "$out"
swiftc -O -emit-library -emit-module -module-name StreamProtocol Sources/StreamProtocol/*.swift \
  -emit-module-path "$out/StreamProtocol.swiftmodule" -o "$out/libStreamProtocol.dylib"
swiftc -swift-version 5 -O -whole-module-optimization -warnings-as-errors -parse-as-library -package-name Sill \
  -Xfrontend -disable-access-control -I "$out" -L "$out" -lStreamProtocol -Xlinker -rpath -Xlinker "$out" \
  Sources/SillHost/*.swift iOSClient/HardwareHEVCDecoder.swift Tests/duodesk/own-window-capture/LoopbackVideo.swift \
  Tests/duodesk/decoder-recovery-loopback/main.swift -o "$out/check"
if [[ "${1:-}" != "--build-only" ]]; then SILL_TEST_LOOPBACK=1 "$out/check" "$@"; fi
