#!/bin/bash
# FocalPoint [session] focus action (PROTOCOL.md §3 "Focus" / §5)
#
# The daemon runs this script when a numbered key whose slot has a live
# session is pressed, with the session exposed via env vars:
#   FOCALPOINT_SESSION_ID, FOCALPOINT_SESSION_KIND, FOCALPOINT_SESSION_LABEL,
#   FOCALPOINT_SESSION_CWD, FOCALPOINT_SESSION_TTY,
#   FOCALPOINT_SESSION_MUX_{SERVER,SESSION,PANE}, FOCALPOINT_SLOT
#
# Goal: bring the terminal window/tab running that session to the front.
#
# Matching strategy, in order:
#   0. MANAGED sessions: if this session is running inside a FocalPoint-managed
#      tmux pane, focus it precisely via `tmux select-window`/`switch-client`
#      instead of AppleScript window-hunting — see try_managed_tmux() below.
#   1. EXACT tty match ($FOCALPOINT_SESSION_TTY, e.g. "/dev/ttys003") against
#      iTerm2's `tty of session` / Terminal's `tty of tab`. This is precise —
#      no two sessions ever share a tty — and is what claude-code/hooks.sh
#      supplies via `--meta tty=$(...)`.
#   2. Falls back to a fuzzy title/tty-string match on the basename of
#      $FOCALPOINT_SESSION_CWD, for adapters that don't send tty. Windows
#      whose tty is already claimed by a *registered* session are skipped:
#      the fuzzy path only ever runs for a tty-less session, so a window
#      some session registered by tty is by definition not ours — without
#      this, a tty-less session's repo-name needle can land on another
#      session's window whose generated tab title happens to mention the
#      repo (confirmed live: a Codex session's "vibekey" needle matched a
#      Claude Code window titled "Review Vibekey open source hardware
#      plan").
#   3. Falls back to just activating whichever of iTerm2/Terminal is running.
#
# HONEST LIMITATION: step 2 was this script's ORIGINAL and only strategy, and
# it doesn't actually work for Claude Code sessions in practice — Claude Code
# titles iTerm2/Terminal tabs with a generated task summary (e.g. "Fix drag
# stutter"), not the cwd, so the cwd's basename may never appear in the title
# at all (confirmed empirically: none of it showed up in a real session's
# title). It also can't disambiguate two sessions open in the same repo
# (common). Step 1 (tty) has neither problem, so treat step 2 as a
# best-effort fallback for adapters that can't supply a tty, not the primary
# mechanism. Not every terminal is supported at all (Warp, Alacritty, VS
# Code's integrated terminal, tmux panes aren't queried here) — tmux users in
# particular may prefer replacing this script with a `tmux` pane switch.
#
# Must never hang the daemon's action dispatch: every osascript call below
# runs under a hard timeout via run_osa().
#
# Managed sessions use the exact private tmux server/session/pane tuple the
# provider hook registered. This must not be reconstructed from tty: state
# updates are keyed by provider session id and can keep working while cached
# pid/tty metadata is stale, and private `tmux -L fp-*` servers are invisible
# to a plain `tmux list-panes`. The tty remains the exact primary identity for
# unmanaged Terminal/iTerm sessions and a fallback if the managed transport
# has disappeared.
#
# MIT License - see adapters/README.md

set -u

# Not every session lives in a terminal. Cursor agent sessions run inside the
# IDE and have no tty at all, so none of the matching below can ever find
# them — hand off to the Cursor adapter's focus script, installed alongside
# this one. Kept as a dispatch here rather than a separate [session] focus
# entry so existing config.toml files keep working unchanged.
if [ "${FOCALPOINT_SESSION_KIND:-}" = "cursor" ]; then
  CURSOR_FOCUS="$(dirname "$0")/focus-cursor.sh"
  [ -x "$CURSOR_FOCUS" ] && exec "$CURSOR_FOCUS"
  exit 0
fi

CWD="${FOCALPOINT_SESSION_CWD:-}"
if [ -n "$CWD" ]; then
  NEEDLE="$(basename "$CWD" 2>/dev/null)"
else
  NEEDLE=""
fi
TARGET_TTY="${FOCALPOINT_SESSION_TTY:-}"
TARGET_MUX_SERVER="${FOCALPOINT_SESSION_MUX_SERVER:-}"
TARGET_MUX_SESSION="${FOCALPOINT_SESSION_MUX_SESSION:-}"
TARGET_MUX_PANE="${FOCALPOINT_SESSION_MUX_PANE:-}"
# The generic /dev/tty alias is not unique per session — treat as missing so
# focus falls through rather than matching every colliding session at once.
if [ "$TARGET_TTY" = "/dev/tty" ]; then
  TARGET_TTY=""
