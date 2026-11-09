#!/bin/bash
# Build and install the iOS app on a connected iPhone.
# Check the phone before advancing the source build number, so an older checkout
# cannot overwrite a newer installation. Install and verify through the same
# version checks used by automatic renewal. Never uninstall to retry a failure.
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
# The team comes from DUODESK_TEAM_ID, else from the Apple Development certificate in
# this Mac's keychain (its OU). No team identifier is kept in the repository.
if [ -z "${DUODESK_TEAM_ID:-}" ]; then
    DUODESK_TEAM_ID="$(security find-certificate -c 'Apple Development' -p 2>/dev/null \
        | openssl x509 -noout -subject 2>/dev/null \
        | sed -n 's/.*OU *= *\([A-Z0-9]\{10\}\).*/\1/p' | head -1)"
fi
team="${DUODESK_TEAM_ID:-}"
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
[ -n "$team" ] || { echo 'No signing team: pass --team, set DUODESK_TEAM_ID, or sign in to Xcode with an Apple account.' >&2; exit 2; }

python3 Signing/device_install.py --device "$device" --bundle-id "$bundle_id" --check-project "$root"

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

python3 Signing/device_install.py --device "$device" --bundle-id "$bundle_id" \
    --app "$app" --log "$derived/install.log"

echo "Installed $bundle_id $built_version on $device"
if [ "$launch" = 1 ]; then
    xcrun devicectl device process launch --device "$device" "$bundle_id" >/dev/null 2>&1 \
        && echo 'Launched.' \
        || echo 'Could not launch: trust this developer in Settings > General > VPN & Device Management.'
fi
