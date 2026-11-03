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
swiftc -emit-library -emit-module -module-name StreamProtocol \
  Sources/StreamProtocol/Input.swift Sources/StreamProtocol/Viewport.swift \
  Sources/StreamProtocol/StreamMessage.swift Sources/StreamProtocol/VideoDecodeBacklog.swift \
  Sources/StreamProtocol/VideoStreamEpoch.swift -o "$out/libStreamProtocol.dylib" -emit-module-path "$out/StreamProtocol.swiftmodule"
swiftc -I "$out" -L "$out" -lStreamProtocol -Xlinker -rpath -Xlinker "$out" \
  iOSClient/DuoControlModel.swift iOSClient/KeyChords.swift Tests/duodesk/clean-image/main.swift -o "$out/check"
"$out/check"
