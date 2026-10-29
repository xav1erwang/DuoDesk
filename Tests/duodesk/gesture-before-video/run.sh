#!/bin/bash
# Copyright 2026 DUO你电脑 contributors. SPDX-License-Identifier: Apache-2.0
# The fixture talks only to its own TCP loopback peer; it never sends real system input.
set -euo pipefail
cd "$(dirname "$0")/../../.."
if [[ -f Local/developer-env.sh ]]; then source Local/developer-env.sh; fi
[[ $# == 2 ]] || { echo "usage: $0 SIMULATOR_UDID NEW_OUTPUT_DIRECTORY" >&2; exit 64; }
device="$1"
out="$2"
bundle="com.duodesk.tests.GestureGate"
preview_pid="$(ps -Ao pid=,comm= | awk -v device="/$device/" '!found && index($0, device) && /\/Sill\.app\/Sill$/ {print $1; found=1}')"
python3 Tests/duodesk/gesture-before-video/build.py "$out"
cleanup() {
  xcrun simctl terminate "$device" "$bundle" >/dev/null 2>&1 || true
  xcrun simctl uninstall "$device" "$bundle" >/dev/null 2>&1 || true
  # Return to the already-running product preview if it exists; do not change its launch arguments.
  if [[ -n "$preview_pid" ]] && ps -p "$preview_pid" >/dev/null 2>&1; then
    xcrun simctl launch "$device" com.duodesk.client >/dev/null 2>&1 || true
  fi
}
trap cleanup EXIT
xcrun simctl install "$device" "$out/Gesture Gate Probe.app"
xcrun simctl launch "$device" "$bundle"
container="$(xcrun simctl get_app_container "$device" "$bundle" data)"
python3 - "$container/Documents/gesture-result.json" "$out/gesture-result.json" <<'PY'
import json, pathlib, shutil, sys, time
source, dest = map(pathlib.Path, sys.argv[1:])
deadline = time.monotonic() + 20
while not source.exists() and time.monotonic() < deadline:
    time.sleep(0.1)
if not source.exists(): raise SystemExit('fixture did not write its result')
shutil.copyfile(source, dest)
result = json.loads(dest.read_text())
print(json.dumps(result, ensure_ascii=False, indent=2))
if not result['passed']: raise SystemExit(1)
PY
