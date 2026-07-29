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
#   PreCompact          → compacting (transient, greyed-out state — see
#                         comment above the case below; the daemon reunites
#                         it with its continuation instead of leaving a
#                         zombie duplicate, PROTOCOL.md §3)
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
# Subagent count: Claude Code spawns subagents via a tool_use block in the
# main transcript (its own sub-transcript isn't reachable from this hook's
# context), so counting those is the only signal available here — it's a
# cumulative count of subagents launched this session, not how many are
# running right now. The tool is named "Task" on some Claude Code
# builds/versions and "Agent" on others (confirmed by grepping a live
# transcript — this session's own subagent launch showed up as "Agent", not
# "Task"), so both names are matched.
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

# Cumulative "turns tool_calls tokens_in tokens_out model" as a TSV line, or
# empty. Recomputed fresh from the transcript every call (no counter state to
# drift out of sync) — real turns are user entries whose content is a plain
# string (tool-result "user" entries carry an array instead).
#
# Token math (easy to get wrong on agentic sessions):
# - tokens_out: sum output_tokens across unique API message.id values.
#   Each tool-call iteration generates new output, so this is a true total.
# - tokens_in: per user turn, take the *last* assistant usage snapshot
#   (input + cache_creation + cache_read for that call). Sum across turns.
#   Do NOT sum cache_read across every iteration — a 38-tool-call turn re-
#   reads the same cached context on each API round-trip, and adding every
#   iteration's cache_read inflates a single-turn session into millions.
#
# model: the raw model id (e.g. "claude-opus-4-8-...") from the last
# assistant message, so the app can derive a short display badge.
#
# context_tokens: current context-window occupancy, distinct from tokens_in
# above. tokens_in sums the last usage snapshot *per turn* across every turn
# (a running cumulative total); context_tokens is just the single latest
# assistant usage snapshot in the whole transcript (input + cache_creation +
# cache_read), i.e. what's actually resident in the model's context right
# now. Reuses the same usage_in() term tokens_in already computes per-turn,
# just applied once to assistants_with_usage's last entry instead of summed.
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
      subagents: ([.[] | select(.type=="assistant") | (.message.content // [])[] | select(.type=="tool_use" and (.name=="Task" or .name=="Agent"))] | length),
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
      ),
      model: ([.[] | select(.type=="assistant") | .message.model] | last // ""),
      context_tokens: (assistants_with_usage | if length == 0 then 0 else (last | usage_in(.message.usage)) end)
    } | [.turns, .tool_calls, .subagents, .tokens_in, .tokens_out, .model, .context_tokens] | @tsv
  ' "$transcript" 2>/dev/null
}

# Find the nearest ancestor with a controlling terminal, e.g.
# "/dev/ttys003", AND the nearest ancestor that IS the Claude Code process
# itself (comm "claude" — confirmed empirically via `ps -o comm=`; it's not
# wrapped by node/electron on this platform). An async hook itself normally
# reports "??" for tty and is never "claude" itself (it's the per-invocation
# bash `hooks.sh` runs as); walking up typically reaches both at once, since
# Claude Code's own process is usually the nearest ancestor holding the
# terminal. Empty session_tty means a background/non-interactive invocation
# with no terminal anywhere in its ancestry; empty claude_pid means the walk
# hit PID 1 without finding a "claude" process (unexpected, but the pid meta
# is simply omitted rather than sent wrong).
session_tty=""
claude_pid=""
tty_pid=$$
while [ -n "$tty_pid" ] && [ "$tty_pid" -gt 1 ] 2>/dev/null; do
  if [ -z "$session_tty" ]; then
    tty_raw=$(ps -o tty= -p "$tty_pid" 2>/dev/null | tr -d '[:space:]')
    if [ -n "$tty_raw" ] && [ "$tty_raw" != "??" ] && [ "$tty_raw" != "?" ]; then
      case "$tty_raw" in
        /*) session_tty="$tty_raw" ;;
        *)  session_tty="/dev/$tty_raw" ;;
      esac
    fi
  fi

  if [ -z "$claude_pid" ]; then
    comm=$(ps -o comm= -p "$tty_pid" 2>/dev/null | tr -d '[:space:]')
    case "$comm" in
      */claude|claude) claude_pid="$tty_pid" ;;
    esac
  fi

  [ -n "$session_tty" ] && [ -n "$claude_pid" ] && break

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
  PreCompact)
    # Compaction is always a session-lifecycle transition in Claude Code
    # (SessionStart fires with source=compact on the continuation), but
    # Claude Code exposes no field linking that continuation back to this
    # session — and empirically the session_id doesn't even always change:
    # a plain interactive/foreground /compact typically keeps the same
    # session_id (same process throughout), while a background job forced
    # to auto-compact mid-run forks a whole new `claude` process under a
    # genuinely new session_id, leaving this one alive forever as an idle
    # supervisor.
    #
    # Rather than guess which case this is, mark the session `compacting`
    # (a transient, greyed-out state — PROTOCOL.md §1) instead of ending
    # it. If the *same* session_id sends the next hook event (the common
    # case), it just transitions state normally and keeps every meta key
    # (turns/tool_calls/tokens/cost) it had already accumulated — ending
    # the session here instead, as this hook used to, would wipe all of
    # that for no reason. If a *different* session_id shows up next with
    # matching cwd/tty (the fork case), the daemon reunites it with this
    # same slot instead of leaving a zombie duplicate behind (Registry::
    # set_state's rekey match, daemon/src/session.rs). Either way, a
    # session stuck `compacting` for more than a few minutes — compaction
    # was cancelled, or the continuation never appears — is reaped by the
    # daemon's own compacting-timeout sweep, independent of
    # session_ttl_minutes.
    if [ -n "${session_id:-}" ]; then
      args=(compacting --session "$session_id" --kind claude --cwd "$cwd")
      [ -n "$session_tty" ] && args+=(--meta "tty=$session_tty")
      [ -n "$claude_pid" ] && args+=(--meta "pid=$claude_pid")
      "$FOCALPOINT" set-state "${args[@]}" 2>/dev/null || true
    fi
    exit 0
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
  # Lets the daemon's dead-process sweep (PROTOCOL.md §3) reap this session
  # the moment Claude Code itself exits, even if the terminal it ran in
  # stays open — the tty sweep alone can't see that failure mode.
  [ -n "$claude_pid" ] && args+=(--meta "pid=$claude_pid")

  if [ "$event" = "Stop" ]; then
    stats=$(extract_stats "$transcript_path")
    if [ -n "$stats" ]; then
      IFS=$'\t' read -r turns tool_calls subagents tokens_in tokens_out model context_tokens <<< "$stats"
      args+=(--meta "turns=$turns" --meta "tool_calls=$tool_calls" \
             --meta "subagents=$subagents" \
             --meta "tokens_in=$tokens_in" --meta "tokens_out=$tokens_out")
      [ -n "$model" ] && args+=(--meta "model=$model")
      [ -n "$context_tokens" ] && args+=(--meta "context_tokens=$context_tokens")
    fi
  fi
fi

# Call focalpoint set-state, silently fail if daemon is not running
"$FOCALPOINT" set-state "${args[@]}" 2>/dev/null || true

exit 0
