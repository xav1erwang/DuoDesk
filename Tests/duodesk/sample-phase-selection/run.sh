#!/bin/bash
# Copyright 2026 DUO你电脑 contributors. SPDX-License-Identifier: Apache-2.0
set -euo pipefail
cd "$(dirname "$0")/../../.."
if [[ -f Local/developer-env.sh ]]; then source Local/developer-env.sh; fi
out="$PWD/.build/duodesk-sample-phase-selection"
mkdir -p "$out"
swiftc -O Tests/duodesk/own-window-capture/PhaseSelection.swift Tests/duodesk/sample-phase-selection/main.swift -o "$out/check"
"$out/check"
