#!/bin/bash
# FocalPoint Cursor CLI headless adapter.
#
# Runs Cursor Agent in print/stream-json mode, mirrors its NDJSON lifecycle to
# FocalPoint, and relays Cursor's NDJSON unchanged on stdout. The adapter never
# writes status text to stdout; stdout is reserved for Cursor's own stream.
#
# Cursor CLI has no documented lifecycle callback API. Its current hook support
# is limited to shell execution hooks, so this wrapper is the supported
# approximation for headless runs. See README.md.
#
# MIT License - see adapters/README.md.

set -u

FOCALPOINT="${FOCALPOINT_PATH:-focalpoint}"
STATE_FILE=""

cleanup() {
  [ -n "$STATE_FILE" ] && rm -f "$STATE_FILE" 2>/dev/null || true
}
trap cleanup EXIT HUP INT TERM

usage() {
  echo "Usage: cursor-cli-focalpoint [Cursor Agent options] <prompt>" >&2
  echo "Runs Cursor Agent with --print --output-format stream-json." >&2
}

for arg in "$@"; do
  case "$arg" in
    -p|--print|--output-format|--output-format=*)
      echo "cursor-cli-focalpoint supplies --print --output-format stream-json; omit $arg" >&2
      exit 1
      ;;
  esac
done

[ "$#" -gt 0 ] || { usage; exit 1; }

if [ -n "${CURSOR_AGENT:-}" ]; then
  if ! command -v "$CURSOR_AGENT" >/dev/null 2>&1; then
    echo "CURSOR_AGENT is not executable: $CURSOR_AGENT" >&2
    exit 127
  fi
  agent_command=("$CURSOR_AGENT")
elif command -v cursor-agent >/dev/null 2>&1; then
  agent_command=(cursor-agent)
elif command -v cursor >/dev/null 2>&1; then
  # `cursor agent` is Cursor's current primary entrypoint; cursor-agent
  # remains its backwards-compatible alias.
  agent_command=(cursor agent)
else
  echo "Cursor Agent not found (install cursor-agent, or set CURSOR_AGENT)." >&2
  exit 127
fi

STATE_FILE=$(mktemp "${TMPDIR:-/tmp}/focalpoint-cursor-cli.XXXXXX") || STATE_FILE=""

# Store simple newline-delimited fields for the parent shell. Cursor documents
# session_id/cwd/model on the initial system/init event; those values are not
# derived from the workspace or PID, so each headless chat claims its true
# numbered-key session.
save_session() {
  [ -n "$STATE_FILE" ] || return 0
  printf '%s\n%s\n%s\n%s\n' "$1" "$2" "$3" "$4" > "$STATE_FILE" 2>/dev/null || true
}

load_field() {
  local line="$1"
  [ -n "$STATE_FILE" ] && [ -s "$STATE_FILE" ] || return 0
  sed -n "${line}p" "$STATE_FILE" 2>/dev/null
}

