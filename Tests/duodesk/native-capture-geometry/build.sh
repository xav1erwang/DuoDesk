#!/bin/bash
# Copyright 2026 DUO你电脑 contributors. SPDX-License-Identifier: Apache-2.0
set -euo pipefail
cd "$(dirname "$0")/../../.."
if [[ -f Local/developer-env.sh ]]; then source Local/developer-env.sh; fi
[[ $# -eq 1 ]] || { echo "usage: $0 NEW_OUTPUT_DIRECTORY" >&2; exit 64; }
out="$1"
mkdir "$out"
app="$out/DUO Native Geometry Fixture.app"
mkdir -p "$app/Contents/MacOS"
swiftc -swift-version 5 -O -warnings-as-errors -D DUO_CAPTURE_GEOMETRY_TESTING -package-name Sill \
  Sources/SillHost/Stats.swift Sources/SillHost/CaptureFramePacer.swift Sources/SillHost/WindowCapture.swift \
  Tests/duodesk/native-capture-geometry/main.swift -o "$app/Contents/MacOS/NativeGeometryFixture"
python3 - "$app/Contents/Info.plist" <<'PY'
import plistlib, sys
from pathlib import Path
Path(sys.argv[1]).write_bytes(plistlib.dumps({
 'CFBundleIdentifier': 'com.duodesk.tests.NativeGeometryFixture', 'CFBundleExecutable': 'NativeGeometryFixture',
 'CFBundleName': 'DUO Native Geometry Fixture', 'CFBundlePackageType': 'APPL', 'CFBundleVersion': '1',
 'NSPrincipalClass': 'NSApplication', 'NSHighResolutionCapable': True, 'LSMinimumSystemVersion': '27.0'}))
PY
codesign --force --sign - --timestamp=none "$app"
codesign --verify --deep --strict "$app"
echo "Built: $app"
