#!/bin/bash
# FocalPoint Claude Code Integration
# Reads hook JSON from stdin and dispatches to focalpoint set-state
#
# MIT License - see adapters/README.md
#
# Hook event mappings:
#   UserPromptSubmit    → thinking
#   PreToolUse          → running
#   PostToolUse         → thinking
#   Notification        → waiting (filtered to permission_prompt/idle_prompt
#                         by the matcher in settings-fragment.json)
#   Stop                → done
#   SessionEnd          → end-session (falls back to sessionless `idle` if
#                         no session_id could be extracted)
#
# Claude Code's hook JSON includes "session_id" and "cwd" fields (see
# https://code.claude.com/docs/en/hooks). When present, every set-state call
# carries --session/--kind/--cwd/--label so the daemon can register/update a
# per-session slot (PROTOCOL.md §3 "Sessions"). When absent (older Claude
# Code versions, or extraction failure), the adapter falls back to plain
# sessionless set-state calls, exactly like before this feature existed.
#
# Session label: Claude Code writes a generated `{"type":"ai-title",
# "aiTitle":"..."}` line into the session's transcript (transcript_path) once
# it has one — the same title shown atop the Claude Code TUI / --resume
# picker. When present we use that instead of the cwd's basename, so FocalPoint
# shows "Fix drag stutter" rather than "focalpoint" for every session in the
# same directory. Requires jq; silently falls back to basename(cwd) without
# it, same as before this feature existed.
#
# Session stats (tokens/tool-calls/turns/subagents): computed from the same
# transcript on the Stop event only (once per turn, not per tool call, to
# keep the hook fast) and sent via --meta (PROTOCOL.md §4). Optional
# end-to-end: skipped without jq, and the menu bar app only shows a badge for
# stats it actually receives (Settings → Claude & Codex).
#
# Subagent count: Claude Code spawns subagents via a tool_use block named
# "Task" in the main transcript (its own sub-transcript isn't reachable from
# this hook's context), so counting those is the only signal available here
# — it's a cumulative count of subagents launched this session, not how many
# are running right now.
#
# Session tty (--meta tty=...): the [session] focus action (PROTOCOL.md §3)
# needs a way to find the RIGHT terminal window. Matching on the cwd's
# basename in window titles doesn't work — Claude Code titles iTerm2/Terminal
# tabs with a generated task summary, not the cwd, so it may never appear in
# the title at all, and two sessions in the same repo are indistinguishable by
# cwd anyway. Async Claude hooks have no controlling terminal of their own, so
# walk their parent chain to find the Claude/shell process that still owns it.
# We use `ps`, not the `tty` builtin: stdin is a pipe carrying the hook JSON.

set -u

# Path to focalpoint CLI
FOCALPOINT="${FOCALPOINT_PATH:-focalpoint}"

# Read the full hook JSON from stdin; if anything fails, silently exit 0
hook_json=$(cat 2>/dev/null) || exit 0

# Extract a JSON string field. Prefers jq; falls back to sed for the common
# case of a flat top-level string field (same pattern used throughout this
# adapter and the other FocalPoint adapters).
extract_field() {
  local field="$1"
  if command -v jq >/dev/null 2>&1; then
    printf '%s' "$hook_json" | jq -r --arg f "$field" '.[$f] // empty' 2>/dev/null
  else
    printf '%s' "$hook_json" \
      | sed -n "s/.*\"${field}\"[[:space:]]*:[[:space:]]*\"\\([^\"]*\\)\".*/\\1/p" \
      | head -n1
  fi
}

# The transcript's most recent generated title, or empty (no jq, no
# transcript, or Claude Code hasn't generated one yet this session).
extract_title() {
  local transcript="$1"
  [ -n "$transcript" ] && [ -f "$transcript" ] || return 0
  command -v jq >/dev/null 2>&1 || return 0
  local line
  line=$(grep -o '"type": *"ai-title"[^}]*}' "$transcript" 2>/dev/null | tail -n1)
  [ -n "$line" ] || return 0
  printf '{%s' "$line" | jq -r '.aiTitle // empty' 2>/dev/null
}

