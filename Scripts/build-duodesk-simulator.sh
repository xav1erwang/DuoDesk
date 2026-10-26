#!/bin/bash
# Simulator only: Xcode embeds keychain entitlements into the executable for TLS pairing tests.
set -euo pipefail
cd "$(dirname "$0")/.."
simulator_team="${DUODESK_SIMULATOR_TEAM_ID:-DUODESKDEV}"
[[ "$simulator_team" =~ ^[A-Z0-9]{10}$ ]] || { echo "Simulator team namespace must be ten uppercase letters/digits." >&2; exit 2; }
xcodebuild -project iOSClient/Sill.xcodeproj -scheme Sill -configuration Debug \
    -sdk iphonesimulator -destination 'generic/platform=iOS Simulator' \
    -derivedDataPath Temp/SimulatorSigned ARCHS=arm64 ONLY_ACTIVE_ARCH=YES \
    CODE_SIGNING_ALLOWED=YES CODE_SIGN_IDENTITY=- DEVELOPMENT_TEAM="$simulator_team" build
codesign --verify --deep --strict Temp/SimulatorSigned/Build/Products/Debug-iphonesimulator/Sill.app
echo "Built: $PWD/Temp/SimulatorSigned/Build/Products/Debug-iphonesimulator/Sill.app"
