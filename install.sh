#!/usr/bin/env bash
# FocalPoint installer.
#
# MIT License - see adapters/README.md.
#
# One command to get a working FocalPoint install: builds the daemon, wires up
# the Claude Code adapter, builds the macOS helpers (backlight + menu bar app
# if present), and installs a launchd user agent so focalpointd starts
# automatically. Safe to re-run any number of times: every step checks
# what's already there before touching it.
#
#   ./install.sh              interactive (asks to confirm once)
#   ./install.sh --yes         no prompts
#   ./install.sh --yes --mock  launchd agent runs `focalpointd --mock-device`
#                               (for dev machines with no hardware attached)

set -euo pipefail

# ---------------------------------------------------------------------------
# Paths & options
# ---------------------------------------------------------------------------

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
DAEMON_DIR="$SCRIPT_DIR/daemon"
ADAPTERS_DIR="$SCRIPT_DIR/adapters"
APP_DIR="$SCRIPT_DIR/app"
PACKAGING_DIR="$SCRIPT_DIR/packaging"
ORCHESTRATOR_DIR="$SCRIPT_DIR/orchestrator"
ORCHESTRATOR_SKILL_SOURCE="$SCRIPT_DIR/skills/focalpoint-orchestrator"

CONFIG_DIR="${XDG_CONFIG_HOME:-$HOME/.config}/focalpoint"
ADAPTER_INSTALL_DIR="$CONFIG_DIR/adapters"
CLAUDE_DIR="$HOME/.claude"
CLAUDE_SETTINGS="$CLAUDE_DIR/settings.json"
CODEX_DIR="$HOME/.codex"
CODEX_CONFIG="$CODEX_DIR/config.toml"
CODEX_HOOKS="$CODEX_DIR/hooks.json"
CODEX_SKILL_DIR="${CODEX_HOME:-$HOME/.codex}/skills/focalpoint-orchestrator"
CLAUDE_SKILL_DIR="$CLAUDE_DIR/skills/focalpoint-orchestrator"
CURSOR_DIR="$HOME/.cursor"
CURSOR_HOOKS="$CURSOR_DIR/hooks.json"
LOG_DIR="$HOME/Library/Logs/focalpoint"
LAUNCH_AGENTS_DIR="$HOME/Library/LaunchAgents"
PLIST_LABEL="dev.focalpoint.daemon"
PLIST_PATH="$LAUNCH_AGENTS_DIR/${PLIST_LABEL}.plist"
LEGACY_ATTENTION_LABEL="dev.focalpoint.attention-watcher"
LEGACY_ATTENTION_PLIST_PATH="$LAUNCH_AGENTS_DIR/${LEGACY_ATTENTION_LABEL}.plist"
LEGACY_RANKER_LABEL="dev.focalpoint.attention-tier2"
LEGACY_RANKER_PLIST_PATH="$LAUNCH_AGENTS_DIR/${LEGACY_RANKER_LABEL}.plist"
STATE_DIR="${XDG_STATE_HOME:-$HOME/.local/state}/focalpoint"
HOOK_MARKER=".config/focalpoint/adapters/hooks.sh"
# Distinct from HOOK_MARKER above: the "cursor-" prefix means neither marker
# is a substring of the other's path, so the Claude and Cursor merge/removal
# passes can never match each other's entries.
CURSOR_HOOK_MARKER=".config/focalpoint/adapters/cursor-hooks.sh"
CODEX_HOOK_MARKER=".config/focalpoint/adapters/codex-hooks.sh"

ASSUME_YES=0
USE_MOCK=0
for arg in "$@"; do
  case "$arg" in
    --yes|-y) ASSUME_YES=1 ;;
    --mock) USE_MOCK=1 ;;
    -h|--help)
      cat <<EOF
Usage: ./install.sh [--yes] [--mock] [--help]

  --yes    skip the confirmation prompt
  --mock   run focalpointd with --mock-device in the launchd agent — use this
           on a machine with no FocalPoint hardware attached (the default
           plist runs plain focalpointd, which still serves the socket API
           with no device present)
  --help   show this help and exit
