#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/../../.."
mkdir -p .build/duo-local-path-selection
swiftc -O iOSClient/LocalPathQuality.swift iOSClient/LocalPathTrial.swift iOSClient/MessageReader.swift \
    Sources/StreamProtocol/StreamMessage.swift Tests/duodesk/local-path-selection/main.swift \
    -o .build/duo-local-path-selection/check
.build/duo-local-path-selection/check
