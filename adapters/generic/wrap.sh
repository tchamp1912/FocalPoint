#!/bin/bash
# FocalPoint Generic Wrapper
#
# Runs a command with FocalPoint state tracking:
# - Sets state to 'running' before executing
# - Sets state to 'done' on success (exit 0)
# - Sets state to 'error' on failure (exit != 0)
#
# Usage:
#   wrap.sh [--session ID] [--kind KIND] [--label LABEL] <command> [args...]
#   wrap.sh npm test
#   wrap.sh ./build.sh --verbose
#   wrap.sh --session build-123 --kind ci --label "release build" ./build.sh
#
# --session/--kind/--label register this run as its own numbered-key session
# (PROTOCOL.md §3) instead of the sessionless aggregate-only default:
#   --session ID     unique id for this run (required to get a slot at all)
#   --kind KIND       free-form tool identifier (default: "generic")
#   --label LABEL     human-readable label (default: none)
# When --session is omitted, behavior is unchanged from before this feature
# existed: plain sessionless `focalpoint set-state <state>` calls.
#
# MIT License - see adapters/README.md

set -u

FOCALPOINT="${FOCALPOINT_PATH:-focalpoint}"

session=""
kind="generic"
label=""

# Parse leading --session/--kind/--label flags, then stop at the first
# argument that isn't one of them — that's the start of the wrapped command.
while [[ $# -gt 0 ]]; do
  case "$1" in
    --session)
      session="${2:-}"
      shift 2
      ;;
    --kind)
      kind="${2:-generic}"
      shift 2
      ;;
    --label)
      label="${2:-}"
      shift 2
      ;;
    --)
      shift
      break
      ;;
    *)
      break
      ;;
  esac
done

# Check that a command was provided
if [[ $# -lt 1 ]]; then
  echo "Usage: wrap.sh [--session ID] [--kind KIND] [--label LABEL] <command> [args...]" >&2
  exit 1
fi

# Build the extra session flags. Only attach them when --session was given;
# otherwise keep the original sessionless behavior (--kind/--label are
# session attributes and are meaningless without a session id).
extra_args=()
if [[ -n "$session" ]]; then
  extra_args+=(--session "$session" --kind "$kind")
  [[ -n "$label" ]] && extra_args+=(--label "$label")
fi

# Call focalpoint set-state with the extra session flags appended, if any.
# NOTE: "${extra_args[@]}" on a zero-element array trips "unbound variable"
# under `set -u` on bash 3.2 (macOS's system /bin/bash) even though the
# array itself is declared — a known old-bash quirk fixed in later
# versions. Guard the expansion with a length check instead of relying on
# it being safe.
vk_set_state() {
  if [[ ${#extra_args[@]} -gt 0 ]]; then
    "$FOCALPOINT" set-state "$1" "${extra_args[@]}" 2>/dev/null || true
  else
    "$FOCALPOINT" set-state "$1" 2>/dev/null || true
  fi
}

# Set state to running before executing command
vk_set_state running

# Execute the command
"$@"
exit_code=$?

# Map exit code to state
if [[ $exit_code -eq 0 ]]; then
  state="done"
else
  state="error"
fi

# Set final state, silently fail if daemon is not running
vk_set_state "$state"

exit $exit_code
