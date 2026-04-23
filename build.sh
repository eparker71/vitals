#!/bin/zsh
set -e
DIR="$(cd "$(dirname "$0")" && pwd)"
OUT="$DIR/WifiSignal"

echo "Building…"
swiftc "$DIR/WifiSignal.swift" \
    -framework Cocoa \
    -framework CoreWLAN \
    -o "$OUT"

echo "Done → $OUT"
echo "Run with:  open -a Terminal '$OUT'  OR  '$OUT' &"
