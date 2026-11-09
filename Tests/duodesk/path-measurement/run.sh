#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/../../.."
mkdir -p .build/duo-path-measurement
stage=$(mktemp -d)
trap 'rm -rf "$stage"' EXIT
sed '/^import StreamProtocol$/d' Sources/SillHost/LocalPathProbeServer.swift > "$stage/LocalPathProbeServer.swift"
swiftc -O -package-name sill Sources/StreamProtocol/*.swift \
    iOSClient/LocalPathQuality.swift iOSClient/LocalPathMeasurements.swift \
    iOSClient/LocalPathProbe.swift iOSClient/MessageReader.swift \
    "$stage/LocalPathProbeServer.swift" Tests/duodesk/path-measurement/main.swift \
    -o .build/duo-path-measurement/check
.build/duo-path-measurement/check
