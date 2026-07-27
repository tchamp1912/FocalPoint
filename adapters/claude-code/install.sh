#!/bin/bash
# FocalPoint Claude Code Adapter Installer
#
# Copies hooks.sh, focus-session.sh, and statusline-usage.sh to
# ~/.config/focalpoint/adapters/ and
# prints setup instructions
# Usage: ./install.sh
#
# MIT License - see adapters/README.md

set -u

ADAPTER_DIR="${HOME}/.config/focalpoint/adapters"
HOOK_SCRIPT="${ADAPTER_DIR}/hooks.sh"
FOCUS_SCRIPT="${ADAPTER_DIR}/focus-session.sh"
USAGE_SCRIPT="${ADAPTER_DIR}/statusline-usage.sh"
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# Create adapter directory
mkdir -p "$ADAPTER_DIR"

# Copy hooks.sh
if cp "$SCRIPT_DIR/hooks.sh" "$HOOK_SCRIPT"; then
  chmod +x "$HOOK_SCRIPT"
  echo "✓ Copied hooks.sh to $HOOK_SCRIPT"
else
  echo "✗ Failed to copy hooks.sh to $HOOK_SCRIPT" >&2
  exit 1
fi

# Copy the optional local-only subscription usage reporter.
if cp "$SCRIPT_DIR/statusline-usage.sh" "$USAGE_SCRIPT"; then
  chmod +x "$USAGE_SCRIPT"
  echo "✓ Copied statusline-usage.sh to $USAGE_SCRIPT"
else
  echo "✗ Failed to copy statusline-usage.sh to $USAGE_SCRIPT" >&2
  exit 1
fi

# Copy focus-session.sh (the default [session] focus action — see
# PROTOCOL.md §3 "Focus" and §5)
if cp "$SCRIPT_DIR/focus-session.sh" "$FOCUS_SCRIPT"; then
  chmod +x "$FOCUS_SCRIPT"
  echo "✓ Copied focus-session.sh to $FOCUS_SCRIPT"
else
  echo "✗ Failed to copy focus-session.sh to $FOCUS_SCRIPT" >&2
  exit 1
fi

# Print settings fragment with instructions
echo ""
echo "╔════════════════════════════════════════════════════════════════╗"
echo "║ FocalPoint Claude Code Adapter Installed                          ║"
echo "╚════════════════════════════════════════════════════════════════╝"
echo ""
echo "To enable FocalPoint integration, add the following 'hooks' block to"
echo "~/.claude/settings.json (or ~/.claude/settings.local.json if you"
echo "prefer to keep it out of version control):"
echo ""
echo "────────────────────────────────────────────────────────────────"

# Read and print settings fragment with proper formatting
python3 << 'PYTHON_EOF'
import json

with open('settings-fragment.json', 'r') as f:
    data = json.load(f)

# Pretty print with 2-space indent
print(json.dumps(data, indent=2))
PYTHON_EOF

echo "────────────────────────────────────────────────────────────────"
echo ""
echo "If ~/.claude/settings.json doesn't exist yet, create it with:"
echo "  mkdir -p ~/.claude"
echo "  echo '{}' > ~/.claude/settings.json"
echo ""
echo "Then merge the hooks block above into the top-level of that file."
echo ""
echo "Optional — show Claude subscription limits in FocalPoint:"
echo "Add this top-level statusLine command if you do not already use one:"
echo ""
echo "  \"statusLine\": { \"type\": \"command\", \"command\": \"bash $USAGE_SCRIPT\" }"
echo ""
echo "The reporter sends only rate-limit percentages/reset timestamps to the"
echo "local daemon. If you already have a status line, wrap both commands"
echo "instead of replacing it."
echo ""
echo "Note: Make sure the focalpointd daemon is running for the hooks to"
echo "have any effect. See adapters/README.md for daemon installation."
echo ""
echo "Note: to have the numbered keys bring a session's terminal to the"
echo "front when pressed (PROTOCOL.md §3 'Focus'), point [session].focus"
echo "in ~/.config/focalpoint/config.toml at the copied focus-session.sh:"
echo ""
echo "  [session]"
echo "  focus = { type = \"shell\", run = \"$FOCUS_SCRIPT\" }"
echo ""
echo "This is a best-effort heuristic (see comments in focus-session.sh) —"
echo "it matches on terminal window/tab titles, not a real session lookup."
echo ""
