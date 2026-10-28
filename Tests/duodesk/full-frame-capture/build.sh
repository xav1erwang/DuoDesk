#!/bin/bash
# Copyright 2026 DUO你电脑 contributors. SPDX-License-Identifier: Apache-2.0
# Builds a new, standalone own-window diagnostic. Does not launch or install it.
set -euo pipefail
cd "$(dirname "$0")/../../.."
if [[ -f Local/developer-env.sh ]]; then source Local/developer-env.sh; fi
if [[ $# -ne 1 ]]; then echo "usage: $0 NEW_OUTPUT_DIRECTORY" >&2; exit 64; fi
out="$1"
mkdir "$out"
app="$out/DUO Full Frame Own Window.app"
mkdir -p "$app/Contents/MacOS"
swiftc -swift-version 5 -O -warnings-as-errors -D DUO_CAPTURE_DIAGNOSTICS -package-name Sill \
  Sources/SillHost/Stats.swift Sources/SillHost/CaptureFramePacer.swift Sources/SillHost/StrictCaptureTimer.swift \
  Sources/SillHost/WindowCapture.swift Tests/duodesk/native-document-workload/DocumentWorkload.swift \
  Tests/duodesk/full-frame-compare/FramePlaneComparison.swift Tests/duodesk/full-frame-capture/FullFrameCaptureStudy.swift \
  Tests/duodesk/full-frame-capture/main.swift -o "$app/Contents/MacOS/FullFrameCapture"
python3 - "$app/Contents/Info.plist" <<'PY'
import plistlib, sys
from pathlib import Path
Path(sys.argv[1]).write_bytes(plistlib.dumps({
    'CFBundleIdentifier': 'com.duodesk.tests.FullFrameOwnWindow', 'CFBundleExecutable': 'FullFrameCapture',
    'CFBundleName': 'DUO Full Frame Own Window', 'CFBundlePackageType': 'APPL', 'CFBundleVersion': '1',
    'NSPrincipalClass': 'NSApplication', 'NSHighResolutionCapable': True, 'LSMinimumSystemVersion': '27.0'}))
PY
codesign --force --sign - --timestamp=none "$app"
codesign --verify --deep --strict "$app"
echo "Built: $app"
