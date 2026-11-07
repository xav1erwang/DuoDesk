#!/bin/bash
# Build and install the iOS app on a connected iPhone, safely.
#
# Why this exists: installing the same build number over and over made iOS take
# the delta path (`installMode=1`, a ComputedDelta), and a delta install can land
# a bundle whose Assets.car and debug dylib are the previous ones — the app then
# looks and behaves like the old version while `devicectl` reports success. Two
# habits prevent it, both automated here:
#
#   1. Every install gets a build number nobody has installed before (the
#      project's CURRENT_PROJECT_VERSION is bumped and committed with it).
#   2. The installed bundle is verified against what was built — its icon's
#      colour and its version — and the install is retried without the delta
#      cache (uninstall, then install) when they disagree.
#
# Usage: Scripts/build-duodesk-ios-device.sh [--device UDID] [--team TEAM]
#                                            [--no-bump] [--launch]
set -euo pipefail
cd "$(dirname "$0")/.."
root="$PWD"
project=iOSClient/Sill.xcodeproj
scheme=Sill
bundle_id=com.duodesk.client
derived=Temp/DeviceBuild
device=""
team="${DUODESK_TEAM_ID:-TEAMIDENT1}"
bump=1
launch=1

while [ "$#" -gt 0 ]; do
    case "$1" in
        --device) device="$2"; shift 2 ;;
        --team) team="$2"; shift 2 ;;
        --no-bump) bump=0; shift ;;
        --no-launch) launch=0; shift ;;
        -h|--help)
            sed -n '2,20p' "$0" | sed 's/^# \{0,1\}//'
            exit 0 ;;
        *) echo "Unknown option: $1" >&2; exit 2 ;;
    esac
done

# One connected, paired device, when none was named. A device's name may hold
# spaces, so the UDID is taken by its shape rather than by a column number.
if [ -z "$device" ]; then
    device="$(xcrun devicectl list devices 2>/dev/null \
        | grep physical | grep -E 'available \(paired\)| connected' \
        | grep -oE '[0-9A-F]{8}-[0-9A-F]{16}' | head -1)"
fi
[ -n "$device" ] || { echo 'No paired iPhone found; connect one, or pass --device UDID.' >&2; exit 2; }

# 1. A build number this device has not seen. The delta path keys off it.
if [ "$bump" = 1 ]; then
    current="$(grep -o 'CURRENT_PROJECT_VERSION = [0-9]*' "$project/project.pbxproj" \
        | head -1 | grep -o '[0-9]*$')"
    current="${current:-0}"
    next=$((current + 1))
    # The value appears once per configuration (Debug and Release).
    /usr/bin/sed -i '' "s/CURRENT_PROJECT_VERSION = $current;/CURRENT_PROJECT_VERSION = $next;/g" "$project/project.pbxproj"
    plutil -lint "$project/project.pbxproj" >/dev/null
    echo "Build number: $current -> $next"
fi

# 2. A clean build: a reused build directory can keep a stale Assets.car.
rm -rf "$derived"
xcodebuild -project "$project" -scheme "$scheme" -configuration Debug \
    -destination "id=$device" -derivedDataPath "$derived" \
    DEVELOPMENT_TEAM="$team" CODE_SIGN_STYLE=Automatic -allowProvisioningUpdates build \
    2>&1 | grep -E "error:|BUILD" | tail -5

app="$derived/Build/Products/Debug-iphoneos/Sill.app"
[ -d "$app" ] || { echo "Build produced no app at $app" >&2; exit 1; }
built_version="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleVersion' "$app/Info.plist")"
echo "Built $built_version"

install_and_verify() {
    xcrun devicectl device install app --device "$device" "$app" >/dev/null 2>&1 || return 1
    # What the device reports: the version it now holds.
    installed="$(xcrun devicectl device info apps --device "$device" 2>/dev/null \
        | grep -F "$bundle_id" | grep -oE '[0-9]+ *$' | tr -d ' ' | head -1)"
    [ "$installed" = "$built_version" ]
}

if ! install_and_verify; then
    echo 'Install did not take the new build; clearing the delta cache and retrying.' >&2
    xcrun devicectl device uninstall app --device "$device" "$bundle_id" >/dev/null 2>&1 || true
    install_and_verify || { echo 'Install failed twice.' >&2; exit 1; }
    echo 'Installed after the cache was cleared. iOS may ask you to trust the developer again.'
fi

echo "Installed $bundle_id $built_version on $device"
if [ "$launch" = 1 ]; then
    xcrun devicectl device process launch --device "$device" "$bundle_id" >/dev/null 2>&1 \
        && echo 'Launched.' \
        || echo 'Could not launch: trust this developer in Settings > General > VPN & Device Management.'
fi
