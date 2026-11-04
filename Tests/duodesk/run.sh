#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/../.."
out="$PWD/.build/duodesk-checks"
mkdir -p "$out"
swiftc -emit-library -emit-module -module-name StreamProtocol Sources/StreamProtocol/*.swift \
    -emit-module-path "$out/StreamProtocol.swiftmodule" -o "$out/libStreamProtocol.dylib"
swiftc -I "$out" -L "$out" -lStreamProtocol -Xlinker -rpath -Xlinker "$out" \
    iOSClient/DuoControlModel.swift iOSClient/KeyChords.swift Tests/duodesk/main.swift -o "$out/checks"
"$out/checks"
python3 -m unittest discover -s Tests/duodesk -p 'test_*.py'
Tests/duodesk/identity-startup/run.sh
