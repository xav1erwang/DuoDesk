#!/bin/bash
# Copyright 2026 DUO你电脑 contributors. SPDX-License-Identifier: Apache-2.0
# Builds only. Running the resulting app creates one temporary virtual display and captures
# only its own test window. It never requests Screen Recording or injects input.
set -euo pipefail
cd "$(dirname "$0")/../../.."
if [[ -f Local/developer-env.sh ]]; then source Local/developer-env.sh; fi
if [[ $# -ne 1 || -e "$1" ]]; then
    echo "usage: $0 NEW_OUTPUT_DIRECTORY" >&2
    exit 64
fi
out="$1"
app="$out/DUO Extended Own Capture.app"
mkdir -p "$app/Contents/MacOS" "$app/Contents/Frameworks"
swiftc -O -emit-library -emit-module -module-name StreamProtocol Sources/StreamProtocol/*.swift \
    -emit-module-path "$out/StreamProtocol.swiftmodule" \
    -Xlinker -install_name -Xlinker '@rpath/libStreamProtocol.dylib' \
    -o "$app/Contents/Frameworks/libStreamProtocol.dylib"
swiftc -O -package-name Sill -I "$out" -L "$app/Contents/Frameworks" -lStreamProtocol \
    -Xlinker -rpath -Xlinker '@executable_path/../Frameworks' \
    Sources/SillHost/*.swift iOSClient/HardwareHEVCDecoder.swift \
    Tests/duodesk/extended-owned-capture/main.swift -o "$app/Contents/MacOS/ExtendedOwnCapture"
python3 - "$app/Contents/Info.plist" <<'PY'
import plistlib, sys
from pathlib import Path
Path(sys.argv[1]).write_bytes(plistlib.dumps({
    'CFBundleIdentifier': 'com.duodesk.tests.ExtendedOwnCapture',
    'CFBundleExecutable': 'ExtendedOwnCapture',
    'CFBundleName': 'DUO Extended Own Capture',
    'CFBundlePackageType': 'APPL', 'CFBundleVersion': '1',
    'NSPrincipalClass': 'NSApplication', 'NSHighResolutionCapable': True,
    'LSMinimumSystemVersion': '27.0',
}))
PY
codesign --force --sign - --timestamp=none "$app/Contents/Frameworks/libStreamProtocol.dylib"
codesign --force --sign - --timestamp=none "$app"
codesign --verify --deep --strict "$app"
printf 'Built only: %s\n' "$app"
