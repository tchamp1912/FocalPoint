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
# Open the workspace through Cursor's CLI, whose ordinary folder-open path
# selects an existing matching workspace. --reuse-window instead replaces the
# last active workspace and can send focus to a completely unrelated session.
# GUI apps have a sparse PATH, so also resolve Cursor's bundled CLI.
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

  # Poll in 10 ms ticks. The previous 100 ms interval added up to 100 ms
  # after every successful CLI or AppleScript call; 10 ms keeps that bounded
  # without changing the existing timeout/kill behavior.
  local max_ticks=$((TIMEOUT_SECS * 100))
  local ticks=0
  while kill -0 "$pid" 2>/dev/null; do
    if [ "$ticks" -ge "$max_ticks" ]; then
      kill -KILL "$pid" 2>/dev/null
      wait "$pid" 2>/dev/null
      return 124
    fi
    sleep 0.01
    ticks=$((ticks + 1))
  done

  wait "$pid" 2>/dev/null
}

# Nothing to focus if Cursor isn't running. Return failure so the daemon
# reports the missing endpoint instead of broadcasting a successful focus.
pgrep -x "Cursor" >/dev/null 2>&1 || exit 1

cursor_cli=$(command -v cursor 2>/dev/null || true)
if [ -z "$cursor_cli" ]; then
  for candidate in "/Applications/Cursor.app/Contents/Resources/app/bin/cursor" \
      "$HOME/Applications/Cursor.app/Contents/Resources/app/bin/cursor"; do
    if [ -x "$candidate" ]; then
      cursor_cli="$candidate"
      break
    fi
  done
fi

if [ -n "$CWD" ] && [ -d "$CWD" ]; then
  if [ -n "$cursor_cli" ]; then
    run_guarded "$cursor_cli" "$CWD" && exit 0
  fi
  # Passing a document to Launch Services reaches an already-running app;
  # --args only supplies launch arguments and is ineffective in that case.
  run_guarded open -a "Cursor" "$CWD"
  exit $?
fi

run_guarded osascript -e 'tell application "Cursor" to activate'
exit $?
