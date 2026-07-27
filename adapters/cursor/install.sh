#!/bin/bash
# FocalPoint Cursor Adapter Installer
#
# Copies hooks.sh and focus-cursor.sh to ~/.config/focalpoint/adapters/ and
# prints the hooks block to merge into ~/.cursor/hooks.json.
# Usage: ./install.sh
#
# The repo-root ./install.sh does all of this AND merges the hooks block for
# you; this script is the manual path for people who'd rather edit their own
# hooks.json.
#
# MIT License - see adapters/README.md

set -u

ADAPTER_DIR="${HOME}/.config/focalpoint/adapters"
# Prefixed to sit alongside the Claude adapter's hooks.sh in the same
# directory without colliding.
HOOK_SCRIPT="${ADAPTER_DIR}/cursor-hooks.sh"
FOCUS_SCRIPT="${ADAPTER_DIR}/focus-cursor.sh"
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

mkdir -p "$ADAPTER_DIR"

if cp "$SCRIPT_DIR/hooks.sh" "$HOOK_SCRIPT"; then
  chmod +x "$HOOK_SCRIPT"
  echo "✓ Copied hooks.sh to $HOOK_SCRIPT"
else
  echo "✗ Failed to copy hooks.sh to $HOOK_SCRIPT" >&2
  exit 1
fi

if cp "$SCRIPT_DIR/focus-cursor.sh" "$FOCUS_SCRIPT"; then
  chmod +x "$FOCUS_SCRIPT"
  echo "✓ Copied focus-cursor.sh to $FOCUS_SCRIPT"
else
  echo "✗ Failed to copy focus-cursor.sh to $FOCUS_SCRIPT" >&2
  exit 1
fi

echo ""
echo "╔════════════════════════════════════════════════════════════════╗"
echo "║ FocalPoint Cursor Adapter Installed                            ║"
echo "╚════════════════════════════════════════════════════════════════╝"
echo ""
echo "To enable FocalPoint integration, merge the following into"
echo "~/.cursor/hooks.json (user-level, applies to every workspace):"
echo ""
echo "────────────────────────────────────────────────────────────────"

# Print the fragment with the real absolute path substituted in. Cursor's
# handling of ${HOME} in hook commands is undocumented, and user-level hook
# paths resolve relative to ~/.cursor, so a resolved path is the safe form.
if command -v jq >/dev/null 2>&1; then
  jq --arg cmd "$HOOK_SCRIPT" \
    '.hooks |= with_entries(.value |= [ .[] | .command = $cmd ])' \
    "$SCRIPT_DIR/hooks-fragment.json"
else
  sed "s|\${HOME}/.config/focalpoint/adapters/cursor-hooks.sh|$HOOK_SCRIPT|g" \
    "$SCRIPT_DIR/hooks-fragment.json"
fi

echo "────────────────────────────────────────────────────────────────"
echo ""
echo "If ~/.cursor/hooks.json doesn't exist yet, create it with:"
echo "  mkdir -p ~/.cursor"
echo "  echo '{\"version\": 1}' > ~/.cursor/hooks.json"
echo ""
echo "If you already have hooks for these events, APPEND FocalPoint's entry"
echo "to each event's array rather than replacing it — Cursor runs every"
echo "command listed for an event."
echo ""
echo "Cursor picks up hooks.json on save; if the Hooks tab in Cursor"
echo "Settings doesn't list them, restart Cursor."
echo ""
echo "Note: Make sure the focalpointd daemon is running for the hooks to"
echo "have any effect. See adapters/README.md for daemon installation."
echo ""
echo "Note: focusing a Cursor session from its numbered key (PROTOCOL.md §3"
echo "'Focus') goes through the shared router, which dispatches to"
echo "focus-cursor.sh by session kind. Point [session].focus in"
echo "~/.config/focalpoint/config.toml at the Claude adapter's script:"
echo ""
echo "  [session]"
echo "  focus = { type = \"shell\", run = \"$ADAPTER_DIR/focus-session.sh\" }"
echo ""
echo "Focus resolves to the Cursor WINDOW for the session's workspace, not"
echo "the individual chat — see README.md for why."
echo ""
