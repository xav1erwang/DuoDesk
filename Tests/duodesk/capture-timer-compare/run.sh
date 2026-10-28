#!/bin/bash
# Copyright 2026 DUO你电脑 contributors. SPDX-License-Identifier: Apache-2.0
# Isolated dispatch timers; no display, screen capture, network, or input injection.
set -euo pipefail
cd "$(dirname "$0")/../../.."
if [[ -f Local/developer-env.sh ]]; then source Local/developer-env.sh; fi
out="$PWD/.build/duodesk-capture-timer-compare"
mkdir -p "$out"
swiftc -swift-version 6 -O -warnings-as-errors Tests/duodesk/capture-timer-compare/main.swift -o "$out/timer-comparison"
if [[ "${1:-}" != "--build-only" ]]; then "$out/timer-comparison" "$@"; fi
