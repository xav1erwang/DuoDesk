#!/bin/bash
# Copyright 2026 DUO你电脑 contributors. SPDX-License-Identifier: Apache-2.0
# Compile a test-only app; it captures only its own fixture window, without a permission request.
set -euo pipefail
cd "$(dirname "$0")/../../.."
if [[ -f Local/developer-env.sh ]]; then source Local/developer-env.sh; fi
out="$PWD/.build/duodesk-pacer-real-capture"
app="$out/DUO Pacer Capture Check.app"
mkdir -p "$app/Contents/MacOS" "$app/Contents/Frameworks"
swiftc -O -emit-library -emit-module -module-name StreamProtocol Sources/StreamProtocol/*.swift \
  -emit-module-path "$out/StreamProtocol.swiftmodule" -Xlinker -install_name -Xlinker '@rpath/libStreamProtocol.dylib' \
  -o "$app/Contents/Frameworks/libStreamProtocol.dylib"
# Access control is disabled only for this fixture to observe the real held sample and invoke
# the production callback; no test hook or reduced access is added to the shipping build.
swiftc -swift-version 5 -O -whole-module-optimization -warnings-as-errors -package-name Sill -Xfrontend -disable-access-control \
  -I "$out" -L "$app/Contents/Frameworks" -lStreamProtocol \
  -Xlinker -rpath -Xlinker '@executable_path/../Frameworks' \
  Sources/SillHost/*.swift Tests/duodesk/native-document-workload/DocumentWorkload.swift \
  Tests/duodesk/own-window-capture/VirtualWindowDisplay.swift Tests/duodesk/pacer-real-capture/main.swift \
  -o "$app/Contents/MacOS/PacerCaptureCheck"
python3 - "$app/Contents/Info.plist" <<'PY'
import plistlib, sys
from pathlib import Path
Path(sys.argv[1]).write_bytes(plistlib.dumps({
    'CFBundleIdentifier': 'com.duodesk.tests.PacerCaptureCheck', 'CFBundleExecutable': 'PacerCaptureCheck',
    'CFBundleName': 'DUO Pacer Capture Check', 'CFBundlePackageType': 'APPL', 'CFBundleVersion': '1',
    'NSPrincipalClass': 'NSApplication', 'NSHighResolutionCapable': True, 'LSMinimumSystemVersion': '27.0'}))
PY
codesign --force --sign - --timestamp=none "$app/Contents/Frameworks/libStreamProtocol.dylib"
codesign --force --sign - --timestamp=none "$app"
codesign --verify --strict "$app"
