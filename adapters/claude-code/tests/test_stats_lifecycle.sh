#!/bin/bash
# Verifies that an asynchronous PostToolUse hook publishes transcript stats
# before the turn reaches Stop. Run from any directory:
#   bash adapters/claude-code/tests/test_stats_lifecycle.sh
set -euo pipefail

repo_root=$(cd "$(dirname "$0")/../../.." && pwd)
hook="$repo_root/adapters/claude-code/hooks.sh"
tmp=$(mktemp -d "${TMPDIR:-/tmp}/focalpoint-claude-stats.XXXXXX")
trap 'rm -rf "$tmp"' EXIT

command -v jq >/dev/null || { echo "SKIP: jq is required"; exit 0; }

transcript="$tmp/transcript.jsonl"
capture="$tmp/capture"
fake_focalpoint="$tmp/focalpoint"
cat > "$transcript" <<'JSON'
{"type":"user","timestamp":"2026-01-01T00:00:00Z","message":{"content":"Run a command"}}
{"type":"assistant","timestamp":"2026-01-01T00:00:01Z","message":{"id":"message-1","model":"claude-sonnet-4","usage":{"input_tokens":100,"output_tokens":20},"content":[{"type":"tool_use","name":"Bash"}]}}
JSON
cat > "$fake_focalpoint" <<'SH'
#!/bin/bash
printf '%s\n' "$*" >> "$FOCALPOINT_CAPTURE"
SH
chmod +x "$fake_focalpoint"

FOCALPOINT_PATH="$fake_focalpoint" FOCALPOINT_CAPTURE="$capture" \
  printf '{"hook_event_name":"PostToolUse","session_id":"session-1","cwd":"/tmp/project","transcript_path":"%s"}' "$transcript" \
  | FOCALPOINT_PATH="$fake_focalpoint" FOCALPOINT_CAPTURE="$capture" "$hook"

line=$(cat "$capture")
for expected in 'set-state thinking' 'turns=1' 'tool_calls=1' 'tokens_in=100' 'tokens_out=20' 'model=claude-sonnet-4' 'context_tokens=100'; do
  [[ "$line" == *"$expected"* ]] || { echo "missing $expected in: $line" >&2; exit 1; }
done

echo "PASS: PostToolUse publishes transcript stats"
