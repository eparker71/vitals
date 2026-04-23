#!/bin/zsh
set -e
DIR="$(cd "$(dirname "$0")" && pwd)"
OUT="$DIR/Vitals"
PLIST_NAME="com.eric.vitals.plist"
LAUNCH_AGENTS="$HOME/Library/LaunchAgents"

echo "Building…"
swiftc "$DIR/Vitals.swift" \
    -framework Cocoa \
    -framework CoreWLAN \
    -framework IOKit \
    -o "$OUT"
echo "Built → $OUT"

if [[ "$1" == "--install" ]]; then
    echo "Installing LaunchAgent…"
    sed "s|INSTALL_DIR|$DIR|g" "$DIR/$PLIST_NAME" > "$LAUNCH_AGENTS/$PLIST_NAME"
    launchctl unload "$LAUNCH_AGENTS/$PLIST_NAME" 2>/dev/null || true
    launchctl load  "$LAUNCH_AGENTS/$PLIST_NAME"
    echo "Installed and started. Vitals will auto-start at login."
else
    echo "Run './Vitals &' to start, or 'bash build.sh --install' to auto-start at login."
fi
