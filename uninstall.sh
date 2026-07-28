#!/usr/bin/env bash
# FocalPoint uninstaller.
#
# MIT License - see adapters/README.md.
#
# Reverses what install.sh did: stops + removes the launchd agent, removes
# the focalpoint/focalpointd symlinks, surgically removes only FocalPoint's hook
# entries from ~/.claude/settings.json and ~/.cursor/hooks.json (each backed
# up first), and removes
# FocalPoint.app. Safe to re-run: every step checks before it acts.
#
#   ./uninstall.sh                dry-run-free, prompts before deleting config
#   ./uninstall.sh --yes          no prompts (still deletes config unless...)
#   ./uninstall.sh --keep-config  leaves ~/.config/focalpoint alone
#   ./uninstall.sh --dry-run      prints what would happen, changes nothing

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
DAEMON_DIR="$SCRIPT_DIR/daemon"

CONFIG_DIR="${XDG_CONFIG_HOME:-$HOME/.config}/focalpoint"
CLAUDE_SETTINGS="$HOME/.claude/settings.json"
CURSOR_HOOKS="$HOME/.cursor/hooks.json"
CODEX_HOOKS="$HOME/.codex/hooks.json"
LOG_DIR="$HOME/Library/Logs/focalpoint"
LAUNCH_AGENTS_DIR="$HOME/Library/LaunchAgents"
PLIST_LABEL="dev.focalpoint.daemon"
PLIST_PATH="$LAUNCH_AGENTS_DIR/${PLIST_LABEL}.plist"
HOOK_MARKER=".config/focalpoint/adapters/hooks.sh"
# The "cursor-" prefix keeps this from matching HOOK_MARKER's entries.
CURSOR_HOOK_MARKER=".config/focalpoint/adapters/cursor-hooks.sh"
CODEX_HOOK_MARKER=".config/focalpoint/adapters/codex-hooks.sh"
REPO_MARKER="$SCRIPT_DIR/daemon/target"

ASSUME_YES=0
KEEP_CONFIG=0
DRY_RUN=0
REMOVE_LOGS=0

for arg in "$@"; do
  case "$arg" in
    --yes|-y) ASSUME_YES=1 ;;
    --keep-config) KEEP_CONFIG=1 ;;
    --dry-run) DRY_RUN=1 ;;
    --remove-logs) REMOVE_LOGS=1 ;;
    -h|--help)
      cat <<EOF
Usage: ./uninstall.sh [--yes] [--keep-config] [--dry-run] [--remove-logs]

  --yes           skip confirmation prompts
  --keep-config   leave ~/.config/focalpoint (and your config.toml) in place
  --dry-run       print what would happen; make no changes
  --remove-logs   also delete ~/Library/Logs/focalpoint
  --help          show this help and exit
EOF
      exit 0
      ;;
    *)
      echo "unknown argument: $arg (see --help)" >&2
      exit 1
      ;;
  esac
done

if [ -t 1 ]; then
  C_GREEN=$'\033[0;32m'; C_RED=$'\033[0;31m'; C_YELLOW=$'\033[0;33m'
  C_BLUE=$'\033[0;34m'; C_BOLD=$'\033[1m'; C_RESET=$'\033[0m'
else
  C_GREEN=""; C_RED=""; C_YELLOW=""; C_BLUE=""; C_BOLD=""; C_RESET=""
fi

ok()   { printf '%s✓%s %s\n' "$C_GREEN" "$C_RESET" "$1"; }
info() { printf '%s→%s %s\n' "$C_YELLOW" "$C_RESET" "$1"; }
fail() { printf '%s✗%s %s\n' "$C_RED" "$C_RESET" "$1" >&2; }
step() { printf '\n%s==>%s %s%s%s\n' "$C_BLUE" "$C_RESET" "$C_BOLD" "$1" "$C_RESET"; }
would() { printf '%s→ [dry-run]%s %s\n' "$C_YELLOW" "$C_RESET" "$1"; }

if [ "$DRY_RUN" -eq 1 ]; then
  info "dry run: no changes will be made"
fi

# ---------------------------------------------------------------------------
# 1. launchd agent
# ---------------------------------------------------------------------------

step "launchd agent"

if launchctl print "gui/$UID/$PLIST_LABEL" >/dev/null 2>&1; then
  if [ "$DRY_RUN" -eq 1 ]; then
    would "launchctl bootout gui/$UID/$PLIST_LABEL"
  else
    launchctl bootout "gui/$UID/$PLIST_LABEL" >/dev/null 2>&1 || true
    ok "stopped + unloaded $PLIST_LABEL"
  fi
