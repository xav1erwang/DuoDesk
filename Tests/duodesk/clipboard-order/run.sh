#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/../../.."
mkdir -p .build/duo-clipboard-order
python3 - <<'PY'
from pathlib import Path
source = Path('Sources/SillHost/HostClipboard.swift').read_text().replace('import StreamProtocol\n', '')
Path('.build/duo-clipboard-order/HostClipboard.swift').write_text(source)
PY
swiftc -O -package-name DuoClipboardOrder Sources/StreamProtocol/*.swift Sources/SillHost/RefusalSummary.swift \
    .build/duo-clipboard-order/HostClipboard.swift Tests/duodesk/clipboard-order/main.swift \
    -o .build/duo-clipboard-order/check
.build/duo-clipboard-order/check
