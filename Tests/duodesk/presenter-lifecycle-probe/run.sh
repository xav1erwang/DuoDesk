#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/../../.."
if [[ -f Local/developer-env.sh ]]; then source Local/developer-env.sh; fi
out="$PWD/.build/duodesk-presenter-lifecycle"
mkdir -p "$out"
presenter_source="iOSClient/HardwareVideoPresenter.swift"
if [[ "${1:-}" == "--flush-required" ]]; then
    presenter_source="$out/HardwareVideoPresenter-resume.swift"
    python3 - "$presenter_source" <<'PY'
from pathlib import Path
import sys
source = Path('iOSClient/HardwareVideoPresenter.swift').read_text()
needle = 'let result = try await receiver.enqueue(ready)'
assert source.count(needle) == 1
source = source.replace(needle, '''let result: AVSampleBufferVideoRenderer.Receiver.EnqueueResult
                    if PresenterResumeFault.shared.take() {
                        result = .cancelledDueToFlushRequiredToResume(NSError(domain: AVFoundationErrorDomain, code: -11847))
                    } else {
                        result = try await receiver.enqueue(ready)
                    }''')
Path(sys.argv[1]).write_text(source)
PY
fi
swiftc -O -swift-version 6 -strict-concurrency=complete -warnings-as-errors -emit-library -emit-module \
    -module-name StreamProtocol Sources/StreamProtocol/VideoDecodeBacklog.swift \
    -emit-module-path "$out/StreamProtocol.swiftmodule" -o "$out/libStreamProtocol.dylib"
swiftc -O -swift-version 6 -strict-concurrency=complete -warnings-as-errors -parse-as-library \
    -I "$out" -L "$out" -lStreamProtocol -Xlinker -rpath -Xlinker "$out" \
    "$presenter_source" Tests/duodesk/presenter-lifecycle-probe/main.swift -o "$out/checks"
if [[ "${1:-}" != "--build-only" ]]; then "$out/checks" "$@"; fi
