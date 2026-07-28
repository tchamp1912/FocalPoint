#!/usr/bin/env bash
# FocalPoint Claude Code status-line usage reporter.
#
# Claude Code invokes a configured status-line command with a JSON object on
# stdin. This script forwards only documented subscription rate-limit numbers
# to the FocalPoint daemon. It deliberately emits no visible status-line text, so
# it is suitable as a reporting-only status line. See adapters/claude-code/README.md
# for a wrapper approach when the user already has a status-line command.

set -u

FOCALPOINT="${FOCALPOINT_PATH:-focalpoint}"
input=$(cat 2>/dev/null) || exit 0
command -v jq >/dev/null 2>&1 || exit 0

# `// empty` makes this safe for API-key users and before Claude's first
# response, when rate_limits is not present.
five_used=$(printf '%s' "$input" | jq -r '.rate_limits.five_hour.used_percentage // empty' 2>/dev/null)
five_reset=$(printf '%s' "$input" | jq -r '.rate_limits.five_hour.resets_at // empty' 2>/dev/null)
week_used=$(printf '%s' "$input" | jq -r '.rate_limits.seven_day.used_percentage // empty' 2>/dev/null)
week_reset=$(printf '%s' "$input" | jq -r '.rate_limits.seven_day.resets_at // empty' 2>/dev/null)

args=()
[ -n "$five_used" ] && args+=(--meta "five_hour_used=$five_used")
[ -n "$five_reset" ] && args+=(--meta "five_hour_resets_at=$five_reset")
[ -n "$week_used" ] && args+=(--meta "seven_day_used=$week_used")
[ -n "$week_reset" ] && args+=(--meta "seven_day_resets_at=$week_reset")
if [ "${#args[@]}" -gt 0 ]; then
    "$FOCALPOINT" set-usage claude "${args[@]}" >/dev/null 2>&1 || true
fi

# Running cost is real (Claude Code reports it, not an estimate) but rides
# the per-session record, not the account-wide usage snapshot above — so it
# needs its own `set-meta` call keyed on session_id. `// empty` covers older
# Claude Code builds / early turns where `cost` isn't populated yet.
cost=$(printf '%s' "$input" | jq -r '.cost.total_cost_usd // empty' 2>/dev/null)
session_id=$(printf '%s' "$input" | jq -r '.session_id // empty' 2>/dev/null)
if [ -n "$cost" ] && [ -n "$session_id" ]; then
    "$FOCALPOINT" set-meta --session "$session_id" --kind claude --meta "cost_usd=$cost" >/dev/null 2>&1 || true
fi

exit 0