fi

# The daemon is normally launched by launchd, whose deliberately minimal PATH
# does not include Homebrew. Resolve tmux once with the same fallbacks as the
# managed launcher; otherwise every managed focus silently skips the exact
# pane path and falls through to the ambiguous cwd/title matcher.
TMUX_BIN="${FOCALPOINT_TMUX_BIN:-}"
if [ -z "$TMUX_BIN" ]; then
  TMUX_BIN="$(command -v tmux 2>/dev/null || true)"
fi
if [ -z "$TMUX_BIN" ]; then
  for candidate in /opt/homebrew/bin/tmux /usr/local/bin/tmux; do
    if [ -x "$candidate" ]; then TMUX_BIN="$candidate"; break; fi
  done
fi

# Seconds to wait for any single osascript call before killing it.
TIMEOUT_SECS="${FOCALPOINT_FOCUS_TIMEOUT:-3}"

focus_log() {
  printf '[focus-action] %s id=%s slot=%s tty=%s mux_server=%s mux_session=%s mux_pane=%s\n' \
    "$1" "${FOCALPOINT_SESSION_ID:-}" "${FOCALPOINT_SLOT:-}" \
    "${TARGET_TTY:-}" "${TARGET_MUX_SERVER:-}" \
    "${TARGET_MUX_SESSION:-}" "${TARGET_MUX_PANE:-}" >&2
}

# Ttys claimed by registered sessions, for the fuzzy fallback's skip list
# (strategy 2 above). Only queried when this session itself has no tty —
# the exact-tty strategies never need it. Extraction is grep/sed, not jq,
# same as the adapters' fallback JSON parsers; degrades to an empty list
# (pre-hardening behavior) if the CLI or daemon is unavailable.
FOCALPOINT="${FOCALPOINT_PATH:-focalpoint}"
CLAIMED_TTYS=""
if [ -z "$TARGET_TTY" ] && command -v "$FOCALPOINT" >/dev/null 2>&1; then
  CLAIMED_TTYS=$("$FOCALPOINT" sessions --json 2>/dev/null \
    | grep -o '"tty"[[:space:]]*:[[:space:]]*"[^"]*"' \
    | sed 's/.*"\([^"]*\)"$/\1/' | sort -u)
fi

# The claimed-tty list as an AppleScript string-list literal, e.g.
# {"/dev/ttys002", "/dev/ttys003"} — empty list when nothing is claimed.
osa_claimed_ttys() {
  local out="" t
  for t in $CLAIMED_TTYS; do
    out="${out}\"$(osa_escape "$t")\", "
  done
  printf '{%s}' "${out%, }"
}

# Escape backslashes and double quotes so a value can be embedded inside an
# AppleScript string literal ("...").
osa_escape() {
  printf '%s' "$1" | sed -e 's/\\/\\\\/g' -e 's/"/\\"/g'
}

# Run `osascript -e "$1"`, hard-killing it after TIMEOUT_SECS so a stuck (or
# permission-prompt-blocked) AppleScript call can never hang this script.
# Prints the script's stdout on success.
run_osa() {
  local script="$1"
  local tmp
  tmp="$(mktemp "${TMPDIR:-/tmp}/focalpoint-focus.XXXXXX" 2>/dev/null)" || return 1

  osascript -e "$script" >"$tmp" 2>/dev/null &
  local pid=$!

  # Poll in 0.1s ticks (not whole seconds) so the common case — osascript
  # returning almost instantly — doesn't pay up to a full extra second of
  # latency on a key press. TIMEOUT_SECS is still the hard ceiling.
  local max_ticks=$((TIMEOUT_SECS * 10))
  local ticks=0
  while kill -0 "$pid" 2>/dev/null; do
    if [ "$ticks" -ge "$max_ticks" ]; then
      kill "$pid" 2>/dev/null
      wait "$pid" 2>/dev/null
      rm -f "$tmp"
      return 124
    fi
    sleep 0.1
    ticks=$((ticks + 1))
  done

  wait "$pid" 2>/dev/null
  local status=$?
  cat "$tmp" 2>/dev/null
  rm -f "$tmp"
  return $status
}

# Best-effort: only try apps that are actually running, so we never launch a
# new terminal instance just to focus a session (nothing to focus in that
# case anyway).
app_running() {
  pgrep -x "$1" >/dev/null 2>&1
}

