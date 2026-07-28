#!/bin/bash
# FocalPoint Cursor Integration
# Reads hook JSON from stdin and dispatches to focalpoint set-state
#
# MIT License - see adapters/README.md
#
# Hook event mappings (see https://cursor.com/docs/hooks):
#   beforeSubmitPrompt  → thinking
#   afterAgentThought   → thinking
#   preToolUse          → running
#   postToolUse         → thinking
#   postToolUseFailure  → error
#   stop                → done (status "completed") / error (aborted, error)
#   sessionEnd          → end-session
#
# Sessions: every agent hook payload carries "conversation_id" (stable across
# the whole conversation); sessionStart/sessionEnd call the same value
# "session_id". Either way it becomes --session, so each Cursor chat claims
# its own numbered key (PROTOCOL.md §3 "Sessions"). Cursor has a real
# sessionEnd hook, so unlike the Codex adapter this one frees the slot
# immediately instead of waiting for the daemon's TTL to reap it.
#
# TWO RULES THIS ADAPTER MUST NEVER BREAK, both specific to Cursor:
#
#   1. Never exit 2. Cursor treats exit code 2 from a command hook as
#      "deny" and BLOCKS the tool call the user was trying to run. Every
#      path here ends in `exit 0`, and the focalpoint calls are `|| true`.
#   2. Never write to stdout. Cursor parses a hook's stdout as its JSON
#      response; stray output is at best logged as an error. All focalpoint
#      output is redirected, and nothing else prints. Emitting nothing at
#      all is a valid "no opinion" response.
#
# Cursor hook definitions also have no `async` option (Claude Code's hooks
# do), so this runs inline in the agent loop on every tool call. Keep it
# cheap: the transcript is only parsed on `stop`, once per turn.
#
# Session stats: turns/tool calls/subagents are computed from transcript_path
# on `stop`; Cursor 3.13+ also puts per-generation token usage directly in the
# stop payload. All are sent via --meta (PROTOCOL.md §4). Older Cursor versions
# omit token usage and continue to report the transcript-derived stats.
# Requires jq; silently skipped without it.
#
# No `waiting` state: Cursor has no equivalent of Claude Code's permission
# prompt Notification hook, so there is no reliable signal for "blocked on
# the user". Cursor sessions never report waiting.

set -u

# Path to focalpoint CLI
FOCALPOINT="${FOCALPOINT_PATH:-focalpoint}"

# Read the full hook JSON from stdin; if anything fails, silently exit 0
hook_json=$(cat 2>/dev/null) || exit 0

# Extract a JSON string field. Prefers jq; falls back to sed for the common
# case of a flat top-level string field (same pattern used throughout the
# other FocalPoint adapters).
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

# The workspace root. CURSOR_PROJECT_DIR is set on every hook invocation and
# needs no parsing, so prefer it; workspace_roots is an array (which the sed
# fallback can't read) and `cwd` is only on the tool hooks.
extract_root() {
  if [ -n "${CURSOR_PROJECT_DIR:-}" ]; then
    printf '%s' "$CURSOR_PROJECT_DIR"
    return 0
  fi
  if command -v jq >/dev/null 2>&1; then
    printf '%s' "$hook_json" | jq -r '.workspace_roots[0] // .cwd // empty' 2>/dev/null
    return 0
  fi
  extract_field "cwd"
}

# Cumulative "turns tool_calls subagents" as a TSV line, or empty.
# Recomputed fresh from the transcript every call, so there's no counter
# state to drift out of sync.
#
# Cursor's transcript is JSONL of two shapes: {"role":..., "message":...}
# for the conversation, and bare {"type":"turn_ended","status":...} markers.
# Those markers are the cleanest definition of a completed turn — user-role
# lines also include content Cursor injects on the user's behalf. The count
# can lag the in-flight turn by one, since the marker for the turn that
# triggered this `stop` may not be written yet.
#
# Subagents are Task tool calls, matching how the Claude Code adapter counts
# them: cumulative launches this session, not how many are running now.
extract_stats() {
  local transcript="$1"
  [ -n "$transcript" ] && [ -f "$transcript" ] || return 0
  command -v jq >/dev/null 2>&1 || return 0
  jq -r -s '
    def tool_uses:
      [.[]
       | select(.role == "assistant")
       | select(.message.content | type == "array")
       | .message.content[]
       | select(.type == "tool_use")];
    {
      turns: ([.[] | select(.type == "turn_ended")] | length),
      tool_calls: (tool_uses | length),
      subagents: (tool_uses | map(select(.name == "Task")) | length)
    } | [.turns, .tool_calls, .subagents] | @tsv
  ' "$transcript" 2>/dev/null
}

event=$(extract_field "hook_event_name")
[ -n "${event:-}" ] || exit 0