EOF
      exit 0
      ;;
    *)
      echo "unknown argument: $arg (see --help)" >&2
      exit 1
      ;;
  esac
done

# ---------------------------------------------------------------------------
# Output helpers
# ---------------------------------------------------------------------------

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

# ---------------------------------------------------------------------------
# 1. Preflight
# ---------------------------------------------------------------------------

step "Preflight checks"

OS="$(uname -s)"
if [ "$OS" != "Darwin" ]; then
  fail "this installer supports macOS only (detected: $OS)."
  echo "  The daemon itself builds fine on Linux (see daemon/README.md)," >&2
  echo "  but the launchd agent, menu bar app, and backlight helper here" >&2
  echo "  are all macOS-specific." >&2
  exit 1
fi
ok "macOS"

ARCH="$(uname -m)"
case "$ARCH" in
  arm64|x86_64) ok "arch: $ARCH" ;;
  *)
    fail "unsupported architecture: $ARCH"
    exit 1
    ;;
esac

MISSING=0
check_tool() {
  local tool="$1" hint="$2"
  if command -v "$tool" >/dev/null 2>&1; then
    ok "found $tool"
  else
    fail "missing $tool — $hint"
    MISSING=1
  fi
}
check_tool cargo  "install Rust via https://rustup.rs, or 'brew install rust'"
check_tool jq     "install via 'brew install jq'"
check_tool swiftc "install the Xcode command line tools: 'xcode-select --install'"

if [ "$MISSING" -ne 0 ]; then
  fail "install the missing tools above, then re-run ./install.sh"
  exit 1
fi

# ---------------------------------------------------------------------------
# 2. Confirm
# ---------------------------------------------------------------------------

step "About to install FocalPoint"
cat <<EOF
This will, all idempotently:
  - cargo build --release the daemon and native CLIs
  - symlink focalpoint, focalpointd, and fpctl-agent into /opt/homebrew/bin
    (or ~/.local/bin as a fallback)
  - install ~/.config/focalpoint/config.toml (only if one isn't already there)
  - install the managed-session launcher and a default private tmux config
    (the tmux config is only created if one isn't already there)
  - install the FocalPoint orchestrator skill for Codex and Claude Code
  - refresh the Claude Code + Codex + Cursor adapter scripts under
    ~/.config/focalpoint/adapters/
  - merge FocalPoint's hooks into ~/.claude/settings.json and
    ~/.cursor/hooks.json (each backed up first; skipped cleanly if already
    merged)
  - build the macOS keyboard-backlight helper (non-fatal if it fails)
  - build + install the FocalPoint.app menu bar app, if this checkout has one
  - install a launchd user agent so focalpointd starts automatically$( [ "$USE_MOCK" -eq 1 ] && echo " (--mock-device)" )
EOF
if [ "$ASSUME_YES" -ne 1 ]; then
  printf '\nProceed? [y/N] '
  read -r REPLY
  case "$REPLY" in
    [yY]|[yY][eE][sS]) ;;
    *) echo "Aborted."; exit 0 ;;
  esac
fi

# ---------------------------------------------------------------------------
# 3. Build the daemon
# ---------------------------------------------------------------------------

step "Building the daemon (cargo build --release)"
( cd "$DAEMON_DIR" && cargo build --release --quiet )
RELEASE_DIR="$DAEMON_DIR/target/release"
ok "built $RELEASE_DIR/{focalpoint,focalpointd,fpctl-agent}"

# ---------------------------------------------------------------------------
# 4. Install the native FocalPoint binaries
# ---------------------------------------------------------------------------

step "Installing native FocalPoint binaries"

BIN_DIR="/opt/homebrew/bin"
if [ ! -d "$BIN_DIR" ] || [ ! -w "$BIN_DIR" ]; then
  BIN_DIR="$HOME/.local/bin"
  mkdir -p "$BIN_DIR"
  case ":${PATH}:" in
    *":$BIN_DIR:"*) ;;
    *) info "$BIN_DIR isn't on your PATH — add to your shell profile:
     export PATH=\"$BIN_DIR:\$PATH\"" ;;
  esac
