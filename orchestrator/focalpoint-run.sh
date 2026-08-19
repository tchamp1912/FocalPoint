#!/bin/bash
# FocalPoint managed-session launch wrapper.
#
# Usage: focalpoint-run.sh <command> [args...]
#   e.g. focalpoint-run.sh claude
#        focalpoint-run.sh codex
#
# "Managed" means an agent runs inside a tmux pane FocalPoint controls, giving a
# precise input channel (`tmux send-keys`) and precise focus
# (`tmux select-window`) instead of best-effort synthesized keystrokes. A
# running process can't be adopted into tmux after the fact on macOS (it's
# bound to its terminal's pty) — mux can only be *created* at launch time,
# which is this script's entire job. The `adapters/claude-code/hooks.sh`
# SessionStart handler *detects* an already-managed session (by checking
# $TMUX) and registers it; it cannot create one.
#
# If already inside tmux (nested invocation, or the user ran this from a
# tmux pane on purpose), just exec the command directly — don't nest
# tmux-in-tmux, which would break status-bar/prefix expectations for
# whatever outer session already exists.
#
# MIT License - see adapters/README.md

set -u

# A small append-only transport log survives cases where LaunchServices opens
# a window but the provider never reaches its first hook. Never record task
# text or command arguments; identity and tmux ownership are enough to trace
# collisions and orphaned launches.
LAUNCH_LOG_DIR="${XDG_STATE_HOME:-$HOME/.local/state}/focalpoint"
LAUNCH_LOG="$LAUNCH_LOG_DIR/managed-launch.log"
LAUNCH_COMMAND=""
log_field() { printf '%s' "${1:-}" | tr '\r\n\t' '   ' | cut -c1-160; }
launch_log() {
  mkdir -p "$LAUNCH_LOG_DIR" 2>/dev/null || return 0
  chmod 700 "$LAUNCH_LOG_DIR" 2>/dev/null || true
  printf 'time=%s event=%s wrapper_pid=%s task_id=%s title=%s slot=%s role=%s layout=%s tmux_server=%s command=%s\n' \
    "$(date -u '+%Y-%m-%dT%H:%M:%SZ' 2>/dev/null || printf unknown)" \
    "$(log_field "$1")" "$$" \
    "$(log_field "${FOCALPOINT_ORCHESTRATOR_TASK_ID:-}")" \
    "$(log_field "${FOCALPOINT_SESSION_TITLE:-}")" \
    "$(log_field "${FOCALPOINT_SESSION_SLOT:-}")" \
    "$(log_field "${FOCALPOINT_ORCHESTRATION_ROLE:-}")" \
    "$(log_field "${LAYOUT:-}")" \
    "$(log_field "${TMUX_SERVER:-}")" \
    "$(log_field "${CMD_NAME:-$LAUNCH_COMMAND}")" >> "$LAUNCH_LOG" 2>/dev/null || true
  chmod 600 "$LAUNCH_LOG" 2>/dev/null || true
}

if [ "$#" -eq 0 ]; then
  echo "usage: focalpoint-run.sh <command> [args...]" >&2
  exit 1
fi
LAUNCH_COMMAND="$(basename "$1" 2>/dev/null)"

# A History recovery is an explicit resume, not a brand-new session. Preserve
# the provider's requested conversation id so adapter hooks can tell the
# daemon exactly which old record is returning. Without this, the daemon has
# only label/cwd/tty/pid recovery signals; two old sessions from the same repo
# can then be confused before the new process identity is known.
#
# Do not overwrite a daemon-managed live-relaunch correlation. This marker is
# deliberately a separate, less-privileged identity hint: it can select only
# the exact tombstone with this id and never a different same-cwd candidate.
if [ -z "${FOCALPOINT_RESUME_SESSION_ID:-}" ]; then
  case "$(basename "$1" 2>/dev/null)" in
    claude)
      if [ "${2:-}" = "--resume" ] && [ -n "${3:-}" ]; then
        export FOCALPOINT_RESUME_SESSION_ID="$3"
      fi
      ;;
    codex)
      if [ "${2:-}" = "resume" ] && [ -n "${3:-}" ]; then
        export FOCALPOINT_RESUME_SESSION_ID="$3"
      fi
      ;;
  esac
