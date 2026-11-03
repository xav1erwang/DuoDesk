#!/bin/bash
# Build a separate host app inside this checkout. Does not install, launch, or change login items.
set -euo pipefail
cd "$(dirname "$0")/.."
swift build -c release --product SillMenuBar
bin="$(swift build -c release --product SillMenuBar --show-bin-path)"
app="$PWD/Build/DUO你电脑 Mac.app"
stage="$PWD/Build/DUO你电脑 Mac.partial.app"
mkdir -p "$stage/Contents/MacOS" "$stage/Contents/Resources"
cp "$bin/SillMenuBar" "$stage/Contents/MacOS/DuoDeskHost"
# Record the current SDK so native controls use the current macOS appearance.
minos="$(xcrun vtool -show-build "$bin/SillMenuBar" | awk '$1 == "minos" && !seen {print $2; seen=1}')"
xcrun vtool -set-build-version macos "$minos" "$(xcrun --sdk macosx --show-sdk-version)" \
    -output "$stage/Contents/MacOS/DuoDeskHost" "$bin/SillMenuBar"
cp Packaging/DuoHost-Info.plist "$stage/Contents/Info.plist"
cp LICENSE NOTICE "$stage/Contents/Resources/"
if [ -f iOSClient/Assets.xcassets/AppIcon.appiconset/AppIcon.png ]; then
    iconset="$PWD/Build/DuoAppIcon.iconset"
    mkdir -p "$iconset"
    for size in 16 32 128 256 512; do
        sips -z "$size" "$size" iOSClient/Assets.xcassets/AppIcon.appiconset/AppIcon.png --out "$iconset/icon_${size}x${size}.png" >/dev/null
        doubled=$((size * 2))
        sips -z "$doubled" "$doubled" iOSClient/Assets.xcassets/AppIcon.appiconset/AppIcon.png --out "$iconset/icon_${size}x${size}@2x.png" >/dev/null
    done
    iconutil -c icns "$iconset" -o "$stage/Contents/Resources/AppIcon.icns"
fi
identity="${DUODESK_SIGN_IDENTITY:-$(security find-identity -v -p codesigning 2>/dev/null | awk '/"Apple Development: / && !/CSSMERR|revoked/ {print $2; exit}' || true)}"
if [ -z "$identity" ]; then
    identity="-"
    echo "No development identity available; this local build uses an ad-hoc signature."
fi
# Copies from shared volumes can carry Finder metadata that codesign refuses.
xattr -cr "$stage"
codesign --force --sign "$identity" --timestamp=none "$stage"
codesign --verify --deep --strict "$stage"
if [ -e "$app" ]; then
    backup="$PWD/Build/DUO你电脑 Mac.previous.app"
    if [ -e "$backup" ]; then mv "$backup" "$PWD/Build/DUO你电脑 Mac.previous.$(date +%s).app"; fi
    mv "$app" "$backup"
fi
mv "$stage" "$app"
echo "Built: $app"
