#!/bin/bash
# Build distributable DUO assets locally. Publishing is handled by the GitHub workflow.
set -euo pipefail

usage() {
    cat <<'USAGE'
Usage: Scripts/release-duodesk.sh [options]
  --platform macos|ios|all  Platforms to package (default all).
  --arch universal|arm64|x86_64  Mac architectures (default universal).
  --version X.Y.Z          Must match both source app version settings.
  --build NUMBER           Build number for both packages (default iOS project setting).
  --output DIR             Empty destination (default Temp/Release/<version>).
  --check-version          Validate versions and exit without building.
  --notarize               Sign and notarize Mac assets using explicitly configured credentials.

Without credentials, the Mac app is ad-hoc signed and the iOS IPA requires user signing.
For --notarize, set DUODESK_SIGN_IDENTITY to your Developer ID Application identity and
DUODESK_NOTARY_PROFILE to an existing notarytool keychain profile.
DUODESK_REPOSITORY_URL optionally sets the iOS app's https://github.com/OWNER/REPO links.
USAGE
}

fail() { printf 'error: %s\n' "$*" >&2; exit 1; }
plist_value() { /usr/libexec/PlistBuddy -c "Print :$1" "$2"; }
project_setting() {
    local values
    values="$(sed -n -E "s/^[[:space:]]*$1 = \"?([^\";]*)\"?;[[:space:]]*$/\1/p" "$root/iOSClient/Sill.xcodeproj/project.pbxproj" | sort -u)"
    [ -n "$values" ] && [ "$(printf '%s\n' "$values" | wc -l | tr -d ' ')" = 1 ] \
        || fail "iOS Debug and Release must have one consistent $1 setting."
    printf '%s\n' "$values"
}
sdk_at_least() {
    local actual
    actual="$(xcrun --sdk "$1" --show-sdk-version)" || fail "Install and select full Xcode with the $1 SDK."
    awk -v actual="$actual" -v minimum="$2" 'BEGIN {
        split(actual, a, "."); split(minimum, b, ".");
        exit !((a[1] > b[1]) || (a[1] == b[1] && a[2] >= b[2]));
    }' || fail "The $1 SDK is $actual; this project requires $2 or later."
}
notarize() {
    local artifact="$1" result identifier
    mkdir -p "$log_dir"
    result="$log_dir/$(basename "$artifact").notary.plist"
    printf 'Notarization result will be retained at %s\n' "$result"
    xcrun notarytool submit "$artifact" --keychain-profile "$DUODESK_NOTARY_PROFILE" \
        --wait --output-format plist > "$result" 2> "$result.stderr.log" \
        || fail "Notarization failed; see $result and $result.stderr.log."
    if [ "$(plist_value status "$result")" != Accepted ]; then
        identifier="$(plist_value id "$result")"
        xcrun notarytool log "$identifier" --keychain-profile "$DUODESK_NOTARY_PROFILE" \
            "$result.diagnostics.json" || true
        fail "Apple did not accept $(basename "$artifact"); see $result and its diagnostics."
    fi
}

cleanup() {
    [ -z "${work:-}" ] || rm -rf "$work"
    rmdir "$output_lock" 2>/dev/null || true
}

root="$(cd "$(dirname "$0")/.." && pwd)"
platform=all
architecture=universal
version=""
build=""
output=""
check_version=0
notarization=0
while [ "$#" -gt 0 ]; do
    case "$1" in
        --platform|--arch|--version|--build|--output)
            [ "$#" -ge 2 ] || fail "Missing value for $1."
            case "$1" in
                --platform) platform="$2" ;;
                --arch) architecture="$2" ;;
                --version) version="$2" ;;
                --build) build="$2" ;;
                --output) output="$2" ;;
            esac
            shift 2 ;;
        --check-version) check_version=1; shift ;;
        --notarize) notarization=1; shift ;;
        -h|--help) usage; exit 0 ;;
        *) fail "Unknown option $1." ;;
    esac
done
case "$platform" in macos|ios|all) ;; *) fail 'Choose platform macos, ios or all.' ;; esac
case "$architecture" in universal|arm64|x86_64) ;; *) fail 'Choose architecture universal, arm64 or x86_64.' ;; esac
mac_version="$(plist_value CFBundleShortVersionString "$root/Packaging/DuoHost-Info.plist")"
ios_version="$(project_setting MARKETING_VERSION)"
[ "$mac_version" = "$ios_version" ] || fail "Mac version $mac_version differs from iOS version $ios_version."
version="${version:-$mac_version}"
[[ "$version" =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]] || fail 'Version must have three numeric components.'
[ "$version" = "$mac_version" ] || fail "Requested version $version differs from source version $mac_version."
build="${build:-$(project_setting CURRENT_PROJECT_VERSION)}"
[[ "$build" =~ ^[1-9][0-9]*$ ]] || fail 'Build must be a positive integer.'
if [ "$check_version" = 1 ]; then
    printf 'DUO %s (%s), consistent Mac and iOS versions\n' "$version" "$build"
    exit 0
