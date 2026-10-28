#!/bin/bash
# Copyright 2026 DUO你电脑 contributors. SPDX-License-Identifier: Apache-2.0
set -euo pipefail
cd "$(dirname "$0")/../../.."
if [[ -f Local/developer-env.sh ]]; then source Local/developer-env.sh; fi
out="$PWD/.build/duodesk-touch-bar-probe"
mkdir -p "$out"
xcrun clang -fobjc-arc -fblocks -Wall -Wextra -Wno-deprecated-declarations \
  -framework Foundation -framework ApplicationServices -framework CoreGraphics -framework IOSurface \
  Tests/duodesk/touch-bar-probe/main.m -o "$out/probe"
echo "Built $out/probe; no sample started."
