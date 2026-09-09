#!/bin/bash
# Gemini CLI observability hooks. Never changes prompts or grants permissions.
# Schema: https://geminicli.com/docs/hooks/reference/
set -u
trap 'printf "{}\n"' EXIT
export PATH="$PATH:$HOME/.local/bin:/opt/homebrew/bin:/usr/local/bin"
FOCALPOINT="${FOCALPOINT_PATH:-focalpoint}"
command -v jq >/dev/null 2>&1 || exit 0
payload=$(cat)
printf '%s' "$payload" | jq -e 'type == "object"' >/dev/null 2>&1 || exit 0
field() { printf '%s' "$payload" | jq -r "$1 | if type == \"string\" then . else \"\" end" 2>/dev/null; }
event=$(field '.hook_event_name')
session_id=$(field '.session_id')
cwd=$(field '.cwd')
# Never let malformed payloads affect an aggregate or unrelated session.
[[ "$session_id" =~ ^[A-Za-z0-9][A-Za-z0-9._:-]{0,255}$ ]] || exit 0
case "$event" in
  SessionEnd) "$FOCALPOINT" end-session "$session_id" >/dev/null 2>&1 || true; exit 0 ;;
  SessionStart) state=idle ;;
  BeforeAgent|AfterTool) state=thinking ;;
  AfterAgent) state=done ;;
  BeforeTool) state=running ;;
  Notification)
    [ "$(field '.notification_type')" = ToolPermission ] || exit 0
    state=approval ;;
  *) exit 0 ;;
esac
if [ "$event" = AfterTool ] && printf '%s' "$payload" | jq -e '.tool_response.error != null and .tool_response.error != false and .tool_response.error != ""' >/dev/null 2>&1; then
  state=error
fi
label="${FOCALPOINT_SESSION_TITLE:-}"
[ -n "$label" ] || label=$(basename "${cwd:-Gemini}")
args=("$state" --session "$session_id" --kind gemini --cwd "$cwd" --label "$label")
[ "$event" != SessionStart ] || args+=(--refresh-identity)
managed=false
mux_pane=""; mux_session=""; mux_server=""; mux_socket=""
if [ -n "${TMUX:-}" ] && [ -n "${FOCALPOINT_TMUX_SERVER:-}" ] && [ -n "${TMUX_PANE:-}" ] && command -v tmux >/dev/null 2>&1; then
  mux_pane=$(tmux -L "$FOCALPOINT_TMUX_SERVER" display-message -p -t "$TMUX_PANE" '#{pane_id}' 2>/dev/null) || mux_pane=""
  mux_session=$(tmux -L "$FOCALPOINT_TMUX_SERVER" display-message -p -t "$TMUX_PANE" '#{session_name}' 2>/dev/null) || mux_session=""
  if [ -n "$mux_pane" ] && [ -n "$mux_session" ]; then
    managed=true; mux_server="$FOCALPOINT_TMUX_SERVER"; mux_socket="${TMUX%%,*}"
  fi
fi
args+=(--meta "managed=$managed" --meta "mux_pane=$mux_pane" --meta "mux_session=$mux_session" --meta "mux_server=$mux_server" --meta "mux_socket=$mux_socket")
for mapping in \
  FOCALPOINT_LAUNCH_ID:launch_id FOCALPOINT_RELAUNCH_ID:relaunch_id \
  FOCALPOINT_RESUME_SESSION_ID:resume_session_id FOCALPOINT_ORCHESTRATOR_TASK_ID:orchestrator_task_id \
  FOCALPOINT_SESSION_TITLE:session_title FOCALPOINT_SESSION_SLOT:requested_slot \
  FOCALPOINT_ORCHESTRATION_ROLE:orchestration_role FOCALPOINT_MANAGER_TASK_ID:manager_task_id \
  FOCALPOINT_CHANNEL_ID:channel_id FOCALPOINT_AGENT_TYPE:agent_type; do
  variable=${mapping%%:*}; key=${mapping#*:}
  value=${!variable:-}
  [ -z "$value" ] || args+=(--meta "$key=$value")
done
"$FOCALPOINT" set-state "${args[@]}" >/dev/null 2>&1 || true
