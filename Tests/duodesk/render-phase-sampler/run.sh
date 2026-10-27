#!/bin/bash
# Copyright 2026 DUO你电脑 contributors. SPDX-License-Identifier: Apache-2.0
set -euo pipefail
cd "$(dirname "$0")/../../.."
if [[ -f Local/developer-env.sh ]]; then source Local/developer-env.sh; fi
out="$PWD/.build/duodesk-render-phase-sampler"
mkdir -p "$out"
swiftc -swift-version 5 -O -warnings-as-errors -parse-as-library \
  Tests/duodesk/own-window-capture/RenderPhaseTrace.swift Tests/duodesk/render-phase-sampler/main.swift -o "$out/check"
"$out/check"
