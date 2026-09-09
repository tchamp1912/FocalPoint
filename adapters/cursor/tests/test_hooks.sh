#!/bin/bash
set -eu

ROOT=$(cd "$(dirname "$0")/../../.." && pwd)
TMP_ROOT=$(mktemp -d "${TMPDIR:-/tmp}/focalpoint-cursor-hooks-test.XXXXXX")
trap 'rm -rf "$TMP_ROOT"' EXIT
mkdir -p "$TMP_ROOT/bin" "$TMP_ROOT/home" "$TMP_ROOT/state"
CAPTURE="$TMP_ROOT/focalpoint-args.log"

printf '%s\n' \
  '#!/bin/bash' \
  'printf "%s\n" "$*" >> "$FOCALPOINT_TEST_CAPTURE"' \
  'exit 0' > "$TMP_ROOT/bin/focalpoint"
chmod 700 "$TMP_ROOT/bin/focalpoint"

run_hook() {
  local payload="$1"
  printf '%s' "$payload" | \
    HOME="$TMP_ROOT/home" \
    XDG_STATE_HOME="$TMP_ROOT/state" \
    CURSOR_PROJECT_DIR="$TMP_ROOT/workspace" \
    CURSOR_VERSION="3.13.25" \
    FOCALPOINT_PATH="$TMP_ROOT/bin/focalpoint" \
    FOCALPOINT_TEST_CAPTURE="$CAPTURE" \
    bash "$ROOT/adapters/cursor/hooks.sh"
}

mkdir -p "$TMP_ROOT/workspace"
output=$(run_hook '{"hook_event_name":"sessionStart","session_id":"cursor-session-a","composer_mode":"agent"}')
[ -z "$output" ]
grep -F -- 'set-state thinking --session cursor-session-a --kind cursor' "$CAPTURE" >/dev/null
grep -F -- '--meta adapter_event=sessionStart' "$CAPTURE" >/dev/null
grep -F -- '--meta adapter_version=3.13.25' "$CAPTURE" >/dev/null
grep -F -- '--refresh-identity' "$CAPTURE" >/dev/null

run_hook '{"hook_event_name":"preToolUse","conversation_id":"cursor-session-a","cwd":"/tmp/work"}' >/dev/null
grep -F -- 'set-state running --session cursor-session-a --kind cursor' "$CAPTURE" >/dev/null
grep -F -- '--meta adapter_event=preToolUse' "$CAPTURE" >/dev/null

run_hook '{"hook_event_name":"sessionEnd","session_id":"cursor-session-a","reason":"completed"}' >/dev/null
grep -F -- 'end-session cursor-session-a' "$CAPTURE" >/dev/null

LOG_FILE="$TMP_ROOT/state/focalpoint/logs/cursor-hooks.log"
grep -F -- 'event=sessionStart session=cursor-session-a command=set-state result=ok cursor_version=3.13.25' "$LOG_FILE" >/dev/null
grep -F -- 'event=sessionEnd session=cursor-session-a command=end-session result=ok cursor_version=3.13.25' "$LOG_FILE" >/dev/null

printf '%s\n' 'Cursor GUI hook lifecycle test passed'

# Child activity must not allocate a session or terminate the parent.
before=$(wc -l < "$CAPTURE")
run_hook '{"hook_event_name":"sessionStart","session_id":"task-child-a"}'
run_hook '{"hook_event_name":"preToolUse","conversation_id":"child-b","parent_conversation_id":"parent-a"}'
run_hook '{"hook_event_name":"sessionEnd","session_id":"task-child-a"}'
run_hook '{"hook_event_name":"stop","conversation_id":"child-c","transcript_path":"/tmp/parent/subagents/child.jsonl","status":"completed"}'
[ "$(wc -l < "$CAPTURE")" -eq "$before" ]
run_hook '{"hook_event_name":"preToolUse","conversation_id":"separate-chat"}'
grep -F -- 'set-state running --session separate-chat --kind cursor' "$CAPTURE" >/dev/null
printf '%s\n' 'Cursor child isolation test passed'
