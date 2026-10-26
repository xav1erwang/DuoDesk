#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/../../.."
out="$PWD/.build/duodesk-presenter-lifecycle"
mkdir -p "$out"
swiftc -O -swift-version 6 -strict-concurrency=complete -warnings-as-errors -parse-as-library \
    iOSClient/HardwareVideoPresenter.swift Tests/duodesk/presenter-lifecycle-probe/main.swift -o "$out/checks"
if [[ "${1:-}" != "--build-only" ]]; then "$out/checks"; fi
