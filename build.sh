#!/bin/zsh
set -e
DIR="$(cd "$(dirname "$0")" && pwd)"
OUT="$DIR/WifiSignal"
PLIST_NAME="com.eric.wifisignal.plist"
LAUNCH_AGENTS="$HOME/Library/LaunchAgents"

echo "Building…"
swiftc "$DIR/WifiSignal.swift" \
    -framework Cocoa \
    -framework CoreWLAN \
    -o "$OUT"
echo "Built → $OUT"

if [[ "$1" == "--install" ]]; then
    echo "Installing LaunchAgent…"
    sed "s|INSTALL_DIR|$DIR|g" "$DIR/$PLIST_NAME" > "$LAUNCH_AGENTS/$PLIST_NAME"
    launchctl unload "$LAUNCH_AGENTS/$PLIST_NAME" 2>/dev/null || true
    launchctl load  "$LAUNCH_AGENTS/$PLIST_NAME"
    echo "Installed and started. WifiSignal will auto-start at login."
else
    echo "Run './WifiSignal &' to start, or 'bash build.sh --install' to auto-start at login."
fi
