#!/bin/bash
# Render an idempotent Cursor hooks.json upgrade while preserving non-FocalPoint hooks.
set -eu

[ "$#" -eq 4 ] || {
  echo "usage: merge-hooks.sh EXISTING_JSON FRAGMENT_JSON COMMAND MARKER" >&2
  exit 2
}

existing="$1"
fragment="$2"
command_path="$3"
marker="$4"

jq -s --arg cmd "$command_path" --arg marker "$marker" '
  .[0] as $orig | .[1] as $frag
  | ($orig.hooks // {} | with_entries(
      .value |= [ .[] | select(((.command // "") | contains($marker)) | not) ]
    )) as $clean
  | ($frag.hooks // {} | with_entries(
      .value |= [ .[] | .command = $cmd ]
    )) as $current
  | $orig
  | .version = ($orig.version // $frag.version // 1)
  | .hooks = ($current | to_entries | reduce .[] as $entry ($clean;
      .[$entry.key] = ((.[$entry.key] // []) + $entry.value)))
' "$existing" "$fragment"
