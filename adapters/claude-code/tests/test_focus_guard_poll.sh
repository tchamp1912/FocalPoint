#!/bin/bash
set -euo pipefail

ROOT=$(cd "$(dirname "$0")/../../.." && pwd)
TMP=$(mktemp -d "${TMPDIR:-/tmp}/focalpoint-focus-guard-test.XXXXXX")
trap 'rm -rf "$TMP"' EXIT

cat >"$TMP/pgrep" <<'SCRIPT'
#!/bin/bash
case "${*: -1}" in
  iTerm2|Cursor) exit 0 ;;
  *) exit 1 ;;
esac
SCRIPT

cat >"$TMP/osascript" <<'SCRIPT'
#!/bin/bash
/bin/sleep 0.03
printf 'matched\n'
SCRIPT

cat >"$TMP/cursor" <<'SCRIPT'
#!/bin/bash
/bin/sleep 0.03
SCRIPT

cat >"$TMP/sleep" <<'SCRIPT'
#!/bin/bash
printf '%s\n' "$1" >>"$FOCUS_TEST_SLEEPS"
/bin/sleep "$1"
SCRIPT

chmod +x "$TMP/pgrep" "$TMP/osascript" "$TMP/cursor" "$TMP/sleep"
export PATH="$TMP:/usr/bin:/bin"
export FOCUS_TEST_SLEEPS="$TMP/sleeps"

FOCALPOINT_ITERM_FOCUS_HELPER="$TMP/missing-helper" \
FOCALPOINT_SESSION_ID="guard-test" \
FOCALPOINT_SESSION_TTY="/dev/ttys099" \
FOCALPOINT_SLOT="1" \
  "$ROOT/adapters/claude-code/focus-session.sh" 2>"$TMP/terminal-log"

FOCALPOINT_SESSION_CWD="$TMP" \
  "$ROOT/adapters/cursor/focus-cursor.sh"

# The fake calls live long enough to exercise the completion guard. A 100 ms
# polling regression would be recorded as 0.1; all current ticks must be 10 ms.
grep -Fx -- '0.01' "$FOCUS_TEST_SLEEPS" >/dev/null
if grep -Fx -- '0.1' "$FOCUS_TEST_SLEEPS" >/dev/null; then
  echo "focus guard regressed to 100 ms polling" >&2
  exit 1
fi
if grep -Fvx -- '0.01' "$FOCUS_TEST_SLEEPS" >/dev/null; then
  echo "focus guard used an unexpected polling interval" >&2
  exit 1
fi
grep -F -- 'result=focused strategy=iterm-tty' "$TMP/terminal-log" >/dev/null

printf 'focus guard polling test passed\n'
