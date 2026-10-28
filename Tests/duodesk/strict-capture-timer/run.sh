#!/bin/bash
# Copyright 2026 DUO你电脑 contributors. SPDX-License-Identifier: Apache-2.0
set -euo pipefail
cd "$(dirname "$0")/../../.."
if [[ -f Local/developer-env.sh ]]; then source Local/developer-env.sh; fi
out="$PWD/.build/duodesk-strict-capture-timer"
mkdir -p "$out"
swiftc -swift-version 5 -O -warnings-as-errors -D DUO_CAPTURE_DIAGNOSTICS \
  Sources/SillHost/StrictCaptureTimer.swift Tests/duodesk/strict-capture-timer/main.swift -o "$out/check"
if [[ "${1:-}" != "--build-only" ]]; then "$out/check"; fi
