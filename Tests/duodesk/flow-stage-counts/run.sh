#!/bin/bash
# Copyright 2026 DUO你电脑 contributors. SPDX-License-Identifier: Apache-2.0
set -euo pipefail
cd "$(dirname "$0")/../../.."
if [[ -f Local/developer-env.sh ]]; then source Local/developer-env.sh; fi
out="$PWD/.build/duodesk-flow-stage-counts"
mkdir -p "$out"
swiftc -O Tests/duodesk/own-window-capture/FlowStageCounts.swift Tests/duodesk/flow-stage-counts/main.swift -o "$out/check"
"$out/check"