# conversation_id is on every agent hook; sessionStart/sessionEnd call the
# same identifier session_id.
session_id=$(extract_field "conversation_id")
[ -n "$session_id" ] || session_id=$(extract_field "session_id")

root=$(extract_root)
transcript_path=$(extract_field "transcript_path")
model=$(extract_field "model")
prompt=$(extract_field "prompt")
generation_id=$(extract_field "generation_id")

state_dir="${XDG_STATE_HOME:-$HOME/.local/state}/focalpoint/cursor"
label_file="$state_dir/$session_id.label"
stats_file="$state_dir/$session_id.stats.json"

# Cursor doesn't expose its generated chat title to hooks. Preserve the first
# submitted prompt as a stable session label; later turns must not rename it.
if [ "$event" = "beforeSubmitPrompt" ] && [ -n "${prompt:-}" ] && [ -n "${session_id:-}" ]; then
  mkdir -p "$state_dir" 2>/dev/null
  if [ ! -s "$label_file" ]; then
    compact_prompt=$(printf '%s' "$prompt" | tr '\r\n\t' '   ' | tr -s ' ' | cut -c1-60)
    [ -n "$compact_prompt" ] && printf '%s' "$compact_prompt" > "$label_file" 2>/dev/null
  fi
fi

case "$event" in
  beforeSubmitPrompt|afterAgentThought)
    state="thinking"
    ;;
  preToolUse)
    state="running"
    ;;
  postToolUse)
    state="thinking"
    ;;
  postToolUseFailure)
    state="error"
    ;;
  stop)
    # "completed" is a clean finish; "aborted" (user stopped the agent) and
    # "error" both leave the session needing attention.
    if [ "$(extract_field "status")" = "completed" ]; then
      state="done"
    else
      state="error"
    fi
    ;;
  sessionEnd)
    # Free the session's numbered-key slot right away (PROTOCOL.md §3).
    if [ -n "${session_id:-}" ]; then
      "$FOCALPOINT" end-session "$session_id" >/dev/null 2>&1 || true
      rm -f "$label_file" "$stats_file" 2>/dev/null || true
    fi
    exit 0
    ;;
  *)
    # Unknown or unwired event, ignore
    exit 0
    ;;
esac

# Only attach session flags when we actually have an id; otherwise fall back
# to a plain sessionless set-state, which still drives the aggregate.
args=("$state")
if [ -n "${session_id:-}" ]; then
  if [ -s "$label_file" ]; then
    label=$(cat "$label_file" 2>/dev/null)
  else
    label="Cursor · $(basename "${root:-.}")"
  fi
  args+=(--session "$session_id" --kind cursor --cwd "$root" \
         --label "$label")
  [ -n "${model:-}" ] && args+=(--meta "model=$model")

  if [ "$event" = "stop" ]; then
    stats=$(extract_stats "$transcript_path")
    if [ -n "$stats" ]; then
      IFS=$'\t' read -r turns tool_calls subagents <<< "$stats"
      args+=(--meta "turns=$turns" --meta "tool_calls=$tool_calls" \
             --meta "subagents=$subagents")
    fi

    # Cursor 3.13+ reports per-generation usage directly on `stop`. Accumulate
    # once per generation id; older Cursor versions simply omit these fields.
    input_tokens=$(extract_field "input_tokens")
    output_tokens=$(extract_field "output_tokens")
    if [ -n "${generation_id:-}" ] && [ -n "${input_tokens:-}" ] && [ -n "${output_tokens:-}" ] \
       && command -v jq >/dev/null 2>&1; then
      mkdir -p "$state_dir" 2>/dev/null
      current='{"generations":[],"tokens_in":0,"tokens_out":0}'
      [ -s "$stats_file" ] && current=$(cat "$stats_file" 2>/dev/null)
      updated=$(printf '%s' "$current" | jq -c --arg generation "$generation_id" \
        --argjson tokens_in "$input_tokens" --argjson tokens_out "$output_tokens" '
          if (.generations // [] | index($generation)) != null then .
          else
            .generations = ((.generations // []) + [$generation])
            | .tokens_in = ((.tokens_in // 0) + $tokens_in)
            | .tokens_out = ((.tokens_out // 0) + $tokens_out)
          end
        ' 2>/dev/null)
      if [ -n "$updated" ]; then
        printf '%s' "$updated" > "$stats_file" 2>/dev/null
        cumulative_in=$(printf '%s' "$updated" | jq -r '.tokens_in')
        cumulative_out=$(printf '%s' "$updated" | jq -r '.tokens_out')
        args+=(--meta "tokens_in=$cumulative_in" --meta "tokens_out=$cumulative_out")
      fi
    fi
  fi
fi

# Silently no-op if the daemon isn't running. stdout is redirected too: see
# rule 2 in the header.
"$FOCALPOINT" set-state "${args[@]}" >/dev/null 2>&1 || true

exit 0
