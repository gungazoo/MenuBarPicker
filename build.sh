#!/bin/bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
SRC="$SCRIPT_DIR/scripts/MenuBarPicker.swift"
PLIST="$SCRIPT_DIR/Info.plist"
APP="$SCRIPT_DIR/MenuBarPicker.app"
MACOS_DIR="$APP/Contents/MacOS"
BIN="$MACOS_DIR/MenuBarPicker"

# Also keep a bare symlink at the repo root for convenience
LINK="$SCRIPT_DIR/MenuBarPicker"

if [ ! -f "$SRC" ]; then
    echo "error: source not found: $SRC" >&2
    exit 1
fi
if [ ! -f "$PLIST" ]; then
    echo "error: Info.plist not found: $PLIST" >&2
    exit 1
fi

echo "Building MenuBarPicker.app…"

# ── Create .app bundle structure ────────────────────────────────
mkdir -p "$MACOS_DIR"
cp "$PLIST" "$APP/Contents/Info.plist"

# ── Compile ─────────────────────────────────────────────────────
swiftc -O -o "$BIN" "$SRC" \
    -framework Cocoa -framework ApplicationServices

# ── Code-sign with stable identity ──────────────────────────────
# Ad-hoc sign, but bound to the bundle's Info.plist.  The TCC entry
# is keyed by CFBundleIdentifier (com.gungazoo.MenuBarPicker), which
# survives rebuilds.  Replace "-" with a Developer ID if available.
codesign --force --sign - \
    --identifier com.gungazoo.MenuBarPicker \
    --options runtime \
    "$APP"

# ── Convenience symlink ────────────────────────────────────────
rm -f "$LINK"
ln -s "MenuBarPicker.app/Contents/MacOS/MenuBarPicker" "$LINK"

echo "Built: $APP"
codesign -dvv "$APP" 2>&1 | grep -E 'Identifier=|CDHash=|Signature=' || true
echo ""
echo "╔══════════════════════════════════════════════════════════════╗"
echo "║  IMPORTANT: Launch via 'open' for correct TCC identity      ║"
echo "╚══════════════════════════════════════════════════════════════╝"
echo ""
echo "Usage (direct, for testing in Terminal — Terminal needs Accessibility):"
echo "  $BIN                  # auto-detect frontmost app"
echo "  $BIN -pid 1234        # target a specific PID"
echo "  $BIN -v               # verbose PID resolution timing"
echo "  $BIN --benchmark      # benchmark all resolution strategies"
echo ""
echo "Usage (from Shortcuts — single 'Run Shell Script' action):"
echo ""
echo "  ── Copy this exactly into a 'Run Shell Script' action ──"
echo "  PID=\$(lsappinfo info -only pid \$(lsappinfo front) | grep -o '[0-9]*')"
echo "  open -g \"$APP\" --args -pid \"\$PID\""
echo "  # Wait for picker to finish (open can't block LSUIElement apps)"
echo "  while pgrep -f 'MenuBarPicker.app/Contents/MacOS/MenuBarPicker' >/dev/null 2>&1; do"
echo "    sleep 0.2"
echo "  done"
echo ""
echo "TCC setup (one-time):"
echo "  1. System Settings → Privacy & Security → Accessibility"
echo "  2. Remove any old 'MenuBarPicker' entries"
echo "  3. Add MenuBarPicker.app (drag from Finder, or '+' and navigate)"
echo "  4. The identity is now stable — rebuilds no longer require re-adding"
echo "  5. NO per-app 'Device Control' or 'Automation' prompts needed"
echo ""
echo "TCC reset (if upgrading from a broken state):"
echo "  tccutil reset Accessibility com.gungazoo.MenuBarPicker"
echo "  tccutil reset AppleEvents com.gungazoo.MenuBarPicker"
echo "  Then re-add in System Settings → Accessibility"
