#!/bin/bash
# Copyright 2026 DUO你电脑 contributors. SPDX-License-Identifier: Apache-2.0
# Pure association checks plus GPU sampling of synthetic owned buffers; no screen capture.
set -euo pipefail
cd "$(dirname "$0")/../../.."
if [[ -f Local/developer-env.sh ]]; then source Local/developer-env.sh; fi
out="$PWD/.build/duodesk-marker-content-correlation"
mkdir -p "$out"
swiftc -swift-version 5 -O -whole-module-optimization -warnings-as-errors -parse-as-library \
  Tests/duodesk/capture-probe/PixelMotionAudit.swift Tests/duodesk/own-window-capture/PhaseSelection.swift \
  Tests/duodesk/own-window-capture/MarkerContentCorrelation.swift Tests/duodesk/own-window-capture/SamplePhaseStudy.swift \
  Tests/duodesk/marker-content-correlation/main.swift -o "$out/check"
if [[ "${1:-}" != "--build-only" ]]; then "$out/check"; fi