fi

for bin in focalpoint focalpointd fpctl-agent; do
  # LaunchAgents on Apple Silicon can stall in dyld/Rosetta when their
  # executable resolves through a symlink into a hidden worktree. Install an
  # immutable local copy and atomically repoint the public name instead. The
  # versioned temp path also avoids overwriting a currently mapped daemon.
  installed="$BIN_DIR/.focalpoint-installed-$bin"
  staged="$installed.tmp.$$"
  cp -X "$RELEASE_DIR/$bin" "$staged"
  chmod 755 "$staged"
  mv -f "$staged" "$installed"
  ln -sfn "$installed" "$BIN_DIR/$bin"
done
ok "installed $BIN_DIR/{focalpoint,focalpointd,fpctl-agent}"

FOCALPOINT_BIN="$BIN_DIR/focalpoint"
FOCALPOINTD_BIN="$BIN_DIR/focalpointd"

# ---------------------------------------------------------------------------
# 5. Config (never clobber a user's existing config)
# ---------------------------------------------------------------------------

step "Daemon config"

mkdir -p "$CONFIG_DIR"
if [ -f "$CONFIG_DIR/config.toml" ]; then
  CONFIG_STATUS="already present — left untouched"
  ok "$CONFIG_DIR/config.toml $CONFIG_STATUS"
else
  cp "$DAEMON_DIR/config.example.toml" "$CONFIG_DIR/config.toml"
  CONFIG_STATUS="installed from config.example.toml"
  ok "$CONFIG_DIR/config.toml $CONFIG_STATUS"
fi

# ---------------------------------------------------------------------------
# 5b. Managed-session launcher
# ---------------------------------------------------------------------------

step "Managed-session launcher"

MANAGED_RUNNER="$CONFIG_DIR/focalpoint-run.sh"
cp "$ORCHESTRATOR_DIR/focalpoint-run.sh" "$MANAGED_RUNNER"
chmod +x "$MANAGED_RUNNER"
ok "refreshed $MANAGED_RUNNER"

if [ -f "$CONFIG_DIR/tmux.conf" ]; then
  TMUX_CONFIG_STATUS="already present — left untouched"
  ok "$CONFIG_DIR/tmux.conf $TMUX_CONFIG_STATUS"
else
  cp "$ORCHESTRATOR_DIR/tmux.conf" "$CONFIG_DIR/tmux.conf"
  TMUX_CONFIG_STATUS="installed default"
  ok "$CONFIG_DIR/tmux.conf $TMUX_CONFIG_STATUS"
fi

if command -v tmux >/dev/null 2>&1; then
  TMUX_STATUS="available"
  ok "found tmux (managed sessions enabled)"
else
  TMUX_STATUS="not installed — launcher falls back to unmanaged sessions"
  info "tmux is optional; install it with 'brew install tmux' to enable managed sessions"
fi

# ---------------------------------------------------------------------------
# 5c. Agent-control skill
# ---------------------------------------------------------------------------

step "FocalPoint orchestrator skill"

for skill_dest in "$CODEX_SKILL_DIR" "$CLAUDE_SKILL_DIR"; do
  mkdir -p "$skill_dest"
  # cp -R updates files but does not remove paths dropped from the source.
  # Delete only known obsolete skill artifacts from earlier releases.
  rm -f "$skill_dest/references/policy.md" \
    "$skill_dest/scripts/focalpoint_control.py"
  rmdir "$skill_dest/references" "$skill_dest/scripts" 2>/dev/null || true
  cp -R "$ORCHESTRATOR_SKILL_SOURCE/." "$skill_dest/"
  ok "refreshed $skill_dest"
done

# ---------------------------------------------------------------------------
# 6. Adapter scripts (always refreshed — these are ours, not user config)
# ---------------------------------------------------------------------------

step "Adapter scripts"

