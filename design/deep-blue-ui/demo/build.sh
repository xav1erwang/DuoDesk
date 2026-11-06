#!/bin/bash
# Builds the design-preview demo app for the iPhone Duo simulator.
# Design only: it is a standalone SwiftUI app, not the DuoDesk client.
set -euo pipefail
cd "$(dirname "$0")"

SIM_SDK=$(xcrun --sdk iphonesimulator --show-sdk-path)
OUT=build
APP="$OUT/DesignDemo.app"
FONT="../fonts/Montserrat-900.ttf"

rm -rf "$OUT"
mkdir -p "$APP"

xcrun --sdk iphonesimulator swiftc \
  -target arm64-apple-ios27.0-simulator \
  -sdk "$SIM_SDK" \
  -parse-as-library \
  -O \
  DesignDemo.swift \
  -o "$APP/DesignDemo"

cp "$FONT" "$APP/Montserrat-900.ttf"

cat > "$APP/Info.plist" <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>CFBundleExecutable</key><string>DesignDemo</string>
  <key>CFBundleIdentifier</key><string>com.duodesk.designdemo</string>
  <key>CFBundleName</key><string>DUO 设计稿</string>
  <key>CFBundlePackageType</key><string>APPL</string>
  <key>CFBundleShortVersionString</key><string>1.0</string>
  <key>CFBundleVersion</key><string>1</string>
  <key>MinimumOSVersion</key><string>17.0</string>
  <key>UIDeviceFamily</key><array><integer>1</integer><integer>2</integer></array>
  <key>UILaunchScreen</key><dict/>
  <key>UIRequiredDeviceCapabilities</key><array><string>arm64</string></array>
  <key>UISupportedInterfaceOrientations</key>
  <array>
    <string>UIInterfaceOrientationPortrait</string>
    <string>UIInterfaceOrientationLandscapeLeft</string>
    <string>UIInterfaceOrientationLandscapeRight</string>
  </array>
</dict>
</plist>
PLIST

codesign --force --sign - "$APP"
echo "Built $APP"
