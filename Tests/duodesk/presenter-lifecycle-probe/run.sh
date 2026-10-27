#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/../../.."
if [[ -f Local/developer-env.sh ]]; then source Local/developer-env.sh; fi
out="$PWD/.build/duodesk-presenter-lifecycle"
mkdir -p "$out"
swiftc -O -swift-version 6 -strict-concurrency=complete -warnings-as-errors -emit-library -emit-module \
    -module-name StreamProtocol Sources/StreamProtocol/VideoDecodeBacklog.swift \
    -emit-module-path "$out/StreamProtocol.swiftmodule" -o "$out/libStreamProtocol.dylib"
swiftc -O -swift-version 6 -strict-concurrency=complete -warnings-as-errors -parse-as-library \
    -I "$out" -L "$out" -lStreamProtocol -Xlinker -rpath -Xlinker "$out" \
    iOSClient/HardwareVideoPresenter.swift Tests/duodesk/presenter-lifecycle-probe/main.swift -o "$out/checks"
if [[ "${1:-}" != "--build-only" ]]; then "$out/checks"; fi
