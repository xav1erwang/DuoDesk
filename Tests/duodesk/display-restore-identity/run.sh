#!/bin/bash
# Copyright 2026 DUO你电脑 contributors. SPDX-License-Identifier: Apache-2.0
set -euo pipefail
cd "$(dirname "$0")/../../.."
if [[ -f Local/developer-env.sh ]]; then source Local/developer-env.sh; fi
out="$PWD/.build/duodesk-display-restore-identity"
mkdir -p "$out"
swiftc -O -warnings-as-errors Sources/SillHost/DisplayRestoreIdentity.swift Tests/duodesk/display-restore-identity/main.swift -o "$out/check"
"$out/check"