emit_state() {
  local state="$1" session cwd model label mux_pane mux_session
  # A Cursor headless stream is the first point at which Cursor gives us its
  # real chat id. Carry the managed-launch identity through that registration
  # so `fpctl-agent` channel and ownership operations work exactly like the
  # Claude/Codex managed adapters.
  local -a meta_args
  meta_args=()
  [ -n "${FOCALPOINT_MANAGED:-}" ] && meta_args+=(--meta "managed=${FOCALPOINT_MANAGED}")
  [ -n "${FOCALPOINT_ORCHESTRATOR_TASK_ID:-}" ] && meta_args+=(--meta "orchestrator_task_id=${FOCALPOINT_ORCHESTRATOR_TASK_ID}")
  [ -n "${FOCALPOINT_ORCHESTRATION_ROLE:-}" ] && meta_args+=(--meta "orchestration_role=${FOCALPOINT_ORCHESTRATION_ROLE}")
  [ -n "${FOCALPOINT_MANAGER_TASK_ID:-}" ] && meta_args+=(--meta "manager_task_id=${FOCALPOINT_MANAGER_TASK_ID}")
  [ -n "${FOCALPOINT_CHANNEL_ID:-}" ] && meta_args+=(--meta "channel_id=${FOCALPOINT_CHANNEL_ID}")
  [ -n "${FOCALPOINT_SESSION_TITLE:-}" ] && meta_args+=(--meta "session_title=${FOCALPOINT_SESSION_TITLE}")
  [ -n "${FOCALPOINT_SESSION_SLOT:-}" ] && meta_args+=(--meta "requested_slot=${FOCALPOINT_SESSION_SLOT}")
  if [ -n "${TMUX:-}" ] && [ -n "${FOCALPOINT_TMUX_SERVER:-}" ] && command -v tmux >/dev/null 2>&1; then
    mux_pane=$(tmux -L "$FOCALPOINT_TMUX_SERVER" display-message -p '#{pane_id}' 2>/dev/null) || mux_pane=""
    mux_session=$(tmux -L "$FOCALPOINT_TMUX_SERVER" display-message -p '#{session_name}' 2>/dev/null) || mux_session=""
    if [ -n "$mux_pane" ] && [ -n "$mux_session" ]; then
      meta_args+=(--meta "mux_server=${FOCALPOINT_TMUX_SERVER}" --meta "mux_session=$mux_session" --meta "mux_pane=$mux_pane")
    fi
  fi
  session=$(load_field 1)
  cwd=$(load_field 2)
  model=$(load_field 3)
  [ -n "$session" ] || return 0
  label="${FOCALPOINT_SESSION_TITLE:-}"
  [ -n "$label" ] || label="Cursor CLI · $(basename "${cwd:-.}")"
  if [ -n "$model" ]; then
    "$FOCALPOINT" set-state "$state" --session "$session" --kind cursor-cli \
      --cwd "$cwd" --label "$label" --meta "model=$model" "${meta_args[@]}" >/dev/null 2>&1 || true
  else
    "$FOCALPOINT" set-state "$state" --session "$session" --kind cursor-cli \
      --cwd "$cwd" --label "$label" "${meta_args[@]}" >/dev/null 2>&1 || true
  fi
}

end_session() {
  local session
  session=$(load_field 1)
  [ -n "$session" ] || return 0
  "$FOCALPOINT" end-session "$session" >/dev/null 2>&1 || true
  save_session "$(load_field 1)" "$(load_field 2)" "$(load_field 3)" ended
}

handle_event() {
  local event="$1" type subtype session cwd model
  command -v jq >/dev/null 2>&1 || return 0

  type=$(printf '%s' "$event" | jq -r '.type // empty' 2>/dev/null) || return 0
  subtype=$(printf '%s' "$event" | jq -r '.subtype // empty' 2>/dev/null) || return 0

  # Every documented stream event carries session_id, but only the init event
  # supplies cwd/model. Preserve those fields as later events arrive.
  session=$(printf '%s' "$event" | jq -r '.session_id // empty' 2>/dev/null)
  if [ -n "$session" ] && [ -z "$(load_field 1)" ]; then
    cwd=$(printf '%s' "$event" | jq -r '.cwd // empty' 2>/dev/null)
    model=$(printf '%s' "$event" | jq -r '.model // empty' 2>/dev/null)
    save_session "$session" "$cwd" "$model" active
  fi

  case "$type/$subtype" in
    system/init) emit_state thinking ;;
    tool_call/started) emit_state running ;;
    tool_call/completed|assistant/*) emit_state thinking ;;
    result/success) emit_state done; end_session ;;
    result/*) emit_state error; end_session ;;
  esac
}

# Keep Cursor's structured stream byte-for-line available to callers. The
# parser intentionally has no stdout of its own. pipefail retains Cursor's
# exit status when its stderr reports an error before a terminal result event.
set +e
set -o pipefail
"${agent_command[@]}" --print --output-format stream-json "$@" | while IFS= read -r line; do
  printf '%s\n' "$line"
  handle_event "$line"
done
agent_status=${PIPESTATUS[0]}
set +o pipefail

ended=$(load_field 4)
if [ "$ended" != "ended" ] && [ -n "$(load_field 1)" ]; then
  if [ "$agent_status" -eq 0 ]; then emit_state done; else emit_state error; fi
  end_session
fi

exit "$agent_status"