fi

# Resolve tmux explicitly because apps launched by Finder/launchd commonly do
# not inherit Homebrew's PATH. FOCALPOINT_TMUX_BIN remains an escape hatch for
# custom installations and tests.
TMUX_BIN="${FOCALPOINT_TMUX_BIN:-}"
if [ -z "$TMUX_BIN" ]; then
  TMUX_BIN="$(command -v tmux 2>/dev/null || true)"
fi
if [ -z "$TMUX_BIN" ]; then
  for candidate in /opt/homebrew/bin/tmux /usr/local/bin/tmux; do
    if [ -x "$candidate" ]; then TMUX_BIN="$candidate"; break; fi
  done
fi

# Silent no-op if tmux isn't installed — never block the agent from
# starting at all just because the managed-session transport isn't
# available. Falls straight through to running the command unmanaged,
# identical to today's behavior with no wrapper at all.
if [ -z "$TMUX_BIN" ] || [ ! -x "$TMUX_BIN" ]; then
  launch_log "unmanaged-no-tmux"
  exec "$@"
fi

# Already inside a tmux pane: nothing to create, just run the command. This
# also covers a user manually re-running focalpoint-run.sh from inside an
# already-managed session.
if [ -n "${TMUX:-}" ]; then
  launch_log "nested-existing-tmux"
  exec "$@"
fi

# Locate tmux.conf: prefer a user override (~/.config/focalpoint/tmux.conf,
# same convention as config.toml), then fall back to the copy shipped
# alongside this script in the repo, so this works both from a checkout and
# from an installed copy without requiring install.sh to have run yet.
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" >/dev/null 2>&1 && pwd)"
TMUX_CONF="${FOCALPOINT_TMUX_CONF:-}"
if [ -z "$TMUX_CONF" ]; then
  if [ -f "$HOME/.config/focalpoint/tmux.conf" ]; then
    TMUX_CONF="$HOME/.config/focalpoint/tmux.conf"
  else
    TMUX_CONF="$SCRIPT_DIR/tmux.conf"
  fi
fi

# Layout: "cockpit" (all managed agents as windows inside one shared
# terminal/session named "focalpoint", the tightest fit for the
# pad-bounces-you-between-sessions UX but only
# one agent visible at a time) vs "per-agent" (a fresh named tmux session
# per invocation, the default — more windows, but normal macOS
# side-by-side window management still works).
LAYOUT="${FOCALPOINT_TMUX_LAYOUT:-per-agent}"

# A long-lived tmux server has its own environment and may predate this launch.
# Pass correlation values explicitly so the new pane cannot inherit stale or
# missing identity from that server.
# Keep one baseline entry: macOS ships Bash 3.2, where expanding an empty
# array under `set -u` raises an unbound-variable error.
TMUX_ENV_ARGS=(-e "FOCALPOINT_MANAGED=1")
# Each managed invocation owns a private tmux server.  Do not use the user's
# default server: the daemon can then target only this server for wake/cleanup.
TMUX_SERVER="fp-${FOCALPOINT_ORCHESTRATOR_TASK_ID:-manual}-$$"
TMUX_SERVER=$(printf '%s' "$TMUX_SERVER" | tr -c 'A-Za-z0-9_-' '-')
export FOCALPOINT_TMUX_SERVER="$TMUX_SERVER"
TMUX_ENV_ARGS+=(-e "FOCALPOINT_TMUX_SERVER=$TMUX_SERVER")
[ -n "${FOCALPOINT_LAUNCH_ID:-}" ] && \
  TMUX_ENV_ARGS+=(-e "FOCALPOINT_LAUNCH_ID=$FOCALPOINT_LAUNCH_ID")
