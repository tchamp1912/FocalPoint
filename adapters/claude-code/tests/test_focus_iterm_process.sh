#!/bin/bash
set -euo pipefail

ROOT=$(cd "$(dirname "$0")/../../.." && pwd)
TMP=$(mktemp -d "${TMPDIR:-/tmp}/focalpoint-iterm-focus-test.XXXXXX")
trap 'rm -rf "$TMP"' EXIT

cat >"$TMP/focalpoint-iterm-focus" <<'SCRIPT'
#!/bin/bash
printf '%s\n' "$*" >>"$FOCUS_TEST_CALLS"
if [ "$*" = "--focus --session-id exact-session-id --application-pid 26748" ]; then
  exit 2
fi
exit 0
SCRIPT
chmod +x "$TMP/focalpoint-iterm-focus"

export FOCUS_TEST_CALLS="$TMP/calls"
FOCALPOINT_ITERM_FOCUS_HELPER="$TMP/focalpoint-iterm-focus" \
FOCALPOINT_SESSION_ID="codex-session" \
FOCALPOINT_SESSION_TTY="/dev/ttys002" \
FOCALPOINT_TERMINAL_SESSION_ID="exact-session-id" \
FOCALPOINT_TERMINAL_APPLICATION_PID="26748" \
FOCALPOINT_SLOT="8" \
  "$ROOT/adapters/claude-code/focus-session.sh" 2>"$TMP/log"

grep -Fx -- '--focus --session-id exact-session-id --application-pid 26748' "$FOCUS_TEST_CALLS" >/dev/null
grep -Fx -- '--focus --session-id exact-session-id' "$FOCUS_TEST_CALLS" >/dev/null
grep -F -- 'result=focused strategy=iterm-process-endpoint' "$TMP/log" >/dev/null

printf 'multi-process iTerm focus test passed\n'
