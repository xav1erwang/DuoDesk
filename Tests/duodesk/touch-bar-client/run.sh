#!/bin/bash
# Copyright 2026 DUO你电脑 contributors. SPDX-License-Identifier: Apache-2.0
# Simulator fixture with a fake decoder and unstarted connections; no Mac capture or system input.
set -euo pipefail
cd "$(dirname "$0")/../../.."
if [[ -f Local/developer-env.sh ]]; then source Local/developer-env.sh; fi
if [[ $# -ne 2 ]]; then
  echo "usage: $0 SIMULATOR_UDID NEW_OUTPUT_DIRECTORY" >&2
  exit 64
fi
device="$1"
output="$2"
python3 Tests/duodesk/touch-bar-client/project.py "$output"
xcodebuild test -project "$output/SystemKeyboard.xcodeproj" -scheme SystemKeyboard \
  -destination "platform=iOS Simulator,id=$device" -collect-test-diagnostics never \
  -derivedDataPath "$output/DerivedData" -resultBundlePath "$output/Results.xcresult"
