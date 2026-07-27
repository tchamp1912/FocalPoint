#!/usr/bin/env bash
# Symlink (or copy) this FocalPoint keymap into a Keychron QMK fork checkout so it
# can be built as keyboards/keychron/v1_max/ansi_encoder/keymaps/focalpoint.
#
# Usage:
#   ./install.sh /path/to/qmk_firmware            # symlink (default)
#   ./install.sh --copy /path/to/qmk_firmware     # hard copy instead
#
# The fork must be Keychron's github.com/Keychron/qmk_firmware on the
# wireless_playground branch (the V1 Max is not in upstream QMK).
set -euo pipefail

MODE="symlink"
if [[ "${1:-}" == "--copy" ]]; then MODE="copy"; shift; fi

QMK_ROOT="${1:?usage: install.sh [--copy] /path/to/qmk_firmware}"
SRC_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
DEST_DIR="$QMK_ROOT/keyboards/keychron/v1_max/ansi_encoder/keymaps/focalpoint"

if [[ ! -d "$QMK_ROOT/keyboards/keychron/v1_max/ansi_encoder" ]]; then
  echo "error: $QMK_ROOT does not look like a Keychron fork with v1_max" >&2
  exit 1
fi

mkdir -p "$(dirname "$DEST_DIR")"
rm -rf "$DEST_DIR"

if [[ "$MODE" == "symlink" ]]; then
  ln -s "$SRC_DIR" "$DEST_DIR"
  echo "symlinked $SRC_DIR -> $DEST_DIR"
else
  mkdir -p "$DEST_DIR"
  cp "$SRC_DIR"/keymap.c "$SRC_DIR"/focalpoint.c "$SRC_DIR"/focalpoint.h \
     "$SRC_DIR"/config.h "$SRC_DIR"/rules.mk "$DEST_DIR"/
  echo "copied keymap into $DEST_DIR"
fi

echo
echo "Build with:"
echo "  qmk compile -kb keychron/v1_max/ansi_encoder -km focalpoint"