mkdir -p "$ADAPTER_INSTALL_DIR"

install_script() {
  local src="$1" dest="$ADAPTER_INSTALL_DIR/$2"
  cp "$src" "$dest"
  chmod +x "$dest"
  ok "refreshed $dest"
}

install_script "$ADAPTERS_DIR/claude-code/hooks.sh" hooks.sh
install_script "$ADAPTERS_DIR/claude-code/focus-session.sh" focus-session.sh
install_script "$ADAPTERS_DIR/claude-code/statusline-usage.sh" statusline-usage.sh
install_script "$ADAPTERS_DIR/codex-cli/notify.sh" codex-notify.sh
install_script "$ADAPTERS_DIR/codex-cli/hooks.sh" codex-hooks.sh
install_script "$ADAPTERS_DIR/cursor/hooks.sh" cursor-hooks.sh
install_script "$ADAPTERS_DIR/cursor/focus-cursor.sh" focus-cursor.sh

# ---------------------------------------------------------------------------
# 7. Merge Claude Code hooks into ~/.claude/settings.json
# ---------------------------------------------------------------------------

step "Claude Code integration"

mkdir -p "$CLAUDE_DIR"
if [ ! -f "$CLAUDE_SETTINGS" ]; then
  echo '{}' > "$CLAUDE_SETTINGS"
  ok "created $CLAUDE_SETTINGS"
fi

if jq -e --arg marker "$HOOK_MARKER" \
     '[.. | select(type == "string") | select(contains($marker))] | length > 0' \
     "$CLAUDE_SETTINGS" >/dev/null 2>&1; then
  HOOKS_STATUS="already present — skipped"
  ok "focalpoint hooks $HOOKS_STATUS"
