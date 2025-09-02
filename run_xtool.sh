#!/bin/bash

# xtool runner script - attempts to run the real xtool if available, 
# otherwise runs the demo version

set -e

SCRIPT_DIR="$(dirname "$0")"
DEMO_XTOOL="$SCRIPT_DIR/demo_xtool.py"

# Try to find the real xtool binary
REAL_XTOOL=""
if [ -f ".build/debug/xtool" ]; then
    REAL_XTOOL=".build/debug/xtool"
elif [ -f ".build/release/xtool" ]; then
    REAL_XTOOL=".build/release/xtool"
elif command -v xtool >/dev/null 2>&1; then
    REAL_XTOOL="xtool"
fi

echo "xtool - Cross-platform Xcode replacement"
echo "========================================"

if [ -n "$REAL_XTOOL" ]; then
    echo "Using real xtool binary: $REAL_XTOOL"
    echo
    exec "$REAL_XTOOL" "$@"
else
    echo "Real xtool binary not found. Using demonstration version."
    echo "Note: This demo shows xtool's intended functionality."
    echo
    exec "$DEMO_XTOOL" "$@"
fi