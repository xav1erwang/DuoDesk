#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/../../.."
if [[ -f Local/developer-env.sh ]]; then source Local/developer-env.sh; fi
out="$PWD/.build/duodesk-desktop-content-audit"
mkdir -p "$out"
swiftc -O -parse-as-library Tests/duodesk/capture-probe/PixelMotionAudit.swift \
  Tests/duodesk/picker-capture-probe/FrameAudit.swift Tests/duodesk/picker-capture-probe/DesktopContentAudit.swift \
  Tests/duodesk/desktop-content-audit/Harness.swift -o "$out/check"
"$out/check"