else
  BACKUP="$CLAUDE_SETTINGS.bak-focalpoint-$(date +%Y%m%d%H%M%S)"
  cp "$CLAUDE_SETTINGS" "$BACKUP"
  ok "backed up settings.json -> $BACKUP"

  FRAGMENT="$ADAPTERS_DIR/claude-code/settings-fragment.json"
  MERGED="$(jq -s '
    .[0] as $orig | .[1] as $frag
    | $orig
    | .hooks = (($orig.hooks // {}) as $oh
        | ($frag.hooks // {}) as $fh
        | $fh | to_entries | reduce .[] as $e ($oh;
            .[$e.key] = (($oh[$e.key] // []) + $e.value)))
  ' "$CLAUDE_SETTINGS" "$FRAGMENT")"
  printf '%s\n' "$MERGED" > "$CLAUDE_SETTINGS"
  HOOKS_STATUS="merged into settings.json"
  ok "focalpoint hooks $HOOKS_STATUS"
fi

# ---------------------------------------------------------------------------
# 7b. Merge Cursor hooks into ~/.cursor/hooks.json
# ---------------------------------------------------------------------------

step "Cursor integration"

mkdir -p "$CURSOR_DIR"
if [ ! -f "$CURSOR_HOOKS" ]; then
  echo '{"version": 1}' > "$CURSOR_HOOKS"
  ok "created $CURSOR_HOOKS"
fi

if jq -e --arg marker "$CURSOR_HOOK_MARKER" \
     '[.. | select(type == "string") | select(contains($marker))] | length > 0' \
     "$CURSOR_HOOKS" >/dev/null 2>&1; then
  CURSOR_STATUS="already present — skipped"
  ok "focalpoint cursor hooks $CURSOR_STATUS"
else
  BACKUP="$CURSOR_HOOKS.bak-focalpoint-$(date +%Y%m%d%H%M%S)"
  cp "$CURSOR_HOOKS" "$BACKUP"
  ok "backed up hooks.json -> $BACKUP"

  # The committed fragment writes the command as ${HOME}/... for readability.
  # Cursor's expansion of that is undocumented, and user-level hook paths
  # resolve relative to ~/.cursor, so substitute the resolved absolute path
  # here rather than trusting either.
  CURSOR_FRAGMENT="$ADAPTERS_DIR/cursor/hooks-fragment.json"
  MERGED="$(jq -s --arg cmd "$ADAPTER_INSTALL_DIR/cursor-hooks.sh" '
    .[0] as $orig | .[1] as $frag
    | $orig
    | .version = ($orig.version // $frag.version // 1)
    | .hooks = (($orig.hooks // {}) as $oh
        | ($frag.hooks // {} | with_entries(
            .value |= [ .[] | .command = $cmd ])) as $fh
        | $fh | to_entries | reduce .[] as $e ($oh;
            .[$e.key] = (($oh[$e.key] // []) + $e.value)))
  ' "$CURSOR_HOOKS" "$CURSOR_FRAGMENT")"
  printf '%s\n' "$MERGED" > "$CURSOR_HOOKS"
  CURSOR_STATUS="merged into hooks.json"
  ok "focalpoint cursor hooks $CURSOR_STATUS"
fi

# ---------------------------------------------------------------------------
# 8. Merge Codex lifecycle hooks into ~/.codex/hooks.json
# ---------------------------------------------------------------------------

step "Codex CLI integration"

mkdir -p "$CODEX_DIR"
if [ ! -f "$CODEX_HOOKS" ]; then
  echo '{}' > "$CODEX_HOOKS"
  ok "created $CODEX_HOOKS"
fi

if jq -e --arg marker "$CODEX_HOOK_MARKER" \
     '[.. | select(type == "string") | select(contains($marker))] | length > 0' \
     "$CODEX_HOOKS" >/dev/null 2>&1; then
  CODEX_STATUS="lifecycle hooks already present — skipped"
  ok "$CODEX_STATUS"
else
  BACKUP="$CODEX_HOOKS.bak-focalpoint-$(date +%Y%m%d%H%M%S)"
  cp "$CODEX_HOOKS" "$BACKUP"
  ok "backed up hooks.json -> $BACKUP"

  CODEX_FRAGMENT="$ADAPTERS_DIR/codex-cli/hooks-fragment.json"
  MERGED="$(jq -s --arg cmd "$ADAPTER_INSTALL_DIR/codex-hooks.sh" '
    .[0] as $orig | .[1] as $frag
    | $orig
    | .hooks = (($orig.hooks // {}) as $oh
        | ($frag.hooks // {} | with_entries(
            .value |= [ .[] | .hooks |= [ .[] | .command = $cmd ] ])) as $fh
        | $fh | to_entries | reduce .[] as $e ($oh;
            .[$e.key] = (($oh[$e.key] // []) + $e.value)))
  ' "$CODEX_HOOKS" "$CODEX_FRAGMENT")"
  printf '%s\n' "$MERGED" > "$CODEX_HOOKS"
  CODEX_STATUS="lifecycle hooks merged into hooks.json"
  ok "$CODEX_STATUS"
fi

# Native hooks supersede the legacy completion-only notify adapter. Leaving
# both enabled would process Stop twice and double-count completed turns.
if [ -f "$CODEX_CONFIG" ] && grep -q "codex-notify.sh" "$CODEX_CONFIG" 2>/dev/null; then
  BACKUP="$CODEX_CONFIG.bak-focalpoint-$(date +%Y%m%d%H%M%S)"
  cp "$CODEX_CONFIG" "$BACKUP"
  CLEANED="$(sed '/^[[:space:]]*notify[[:space:]]*=.*codex-notify\.sh/d' "$CODEX_CONFIG")"
  printf '%s\n' "$CLEANED" > "$CODEX_CONFIG"
  ok "removed legacy codex-notify.sh config (backup: $BACKUP)"
fi

# ---------------------------------------------------------------------------
# 9. macOS backlight helper (non-fatal)
# ---------------------------------------------------------------------------

step "Backlight helper (adapters/mac-virtual)"

if ( cd "$ADAPTERS_DIR/mac-virtual" && ./build.sh >/tmp/focalpoint-backlight-build.log 2>&1 ); then
  BACKLIGHT_STATUS="built"
  ok "built focalpoint-backlight"
else
  BACKLIGHT_STATUS="build failed (non-fatal)"
  info "$BACKLIGHT_STATUS — see /tmp/focalpoint-backlight-build.log"
fi

# ---------------------------------------------------------------------------
# 10. Menu bar app (only if this checkout has one yet)
# ---------------------------------------------------------------------------

step "Menu bar app"

if [ -f "$APP_DIR/build.sh" ]; then
  if ( cd "$APP_DIR" && ./build.sh >/tmp/focalpoint-app-build.log 2>&1 ); then
    APPS_DIR="/Applications"
    [ -w "$APPS_DIR" ] || APPS_DIR="$HOME/Applications"
    mkdir -p "$APPS_DIR"
    # `open` will otherwise keep the already-running process from the old
    # bundle alive, even after replacing the files on disk.
    pkill -x FocalPoint >/dev/null 2>&1 || true
    rm -rf "$APPS_DIR/FocalPoint.app"
    cp -R "$APP_DIR/FocalPoint.app" "$APPS_DIR/FocalPoint.app"
    APP_STATUS="built + installed to $APPS_DIR/FocalPoint.app"
    ok "$APP_STATUS"
    open "$APPS_DIR/FocalPoint.app" && ok "launched FocalPoint.app"
  else
    APP_STATUS="build failed (non-fatal) — see /tmp/focalpoint-app-build.log"
    info "$APP_STATUS"
  fi
else
  APP_STATUS="not present in this checkout — skipping"
  info "menu bar app $APP_STATUS"
fi

# ---------------------------------------------------------------------------
# 11. launchd user agent
# ---------------------------------------------------------------------------

step "launchd service"

mkdir -p "$LOG_DIR" "$LAUNCH_AGENTS_DIR"

MOCK_ARG_LINE=""
[ "$USE_MOCK" -eq 1 ] && MOCK_ARG_LINE=$'\t\t<string>--mock-device</string>'

TMP_PLIST="$(mktemp)"
sed \
  -e "s#@@FOCALPOINTD_PATH@@#$FOCALPOINTD_BIN#" \
  -e "s#@@LOG_DIR@@#$LOG_DIR#g" \
  -e "s#@@MOCK_ARG_LINE@@#$MOCK_ARG_LINE#" \
  "$PACKAGING_DIR/dev.focalpoint.daemon.plist" > "$TMP_PLIST"
cp "$TMP_PLIST" "$PLIST_PATH"
rm -f "$TMP_PLIST"
ok "wrote $PLIST_PATH$( [ "$USE_MOCK" -eq 1 ] && echo " (--mock-device)" )"

# Stop any manually-started focalpointd (e.g. a dev session) so the launchd copy
# becomes the one true instance.
if pkill -x focalpointd 2>/dev/null; then
  ok "stopped a manually-running focalpointd"
  sleep 1
fi

if launchctl print "gui/$UID/$PLIST_LABEL" >/dev/null 2>&1; then
  launchctl bootout "gui/$UID/$PLIST_LABEL" >/dev/null 2>&1 || true
  ok "unloaded the previous launchd agent"
fi

launchctl bootstrap "gui/$UID" "$PLIST_PATH"
ok "bootstrapped $PLIST_LABEL"

echo ""
launchctl print "gui/$UID/$PLIST_LABEL" 2>/dev/null | head -n 10 || true

printf '\nwaiting for the daemon to answer'
DAEMON_OK=0
for _ in 1 2 3 4 5 6 7 8 9 10 11 12 13 14 15 16 17 18 19 20 \
         21 22 23 24 25 26 27 28 29 30; do
  if DAEMON_OUT="$("$FOCALPOINT_BIN" get-state 2>&1)"; then
    DAEMON_OK=1
    break
  fi
  printf '.'
  sleep 1
done
echo ""

if [ "$DAEMON_OK" -eq 1 ]; then
  ok "focalpoint daemon: $DAEMON_OUT"
else
  fail "focalpoint daemon did not answer after 30s (last: ${DAEMON_OUT:-no output})"
  fail "check $LOG_DIR/focalpointd.err.log"
fi

# ---------------------------------------------------------------------------
# 11b. Remove obsolete attention services from older installations
# ---------------------------------------------------------------------------

step "Removing obsolete attention services"

for legacy_label in "$LEGACY_ATTENTION_LABEL" "$LEGACY_RANKER_LABEL"; do
  if launchctl print "gui/$UID/$legacy_label" >/dev/null 2>&1; then
    launchctl bootout "gui/$UID/$legacy_label" >/dev/null 2>&1 || true
    ok "stopped + unloaded $legacy_label"
  fi
done

rm -f "$LEGACY_ATTENTION_PLIST_PATH" "$LEGACY_RANKER_PLIST_PATH" \
  "$CONFIG_DIR/attention-watcher.disabled" \
  "$CONFIG_DIR/attention-watcher.py" "$CONFIG_DIR/attention-tier2.py" \
  "$CONFIG_DIR/policy.schema.json" \
  "$STATE_DIR/attention-policy.json" \
  "$STATE_DIR/attention-policy.json.inputs.sha256" \
  "$STATE_DIR/attention-policy.json.inputs.fingerprint" \
  "$STATE_DIR/attention-policy.inputs.sha256" \
  "$STATE_DIR/attention-policy.inputs.fingerprint"

for legacy_dir in /opt/homebrew/bin "$HOME/.local/bin"; do
  [ -d "$legacy_dir" ] || continue
  for legacy_bin in focalpoint-attention focalpoint-tier2; do
    legacy_path="$legacy_dir/$legacy_bin"
    installed_path="$legacy_dir/.focalpoint-installed-$legacy_bin"
    if [ -e "$legacy_path" ] || [ -L "$legacy_path" ] || [ -f "$installed_path" ]; then
      rm -f "$legacy_path" "$installed_path"
      ok "removed obsolete $legacy_path"
    fi
  done
done
ok "obsolete watcher/ranker files are absent"

# ---------------------------------------------------------------------------
# 12. Summary
# ---------------------------------------------------------------------------

step "Summary"
cat <<EOF
  native binaries    $BIN_DIR/{focalpoint,focalpointd,fpctl-agent}
  config.toml        $CONFIG_STATUS
  managed launcher   $MANAGED_RUNNER
  tmux config        $TMUX_CONFIG_STATUS
  tmux dependency    $TMUX_STATUS
  adapter scripts    refreshed in $ADAPTER_INSTALL_DIR
  Claude Code hooks  $HOOKS_STATUS
  Cursor hooks       $CURSOR_STATUS
  Codex CLI          $CODEX_STATUS
  backlight helper   $BACKLIGHT_STATUS
  menu bar app       $APP_STATUS
  launchd agent      $PLIST_LABEL @ $PLIST_PATH$( [ "$USE_MOCK" -eq 1 ] && echo " (mock device)" )
  agent skill        $CODEX_SKILL_DIR + $CLAUDE_SKILL_DIR
  daemon socket       $( [ "$DAEMON_OK" -eq 1 ] && echo "OK — $DAEMON_OUT" || echo "FAILED — see $LOG_DIR/focalpointd.err.log" )
EOF

echo ""
echo "Next steps:"
echo "  - Use 'fpctl-agent prioritize SESSION_ID ...' to set the daemon's attention order."
echo "  - Optionally run '$MANAGED_RUNNER claude' (or codex) for precise managed-session focus."
echo "  - Restart any running Claude Code sessions so they pick up the new hooks."
echo "  - Cursor reloads hooks.json on save; restart Cursor if the Hooks tab doesn't list them."
echo "  - Restart Codex, then review and trust the FocalPoint lifecycle hooks with /hooks."
echo "  - Run 'focalpoint watch' to see live events, or 'focalpoint ping' any time to check status."
echo "  - Re-run ./install.sh any time — it's safe, everything above is idempotent."
echo ""

if [ "$DAEMON_OK" -ne 1 ]; then
  exit 1
fi
