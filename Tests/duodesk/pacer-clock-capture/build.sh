#!/bin/bash
# Copyright 2026 DUO你电脑 contributors. SPDX-License-Identifier: Apache-2.0
# The fixture selects only its own window. No permission request or display mode change.
set -euo pipefail
cd "$(dirname "$0")/../../.."
if [[ -f Local/developer-env.sh ]]; then source Local/developer-env.sh; fi
out="$PWD/.build/duodesk-pacer-clock-capture"
app="$out/DUO Pacer Clock Check.app"
mkdir -p "$app/Contents/MacOS"
swiftc -swift-version 5 -O -whole-module-optimization -warnings-as-errors -package-name Sill -Xfrontend -disable-access-control \
  Sources/SillHost/Stats.swift Sources/SillHost/CaptureFramePacer.swift Sources/SillHost/WindowCapture.swift \
  Tests/duodesk/native-document-workload/DocumentWorkload.swift Tests/duodesk/pacer-clock-capture/main.swift \
  -o "$app/Contents/MacOS/PacerClockCheck"
python3 - "$app/Contents/Info.plist" <<'PY'
import plistlib, sys
from pathlib import Path
Path(sys.argv[1]).write_bytes(plistlib.dumps({
    'CFBundleIdentifier': 'com.duodesk.tests.PacerClockCheck', 'CFBundleExecutable': 'PacerClockCheck',
    'CFBundleName': 'DUO Pacer Clock Check', 'CFBundlePackageType': 'APPL', 'CFBundleVersion': '1',
    'NSPrincipalClass': 'NSApplication', 'NSHighResolutionCapable': True, 'LSMinimumSystemVersion': '27.0'}))
PY
codesign --force --sign - --timestamp=none "$app"
codesign --verify --strict "$app"
