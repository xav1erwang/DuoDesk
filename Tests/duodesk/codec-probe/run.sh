#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/../../.."
out="$PWD/.build/duodesk-codec-probe"
mkdir -p "$out"
swiftc -O -emit-library -emit-module -module-name StreamProtocol Sources/StreamProtocol/Viewport.swift Sources/StreamProtocol/StreamMessage.swift Sources/StreamProtocol/VideoDecodeBacklog.swift \
    -emit-module-path "$out/StreamProtocol.swiftmodule" -o "$out/libStreamProtocol.dylib"
swiftc -O -package-name Sill -I "$out" -L "$out" -lStreamProtocol -Xlinker -rpath -Xlinker "$out" \
    Sources/SillHost/HEVCEncoder.swift Sources/SillHost/EncoderMailbox.swift Sources/SillHost/EncoderSlowState.swift \
    Sources/SillHost/Stats.swift iOSClient/HardwareHEVCDecoder.swift Tests/duodesk/codec-probe/main.swift -o "$out/probe"
"$out/probe" "$@"
