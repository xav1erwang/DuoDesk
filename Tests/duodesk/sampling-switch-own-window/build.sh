#!/bin/bash
# Copyright 2026 DUO你电脑 contributors. SPDX-License-Identifier: Apache-2.0
# Builds a standalone own-window check from an archived source snapshot; does not launch it.
set -euo pipefail
cd "$(dirname "$0")/../../.."
if [[ -f Local/developer-env.sh ]]; then source Local/developer-env.sh; fi
[[ $# -eq 1 ]] || { printf 'usage: %s NEW_OUTPUT_DIRECTORY\n' "$0" >&2; exit 64; }
out="$1"
mkdir "$out"
python3 - "$out/source" <<'PY'
from pathlib import Path
import hashlib, json, shutil, sys
root = Path.cwd()
snapshot = Path(sys.argv[1])
files = sorted((root / 'Sources/StreamProtocol').glob('*.swift')) + sorted((root / 'Sources/SillHost').glob('*.swift'))
files += [root / path for path in [
    'iOSClient/HardwareHEVCDecoder.swift',
    'Tests/duodesk/capture-probe/PixelMotionAudit.swift',
    'Tests/duodesk/picker-capture-probe/FrameAudit.swift',
    'Tests/duodesk/picker-capture-probe/DesktopContentAudit.swift',
    'Tests/duodesk/native-document-workload/DocumentWorkload.swift',
    'Tests/duodesk/sampling-switch-own-window/main.swift',
    'Tests/duodesk/sampling-switch-own-window/build.sh',
]]
manifest = {}
for source in files:
    relative = source.relative_to(root)
    target = snapshot / relative
    target.parent.mkdir(parents=True, exist_ok=True)
    shutil.copyfile(source, target)
    manifest[str(relative)] = hashlib.sha256(target.read_bytes()).hexdigest()
(snapshot / 'SHA256.json').write_text(json.dumps(manifest, ensure_ascii=False, indent=2) + '\n')
PY
src="$out/source"
app="$out/DUO Sampling Switch Own Window.app"
mkdir -p "$app/Contents/MacOS" "$app/Contents/Frameworks"
swiftc -O -emit-library -emit-module -module-name StreamProtocol "$src"/Sources/StreamProtocol/*.swift \
  -emit-module-path "$out/StreamProtocol.swiftmodule" -Xlinker -install_name -Xlinker '@rpath/libStreamProtocol.dylib' \
  -o "$app/Contents/Frameworks/libStreamProtocol.dylib"
swiftc -swift-version 5 -O -warnings-as-errors -D DUO_DISPLAY_RESTORE_TESTING -D DUO_CAPTURE_DIAGNOSTICS -package-name Sill \
  -I "$out" -L "$app/Contents/Frameworks" -lStreamProtocol -Xlinker -rpath -Xlinker '@executable_path/../Frameworks' \
  "$src"/Sources/SillHost/*.swift "$src/iOSClient/HardwareHEVCDecoder.swift" \
  "$src/Tests/duodesk/capture-probe/PixelMotionAudit.swift" \
  "$src/Tests/duodesk/picker-capture-probe/FrameAudit.swift" \
  "$src/Tests/duodesk/picker-capture-probe/DesktopContentAudit.swift" \
  "$src/Tests/duodesk/native-document-workload/DocumentWorkload.swift" \
  "$src/Tests/duodesk/sampling-switch-own-window/main.swift" -o "$app/Contents/MacOS/SamplingSwitch"
python3 - "$app/Contents/Info.plist" <<'PY'
import plistlib, sys
from pathlib import Path
Path(sys.argv[1]).write_bytes(plistlib.dumps({
    'CFBundleIdentifier': 'com.duodesk.tests.SamplingSwitchOwn20261029',
    'CFBundleExecutable': 'SamplingSwitch', 'CFBundleName': 'DUO Sampling Switch Own Window',
    'CFBundlePackageType': 'APPL', 'CFBundleVersion': '1', 'NSPrincipalClass': 'NSApplication',
    'NSHighResolutionCapable': True, 'LSMinimumSystemVersion': '27.0'}))
PY
codesign --force --sign - --timestamp=none "$app/Contents/Frameworks/libStreamProtocol.dylib"
codesign --force --sign - --timestamp=none "$app"
codesign --verify --deep --strict "$app"
printf 'Built %s from archived sources; not launched\n' "$app"
