#!/bin/bash
# Copyright 2026 DUO你电脑 contributors. SPDX-License-Identifier: Apache-2.0
# Exercise production startup and retry logic with inert test-only SCK entry points.
set -euo pipefail
cd "$(dirname "$0")/../../.."
if [[ -f Local/developer-env.sh ]]; then source Local/developer-env.sh; fi
if [[ $# != 1 ]]; then echo "usage: run.sh NEW_OUTPUT_DIRECTORY" >&2; exit 2; fi
out="$1"
mkdir "$out"
swiftc -swift-version 5 -O -D DUO_CAPTURE_STARTUP_TESTING -warnings-as-errors \
  -parse-as-library -whole-module-optimization -Xfrontend -disable-access-control \
  -package-name Sill Sources/SillHost/WindowCapture.swift Sources/SillHost/CaptureFramePacer.swift \
  Sources/SillHost/CaptureStartupRetry.swift Sources/SillHost/Stats.swift \
  Tests/duodesk/capture-startup-retry/main.swift -o "$out/check"
"$out/check"
