#!/bin/bash
# Run with a signed Debug simulator app and a release SillHost binary. The simulator and hosts
# are isolated test instances; no real pairing or device data is used.
set -euo pipefail
if [ "$#" -ne 2 ]; then
    echo "Usage: bash $0 /path/to/Debug-iphonesimulator/Sill.app /path/to/SillHost" >&2
    exit 2
fi
app="$1"
host="$2"
test -d "$app" && test -x "$host"
scratch="$(mktemp -d "${TMPDIR:-/tmp/}duodesk-local-connect.XXXXXXXX")"
sim=""
host_pid=""
other_pid=""
client_pid=""

cleanup() {
    result=$?
    trap - EXIT
    if [ -n "$sim" ]; then
        xcrun simctl terminate "$sim" com.duodesk.client >/dev/null 2>&1 || true
    fi
    if [ -n "$client_pid" ]; then wait "$client_pid" 2>/dev/null || true; fi
    if [ -n "$other_pid" ]; then kill "$other_pid" 2>/dev/null || true; wait "$other_pid" 2>/dev/null || true; fi
    if [ -n "$host_pid" ]; then kill "$host_pid" 2>/dev/null || true; wait "$host_pid" 2>/dev/null || true; fi
    if [ -n "$sim" ]; then
        xcrun simctl shutdown "$sim" >/dev/null 2>&1 || true
        xcrun simctl delete "$sim" >/dev/null 2>&1 || true
    fi
    if [ "$result" -eq 0 ]; then rm -rf "$scratch"; else echo "Test logs: $scratch" >&2; fi
    exit "$result"
}
trap cleanup EXIT

wait_for() {
    local pattern="$1" file="$2"
    for _ in {1..60}; do
        if [ -f "$file" ] && rg -q "$pattern" "$file"; then return 0; fi
        sleep 1
    done
    echo "Timed out waiting for $pattern" >&2
    return 1
}

start_client() {
    local log="$1"
    shift
    SIMCTL_CHILD_NSUnbufferedIO=YES xcrun simctl launch --console "$sim" com.duodesk.client \
        -SillServiceType _silltest._tcp "$@" >"$log" 2>&1 &
    client_pid=$!
}

stop_client() {
    xcrun simctl terminate "$sim" com.duodesk.client >/dev/null 2>&1 || true
    if [ -n "$client_pid" ]; then wait "$client_pid" 2>/dev/null || true; fi
    client_pid=""
}

SILL_TEST_REMOTE_DIR="$scratch/host" SILL_TEST_LOOPBACK=1 SILL_TEST_NO_ROUTER=1 \
    SILL_TEST_SOFTWARE_ENCODER=1 SILL_TEST_SERVICE_TYPE=_silltest._tcp NSUnbufferedIO=YES \
    "$host" --synthetic --remote --pairing >"$scratch/host.log" 2>&1 &
host_pid=$!
wait_for 'sill://pair\?' "$scratch/host.log"
pairing_link="$(awk 'match($0, /sill:\/\/pair\?[^ ]+/) { print substr($0, RSTART, RLENGTH); exit }' "$scratch/host.log")"
sim="$(xcrun simctl create DuoDesk-Connection-Test com.apple.CoreSimulator.SimDeviceType.iPhone-Duo \
    com.apple.CoreSimulator.SimRuntime.iOS-27-1)"
xcrun simctl boot "$sim"
xcrun simctl bootstatus "$sim" -b >/dev/null
xcrun simctl install "$sim" "$app"
appdir="$(xcrun simctl get_app_container "$sim" com.duodesk.client data)"

start_client "$scratch/pair.log" -SillPairURL "$pairing_link"
wait_for 'remote: paired with' "$scratch/pair.log"
wait_for 'remote: connected to' "$scratch/pair.log"
stop_client
start_client "$scratch/home.log" -SillTapRow "Sill test $host_pid"
wait_for 'home: connected to .* a saved Mac' "$scratch/home.log"
saved=""
for _ in {1..30}; do
    saved="$(plutil -convert json -o - "$appdir/Library/Preferences/com.duodesk.client.plist" \
        | jq -c '.["Sill.savedMacs"] | fromjson')"
    if printf '%s' "$saved" | jq -e --arg name "Sill test $host_pid" \
        'length == 1 and .[0].bonjourName == $name and (.[0].addresses | length) > 0' >/dev/null; then break; fi
    sleep 1
