#!/bin/bash
# FocalPoint Codex lifecycle-hook adapter.

set -u

FOCALPOINT="${FOCALPOINT_PATH:-focalpoint}"
payload=$(cat 2>/dev/null) || exit 0

field() {
  local name="$1"
  if command -v jq >/dev/null 2>&1; then
    printf '%s' "$payload" | jq -r --arg name "$name" '.[$name] // empty' 2>/dev/null
  else
    printf '%s' "$payload" \
      | sed -n "s/.*\"${name}\"[[:space:]]*:[[:space:]]*\"\\([^\"]*\\)\".*/\\1/p" \
      | head -n1
  fi
}

event=$(field hook_event_name)
session_id=$(field session_id)
cwd=$(field cwd)
model=$(field model)
transcript_path=$(field transcript_path)
prompt=$(field prompt)

label_dir="${XDG_STATE_HOME:-$HOME/.local/state}/focalpoint/codex"
label_file="$label_dir/$session_id.label"
if [ "$event" = "UserPromptSubmit" ] && [ -n "${prompt:-}" ] && [ -n "${session_id:-}" ]; then
  mkdir -p "$label_dir" 2>/dev/null
  if [ ! -s "$label_file" ]; then
    compact_prompt=$(printf '%s' "$prompt" | tr '\r\n\t' '   ' | tr -s ' ' | cut -c1-60)
    [ -n "$compact_prompt" ] && printf '%s' "$compact_prompt" > "$label_file" 2>/dev/null
  fi
fi
[ -n "${event:-}" ] || exit 0

case "$event" in
  SessionStart|UserPromptSubmit|PostToolUse) state="thinking" ;;
  PreToolUse) state="running" ;;
  PermissionRequest) state="waiting" ;;
  Stop) state="done" ;;
  SessionEnd)
    if [ -n "${session_id:-}" ]; then
      "$FOCALPOINT" end-session "$session_id" >/dev/null 2>&1 || true
      counter_file="${XDG_STATE_HOME:-$HOME/.local/state}/focalpoint/counters/$session_id.turns"
      rm -f "$counter_file" 2>/dev/null || true
      rm -f "$label_file" 2>/dev/null || true
    fi
    exit 0
    ;;
  *) exit 0 ;;
esac

args=("$state")
if [ -n "${session_id:-}" ]; then
  if [ -s "$label_file" ]; then
    label=$(cat "$label_file" 2>/dev/null)
  else
    label="Codex · $(basename "${cwd:-.}")"
  fi
  args+=(--session "$session_id" --kind codex --cwd "$cwd" --label "$label")
  [ -n "${model:-}" ] && args+=(--meta "model=$model")

  if [ "$event" = "Stop" ]; then
    counter_dir="${XDG_STATE_HOME:-$HOME/.local/state}/focalpoint/counters"
    mkdir -p "$counter_dir" 2>/dev/null
    counter_file="$counter_dir/$session_id.turns"
    stats=""
    if [ -n "${transcript_path:-}" ] && [ -f "$transcript_path" ] && command -v jq >/dev/null 2>&1; then
      # Codex rollout JSONL is explicitly a convenience rather than a stable
      # hook API, so keep this parser defensive and retain the counter fallback
      # below. token_count.total_token_usage is already cumulative; cached and
      # reasoning tokens are subsets of input_tokens/output_tokens respectively.
      stats=$(jq -r -s '
        ([.[] | select(.type=="event_msg" and .payload.type=="token_count"
          and .payload.info.total_token_usage!=null) | .payload.info] | last // {}) as $usage
        | {
            turns: ([.[] | select(.type=="event_msg" and .payload.type=="task_complete")] | length),
            tool_calls: ([.[] | select(.type=="response_item" and
              (.payload.type=="function_call" or .payload.type=="custom_tool_call"))] | length),
            subagents: ([.[] | select(.type=="response_item" and
              (.payload.type=="function_call" or .payload.type=="custom_tool_call") and
              ((.payload.name // "") | test("^(spawn_agent|Agent)$")))] | length),
            tokens_in: ($usage.total_token_usage.input_tokens // 0),
            tokens_out: ($usage.total_token_usage.output_tokens // 0),
            model: ([.[] | select(.type=="turn_context") | .payload.model]
              | map(select(.!=null and .!="")) | last // ""),
            context_tokens: ($usage.last_token_usage.input_tokens // 0),
            context_window: ($usage.model_context_window // 0)
          }
        | [.turns, .tool_calls, .subagents, .tokens_in, .tokens_out, .model,
           .context_tokens, .context_window]
        | @tsv
      ' "$transcript_path" 2>/dev/null)
    fi

    if [ -n "$stats" ]; then
      IFS=$'\t' read -r turns tool_calls subagents tokens_in tokens_out transcript_model context_tokens context_window <<< "$stats"
      printf '%s' "$turns" > "$counter_file" 2>/dev/null
      args+=(--meta "turns=$turns" --meta "tool_calls=$tool_calls" \
             --meta "subagents=$subagents" --meta "tokens_in=$tokens_in" \
             --meta "tokens_out=$tokens_out" --meta "context_tokens=$context_tokens" \
             --meta "context_window=$context_window")
      [ -n "$transcript_model" ] && args+=(--meta "model=$transcript_model")
    else
      turns=$(( $(cat "$counter_file" 2>/dev/null || echo 0) + 1 ))
      printf '%s' "$turns" > "$counter_file" 2>/dev/null
      args+=(--meta "turns=$turns")
    fi
  fi
fi

# Hook stdout is part of Codex's hook protocol; never write to it.
"$FOCALPOINT" set-state "${args[@]}" >/dev/null 2>&1 || true
exit 0
