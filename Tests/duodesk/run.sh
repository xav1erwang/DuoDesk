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
python3 Tests/duodesk/signing-device-version/main.py
python3 Tests/duodesk/signing-source-pin/main.py
python3 Tests/duodesk/signing-monitor/main.py
python3 Tests/duodesk/signing-export-refresh/main.py
python3 Tests/duodesk/signing-profile-cache/main.py
Tests/duodesk/identity-startup/run.sh
