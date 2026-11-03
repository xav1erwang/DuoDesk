#!/bin/bash
# Copyright 2026 DUO你电脑 contributors. SPDX-License-Identifier: Apache-2.0
set -euo pipefail
cd "$(dirname "$0")/../../.."
if [[ -f Local/developer-env.sh ]]; then source Local/developer-env.sh; fi
if [[ $# -ne 1 || -e "$1" ]]; then
    echo "usage: $0 NEW_OUTPUT_DIRECTORY" >&2
    exit 64
fi
out="$1"
mkdir -p "$out"
swiftc Sources/StreamProtocol/Input.swift Sources/StreamProtocol/Viewport.swift \
    Sources/StreamProtocol/StreamMessage.swift Sources/StreamProtocol/VideoDecodeBacklog.swift \
    Sources/StreamProtocol/VideoStreamEpoch.swift Sources/StreamProtocol/Display.swift Sources/StreamProtocol/Switcher.swift \
    Tests/duodesk/extended-desktop-wire/main.swift -o "$out/check"
"$out/check"