else
  ok "$PLIST_LABEL not loaded"
fi

if [ -f "$PLIST_PATH" ]; then
  if [ "$DRY_RUN" -eq 1 ]; then
    would "rm $PLIST_PATH"
  else
    rm -f "$PLIST_PATH"
    ok "removed $PLIST_PATH"
  fi
else
  ok "$PLIST_PATH already absent"
fi

# Also stop a stray manually-started focalpointd, if any.
if pgrep -x focalpointd >/dev/null 2>&1; then
  if [ "$DRY_RUN" -eq 1 ]; then
    would "pkill -x focalpointd"
  else
    pkill -x focalpointd 2>/dev/null || true
    ok "stopped a running focalpointd"
  fi
fi

# ---------------------------------------------------------------------------
# 2. Symlinks
# ---------------------------------------------------------------------------

step "Binaries"

for dir in /opt/homebrew/bin "$HOME/.local/bin"; do
  for bin in focalpoint focalpointd; do
    link="$dir/$bin"
    if [ -L "$link" ]; then
      target="$(readlink "$link")"
      case "$target" in
        "$REPO_MARKER"*)
          if [ "$DRY_RUN" -eq 1 ]; then
            would "rm $link (-> $target)"
          else
            rm -f "$link"
            ok "removed $link"
          fi
          ;;
        *)
          info "leaving $link alone — points elsewhere ($target)"
          ;;
      esac
    fi
  done
done

# ---------------------------------------------------------------------------
# 3. Config (prompt unless --keep-config or --yes)
# ---------------------------------------------------------------------------

step "Config"

if [ "$KEEP_CONFIG" -eq 1 ]; then
  info "--keep-config passed — leaving $CONFIG_DIR in place"
elif [ ! -d "$CONFIG_DIR" ]; then
  ok "$CONFIG_DIR already absent"
elif [ "$DRY_RUN" -eq 1 ]; then
  would "prompt to remove $CONFIG_DIR (rm -rf), including your config.toml"
else
  REMOVE_CONFIG=0
  if [ "$ASSUME_YES" -eq 1 ]; then
    REMOVE_CONFIG=1
  else
    printf 'Remove %s (including your config.toml and adapter scripts)? [y/N] ' "$CONFIG_DIR"
    read -r REPLY
    case "$REPLY" in
      [yY]|[yY][eE][sS]) REMOVE_CONFIG=1 ;;
      *) REMOVE_CONFIG=0 ;;
    esac
  fi
  if [ "$REMOVE_CONFIG" -eq 1 ]; then
    rm -rf "$CONFIG_DIR"
    ok "removed $CONFIG_DIR"
  else
    info "kept $CONFIG_DIR"
  fi
fi

# ---------------------------------------------------------------------------
# 4. Claude Code hooks — surgical removal, backed up first
# ---------------------------------------------------------------------------

step "Claude Code hooks"

if [ ! -f "$CLAUDE_SETTINGS" ]; then
  ok "$CLAUDE_SETTINGS doesn't exist — nothing to do"
elif ! jq -e --arg marker "$HOOK_MARKER" \
       '[.. | select(type == "string") | select(contains($marker))] | length > 0' \
       "$CLAUDE_SETTINGS" >/dev/null 2>&1; then
  ok "no focalpoint hooks found in settings.json — nothing to do"
elif [ "$DRY_RUN" -eq 1 ]; then
  would "back up $CLAUDE_SETTINGS and remove focalpoint hook entries from it"
