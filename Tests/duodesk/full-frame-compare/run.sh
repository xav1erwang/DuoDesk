#!/bin/bash
# Copyright 2026 DUO你电脑 contributors. SPDX-License-Identifier: Apache-2.0
# In-memory GPU plane comparison; no system capture, display, network or input.
set -euo pipefail
cd "$(dirname "$0")/../../.."
if [[ -f Local/developer-env.sh ]]; then source Local/developer-env.sh; fi
if [[ $# -ne 1 ]]; then echo "usage: $0 NEW_OUTPUT_DIRECTORY" >&2; exit 64; fi
out="$1"
mkdir "$out"
swiftc -swift-version 5 -O -warnings-as-errors -parse-as-library \
  Tests/duodesk/full-frame-compare/FramePlaneComparison.swift \
  Tests/duodesk/full-frame-compare/Harness.swift -o "$out/check"
"$out/check"
