#!/bin/bash
# FocalPoint Codex CLI adapter — notify hook handler
#
# Codex CLI invokes the configured `notify` program with ONE argument:
# a JSON payload, e.g.
#   {"type":"agent-turn-complete","thread-id":"...","turn-id":"...",
#    "cwd":"...","input-messages":[...],"last-assistant-message":"..."}
#
# Wire it up in ~/.codex/config.toml:
#   notify = ["bash", "/Users/you/.config/focalpoint/adapters/codex-notify.sh"]
#
# Event → state mapping:
#   agent-turn-complete → done
#   approval-requested  → waiting
#
# Codex's notify hook only fires on those two events, so this adapter
# cannot show thinking/running transitions — see README.md.
#
# Sessions: the payload's "thread-id" and "cwd" fields (when present) are
# passed through as --session/--kind codex/--cwd/--label so the daemon can
# track this Codex thread as its own numbered-key session (PROTOCOL.md §3).
#
# Codex has no session-end notification, but `notify` is invoked as a direct
# child of the `codex` process itself (no intermediate shell — verified via
# $PPID), so on the first event for a given thread this script backgrounds a
# tiny watcher that polls that PID and calls `end-session` the moment it
# exits. That means real, prompt session-end behavior without needing an
# `end-session` event from Codex OR any wrapper/shell-profile change on the
# user's end — everything lives in this already-installed script. See
# `watch_codex_exit` below. Falls back to session_ttl_minutes if this script
# is ever removed/reinstalled mid-session (the watcher dies with the marker
# left orphaned only until the next TTL sweep).
#
# Turn count: each "agent-turn-complete" notification IS one completed turn,
# so a per-session counter file is ground truth here (unlike Claude Code,
# Codex's notify payload has no transcript to recompute stats from). Sent as
# --meta turns=N (PROTOCOL.md §4); the menu bar app shows it as an optional
# badge (Settings → Claude & Codex). Token usage / tool-call counts aren't in
# this payload at all, so this adapter doesn't report them.
#
# MIT License - see adapters/README.md

set -u

FOCALPOINT="${FOCALPOINT_PATH:-focalpoint}"
payload="${1:-}"
[ -n "$payload" ] || exit 0

# Extract a JSON string field. Prefers jq; falls back to sed. Field names
# may contain hyphens (e.g. "thread-id"), so jq's bracket form is used
# instead of dot-notation.
extract_field() {
  local field="$1"
  if command -v jq >/dev/null 2>&1; then
    printf '%s' "$payload" | jq -r --arg f "$field" '.[$f] // empty' 2>/dev/null
  else
    printf '%s' "$payload" \
      | sed -n "s/.*\"${field}\"[[:space:]]*:[[:space:]]*\"\\([^\"]*\\)\".*/\\1/p" \
      | head -n1
  fi
}

# Spawns (once per Codex process, not once per turn) a background watcher
# that calls `end-session` the moment that process exits. Guarded by a marker
# file per PID so the repeat notify events a long session sends don't pile up
# redundant watchers — and self-heals stale markers left by a PID that got
# reused or a watcher that never got to clean up after itself (e.g. this
# script was reinstalled mid-session).
watch_codex_exit() {
  local pid="$1" session_id="$2"
  local watch_dir="${XDG_STATE_HOME:-$HOME/.local/state}/focalpoint/watchers"
  local counter_file="${XDG_STATE_HOME:-$HOME/.local/state}/focalpoint/counters/$session_id.turns"
  mkdir -p "$watch_dir" 2>/dev/null

  local stale
  for stale in "$watch_dir"/*; do
    [ -e "$stale" ] || continue
    kill -0 "${stale##*/}" 2>/dev/null || rm -f "$stale"
  done

  local marker="$watch_dir/$pid"
  [ -e "$marker" ] && return 0
  touch "$marker" 2>/dev/null

  (
    while kill -0 "$pid" 2>/dev/null; do
      sleep 5
    done
    "$FOCALPOINT" end-session "$session_id" 2>/dev/null || true
    rm -f "$marker" "$counter_file" 2>/dev/null
  ) &
  disown 2>/dev/null || true
}

event=$(extract_field "type")
thread_id=$(extract_field "thread-id")
cwd=$(extract_field "cwd")

case "${event:-}" in
  agent-turn-complete)
    state="done"
    ;;
  approval-requested)
    state="waiting"
    ;;
  *)
    # Unknown or missing event type: ignore quietly
    exit 0
    ;;
esac

# Build the extra session flags. Only attach them when we actually have a
# thread-id; otherwise keep working exactly as a sessionless adapter.
args=("$state")
if [ -n "${thread_id:-}" ]; then
  args+=(--session "$thread_id" --kind codex --cwd "$cwd" --label "$(basename "${cwd:-.}")")
  watch_codex_exit "$PPID" "$thread_id"
  if [ "$event" = "agent-turn-complete" ]; then
    counter_dir="${XDG_STATE_HOME:-$HOME/.local/state}/focalpoint/counters"
    mkdir -p "$counter_dir" 2>/dev/null
    counter_file="$counter_dir/$thread_id.turns"
    turns=$(( $(cat "$counter_file" 2>/dev/null || echo 0) + 1 ))
    printf '%s' "$turns" > "$counter_file" 2>/dev/null
    args+=(--meta "turns=$turns")
  fi
fi

# Never block or break Codex: silently no-op if the daemon is down.
"$FOCALPOINT" set-state "${args[@]}" 2>/dev/null || true

exit 0
