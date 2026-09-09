#!/bin/bash
set -eu
ROOT=$(cd "$(dirname "$0")/../../.." && pwd)
TEST_DIR=$(mktemp -d "${TMPDIR:-/tmp}/focalpoint-codex-children.XXXXXX")
trap 'rm -rf "$TEST_DIR"' EXIT
mkdir -p "$TEST_DIR/bin"
cat > "$TEST_DIR/bin/focalpoint" <<'STUB'
#!/bin/bash
printf '%s\n' "$*" >> "$FOCALPOINT_TEST_CAPTURE"
STUB
chmod +x "$TEST_DIR/bin/focalpoint"
export FOCALPOINT_PATH="$TEST_DIR/bin/focalpoint"
export FOCALPOINT_TEST_CAPTURE="$TEST_DIR/calls"
export XDG_STATE_HOME="$TEST_DIR/state"
export FOCALPOINT_SESSION_TITLE="Parent title"
# Hooks may retain the PARENT session id while pointing at the child's
# transcript. Suppress the entire event before counters or identity mutate.
for source in '{"subagent":{"thread_spawn":{"parent_thread_id":"parent","depth":1}}}' '{"subagent":{"other":"guardian"}}'; do
  printf '{"type":"session_meta","payload":{"id":"child","source":%s}}\n' "$source" > "$TEST_DIR/child.jsonl"
  printf '%s\n' '{"type":"event_msg","payload":{"type":"token_count","info":{"last_token_usage":{"input_tokens":37000},"model_context_window":128000}}}' >> "$TEST_DIR/child.jsonl"
  for event in SessionStart PreToolUse PostToolUse PermissionRequest Stop SessionEnd; do
    printf '{"hook_event_name":"%s","session_id":"parent","transcript_path":"%s/child.jsonl"}' "$event" "$TEST_DIR" | bash "$ROOT/adapters/codex-cli/hooks.sh"
  done
done
[ ! -e "$FOCALPOINT_TEST_CAPTURE" ]
[ ! -e "$XDG_STATE_HOME/focalpoint/counters/parent.turns" ]
printf '%s\n' '{"type":"session_meta","payload":{"id":"parent","source":"cli"}}' > "$TEST_DIR/parent.jsonl"
printf '{"hook_event_name":"PreToolUse","session_id":"parent","transcript_path":"%s/parent.jsonl"}' "$TEST_DIR" | bash "$ROOT/adapters/codex-cli/hooks.sh"
grep -F -- 'set-state running --session parent --kind codex' "$FOCALPOINT_TEST_CAPTURE" >/dev/null
printf '%s\n' 'Codex child hook isolation passed'