# Raise whichever of iTerm2/Terminal has a tab/session whose tty is exactly
# $1, without touching the module-level $TARGET_TTY (used by try_managed_tmux
# below to raise the *hosting terminal's* tty, which is a different pty from
# the tmux pane's own tty that $TARGET_TTY holds for a managed session).
# Same matching logic as try_iterm_tty/try_terminal_tty, just parameterized.
raise_terminal_by_tty() {
  local tty="$1" tty_esc script result
  tty_esc="$(osa_escape "$tty")"

  if app_running "iTerm2"; then
    script=$(cat <<APPLESCRIPT
tell application "iTerm2"
  set found to false
  repeat with w in windows
    repeat with t in tabs of w
      repeat with s in sessions of t
        try
          if (tty of s) is "$tty_esc" then
            select t
            select w
            set found to true
            exit repeat
          end if
        end try
      end repeat
      if found then exit repeat
    end repeat
    if found then exit repeat
  end repeat
  if found then activate
  if found then
    return "matched"
  else
    return "nomatch"
  end if
end tell
APPLESCRIPT
)
    result="$(run_osa "$script")"
    [ "$result" = "matched" ] && return 0
  fi

  if app_running "Terminal"; then
    script=$(cat <<APPLESCRIPT
tell application "Terminal"
  set found to false
  repeat with w in windows
    repeat with tb in tabs of w
      try
        if (tty of tb) is "$tty_esc" then
          set selected of tb to true
          set index of w to 1
          set found to true
          exit repeat
        end if
      end try
    end repeat
    if found then exit repeat
  end repeat
  if found then activate
  if found then
    return "matched"
  else
    return "nomatch"
  end if
end tell
APPLESCRIPT
)
    result="$(run_osa "$script")"
    [ "$result" = "matched" ] && return 0
  fi

  return 1
}

# Managed-session focus: verifies the exact pane on its private tmux server,
# flips to its window with `select-window`, then switches any attached
# client(s) showing that session with `switch-client -c <client-tty>` and
# raises the hosting terminal app by the *client's* tty (not the pane's).
# The live pane tty is logged but deliberately not compared with cached
# TARGET_TTY: the private server/session/pane tuple is authoritative and this
# path exists specifically so stale pid/tty metadata cannot break focus.
# Returns 0
# ("handled, stop here") whenever a matching pane is found at all — even a
# detached session with no client to raise is correctly "handled": there is
# nothing else in this script that could find it either, and select-window
# still means the *next* attach lands on the right window.
try_managed_tmux() {
  [ -n "$TARGET_MUX_SERVER" ] || return 1
  if [ -z "$TMUX_BIN" ] || [ ! -x "$TMUX_BIN" ]; then
    focus_log "result=miss strategy=managed reason=tmux-unavailable"
    return 1
  fi
  if ! [[ "$TARGET_MUX_SERVER" =~ ^fp-[A-Za-z0-9_-]+$ ]] \
     || ! [[ "$TARGET_MUX_SESSION" =~ ^[A-Za-z0-9_.-]+$ ]] \
     || ! [[ "$TARGET_MUX_PANE" =~ ^%[0-9]+$ ]]; then
    focus_log "result=miss strategy=managed reason=invalid-identity"
    return 1
  fi

  local line session_name pane_id pane_tty window_id
  line=$("$TMUX_BIN" -L "$TARGET_MUX_SERVER" display-message -p \
    -t "$TARGET_MUX_PANE" \
    '#{session_name}	#{pane_id}	#{pane_tty}	#{window_id}' 2>/dev/null) || line=""
  if [ -z "$line" ]; then
    focus_log "result=miss strategy=managed reason=pane-not-found"
    return 1
  fi
  IFS=$'\t' read -r session_name pane_id pane_tty window_id <<<"$line"
  if [ "$session_name" != "$TARGET_MUX_SESSION" ] \
     || [ "$pane_id" != "$TARGET_MUX_PANE" ] \
     || [ -z "$window_id" ]; then
    focus_log "result=miss strategy=managed reason=ownership-mismatch"
    return 1
  fi

  # Precise in-mux focus: flip the session to the right window regardless
  # of whether any client is currently attached to see it.
  if ! "$TMUX_BIN" -L "$TARGET_MUX_SERVER" select-window -t "$window_id" 2>/dev/null; then
    focus_log "result=miss strategy=managed reason=select-window-failed"
    return 1
  fi

  # Raise whichever real terminal window(s) are attached to this session,
  # switching each attached client to it first. Normally exactly one client
  # (per-agent layout, or cockpit layout's single shared terminal); loop
  # covers the rare case of more than one.
  local clients client_tty
  clients=$("$TMUX_BIN" -L "$TARGET_MUX_SERVER" list-clients \
    -t "$session_name" -F '#{client_tty}' 2>/dev/null)
  if [ -n "$clients" ]; then
    while IFS= read -r client_tty; do
      [ -n "$client_tty" ] || continue
      "$TMUX_BIN" -L "$TARGET_MUX_SERVER" switch-client \
        -c "$client_tty" -t "$session_name" 2>/dev/null || true
      if command -v osascript >/dev/null 2>&1; then
        raise_terminal_by_tty "$client_tty" || true
      fi
    done <<CLIENTS
$clients
CLIENTS
  fi

  focus_log "result=focused strategy=managed live_pane_tty=$pane_tty"
  return 0
}

