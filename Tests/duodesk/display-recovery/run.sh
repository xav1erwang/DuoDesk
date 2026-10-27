#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/../../.."
if [[ -f Local/developer-env.sh ]]; then source Local/developer-env.sh; fi
if [[ $# != 1 || -e "$1" ]]; then echo "Supply a new, unused fixture directory" >&2; exit 2; fi
out="$PWD/.build/duodesk-display-recovery"
mkdir -p "$out"
swiftc -O -warnings-as-errors Sources/SillHost/DisplayRestoreIdentity.swift Sources/SillHost/DisplayRecoveryStore.swift \
  Tests/duodesk/display-recovery/main.swift -o "$out/check"
"$out/check" "$1"
