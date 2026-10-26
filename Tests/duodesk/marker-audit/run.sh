#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/../../.."
out="$PWD/.build/duodesk-marker-audit"
mkdir -p "$out"
swiftc -O -swift-version 6 -strict-concurrency=complete -warnings-as-errors -parse-as-library \
    Tests/duodesk/capture-probe/PixelMotionAudit.swift Tests/duodesk/marker-audit/main.swift -o "$out/checks"
"$out/checks"
