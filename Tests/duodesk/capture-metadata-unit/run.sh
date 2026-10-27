#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/../../.."
if [[ -f Local/developer-env.sh ]]; then source Local/developer-env.sh; fi
out="$PWD/.build/duodesk-capture-metadata-unit"
mkdir -p "$out"
swiftc -O -D DUO_CAPTURE_DIAGNOSTICS -package-name Sill \
  Sources/SillHost/Stats.swift Sources/SillHost/CaptureFramePacer.swift Sources/SillHost/WindowCapture.swift \
  Tests/duodesk/capture-metadata-unit/main.swift -o "$out/check"
"$out/check"