fi
if [ "$notarization" = 1 ]; then
    [ "$platform" != ios ] || fail '--notarize requires a Mac package.'
    [ -n "${DUODESK_SIGN_IDENTITY:-}" ] && [ "$DUODESK_SIGN_IDENTITY" != - ] \
        || fail '--notarize requires DUODESK_SIGN_IDENTITY.'
    [ -n "${DUODESK_NOTARY_PROFILE:-}" ] || fail '--notarize requires DUODESK_NOTARY_PROFILE.'
fi
if [ -n "${DUODESK_REPOSITORY_URL:-}" ]; then
    [[ "$DUODESK_REPOSITORY_URL" =~ ^https://github\.com/[A-Za-z0-9_.-]+/[A-Za-z0-9_.-]+$ ]] \
        || fail 'DUODESK_REPOSITORY_URL must be https://github.com/OWNER/REPO.'
fi
if [ "$platform" != ios ]; then sdk_at_least macosx 27.0; fi
if [ "$platform" != macos ]; then sdk_at_least iphoneos 27.1; fi
output="${output:-$root/Temp/Release/$version}"
mkdir -p "$output"
output="$(cd "$output" && pwd -P)"
output_lock="$output.release-lock"
mkdir "$output_lock" 2>/dev/null \
    || fail "The output is locked by another or interrupted release: $output_lock."
work=""
trap cleanup EXIT
[ -z "$(ls -A "$output")" ] || fail "The output directory must be empty; choose a new --output directory: $output."
work="$(mktemp -d "$(dirname "$output")/.duo-release.XXXXXX")"
log_dir="$root/Temp/ReleaseLogs/$version-$build-$(date +%Y%m%dT%H%M%S)-$$"
assets=()
cd "$root"

if [ "$platform" != ios ]; then
    signing_options=()
    if [ "${DUODESK_SIGN_IDENTITY:--}" != - ]; then signing_options+=(--release); fi
    bash Scripts/build-duodesk-mac.sh --arch "$architecture" --output "$work/mac" \
        --version "$version" --build "$build" ${signing_options[@]+"${signing_options[@]}"}
    app="$work/mac/DUO你电脑.app"
    executable="$app/Contents/MacOS/DuoDeskHost"
    if [ "$architecture" = universal ]; then
        lipo "$executable" -verify_arch arm64
        lipo "$executable" -verify_arch x86_64
    else
        lipo "$executable" -verify_arch "$architecture"
    fi
    dmg_name="DUO-macOS-$architecture.dmg"
    # The ZIP is not shipped: the DMG is the one Mac download. Notarizing the app itself still
    # needs a container to upload, so the ZIP exists only while --notarize runs, and disappears
    # before the assets are listed.
    if [ "$notarization" = 1 ]; then
        zip_name="DUO-macOS-$architecture.zip"
        ditto -c -k --sequesterRsrc --keepParent "$app" "$work/$zip_name"
        notarize "$work/$zip_name"
        xcrun stapler staple "$app"
        xcrun stapler validate "$app"
        spctl --assess --type execute --verbose=2 "$app"
        rm "$work/$zip_name"
    fi
    mkdir "$work/dmg"
    ditto "$app" "$work/dmg/DUO你电脑.app"
    ln -s /Applications "$work/dmg/Applications"
    hdiutil create -quiet -volname 'DUO你电脑' -srcfolder "$work/dmg" -format UDZO "$work/$dmg_name"
    if [ "${DUODESK_SIGN_IDENTITY:--}" != - ]; then
        codesign --sign "$DUODESK_SIGN_IDENTITY" --timestamp "$work/$dmg_name"
    fi
    if [ "$notarization" = 1 ]; then
        notarize "$work/$dmg_name"
        xcrun stapler staple "$work/$dmg_name"
        xcrun stapler validate "$work/$dmg_name"
        spctl --assess --type open --context context:primary-signature --verbose=2 "$work/$dmg_name"
    fi
    hdiutil verify "$work/$dmg_name"
    # What ships is verified as shipped: read the app back out of the DMG itself, rather than
    # trusting the staging copy the image was built from.
    mount_point="$work/dmg-check"
    mkdir "$mount_point"
    hdiutil attach -quiet -readonly -nobrowse -mountpoint "$mount_point" "$work/$dmg_name"
    codesign --verify --deep --strict "$mount_point/DUO你电脑.app"
    if [ "$notarization" = 1 ]; then
        xcrun stapler validate "$mount_point/DUO你电脑.app"
        spctl --assess --type execute --verbose=2 "$mount_point/DUO你电脑.app"
    fi
    hdiutil detach -quiet "$mount_point"
    assets+=("$dmg_name")
fi

if [ "$platform" != macos ]; then
    mkdir -p "$root/Temp/Build/ios"
    archive="$work/DUO.xcarchive"
    xcodebuild -quiet -project iOSClient/Sill.xcodeproj -scheme Sill -configuration Release \
        -sdk iphoneos -destination 'generic/platform=iOS' \
        -derivedDataPath "$root/Temp/Build/ios" -archivePath "$archive" \
        CODE_SIGNING_ALLOWED=NO CODE_SIGNING_REQUIRED=NO CODE_SIGN_IDENTITY= DEVELOPMENT_TEAM= \
        MARKETING_VERSION="$version" CURRENT_PROJECT_VERSION="$build" archive
    app="$archive/Products/Applications/Sill.app"
    [ -d "$app" ] || fail 'The iOS archive contains no Sill.app.'
    [ "$(plist_value CFBundleIdentifier "$app/Info.plist")" = com.duodesk.client ] || fail 'Unexpected iOS bundle identifier.'
    [ "$(plist_value CFBundleShortVersionString "$app/Info.plist")" = "$version" ] || fail 'Incorrect iOS package version.'
    [ "$(plist_value CFBundleVersion "$app/Info.plist")" = "$build" ] || fail 'Incorrect iOS package build number.'
    [ "$(plist_value DTPlatformName "$app/Info.plist")" = iphoneos ] || fail 'The IPA must contain an iOS device build.'
    [ -f "$app/PrivacyInfo.xcprivacy" ] || fail 'The iOS privacy manifest is missing.'
    [ ! -e "$app/embedded.mobileprovision" ] || fail 'The unsigned archive unexpectedly contains a provisioning profile.'
    if [ -n "${DUODESK_REPOSITORY_URL:-}" ]; then
        plutil -replace DUORepositoryURL -string "$DUODESK_REPOSITORY_URL" "$app/Info.plist"
    fi
    cp LICENSE NOTICE "$app/"
    mkdir -p "$work/ipa/Payload"
    ditto "$app" "$work/ipa/Payload/Sill.app"
    ipa_name=DUO-iOS-unsigned.ipa
    (cd "$work/ipa" && COPYFILE_DISABLE=1 /usr/bin/zip -q -r "$work/$ipa_name" Payload)
    /usr/bin/unzip -tq "$work/$ipa_name"
    assets+=("$ipa_name")
fi

cat > "$work/INSTALL.txt" <<EOF
DUO你电脑 $version ($build)

macOS requires macOS 27 or later. Copy DUO你电脑.app to Applications.
Apple notarization performed for this package: $notarization (1=yes, 0=no).
For an unnotarized build, macOS may require Open Anyway in System Settings > Privacy & Security.
Grant Screen Recording and Accessibility when prompted, then pair with the iOS app.

The iOS IPA requires iOS 27.1 or later and signing with your own Apple Account before installation.
Use a compatible sideloading tool, or build iOSClient/Sill.xcodeproj with Xcode and your Personal Team.
Unsigned IPA files cannot be installed directly. Free Personal Team profiles normally expire in 7 days.
Keep the same Team and bundle identifier when renewing to preserve the app's identity and pairing.

Read README.md and docs/release-checklist.md in the source repository for installation and release details.
Verify downloaded assets by running: shasum -a 256 -c SHA256SUMS
Source code and bundled notices are licensed under Apache-2.0. See LICENSE and NOTICE.
EOF
assets+=(INSTALL.txt)
(cd "$work" && shasum -a 256 "${assets[@]}" > SHA256SUMS)
mkdir "$work/assets"
for asset in "${assets[@]}" SHA256SUMS; do mv "$work/$asset" "$work/assets/$asset"; done
# Replacing the empty directory in one rename avoids a gap in which another invocation
# could recreate it. The OS refuses replacement if new files appeared in the destination.
python3 - "$work/assets" "$output" <<'PY'
import os
import sys

os.rename(sys.argv[1], sys.argv[2])
PY
printf '\nRelease assets written to %s\n' "$output"
(cd "$output" && shasum -a 256 -c SHA256SUMS)
