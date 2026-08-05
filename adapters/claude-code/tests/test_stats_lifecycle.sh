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
  | XDG_STATE_HOME="$tmp/state" FOCALPOINT_PATH="$fake_focalpoint" FOCALPOINT_CAPTURE="$capture" "$hook"

lines=$(cat "$capture")
state_line=$(sed -n '1p' "$capture")
meta_line=$(sed -n '2p' "$capture")
[[ "$state_line" == *'set-state thinking'* ]] \
  || { echo "state was not published first: $lines" >&2; exit 1; }
[[ "$meta_line" == *'set-meta --session session-1'* ]] \
  || { echo "telemetry was not published separately: $lines" >&2; exit 1; }
for expected in 'turns=1' 'tool_calls=1' 'tokens_in=100' 'tokens_out=20' 'model=claude-sonnet-4' 'context_tokens=100'; do
  [[ "$meta_line" == *"$expected"* ]] || { echo "missing $expected in: $meta_line" >&2; exit 1; }
done

echo "PASS: PostToolUse publishes state before separate transcript stats"

: > "$capture"
printf '{"hook_event_name":"PostToolUse","session_id":"session-1","cwd":"/tmp/project","transcript_path":"%s"}' "$transcript" \
  | XDG_STATE_HOME="$tmp/state" FOCALPOINT_PATH="$fake_focalpoint" FOCALPOINT_CAPTURE="$capture" "$hook"
[[ "$(wc -l < "$capture" | tr -d ' ')" = "1" ]] \
  || { echo "throttled PostToolUse unexpectedly rescanned telemetry" >&2; exit 1; }
[[ "$(cat "$capture")" == *'set-state thinking'* ]] \
  || { echo "throttled PostToolUse failed to publish state" >&2; exit 1; }

echo "PASS: dense PostToolUse telemetry is throttled without delaying state"

# Claude Code supplies permission_mode on PreCompact. Ensure plan-mode
# compactions carry the lifecycle marker and mode into the daemon rather than
# relying on a later, possibly same-id SessionStart/rekey to infer it.
: > "$capture"
printf '%s' '{"hook_event_name":"PreCompact","session_id":"session-1","cwd":"/tmp/project","trigger":"auto","permission_mode":"plan"}' \
  | XDG_STATE_HOME="$tmp/state" FOCALPOINT_PATH="$fake_focalpoint" FOCALPOINT_CAPTURE="$capture" "$hook"

line=$(cat "$capture")
for expected in 'set-state compacting' 'compaction_event=precompact' 'compaction_trigger=auto' 'compaction_permission_mode=plan'; do
  [[ "$line" == *"$expected"* ]] || { echo "missing $expected in: $line" >&2; exit 1; }
done

echo "PASS: PreCompact carries plan-mode tracking metadata"

: > "$capture"
printf '%s' '{"hook_event_name":"PostCompact","session_id":"session-1","cwd":"/tmp/project"}' \
  | XDG_STATE_HOME="$tmp/state" FOCALPOINT_PATH="$fake_focalpoint" FOCALPOINT_CAPTURE="$capture" "$hook"
[[ "$(cat "$capture")" == *'set-state thinking'* ]] \
  || { echo "PostCompact did not clear compacting state" >&2; exit 1; }

echo "PASS: PostCompact restores active state"
