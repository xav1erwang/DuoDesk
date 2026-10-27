#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/../../.."
if [[ -f Local/developer-env.sh ]]; then source Local/developer-env.sh; fi
out="$PWD/.build/duodesk-encoder-duplicate"
mkdir -p "$out"
sed -e '/^import VideoToolbox$/d' -e '/^import StreamProtocol$/d' Sources/SillHost/HEVCEncoder.swift > "$out/HEVCEncoder.swift"
swiftc -O -module-name EncoderDuplicateCheck "$out/HEVCEncoder.swift" Sources/SillHost/EncoderMailbox.swift \
  Sources/SillHost/EncoderSlowState.swift Sources/SillHost/EncoderProbe.swift \
  Scripts/encoder-check/encoder/FakeVT.swift Tests/duodesk/encoder-duplicate-callback/main.swift -o "$out/check"
if otool -L "$out/check" | grep -q VideoToolbox || nm -u "$out/check" | grep -q '_VT'; then
  echo 'REFUSED: diagnostic unexpectedly links VideoToolbox' >&2
  exit 1
fi
SILL_TEST_ENCODER_RECYCLE=0 "$out/check"
