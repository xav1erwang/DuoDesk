#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/../../.."
out="$PWD/.build/duodesk-desktop-fixture"
app="$out/DUO Input Fixture.app"
mkdir -p "$app/Contents/MacOS"
swiftc -O Tests/duodesk/desktop-fixture/*.swift -o "$app/Contents/MacOS/DesktopFixture"
python3 - "$app/Contents/Info.plist" <<'PY'
import plistlib, sys
from pathlib import Path
Path(sys.argv[1]).write_bytes(plistlib.dumps({
    'CFBundleIdentifier': 'com.duodesk.tests.DesktopFixture',
    'CFBundleExecutable': 'DesktopFixture', 'CFBundleName': 'DUO Input Fixture',
    'CFBundlePackageType': 'APPL', 'CFBundleVersion': '1',
    'NSPrincipalClass': 'NSApplication', 'NSHighResolutionCapable': True,
    'LSMinimumSystemVersion': '14.0'}))
PY
codesign --force --sign - --timestamp=none "$app"
if [[ "${1:-}" != "--build-only" ]]; then "$app/Contents/MacOS/DesktopFixture" "$@"; fi
