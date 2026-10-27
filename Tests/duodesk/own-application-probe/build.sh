#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/../../.."
if [[ -f Local/developer-env.sh ]]; then source Local/developer-env.sh; fi
out="$PWD/.build/duodesk-own-application-probe"
app="$out/DUO Privacy Probe.app"
mkdir -p "$app/Contents/MacOS" "$app/Contents/Frameworks"
swiftc -O -emit-library -emit-module -module-name StreamProtocol Sources/StreamProtocol/*.swift \
  -emit-module-path "$out/StreamProtocol.swiftmodule" -Xlinker -install_name -Xlinker '@rpath/libStreamProtocol.dylib' \
  -o "$app/Contents/Frameworks/libStreamProtocol.dylib"
swiftc -O -package-name Sill -I "$out" -L "$app/Contents/Frameworks" -lStreamProtocol \
  -Xlinker -rpath -Xlinker '@executable_path/../Frameworks' \
  Sources/SillHost/Stats.swift Sources/SillHost/InstalledApps.swift Sources/SillHost/WindowCatalog.swift \
  Tests/duodesk/own-application-probe/main.swift -o "$app/Contents/MacOS/OwnApplicationProbe"
python3 - "$app/Contents/Info.plist" <<'PY'
import plistlib,sys
from pathlib import Path
Path(sys.argv[1]).write_bytes(plistlib.dumps({
 'CFBundleIdentifier':'com.duodesk.tests.OwnApplicationProbe', 'CFBundleExecutable':'OwnApplicationProbe',
 'CFBundleName':'DUO Privacy Probe', 'CFBundlePackageType':'APPL', 'CFBundleVersion':'1',
 'NSPrincipalClass':'NSApplication', 'NSHighResolutionCapable':True, 'LSMinimumSystemVersion':'27.0'}))
PY
codesign --force --sign - --timestamp=none "$app/Contents/Frameworks/libStreamProtocol.dylib"
codesign --force --sign - --timestamp=none "$app"
codesign --verify --strict "$app"
