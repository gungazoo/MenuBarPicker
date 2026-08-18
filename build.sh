#!/bin/bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
SRC="$SCRIPT_DIR/scripts/MenuBarPicker.swift"
OUT="$SCRIPT_DIR/MenuBarPicker"

if [ ! -f "$SRC" ]; then
    echo "error: source not found: $SRC" >&2
    exit 1
fi

echo "Building MenuBarPicker…"
swiftc -O -o "$OUT" "$SRC" \
    -framework Cocoa -framework ApplicationServices

echo "Built: $OUT"
echo ""
echo "Usage:"
echo "  ./MenuBarPicker               # auto-detect frontmost app"
echo "  ./MenuBarPicker -pid 1234     # target a specific PID"
echo "  ./MenuBarPicker -v            # verbose PID resolution timing"
echo "  ./MenuBarPicker --benchmark   # benchmark all resolution strategies"
