#!/bin/bash
# Copyright 2026 DUO你电脑 contributors. SPDX-License-Identifier: Apache-2.0
set -euo pipefail
cd "$(dirname "$0")/../../.."
if [[ -f Local/developer-env.sh ]]; then source Local/developer-env.sh; fi
[[ $# -le 2 ]] || { echo "usage: $0 [NEW_OUTPUT_DIRECTORY] [--trust-revocation-only|--trust-regrant-only]" >&2; exit 64; }
if [[ $# -ge 1 ]]; then out="$1"; mkdir "$out"; else out="$PWD/.build/duodesk-touch-bar-egress"; mkdir -p "$out"; fi
mode="${2:-}"
[[ -z "$mode" || "$mode" == "--trust-revocation-only" || "$mode" == "--trust-regrant-only" ]] || { echo "unknown mode" >&2; exit 64; }
python3 - "$out/LoopbackTouchBar.swift" "$mode" <<'PY'
from pathlib import Path
import sys
source = Path('Tests/duodesk/own-window-capture/LoopbackVideo.swift').read_text()
needle = 'case .frame: decoder.enqueue(payload, isKeyframe: header.isKeyframe)\n                default: break'
assert source.count(needle) == 1
source = source.replace(needle, 'case .frame: decoder.enqueue(payload, isKeyframe: header.isKeyframe)\n                case .touchBarFrame: TouchBarObserver.shared.receive(payload)\n                case .goodbye: GoodbyeObserver.shared.receive(payload)\n                default: break')
if sys.argv[2] in ('--trust-revocation-only', '--trust-regrant-only'):
    replacements = {
        'RemoteTLS.quicOptions(identity: device.tls': 'RemoteTLS.options(identity: device.tls',
        'RemoteTLS.quicParameters(options: options)': 'RemoteTLS.parameters(tls: options, dialing: true)',
        'connection.metadata(definition: NWProtocolQUIC.definition) != nil': 'connection.metadata(definition: NWProtocolTLS.definition) != nil',
        'OWN LOOPBACK QUIC READY:': 'OWN LOOPBACK TCP READY:'
    }
    for before, after in replacements.items():
        assert source.count(before) == 1
        source = source.replace(before, after)
Path(sys.argv[1]).write_text(source)
PY
swiftc -O -emit-library -emit-module -module-name StreamProtocol Sources/StreamProtocol/*.swift \
  -emit-module-path "$out/StreamProtocol.swiftmodule" -o "$out/libStreamProtocol.dylib"
swiftc -swift-version 5 -O -whole-module-optimization -warnings-as-errors -parse-as-library -package-name Sill -D DUO_TOUCH_BAR_EGRESS_TESTING \
  -Xfrontend -disable-access-control -I "$out" -L "$out" -lStreamProtocol -Xlinker -rpath -Xlinker "$out" \
  Sources/SillHost/*.swift iOSClient/HardwareHEVCDecoder.swift iOSClient/HardwareDecoderRouter.swift \
  "$out/LoopbackTouchBar.swift" Tests/duodesk/touch-bar-egress/main.swift -o "$out/check"
if [[ -n "$mode" ]]; then SILL_TEST_LOOPBACK=1 "$out/check" "$mode"; else SILL_TEST_LOOPBACK=1 "$out/check"; fi