done
printf '%s' "$saved" | jq -e --arg name "Sill test $host_pid" \
    'length == 1 and .[0].bonjourName == $name and (.[0].addresses | length) > 0' >/dev/null
stop_client

start_client "$scratch/local.log" -SillDialSaved local
wait_for 'home: connected to .* a saved Mac' "$scratch/local.log"
sleep 6
! rg -q 'saved lookup: local service did not connect' "$scratch/local.log"
stop_client

# Hide the host from both browsers while leaving its service resolvable. The saved-service query
# must identify it from its TXT tag, restore a local row, and connect using the existing pin.
saved_name="$(printf '%s' "$saved" | jq -r '.[0].name')"
start_client "$scratch/missed-browse.log" -SillHideBrowseName "Sill test $host_pid" -SillTapRow "$saved_name"
wait_for 'saved discovery: verified local service' "$scratch/missed-browse.log"
wait_for 'home: connected to .* a saved Mac' "$scratch/missed-browse.log"
stop_client

missing="$(printf '%s' "$saved" | jq -c 'map(.bonjourName = "DuoDesk missing service")')"
start_client "$scratch/fallback.log" -Sill.savedMacs "$missing" -SillDialSaved local
wait_for 'remote: connected to' "$scratch/fallback.log"
rg -q 'saved lookup: local service did not connect' "$scratch/fallback.log"
stop_client

no_address="$(printf '%s' "$missing" | jq -c 'map(.addresses = [] | .typedAddresses = [])')"
start_client "$scratch/no-address.log" -Sill.savedMacs "$no_address" -SillDialSaved local
wait_for 'saved lookup: local service did not connect' "$scratch/no-address.log"
! rg -q 'remote: dialing' "$scratch/no-address.log"
stop_client

start_client "$scratch/switch.log" -Sill.savedMacs "$missing" -SillDialSaved local -SillTapRow "Sill test $host_pid"
wait_for 'home: connected to .* a saved Mac' "$scratch/switch.log"
sleep 6
! rg -q 'saved lookup: local service did not connect' "$scratch/switch.log"
stop_client

SILL_TEST_REMOTE_DIR="$scratch/other" SILL_TEST_LOOPBACK=1 SILL_TEST_NO_ROUTER=1 \
    SILL_TEST_SOFTWARE_ENCODER=1 SILL_TEST_SERVICE_TYPE=_silltest._tcp NSUnbufferedIO=YES \
    "$host" --synthetic --pairing >"$scratch/other.log" 2>&1 &
other_pid=$!
wait_for 'Home door QUIC: listening' "$scratch/other.log"
other="$(printf '%s' "$saved" | jq -c --arg name "Sill test $other_pid" 'map(.bonjourName = $name)')"
start_client "$scratch/forged-discovery.log" -Sill.savedMacs "$other" -SillHideBrowseName "Sill test $host_pid"
sleep 7
! rg -q "saved discovery: verified local service for Sill test $other_pid" "$scratch/forged-discovery.log"
stop_client
start_client "$scratch/wrong-key.log" -Sill.savedMacs "$other" -SillDialSaved local
wait_for 'remote: connected to' "$scratch/wrong-key.log"
rg -q 'pin refused the key' "$scratch/wrong-key.log"
! rg -q 'paired again with a tap' "$scratch/wrong-key.log"
stop_client

for flag in revoked newKey; do
    blocked="$(printf '%s' "$saved" | jq -c --arg flag "$flag" 'map(.[$flag] = true)')"
    start_client "$scratch/$flag.log" -Sill.savedMacs "$blocked" -SillDialSaved local
    wait_for 'remote: dialing' "$scratch/$flag.log"
    ! rg -q 'saved lookup: trying' "$scratch/$flag.log"
    stop_client
done
echo 'Saved local connection: all integration checks passed'