try_iterm_tty() {
  [ -n "$TARGET_TTY" ] || return 1
  app_running "iTerm2" || return 1

  local tty_esc script result
  tty_esc="$(osa_escape "$TARGET_TTY")"
  script=$(cat <<APPLESCRIPT
tell application "iTerm2"
  set found to false
  repeat with w in windows
    repeat with t in tabs of w
      repeat with s in sessions of t
        try
          if (tty of s) is "$tty_esc" then
            select t
            select w
            set found to true
            exit repeat
          end if
        end try
      end repeat
      if found then exit repeat
    end repeat
    if found then exit repeat
  end repeat
  if found then activate
  if found then
    return "matched"
  else
    return "nomatch"
  end if
end tell
APPLESCRIPT
)
  result="$(run_osa "$script")"
  [ "$result" = "matched" ]
}

try_terminal_tty() {
  [ -n "$TARGET_TTY" ] || return 1
  app_running "Terminal" || return 1

  local tty_esc script result
  tty_esc="$(osa_escape "$TARGET_TTY")"
  script=$(cat <<APPLESCRIPT
tell application "Terminal"
  set found to false
  repeat with w in windows
    repeat with tb in tabs of w
      try
        if (tty of tb) is "$tty_esc" then
          set selected of tb to true
          set index of w to 1
          set found to true
          exit repeat
        end if
      end try
    end repeat
    if found then exit repeat
  end repeat
  if found then activate
  if found then
    return "matched"
  else
    return "nomatch"
  end if
end tell
APPLESCRIPT
)
  result="$(run_osa "$script")"
  [ "$result" = "matched" ]
}

try_iterm() {
  [ -n "$NEEDLE" ] || return 1
  app_running "iTerm2" || return 1

  local needle_esc script result
  needle_esc="$(osa_escape "$NEEDLE")"
  script=$(cat <<APPLESCRIPT
tell application "iTerm2"
  set claimed to $(osa_claimed_ttys)
  set found to false
  repeat with w in windows
    repeat with t in tabs of w
      repeat with s in sessions of t
        try
          if (claimed does not contain (tty of s)) and ((name of s contains "$needle_esc") or (tty of s contains "$needle_esc")) then
            select t
            select w
            set found to true
            exit repeat
          end if
        end try
      end repeat
      if found then exit repeat
    end repeat
    if found then exit repeat
  end repeat
  if found then activate
  if found then
    return "matched"
  else
    return "nomatch"
  end if
end tell
APPLESCRIPT
)
  result="$(run_osa "$script")"
  [ "$result" = "matched" ]
}

try_terminal() {
  [ -n "$NEEDLE" ] || return 1
  app_running "Terminal" || return 1

  local needle_esc script result
  needle_esc="$(osa_escape "$NEEDLE")"
  script=$(cat <<APPLESCRIPT
tell application "Terminal"
  set claimed to $(osa_claimed_ttys)
  set found to false
  repeat with w in windows
    repeat with tb in tabs of w
      try
        if (claimed does not contain (tty of tb)) and ((custom title of tb contains "$needle_esc") or (tty of tb contains "$needle_esc")) then
          set selected of tb to true
          set index of w to 1
          set found to true
          exit repeat
        end if
      end try
    end repeat
    if found then exit repeat
  end repeat
  if found then activate
  if found then
    return "matched"
  else
    return "nomatch"
  end if
end tell
APPLESCRIPT
)
  result="$(run_osa "$script")"
  [ "$result" = "matched" ]
}

fallback_activate() {
  if app_running "iTerm2"; then
    run_osa 'tell application "iTerm2" to activate' >/dev/null 2>&1 || true
  elif app_running "Terminal"; then
    run_osa 'tell application "Terminal" to activate' >/dev/null 2>&1 || true
  fi
}

if try_managed_tmux; then
  :
elif command -v osascript >/dev/null 2>&1; then
  if try_iterm_tty; then
    focus_log "result=focused strategy=iterm-tty"
  elif try_terminal_tty; then
    focus_log "result=focused strategy=terminal-tty"
  elif try_iterm; then
    focus_log "result=focused strategy=iterm-fuzzy"
  elif try_terminal; then
    focus_log "result=focused strategy=terminal-fuzzy"
  else
    focus_log "result=fallback strategy=activate"
    fallback_activate
  fi
else
  focus_log "result=miss strategy=none reason=osascript-unavailable"
fi

exit 0
