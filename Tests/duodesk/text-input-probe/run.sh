#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/../../.."
out="$PWD/.build/duodesk-text-input-probe"
app="$out/DUO Text Input Checks.app"
mkdir -p "$app"
if [[ -d "$app/Contents" ]]; then rmdir "$app/Contents"; fi
sdk="$(xcrun --sdk iphonesimulator --show-sdk-path)"
export SDKROOT="$sdk"
swiftc -O -sdk "$sdk" -target arm64-apple-ios27.1-simulator -emit-library -emit-module \
    -module-name StreamProtocol Sources/StreamProtocol/*.swift \
    -Xlinker -install_name -Xlinker @rpath/libStreamProtocol.dylib \
    -emit-module-path "$out/StreamProtocol.swiftmodule" -o "$app/libStreamProtocol.dylib"
swiftc -O -sdk "$sdk" -target arm64-apple-ios27.1-simulator -I "$out" -L "$app" -lStreamProtocol \
    -Xlinker -rpath -Xlinker @executable_path iOSClient/StreamTextInputView.swift iOSClient/KeyChords.swift \
    Tests/duodesk/text-input-probe/ProbeApp.swift -o "$app/Probe"
python3 - "$app/Info.plist" <<'PY'
import plistlib,sys
from pathlib import Path
Path(sys.argv[1]).write_bytes(plistlib.dumps({
    'CFBundleIdentifier':'com.duodesk.tests.NativeTextInput', 'CFBundleExecutable':'Probe',
    'CFBundleName':'DUO Text Input Checks', 'CFBundlePackageType':'APPL',
    'CFBundleDevelopmentRegion':'en',
    'CFBundleVersion':'1','CFBundleShortVersionString':'1.0','MinimumOSVersion':'27.1',
    'UIDeviceFamily':[1,2], 'UILaunchScreen':{},
    'CFBundleSupportedPlatforms':['iPhoneSimulator'],'DTPlatformName':'iphonesimulator',
    'UIApplicationSceneManifest':{'UIApplicationSupportsMultipleScenes':False}}))
PY
codesign --force --sign - --timestamp=none "$app/libStreamProtocol.dylib"
codesign --force --sign - --timestamp=none "$app"
echo "Built: $app"
