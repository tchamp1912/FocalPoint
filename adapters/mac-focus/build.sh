#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
OUTPUT="${1:-focalpoint-iterm-focus}"
xcrun clang -fobjc-arc -fblocks -O2 \
  -framework Foundation -framework AppKit -framework ScriptingBridge \
  "$SCRIPT_DIR/focalpoint-iterm-focus.m" -o "$OUTPUT"
echo "built: $OUTPUT"
