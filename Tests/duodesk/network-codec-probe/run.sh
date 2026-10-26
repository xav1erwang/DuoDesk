#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/../../.."
out="$PWD/.build/duodesk-network-codec-probe"
mkdir -p "$out"
swiftc -O -emit-library -emit-module -module-name StreamProtocol Sources/StreamProtocol/*.swift \
    -emit-module-path "$out/StreamProtocol.swiftmodule" -o "$out/libStreamProtocol.dylib"
swiftc -O -I "$out" -L "$out" -lStreamProtocol -Xlinker -rpath -Xlinker "$out" \
    iOSClient/DeviceTLS.swift iOSClient/HardwareHEVCDecoder.swift iOSClient/HardwareVideoPresenter.swift \
    iOSClient/DuoControlModel.swift iOSClient/KeyChords.swift \
    Tests/duodesk/capture-probe/PixelMotionAudit.swift \
    Tests/duodesk/network-codec-probe/ProbePairingInput.swift \
    Tests/duodesk/network-codec-probe/ProbeKeyboardCases.swift \
    Tests/duodesk/network-codec-probe/ProbeIMECases.swift \
    Tests/duodesk/network-codec-probe/main.swift -o "$out/probe"
if [[ "${1:-}" != "--build-only" ]]; then "$out/probe" "$@"; fi
