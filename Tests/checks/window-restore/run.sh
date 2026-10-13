#!/bin/bash
# WindowRestore (Sources/SillHost/WindowRestore.swift; docs/restore-window-frames-plan.md, issue #57):
# a window Sill sized for a device goes back when it stops streaming. The rule at its edges (`keep`,
# `fitted`, `decide` for every outcome, `homeForStage`, the ledger, the lines), then a model of the
# coordinator's glue against a stand-in Mac: 5,000 random sessions of picks, viewports, restarts, the
# person at the Mac moving, resizing, closing and full-screening windows, apps that clamp, snap or
# apply a size late, the virtual display on and off, the last device leaving and Quit.
# Compiled alone with swiftc (Foundation and CoreGraphics).
#   Tests/checks/window-restore/run.sh             compile and run the check
#   Tests/checks/window-restore/run.sh --mutants   one-line mutants of WindowRestore.swift; each must fail it
here="$(cd "$(dirname "$0")" && pwd)"
source "$here/../common.sh"
if [ "${1:-}" = "--mutants" ]; then run_mutants python3 "$here/mutants.py" "$root"; exit; fi
rm -f "$out/check"
"$here/build.sh" "$root" "$out/check"
[ -x "$out/check" ] || { echo "$name: did not compile" >&2; exit 1; }
"$out/check"
