#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/../../.."
swift build -c release --product SillMenuBar
bin="$(swift build -c release --product SillMenuBar --show-bin-path)"
package_name="$(swift package show-dependencies --format json | python3 -c 'import json,sys; print(json.load(sys.stdin)["identity"])')"
out="$PWD/.build/duodesk-identity-startup"
mkdir -p "$out"
if [ -f "$bin/SillHostCore.o" ]; then
    # Xcode's build engine emits one merged object and architecture-specific module bundles.
    modules="$bin"
    objects=("$bin/SillHostCore.o" "$bin/StreamProtocol.o")
else
    modules="$bin/Modules"
    objects=("$bin/SillHostCore.build/"*.o "$bin/StreamProtocol.build/"*.o)
fi
swiftc -swift-version 6 -strict-concurrency=complete -warnings-as-errors -parse-as-library \
    -package-name "$package_name" -I "$modules" Tests/duodesk/identity-startup/main.swift \
    "${objects[@]}" -o "$out/checks"
"$out/checks"
