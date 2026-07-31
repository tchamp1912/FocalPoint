#!/bin/bash
# FocalPoint Codex lifecycle-hook adapter.
#
# tty/pid identity: previously resolved here via a `ps` ancestry walk on
# every hook call (the same design claude-code/hooks.sh had before it was
# fixed to cache once per process instance — this script had drifted out of
# sync with that fix). Moved into the `focalpoint` CLI itself
# (daemon/src/identity.rs) so there's exactly one implementation shared by
# both adapters instead of two copies that can silently diverge again.
# set-state/set-meta resolve+cache tty/pid automatically whenever --session
# and --kind claude|codex are given and no explicit --meta tty=/pid= was
# passed; --refresh-identity (passed below on SessionStart) forces a fresh
# walk instead of trusting the cache. See
# SESSION-IDENTITY-PERSISTENCE-PLAN.md Part 1.
#
# Compaction: unlike Claude Code, Codex has no PreCompact-equivalent hook,
# but it also doesn't need one — verified against real local rollout files,
# Codex compacts *in place* (same thread_id, same rollout file, nothing
# forks), so the existing full-transcript recompute below is already
# correctly cumulative across a Codex compaction for free. The only thing
# missing was a `compactions` counter itself, added below (Part 2b).

set -u

# Detached half of the permission debounce. It is intentionally a mode of
# this same installed hook so no extra helper needs to be deployed.
if [ "${1:-}" = "--deferred-wait" ]; then
  pending_file="$2" lock_dir="$3" expected_token="$4" grace_secs="$5" focalpoint_bin="$6"
  shift 6
  sleep "$grace_secs"
  attempts=0
  while ! mkdir "$lock_dir" 2>/dev/null; do
    attempts=$((attempts + 1))
    [ "$attempts" -ge 100 ] && exit 0
    sleep 0.01
  done
  current_token=$(cat "$pending_file" 2>/dev/null || true)
  if [ "$current_token" = "$expected_token" ]; then
    "$focalpoint_bin" set-state "$@" >/dev/null 2>&1 || true
    rm -f "$pending_file"
  fi
  rmdir "$lock_dir" 2>/dev/null || true
  exit 0
fi

FOCALPOINT="${FOCALPOINT_PATH:-focalpoint}"

channel_pull() {
  [ -n "${FOCALPOINT_CHANNEL_ID:-}" ] || return 0
  command -v fpctl-agent >/dev/null 2>&1 || return 0
  fpctl-agent channel read --channel "$FOCALPOINT_CHANNEL_ID" 2>/dev/null || true
}
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

# Codex can immediately auto-approve PermissionRequest. Use a short,
# cancelable grace period so only a permission request that remains blocked
# becomes FocalPoint `waiting` (and therefore lights the keyboard/widget).
defer_permission_wait=0
if [ "$event" = "PermissionRequest" ] && [ -n "${session_id:-}" ]; then
  defer_permission_wait=1
fi

approval_pending_file=""
approval_lock_dir=""
if [ -n "${session_id:-}" ]; then
  safe_session_id=$(printf '%s' "$session_id" | tr -c 'A-Za-z0-9._-' '_')
  approval_dir="${XDG_STATE_HOME:-$HOME/.local/state}/focalpoint/approval-pending"
  approval_pending_file="$approval_dir/codex-$safe_session_id.token"
  approval_lock_dir="$approval_dir/codex-$safe_session_id.lock"
fi

approval_lock() {
  local attempts=0
  while ! mkdir "$approval_lock_dir" 2>/dev/null; do
    attempts=$((attempts + 1))
    [ "$attempts" -ge 100 ] && return 1
    sleep 0.01
  done
}

approval_unlock() { rmdir "$approval_lock_dir" 2>/dev/null || true; }

if [ "$defer_permission_wait" -eq 1 ]; then
  mkdir -p "$approval_dir" 2>/dev/null
  approval_token="$$-${RANDOM:-0}-$(date +%s)"
  printf '%s' "$approval_token" > "$approval_pending_file" 2>/dev/null || exit 0
fi

if [ "$defer_permission_wait" -eq 0 ] && [ -n "$approval_pending_file" ] \
   && [ -f "$approval_pending_file" ]; then
  if approval_lock; then
    rm -f "$approval_pending_file"
    approval_unlock
  fi
fi

