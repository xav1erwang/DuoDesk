#!/bin/bash
# Copyright 2026 DUO你电脑 contributors. SPDX-License-Identifier: Apache-2.0
set -euo pipefail
cd "$(dirname "$0")/../../.."
if [[ -f Local/developer-env.sh ]]; then source Local/developer-env.sh; fi
out="$PWD/.build/duodesk-render-sequence-correlation"
mkdir -p "$out"
swiftc -O -warnings-as-errors Tests/duodesk/own-window-capture/RenderSequenceCorrelation.swift \
  Tests/duodesk/render-sequence-correlation/main.swift -o "$out/check"
"$out/check"
