#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/../../.."
if [[ -f Local/developer-env.sh ]]; then source Local/developer-env.sh; fi
app="$PWD/.build/duodesk-native-document/DUO Document Workload.app"
mkdir -p "$app/Contents/MacOS"
swiftc -O Tests/duodesk/native-document-workload/*.swift -o "$app/Contents/MacOS/DocumentWorkload"
python3 - "$app/Contents/Info.plist" <<'PY'
import plistlib, sys
from pathlib import Path
Path(sys.argv[1]).write_bytes(plistlib.dumps({
 'CFBundleIdentifier': 'com.duodesk.tests.NativeDocument', 'CFBundleExecutable': 'DocumentWorkload',
 'CFBundleName': 'DUO Document Workload', 'CFBundlePackageType': 'APPL', 'CFBundleVersion': '1',
 'NSPrincipalClass': 'NSApplication', 'NSHighResolutionCapable': True, 'LSMinimumSystemVersion': '27.0'}))
PY
codesign --force --sign - --timestamp=none "$app"
codesign --verify --strict "$app"