# Cumulative "turns tool_calls tokens_in tokens_out" as a TSV line, or empty.
# Recomputed fresh from the transcript every call (no counter state to drift
# out of sync) — real turns are user entries whose content is a plain string
# (tool-result "user" entries carry an array instead).
#
# Token math (easy to get wrong on agentic sessions):
# - tokens_out: sum output_tokens across unique API message.id values.
#   Each tool-call iteration generates new output, so this is a true total.
# - tokens_in: per user turn, take the *last* assistant usage snapshot
#   (input + cache_creation + cache_read for that call). Sum across turns.
#   Do NOT sum cache_read across every iteration — a 38-tool-call turn re-
#   reads the same cached context on each API round-trip, and adding every
#   iteration's cache_read inflates a single-turn session into millions.
extract_stats() {
  local transcript="$1"
  [ -n "$transcript" ] && [ -f "$transcript" ] || return 0
  command -v jq >/dev/null 2>&1 || return 0
  jq -r -s '
    def usage_in(u):
      ((u.input_tokens // 0) + (u.cache_creation_input_tokens // 0) + (u.cache_read_input_tokens // 0));
    def user_turns:
      [.[] | select(.type=="user") | select(.message.content | type == "string")];
    def assistants_with_usage:
      [.[] | select(.type=="assistant" and .message.usage != null)];
    {
      turns: (user_turns | length),
      tool_calls: ([.[] | select(.type=="assistant") | (.message.content // [])[] | select(.type=="tool_use")] | length),
      subagents: ([.[] | select(.type=="assistant") | (.message.content // [])[] | select(.type=="tool_use" and .name=="Task")] | length),
      tokens_in: (
        user_turns as $users
        | if ($users | length) == 0 then
            (assistants_with_usage | if length == 0 then 0 else (last | usage_in(.message.usage)) end)
          else
            [range(0; ($users | length)) as $i |
              assistants_with_usage
              | map(select(.timestamp >= $users[$i].timestamp
                and (if $i + 1 < ($users | length) then .timestamp < $users[$i + 1].timestamp else true end)))
              | if length == 0 then 0 else (last | usage_in(.message.usage)) end
            ] | add
          end
      ),
      tokens_out: (
        [.[] | select(.type=="assistant" and .message.usage != null) | {id: .message.id, u: .message.usage}] | unique_by(.id)
        | ([.[].u.output_tokens // 0] | add // 0)
      )
    } | [.turns, .tool_calls, .subagents, .tokens_in, .tokens_out] | @tsv
  ' "$transcript" 2>/dev/null
}

# Find the nearest ancestor with a controlling terminal, e.g.
# "/dev/ttys003". An async hook itself normally reports "??"; its Claude Code
# or shell ancestor retains the terminal. Empty means a background or
# non-interactive invocation with no terminal anywhere in its ancestry.
session_tty=""
tty_pid=$$
while [ -n "$tty_pid" ] && [ "$tty_pid" -gt 1 ] 2>/dev/null; do
  tty_raw=$(ps -o tty= -p "$tty_pid" 2>/dev/null | tr -d '[:space:]')
  if [ -n "$tty_raw" ] && [ "$tty_raw" != "??" ] && [ "$tty_raw" != "?" ]; then
    case "$tty_raw" in
      /*) session_tty="$tty_raw" ;;
      *)  session_tty="/dev/$tty_raw" ;;
    esac
    break
  fi

  parent_pid=$(ps -o ppid= -p "$tty_pid" 2>/dev/null | tr -d '[:space:]')
  [ -n "$parent_pid" ] && [ "$parent_pid" != "$tty_pid" ] || break
  tty_pid="$parent_pid"
done

event=$(extract_field "hook_event_name")
[ -n "${event:-}" ] || exit 0

session_id=$(extract_field "session_id")
cwd=$(extract_field "cwd")
transcript_path=$(extract_field "transcript_path")

# Map event to state
case "$event" in
  UserPromptSubmit)
    state="thinking"
    ;;
  PreToolUse)
    state="running"
    ;;
  PostToolUse)
    state="thinking"
    ;;
  Stop)
    state="done"
    ;;
  SessionEnd)
    # Prefer a clean end-session over just marking idle, so the session's
    # numbered-key slot is freed immediately (PROTOCOL.md §3).
    if [ -n "${session_id:-}" ]; then
      "$FOCALPOINT" end-session "$session_id" 2>/dev/null || true
    else
      "$FOCALPOINT" set-state idle 2>/dev/null || true
    fi
    exit 0
    ;;
  Notification)
    # Type filtering happens via the matcher in settings-fragment.json
    # (permission_prompt|idle_prompt); anything that reaches us means
    # the agent is blocked on the user.
    state="waiting"
    ;;
  *)
    # Unknown event, ignore
    exit 0
    ;;
esac

# Build the extra session flags. Only attach them when we actually have a
# session_id; otherwise keep working exactly as a sessionless adapter (the
# daemon's sessionless default still participates in the aggregate state).
args=("$state")
if [ -n "${session_id:-}" ]; then
  label=$(extract_title "$transcript_path")
  [ -n "$label" ] || label="$(basename "${cwd:-.}")"
  args+=(--session "$session_id" --kind claude --cwd "$cwd" --label "$label")
  [ -n "$session_tty" ] && args+=(--meta "tty=$session_tty")

  if [ "$event" = "Stop" ]; then
    stats=$(extract_stats "$transcript_path")
    if [ -n "$stats" ]; then
      IFS=$'\t' read -r turns tool_calls subagents tokens_in tokens_out <<< "$stats"
      args+=(--meta "turns=$turns" --meta "tool_calls=$tool_calls" \
             --meta "subagents=$subagents" \
             --meta "tokens_in=$tokens_in" --meta "tokens_out=$tokens_out")
    fi
  fi
fi

# Call focalpoint set-state, silently fail if daemon is not running
"$FOCALPOINT" set-state "${args[@]}" 2>/dev/null || true

exit 0
