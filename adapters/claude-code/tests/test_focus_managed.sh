#!/bin/bash
set -euo pipefail

ROOT=$(cd "$(dirname "$0")/../../.." && pwd)
TMP=$(mktemp -d "${TMPDIR:-/tmp}/focalpoint-focus-test.XXXXXX")
trap 'rm -rf "$TMP"' EXIT

cat >"$TMP/tmux" <<'SCRIPT'
#!/bin/bash
printf '%s\n' "$*" >>"$FOCUS_TEST_CALLS"
if [ "$1" != "-L" ] || [ "$2" != "fp-worker-42" ]; then
  exit 91
fi
shift 2
case "$1" in
  display-message)
    printf 'worker-42|%%7|/dev/ttys099|@3\n'
    ;;
  select-window)
    ;;
  list-clients)
    # Detached is still a successful exact focus: select-window determines
    # what the next client attach sees.
    ;;
  *)
    exit 92
    ;;
esac
SCRIPT
chmod +x "$TMP/tmux"

export FOCUS_TEST_CALLS="$TMP/calls"
FOCALPOINT_TMUX_BIN="$TMP/tmux" \
FOCALPOINT_SESSION_ID="claude-session" \
FOCALPOINT_SESSION_TTY="/dev/ttys-stale" \
FOCALPOINT_SESSION_MUX_SERVER="fp-worker-42" \
FOCALPOINT_SESSION_MUX_SESSION="worker-42" \
FOCALPOINT_SESSION_MUX_PANE="%7" \
FOCALPOINT_SLOT="4" \
  "$ROOT/adapters/claude-code/focus-session.sh" 2>"$TMP/log"

grep -F -- '-L fp-worker-42 display-message -p -t %7' "$FOCUS_TEST_CALLS" >/dev/null
grep -F -- '-L fp-worker-42 select-window -t @3' "$FOCUS_TEST_CALLS" >/dev/null
grep -F -- '-L fp-worker-42 list-clients -t worker-42' "$FOCUS_TEST_CALLS" >/dev/null
grep -F -- 'result=focused strategy=managed live_pane_tty=/dev/ttys099' "$TMP/log" >/dev/null

printf 'managed focus test passed\n'
