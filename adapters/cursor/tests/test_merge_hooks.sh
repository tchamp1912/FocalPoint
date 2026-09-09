#!/bin/bash
set -eu

ROOT=$(cd "$(dirname "$0")/../../.." && pwd)
TMP_ROOT=$(mktemp -d "${TMPDIR:-/tmp}/focalpoint-cursor-merge-test.XXXXXX")
trap 'rm -rf "$TMP_ROOT"' EXIT
EXISTING="$TMP_ROOT/hooks.json"
MERGED="$TMP_ROOT/merged.json"
SECOND="$TMP_ROOT/second.json"
MARKER='.config/focalpoint/adapters/cursor-hooks.sh'
COMMAND='/Users/test/.config/focalpoint/adapters/cursor-hooks.sh'

printf '%s\n' '{"version":1,"hooks":{"preToolUse":[' \
  '{"command":"/Users/test/.config/focalpoint/adapters/cursor-hooks.sh","timeout":5},' \
  '{"command":"./my-own-hook.sh"}],"stop":[' \
  '{"command":"/Users/test/.config/focalpoint/adapters/cursor-hooks.sh","timeout":2}]}}' \
  | tr -d '\n' > "$EXISTING"

bash "$ROOT/adapters/cursor/merge-hooks.sh" "$EXISTING" \
  "$ROOT/adapters/cursor/hooks-fragment.json" "$COMMAND" "$MARKER" > "$MERGED"

jq -e --arg cmd "$COMMAND" '.hooks.sessionStart | map(select(.command == $cmd)) | length == 1' "$MERGED" >/dev/null
jq -e '.hooks.preToolUse | map(select(.command == "./my-own-hook.sh")) | length == 1' "$MERGED" >/dev/null
jq -e --arg cmd "$COMMAND" '[.hooks[] | .[] | select(.command == $cmd)] | length == 8' "$MERGED" >/dev/null

bash "$ROOT/adapters/cursor/merge-hooks.sh" "$MERGED" \
  "$ROOT/adapters/cursor/hooks-fragment.json" "$COMMAND" "$MARKER" > "$SECOND"
diff -u <(jq -S . "$MERGED") <(jq -S . "$SECOND") >/dev/null

printf '%s\n' 'Cursor hook merge test passed'
