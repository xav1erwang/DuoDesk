#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/../../.."
mkdir -p .build/duo-local-diagnostics
swiftc -O Sources/StreamProtocol/DuoDiagnosticReport.swift Sources/StreamProtocol/DuoDiagnostics.swift \
    Tests/duodesk/local-diagnostics/main.swift -o .build/duo-local-diagnostics/check
.build/duo-local-diagnostics/check
