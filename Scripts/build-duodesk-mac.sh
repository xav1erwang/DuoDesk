#!/bin/bash
# Build a separate host app inside this checkout. Does not install, launch, or change login items.
set -euo pipefail
root="$(cd "$(dirname "$0")/.." && pwd)"
output="$root/Build"
architecture="$(uname -m)"
version=""
build=""
release=0
while [ "$#" -gt 0 ]; do
    case "$1" in
        --output|--arch|--version|--build)
            [ "$#" -ge 2 ] || { echo "Missing value for $1" >&2; exit 2; }
            case "$1" in
                --output) output="$2" ;;
                --arch) architecture="$2" ;;
                --version) version="$2" ;;
                --build) build="$2" ;;
            esac
            shift 2 ;;
        --release) release=1; shift ;;
        -h|--help)
            echo 'Usage: Scripts/build-duodesk-mac.sh [--arch arm64|x86_64|universal] [--output DIR] [--version VERSION] [--build NUMBER] [--release]'
            echo 'DUODESK_SIGN_IDENTITY explicitly selects a signing identity. The default is ad-hoc signing.'
            exit 0 ;;
        *) echo "Unknown option: $1" >&2; exit 2 ;;
    esac
done
case "$architecture" in arm64|x86_64|universal) ;; *) echo "Unsupported architecture: $architecture" >&2; exit 2 ;; esac
[[ -z "$version" || "$version" =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]] || { echo 'Version must have three numeric components.' >&2; exit 2; }
[[ -z "$build" || "$build" =~ ^[1-9][0-9]*$ ]] || { echo 'Build must be a positive integer.' >&2; exit 2; }
mkdir -p "$output"
output="$(cd "$output" && pwd)"
cd "$root"
identity="${DUODESK_SIGN_IDENTITY:--}"
if [ "$release" = 1 ] && [ "$identity" = - ]; then
    echo '--release requires DUODESK_SIGN_IDENTITY for Developer ID signing.' >&2
    exit 2
fi
architectures=("$architecture")
if [ "$architecture" = universal ]; then architectures=(arm64 x86_64); fi
work="$(mktemp -d "$output/.duo-build.XXXXXX")"
trap 'rm -rf "$work"' EXIT
binaries=()
for arch in "${architectures[@]}"; do
    scratch="${DUODESK_SWIFT_SCRATCH_PATH:-$root/Temp/Build/mac}/$arch"
    swift build -c release --product SillMenuBar --triple "$arch-apple-macosx" --scratch-path "$scratch"
    bin="$(swift build -c release --product SillMenuBar --triple "$arch-apple-macosx" --scratch-path "$scratch" --show-bin-path)"
    binaries+=("$bin/SillMenuBar")
done
if [ "${#binaries[@]}" = 1 ]; then
    cp "${binaries[0]}" "$work/DuoDeskHost"
else
    lipo -create "${binaries[@]}" -output "$work/DuoDeskHost"
fi
app="$output/DUO你电脑.app"
stage="$work/DUO你电脑.app"
mkdir -p "$stage/Contents/MacOS" "$stage/Contents/Resources"
# Record the current SDK so native controls use the current macOS appearance.
minos="$(xcrun vtool -show-build "$work/DuoDeskHost" | awk '$1 == "minos" && !seen {print $2; seen=1}')"
xcrun vtool -set-build-version macos "$minos" "$(xcrun --sdk macosx --show-sdk-version)" \
    -output "$stage/Contents/MacOS/DuoDeskHost" "$work/DuoDeskHost"
cp Packaging/DuoHost-Info.plist "$stage/Contents/Info.plist"
[ -z "$version" ] || /usr/libexec/PlistBuddy -c "Set :CFBundleShortVersionString $version" "$stage/Contents/Info.plist"
[ -z "$build" ] || /usr/libexec/PlistBuddy -c "Set :CFBundleVersion $build" "$stage/Contents/Info.plist"
cp LICENSE NOTICE "$stage/Contents/Resources/"
if [ -f "$root/Packaging/DuoAppIcon.icon/icon.json" ]; then
    # Packaging/DuoAppIcon.icon is an Icon Composer document (macOS 26/27's layered,
    # Liquid Glass format). actool compiles it into Assets.car, which macOS 26+ masks
    # and lights natively, plus a pre-masked .icns for macOS 14–15. A flat .icns made
    # with sips/iconutil shows up on macOS 27 as a shrunken icon inside a grey tile.
    # The path is absolute: actool resolves relative paths in its helper's directory.
    icon_out="$work/icon"
    mkdir -p "$icon_out"
    xcrun actool --compile "$icon_out" --platform macosx --minimum-deployment-target 14.0 \
        --app-icon DuoAppIcon --output-partial-info-plist "$icon_out/partial.plist" \
        "$root/Packaging/DuoAppIcon.icon" >/dev/null \
        || echo 'warning: actool could not compile Packaging/DuoAppIcon.icon; the bundle gets the generic icon.' >&2
    cp "$icon_out"/Assets.car "$icon_out"/DuoAppIcon.icns "$stage/Contents/Resources/" 2>/dev/null || true
elif [ -f iOSClient/Assets.xcassets/AppIcon.appiconset/AppIcon.png ]; then
    iconset="$work/DuoAppIcon.iconset"
    mkdir -p "$iconset"
    for size in 16 32 128 256 512; do
        sips -z "$size" "$size" iOSClient/Assets.xcassets/AppIcon.appiconset/AppIcon.png --out "$iconset/icon_${size}x${size}.png" >/dev/null
        doubled=$((size * 2))
        sips -z "$doubled" "$doubled" iOSClient/Assets.xcassets/AppIcon.appiconset/AppIcon.png --out "$iconset/icon_${size}x${size}@2x.png" >/dev/null
    done
    iconutil -c icns "$iconset" -o "$stage/Contents/Resources/DuoAppIcon.icns"
    /usr/libexec/PlistBuddy -c 'Add :CFBundleIconName string DuoAppIcon' "$stage/Contents/Info.plist" 2>/dev/null \
        || /usr/libexec/PlistBuddy -c 'Set :CFBundleIconName DuoAppIcon' "$stage/Contents/Info.plist"
fi
# Copies from shared volumes can carry Finder metadata that codesign refuses.
xattr -cr "$stage"
if [ "$release" = 1 ]; then
    codesign --force --sign "$identity" --options runtime --timestamp "$stage"
    codesign -dv "$stage" 2>&1 | grep -F 'Authority=Developer ID Application:' >/dev/null \
        || { echo '--release requires a Developer ID Application identity.' >&2; exit 2; }
else
    codesign --force --sign "$identity" --timestamp=none "$stage"
fi
codesign --verify --deep --strict "$stage"
if [ -e "$app" ]; then
    backup="$output/DUO你电脑.previous.app"
    if [ -e "$backup" ]; then mv "$backup" "$output/DUO你电脑.previous.$(date +%s).app"; fi
    mv "$app" "$backup"
fi
mv "$stage" "$app"
echo "Built: $app"
