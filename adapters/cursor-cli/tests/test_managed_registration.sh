#!/bin/bash
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/../../.." && pwd)"
TMP_ROOT=$(mktemp -d "${TMPDIR:-/tmp}/focalpoint-cursor-wrapper-test.XXXXXX")
trap 'rm -rf "$TMP_ROOT"' EXIT
mkdir -p "$TMP_ROOT/bin"

CAPTURE="$TMP_ROOT/focalpoint.log"
export CAPTURE

printf '%s\n' '#!/bin/bash' 'printf "%s\\n" "$*" >> "$CAPTURE"' > "$TMP_ROOT/bin/focalpoint"
printf '%s\n' '#!/bin/bash' \
  'case "$*" in' \
  '  *"#{pane_id}"*) printf "%%7\\n" ;;' \
  '  *"#{session_name}"*) printf "fp-cursor-77\\n" ;;' \
  '  *"#{pane_pid}"*) printf "7777\\n" ;;' \
  'esac' > "$TMP_ROOT/bin/tmux"
printf '%s\n' '#!/bin/bash' \
  'printf "%s\\n" '\''{"type":"system","subtype":"init","cwd":"/tmp/work","session_id":"cursor-real-id","model":"composer"}'\''' \
  'printf "%s\\n" '\''{"type":"result","subtype":"success","session_id":"cursor-real-id","result":"done"}'\''' \
  > "$TMP_ROOT/bin/cursor-agent"
chmod 700 "$TMP_ROOT/bin/focalpoint" "$TMP_ROOT/bin/tmux" "$TMP_ROOT/bin/cursor-agent"

PATH="$TMP_ROOT/bin:$PATH" \
FOCALPOINT_PATH="$TMP_ROOT/bin/focalpoint" \
FOCALPOINT_MANAGED=1 \
FOCALPOINT_TMUX_SERVER=fp-cursor-self-42 \
FOCALPOINT_ORCHESTRATOR_TASK_ID=cursor-self \
FOCALPOINT_SESSION_TITLE='Managed Cursor' \
TMUX='/tmp/tmux-501/fp-cursor-self-42,123,0' \
  bash "$ROOT/adapters/cursor-cli/wrap.sh" 'Test task' >/dev/null

grep -F -- 'set-state thinking --session cursor-real-id --kind cursor-cli' "$CAPTURE" >/dev/null
grep -F -- '--meta pid=7777' "$CAPTURE" >/dev/null
grep -F -- '--meta mux_server=fp-cursor-self-42' "$CAPTURE" >/dev/null
grep -F -- '--meta orchestrator_task_id=cursor-self' "$CAPTURE" >/dev/null
grep -F -- 'end-session cursor-real-id' "$CAPTURE" >/dev/null

echo "Cursor managed registration test passed"
