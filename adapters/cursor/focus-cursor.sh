#!/bin/bash
# FocalPoint [session] focus action for Cursor sessions (PROTOCOL.md §3 "Focus")
#
# Reached from focus-session.sh, which dispatches here when
# FOCALPOINT_SESSION_KIND is "cursor". The session is exposed via env vars:
#   FOCALPOINT_SESSION_ID, FOCALPOINT_SESSION_KIND, FOCALPOINT_SESSION_LABEL,
#   FOCALPOINT_SESSION_CWD, FOCALPOINT_SLOT
#
# Goal: bring the Cursor window for this session's workspace to the front.
#
# Strategy, in order:
#   1. `cursor -r <workspace>` — Cursor's CLI flag to reuse and raise the
#      window already showing that folder. Plain `cursor <path>` can spawn a
#      new window (especially with multi-workbench / glass builds).
#   2. `open -a Cursor --args -r <workspace>` — same reuse flag when the CLI
#      shim isn't on PATH.
#   3. Plain activate when there's no workspace path to target.
#
# HONEST LIMITATION: this focuses the WORKSPACE WINDOW, not the individual
# chat. Cursor's hooks expose no window or composer handle — only
# conversation_id, which nothing outside Cursor can address — so two agent
# chats open on the same repo both land on that repo's window. There is no
# per-conversation focus available today at any level of effort.
#
# Deliberately NOT used: System Events UI scripting to enumerate and AXRaise
# individual Cursor windows. It would be no more precise (Cursor window
# titles don't carry the conversation either) and it would require the user
# to grant Accessibility permission, which none of the other focus paths
# need.
#
# Never launches Cursor from cold: if it isn't already running there is no
# session window to focus, and starting an IDE from a keypress would be a
# surprising side effect. Same rule the terminal focus paths follow.
#
# Must never hang the daemon's action dispatch: the osascript call runs under
# a hard timeout via run_osa(), and the CLI paths are backgrounded-and-reaped
# the same way.
#
# MIT License - see adapters/README.md

set -u

CWD="${FOCALPOINT_SESSION_CWD:-}"

# Resolve symlinks so the path matches what Cursor registered when the user
# opened the folder (e.g. /var/... vs /private/var/..., or a symlinked repo).
if [ -n "$CWD" ] && [ -d "$CWD" ]; then
  CWD="$(cd "$CWD" && pwd -P)" || true
fi

# Seconds to wait for any single external call before killing it. Shares the
# knob with the terminal focus script.
TIMEOUT_SECS="${FOCALPOINT_FOCUS_TIMEOUT:-3}"

# Run "$@", hard-killing it after TIMEOUT_SECS so a stuck call can never hang
# this script. Output is discarded; only the exit status matters.
run_guarded() {
  "$@" >/dev/null 2>&1 &
  local pid=$!

  # Poll in 0.1s ticks so the common case — returning almost instantly —
  # doesn't pay up to a full extra second of latency on a key press.
  local max_ticks=$((TIMEOUT_SECS * 10))
  local ticks=0
  while kill -0 "$pid" 2>/dev/null; do
    if [ "$ticks" -ge "$max_ticks" ]; then
      kill "$pid" 2>/dev/null
      wait "$pid" 2>/dev/null
      return 124
    fi
    sleep 0.1
    ticks=$((ticks + 1))
  done

  wait "$pid" 2>/dev/null
}

# Nothing to focus if Cursor isn't running — and we won't start it.
pgrep -x "Cursor" >/dev/null 2>&1 || exit 0

# 1/2: reuse and raise the existing workspace window — never spawn a new one.
if [ -n "$CWD" ] && [ -d "$CWD" ]; then
  if command -v cursor >/dev/null 2>&1; then
    run_guarded cursor -r "$CWD" || true
  else
    run_guarded open -a "Cursor" --args -r "$CWD" || true
  fi
fi

# 3: make sure Cursor is the frontmost app regardless of which path ran.
if command -v osascript >/dev/null 2>&1; then
  run_guarded osascript -e 'tell application "Cursor" to activate' || true
fi

exit 0
