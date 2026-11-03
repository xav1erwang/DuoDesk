#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/../../.."
out="$PWD/.build/duodesk-display-picker"
mkdir -p "$out/PickerFixture.app"
sdk="$(xcrun --sdk iphonesimulator --show-sdk-path)"
target=arm64-apple-ios27.0-simulator
xcrun --sdk iphonesimulator swiftc -sdk "$sdk" -target "$target" -emit-module -emit-library -module-name StreamProtocol \
  Sources/StreamProtocol/Display.swift -emit-module-path "$out/StreamProtocol.swiftmodule" -o "$out/PickerFixture.app/libStreamProtocol.dylib"
xcrun --sdk iphonesimulator swiftc -parse-as-library -sdk "$sdk" -target "$target" -I "$out" -L "$out/PickerFixture.app" -lStreamProtocol \
  -Xlinker -rpath -Xlinker @executable_path iOSClient/DisplayPicker.swift Tests/duodesk/display-selection/PickerFixture.swift \
  -o "$out/PickerFixture.app/PickerFixture"
python3 - "$out/PickerFixture.app/Info.plist" <<'PY'
import sys,plistlib,pathlib
pathlib.Path(sys.argv[1]).write_bytes(plistlib.dumps(dict(CFBundleExecutable='PickerFixture',CFBundleIdentifier='com.duodesk.qa.displaypicker',CFBundleName='Display Picker QA',CFBundlePackageType='APPL',CFBundleVersion='1',CFBundleShortVersionString='1',CFBundleSupportedPlatforms=['iPhoneSimulator'],MinimumOSVersion='27.0',UIDeviceFamily=[1,2],UILaunchScreen={},UISupportedInterfaceOrientations=['UIInterfaceOrientationPortrait','UIInterfaceOrientationLandscapeLeft','UIInterfaceOrientationLandscapeRight'],UIApplicationSceneManifest={'UIApplicationSupportsMultipleScenes':False})))
PY
codesign --force --sign - "$out/PickerFixture.app/libStreamProtocol.dylib"
codesign --force --sign - "$out/PickerFixture.app"
