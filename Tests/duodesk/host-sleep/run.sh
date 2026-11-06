#!/bin/bash
set -euo pipefail
root="$(cd "$(dirname "$0")/../../.." && pwd)"
out="$root/.build/duodesk-host-sleep"
mkdir -p "$out"
swiftc "$root/Sources/SillMenuBar/HostSleepPolicy.swift" "$root/Tests/duodesk/host-sleep/main.swift" -o "$out/check"
"$out/check"
