#!/bin/bash
set -eu
ROOT=$(cd "$(dirname "$0")/../../.." && pwd)
TEST_DIR=$(mktemp -d "${TMPDIR:-/tmp}/focalpoint-cursor-focus.XXXXXX")
trap 'rm -rf "$TEST_DIR"' EXIT
mkdir -p "$TEST_DIR/bin" "$TEST_DIR/workspace with spaces"
export FOCALPOINT_TEST_CAPTURE="$TEST_DIR/calls"
export FOCALPOINT_SESSION_CWD="$(cd "$TEST_DIR/workspace with spaces" && pwd -P)"
export PATH="$TEST_DIR/bin:$PATH"
cat > "$TEST_DIR/bin/pgrep" <<'STUB'
#!/bin/bash
exit "${TEST_CURSOR_ABSENT:-0}"
STUB
cat > "$TEST_DIR/bin/cursor" <<'STUB'
#!/bin/bash
printf 'cursor:<%s>\n' "$@" >> "$FOCALPOINT_TEST_CAPTURE"
exit "${TEST_CURSOR_FAIL:-0}"
STUB
cat > "$TEST_DIR/bin/open" <<'STUB'
#!/bin/bash
printf 'open:<%s>\n' "$@" >> "$FOCALPOINT_TEST_CAPTURE"
exit "${TEST_OPEN_FAIL:-0}"
STUB
chmod +x "$TEST_DIR/bin/"*
bash "$ROOT/adapters/cursor/focus-cursor.sh"
grep -F -- "cursor:<$FOCALPOINT_SESSION_CWD>" "$FOCALPOINT_TEST_CAPTURE" >/dev/null
! grep -F -- '<-r>' "$FOCALPOINT_TEST_CAPTURE" >/dev/null
TEST_CURSOR_FAIL=1 bash "$ROOT/adapters/cursor/focus-cursor.sh"
grep -F -- "open:<$FOCALPOINT_SESSION_CWD>" "$FOCALPOINT_TEST_CAPTURE" >/dev/null
if TEST_CURSOR_FAIL=1 TEST_OPEN_FAIL=1 bash "$ROOT/adapters/cursor/focus-cursor.sh"; then
  echo 'missing focus endpoint was reported as successful' >&2
  exit 1
fi
before=$(wc -l < "$FOCALPOINT_TEST_CAPTURE")
if TEST_CURSOR_ABSENT=1 bash "$ROOT/adapters/cursor/focus-cursor.sh"; then
  echo 'absent Cursor was reported as focused' >&2
  exit 1
fi
[ "$(wc -l < "$FOCALPOINT_TEST_CAPTURE")" -eq "$before" ]
printf '%s\n' 'Cursor focus routing passed'
