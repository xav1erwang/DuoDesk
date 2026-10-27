#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/../../.."
if [[ -f Local/developer-env.sh ]]; then source Local/developer-env.sh; fi
out="$PWD/.build/duodesk-capture-frame-pacer"
mkdir -p "$out"
swiftc -O Sources/SillHost/CaptureFramePacer.swift Tests/duodesk/capture-frame-pacer/main.swift -o "$out/check"
"$out/check"