[ -n "${FOCALPOINT_ORCHESTRATOR_TASK_ID:-}" ] && \
  TMUX_ENV_ARGS+=(-e "FOCALPOINT_ORCHESTRATOR_TASK_ID=$FOCALPOINT_ORCHESTRATOR_TASK_ID")
[ -n "${FOCALPOINT_ORCHESTRATION_ROLE:-}" ] && \
  TMUX_ENV_ARGS+=(-e "FOCALPOINT_ORCHESTRATION_ROLE=$FOCALPOINT_ORCHESTRATION_ROLE")
[ -n "${FOCALPOINT_MANAGER_TASK_ID:-}" ] && \
  TMUX_ENV_ARGS+=(-e "FOCALPOINT_MANAGER_TASK_ID=$FOCALPOINT_MANAGER_TASK_ID")
[ -n "${FOCALPOINT_CHANNEL_ID:-}" ] && \
  TMUX_ENV_ARGS+=(-e "FOCALPOINT_CHANNEL_ID=$FOCALPOINT_CHANNEL_ID")
[ -n "${FOCALPOINT_SESSION_TITLE:-}" ] && \
  TMUX_ENV_ARGS+=(-e "FOCALPOINT_SESSION_TITLE=$FOCALPOINT_SESSION_TITLE")
[ -n "${FOCALPOINT_SESSION_SLOT:-}" ] && \
  TMUX_ENV_ARGS+=(-e "FOCALPOINT_SESSION_SLOT=$FOCALPOINT_SESSION_SLOT")
[ -n "${FOCALPOINT_RELAUNCH_ID:-}" ] && \
  TMUX_ENV_ARGS+=(-e "FOCALPOINT_RELAUNCH_ID=$FOCALPOINT_RELAUNCH_ID")
[ -n "${FOCALPOINT_RESUME_SESSION_ID:-}" ] && \
  TMUX_ENV_ARGS+=(-e "FOCALPOINT_RESUME_SESSION_ID=$FOCALPOINT_RESUME_SESSION_ID")

# Build a filesystem/tmux-safe session-name fragment out of the command
# being launched (e.g. "claude" -> "claude", "claude --resume abc" ->
# "claude"), so session names stay short and readable in `tmux ls`.
CMD_NAME="$(basename "$1" 2>/dev/null)"
SAFE_CMD="$(printf '%s' "$CMD_NAME" | tr -c 'A-Za-z0-9_-' '-')"
[ -n "$SAFE_CMD" ] || SAFE_CMD="cmd"

launch_log "tmux-exec"

case "$LAYOUT" in
  cockpit)
    # The first invocation creates and attaches the cockpit. Later
    # invocations add a window to that existing cockpit and return; tmux
    # selects the new window for the already-attached cockpit client.
    if "$TMUX_BIN" -L "$TMUX_SERVER" has-session -t focalpoint 2>/dev/null; then
      exec "$TMUX_BIN" -L "$TMUX_SERVER" new-window "${TMUX_ENV_ARGS[@]}" -t focalpoint -c "$PWD" -n "${SAFE_CMD}-$$" "$@"
    fi
    exec "$TMUX_BIN" -L "$TMUX_SERVER" -f "$TMUX_CONF" new-session "${TMUX_ENV_ARGS[@]}" -s focalpoint -c "$PWD" \
      -n "${SAFE_CMD}-$$" "$@"
    ;;
  per-agent|*)
    # Default: one dedicated tmux session per invocation, named after the
    # command and this shell's pid so concurrent launches never collide.
    exec "$TMUX_BIN" -L "$TMUX_SERVER" -f "$TMUX_CONF" new-session "${TMUX_ENV_ARGS[@]}" -s "fp-${SAFE_CMD}-$$" -c "$PWD" "$@"
    ;;
esac