managed_value="false"
mux_pane=""
if [ -n "${TMUX:-}" ] && command -v tmux >/dev/null 2>&1; then
  mux_pane=$(tmux display-message -p '#{pane_id}' 2>/dev/null) || mux_pane=""
  [ -n "$mux_pane" ] && managed_value="true"
fi

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
  args+=(--meta "managed=$managed_value" --meta "mux_pane=$mux_pane")
  [ -n "${transcript_path:-}" ] && args+=(--meta "transcript_path=$transcript_path")
  [ -n "${FOCALPOINT_RELAUNCH_ID:-}" ] && \
    args+=(--meta "relaunch_id=$FOCALPOINT_RELAUNCH_ID")
  [ -n "${FOCALPOINT_RESUME_SESSION_ID:-}" ] && \
    args+=(--meta "resume_session_id=$FOCALPOINT_RESUME_SESSION_ID")
  [ -n "${FOCALPOINT_ORCHESTRATOR_TASK_ID:-}" ] && \
    args+=(--meta "orchestrator_task_id=$FOCALPOINT_ORCHESTRATOR_TASK_ID")
  [ -n "${FOCALPOINT_ORCHESTRATION_ROLE:-}" ] && \
    args+=(--meta "orchestration_role=$FOCALPOINT_ORCHESTRATION_ROLE")
  [ -n "${FOCALPOINT_MANAGER_TASK_ID:-}" ] && \
    args+=(--meta "manager_task_id=$FOCALPOINT_MANAGER_TASK_ID")
  [ -n "${FOCALPOINT_CHANNEL_ID:-}" ] && args+=(--meta "channel_id=$FOCALPOINT_CHANNEL_ID")
  # SessionStart means "a fresh process instance for this session_id just
  # began" — force the CLI to re-walk instead of trusting a (possibly stale,
  # possibly nonexistent) cached identity (identity.rs).
  [ "$event" = "SessionStart" ] && args+=(--refresh-identity)
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
      # compactions: counts inline context-compaction events (verified against
      # real rollout files — Codex compacts in place, same thread_id, so this
      # is already a whole-lineage total with no daemon-side carry-forward
      # needed, unlike Claude Code's cumulative stats).
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
            context_window: ($usage.model_context_window // 0),
            compactions: ([.[] | select(.type=="event_msg" and .payload.type=="context_compacted")] | length)
          }
        | [.turns, .tool_calls, .subagents, .tokens_in, .tokens_out, .model,
           .context_tokens, .context_window, .compactions]
        | @tsv
      ' "$transcript_path" 2>/dev/null)
    fi

    if [ -n "$stats" ]; then
      IFS=$'\t' read -r turns tool_calls subagents tokens_in tokens_out transcript_model context_tokens context_window compactions <<< "$stats"
      printf '%s' "$turns" > "$counter_file" 2>/dev/null
      args+=(--meta "turns=$turns" --meta "tool_calls=$tool_calls" \
             --meta "subagents=$subagents" --meta "tokens_in=$tokens_in" \
             --meta "tokens_out=$tokens_out" --meta "context_tokens=$context_tokens" \
             --meta "context_window=$context_window" --meta "compactions=$compactions")
      [ -n "$transcript_model" ] && args+=(--meta "model=$transcript_model")
    else
      turns=$(( $(cat "$counter_file" 2>/dev/null || echo 0) + 1 ))
      printf '%s' "$turns" > "$counter_file" 2>/dev/null
      args+=(--meta "turns=$turns")
    fi
  fi
fi

# Publish `waiting` only if no PreToolUse/other lifecycle event arrived during
# the auto-approval grace period. The per-session lock makes the race resolve
# in event order: either cancellation wins, or its newer state follows the
# delayed waiting update.
if [ "$defer_permission_wait" -eq 1 ]; then
  nohup /bin/bash "$0" --deferred-wait "$approval_pending_file" "$approval_lock_dir" \
    "$approval_token" "${FOCALPOINT_APPROVAL_GRACE_SECS:-2}" "$FOCALPOINT" \
    "${args[@]}" </dev/null >/dev/null 2>&1 &
  exit 0
fi

"$FOCALPOINT" set-state "${args[@]}" >/dev/null 2>&1 || true
if [ "$event" = "SessionStart" ] || [ "$event" = "Stop" ]; then channel_pull; fi
exit 0