else
  BACKUP="$CLAUDE_SETTINGS.bak-focalpoint-$(date +%Y%m%d%H%M%S)"
  cp "$CLAUDE_SETTINGS" "$BACKUP"
  ok "backed up settings.json -> $BACKUP"

  CLEANED="$(jq --arg marker "$HOOK_MARKER" '
    .hooks = ((.hooks // {})
      | with_entries(
          .value |= [ .[] | select(
            ([.hooks[]?.command // "" | tostring] | any(contains($marker))) | not
          ) ]
        )
      | with_entries(select(.value | length > 0)))
    | if (.hooks | length) == 0 then del(.hooks) else . end
  ' "$CLAUDE_SETTINGS")"
  printf '%s\n' "$CLEANED" > "$CLAUDE_SETTINGS"
  ok "removed focalpoint hooks from settings.json"
fi

# ---------------------------------------------------------------------------
# 4b. Cursor hooks — surgical removal, backed up first
# ---------------------------------------------------------------------------

step "Cursor hooks"

if [ ! -f "$CURSOR_HOOKS" ]; then
  ok "$CURSOR_HOOKS doesn't exist — nothing to do"
elif ! jq -e --arg marker "$CURSOR_HOOK_MARKER" \
       '[.. | select(type == "string") | select(contains($marker))] | length > 0' \
       "$CURSOR_HOOKS" >/dev/null 2>&1; then
  ok "no focalpoint hooks found in hooks.json — nothing to do"
elif [ "$DRY_RUN" -eq 1 ]; then
  would "back up $CURSOR_HOOKS and remove focalpoint hook entries from it"
else
  BACKUP="$CURSOR_HOOKS.bak-focalpoint-$(date +%Y%m%d%H%M%S)"
  cp "$CURSOR_HOOKS" "$BACKUP"
  ok "backed up hooks.json -> $BACKUP"

  # Cursor's shape is flatter than Claude's: the command sits directly on
  # each entry rather than inside a nested .hooks array. `version` is
  # required by Cursor, so it always stays.
  CLEANED="$(jq --arg marker "$CURSOR_HOOK_MARKER" '
    .hooks = ((.hooks // {})
      | with_entries(
          .value |= [ .[] | select((.command // "" | tostring | contains($marker)) | not) ]
        )
      | with_entries(select(.value | length > 0)))
    | if (.hooks | length) == 0 then del(.hooks) else . end
  ' "$CURSOR_HOOKS")"
  printf '%s\n' "$CLEANED" > "$CURSOR_HOOKS"
  ok "removed focalpoint hooks from hooks.json"
fi

# ---------------------------------------------------------------------------
# 4c. Codex hooks — surgical removal, backed up first
# ---------------------------------------------------------------------------

step "Codex hooks"

if [ ! -f "$CODEX_HOOKS" ]; then
  ok "$CODEX_HOOKS doesn't exist — nothing to do"
elif ! jq -e --arg marker "$CODEX_HOOK_MARKER" \
       '[.. | select(type == "string") | select(contains($marker))] | length > 0' \
       "$CODEX_HOOKS" >/dev/null 2>&1; then
  ok "no focalpoint hooks found in Codex hooks.json — nothing to do"
elif [ "$DRY_RUN" -eq 1 ]; then
  would "back up $CODEX_HOOKS and remove focalpoint hook entries from it"
else
  BACKUP="$CODEX_HOOKS.bak-focalpoint-$(date +%Y%m%d%H%M%S)"
  cp "$CODEX_HOOKS" "$BACKUP"
  ok "backed up hooks.json -> $BACKUP"

  CLEANED="$(jq --arg marker "$CODEX_HOOK_MARKER" '
    .hooks = ((.hooks // {})
      | with_entries(
          .value |= [ .[] | select(
            ([.hooks[]?.command // "" | tostring] | any(contains($marker))) | not
          ) ]
        )
      | with_entries(select(.value | length > 0)))
    | if (.hooks | length) == 0 then del(.hooks) else . end
  ' "$CODEX_HOOKS")"
  printf '%s\n' "$CLEANED" > "$CODEX_HOOKS"
  ok "removed focalpoint hooks from Codex hooks.json"
fi

# ---------------------------------------------------------------------------
# 5. FocalPoint.app
# ---------------------------------------------------------------------------

step "Menu bar app"

APP_REMOVED=0
for dir in /Applications "$HOME/Applications"; do
  app="$dir/FocalPoint.app"
  if [ -d "$app" ]; then
    if [ "$DRY_RUN" -eq 1 ]; then
      would "rm -rf $app"
    else
      rm -rf "$app"
      ok "removed $app"
    fi
    APP_REMOVED=1
  fi
done
[ "$APP_REMOVED" -eq 0 ] && ok "FocalPoint.app not found — nothing to do"

# ---------------------------------------------------------------------------
# 6. Logs (opt-in)
# ---------------------------------------------------------------------------

step "Logs"

if [ "$REMOVE_LOGS" -ne 1 ]; then
  info "leaving $LOG_DIR in place (pass --remove-logs to delete it)"
elif [ ! -d "$LOG_DIR" ]; then
  ok "$LOG_DIR already absent"
elif [ "$DRY_RUN" -eq 1 ]; then
  would "rm -rf $LOG_DIR"
else
  rm -rf "$LOG_DIR"
  ok "removed $LOG_DIR"
fi

step "Done"
if [ "$DRY_RUN" -eq 1 ]; then
  echo "Dry run complete — nothing was changed."
else
  echo "FocalPoint has been uninstalled."
  echo "(The repo checkout itself — including $DAEMON_DIR/target — is untouched;"
  echo " delete the cloned directory yourself if you're done with it.)"
fi
