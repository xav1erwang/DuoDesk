#!/bin/bash
# Copyright 2026 DUO你电脑 contributors. SPDX-License-Identifier: Apache-2.0
set -euo pipefail
cd "$(dirname "$0")/../../.."
if [[ -f Local/developer-env.sh ]]; then source Local/developer-env.sh; fi
[[ $# -eq 1 ]] || { echo "usage: $0 NEW_OUTPUT_DIRECTORY" >&2; exit 64; }
out="$1"
mkdir "$out"
app="$out/DUO Odd Buffer Fixture.app"
mkdir -p "$app/Contents/MacOS" "$app/Contents/Frameworks"
swiftc -O -emit-library -emit-module -module-name StreamProtocol Sources/StreamProtocol/*.swift \
  -emit-module-path "$out/StreamProtocol.swiftmodule" -Xlinker -install_name -Xlinker '@rpath/libStreamProtocol.dylib' \
  -o "$app/Contents/Frameworks/libStreamProtocol.dylib"
swiftc -swift-version 5 -O -warnings-as-errors -parse-as-library -package-name Sill -I "$out" -L "$app/Contents/Frameworks" -lStreamProtocol \
  -Xlinker -rpath -Xlinker '@executable_path/../Frameworks' \
  Sources/SillHost/Stats.swift Sources/SillHost/CaptureFramePacer.swift Sources/SillHost/WindowCapture.swift \
  Sources/SillHost/NativeDesktopPadder.swift Sources/SillHost/HEVCEncoder.swift Sources/SillHost/EncoderMailbox.swift \
  Sources/SillHost/EncoderSlowState.swift iOSClient/HardwareHEVCDecoder.swift iOSClient/HardwareDecoderRouter.swift \
  Tests/duodesk/native-odd-desktop/owned-window.swift -o "$app/Contents/MacOS/OddBufferFixture"
python3 - "$app/Contents/Info.plist" <<'PY'
import plistlib, sys
from pathlib import Path
Path(sys.argv[1]).write_bytes(plistlib.dumps({
 'CFBundleIdentifier': 'com.duodesk.tests.OddBufferFixture', 'CFBundleExecutable': 'OddBufferFixture',
 'CFBundleName': 'DUO Odd Buffer Fixture', 'CFBundlePackageType': 'APPL', 'CFBundleVersion': '1',
 'NSPrincipalClass': 'NSApplication', 'NSHighResolutionCapable': True, 'LSMinimumSystemVersion': '27.0'}))
PY
codesign --force --sign - --timestamp=none "$app/Contents/Frameworks/libStreamProtocol.dylib"
codesign --force --sign - --timestamp=none "$app"
codesign --verify --deep --strict "$app"
echo "Built: $app"
