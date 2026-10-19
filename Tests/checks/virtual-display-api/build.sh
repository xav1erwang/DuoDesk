#!/bin/bash
# usage: build.sh WT OUT [VirtualDisplay.swift override]
# Compiles Sources/SillHost/VirtualDisplay.swift whole (Foundation, CoreGraphics, ObjectiveC), as
# VirtualDisplayProbe compiles it, with this check's main.swift, which runs only its static surface
# and its pure TypeEncoding: no private class is looked up and no display is made.
WT=$1; OUT=$2; T=$(mktemp -d)
cp "${3:-$WT/Sources/SillHost/VirtualDisplay.swift}" "$T/VirtualDisplay.swift"
cp "$(dirname "$0")/main.swift" "$T/main.swift"
swiftc -O "$T"/*.swift -o "$OUT" 2>&1 | grep -E "error|warning" ; rm -rf "$T"
