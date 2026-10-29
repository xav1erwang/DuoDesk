#!/bin/bash
# Copyright 2026 DUO你电脑 contributors. SPDX-License-Identifier: Apache-2.0
set -euo pipefail
cd "$(dirname "$0")/../../.."
[[ $# -eq 2 ]] || { echo "usage: $0 BUILT_APP NEW_OUTPUT_DIRECTORY" >&2; exit 64; }
app="$(cd "$(dirname "$1")" && pwd)/$(basename "$1")"
mkdir "$2"
out="$(cd "$2" && pwd)"
open -n -W --stdout "$out/stdout.log" --stderr "$out/stderr.log" "$app"
cat "$out/stdout.log"
if [[ -s "$out/stderr.log" ]]; then cat "$out/stderr.log" >&2; fi
grep -Fxq 'ODD SCK PIPELINE PASS' "$out/stdout.log"
