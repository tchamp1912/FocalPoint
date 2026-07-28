#!/bin/sh
set -eu

repo_root=$(CDPATH= cd -- "$(dirname -- "$0")/../.." && pwd)
generated="$repo_root/hardware/ergogen/output/pcbs/focalpoint_matrix.kicad_pcb"
working="$repo_root/hardware/kicad/focalpoint_matrix.kicad_pcb"

if [ ! -f "$generated" ]; then
  echo "Missing generated board. Run Ergogen first." >&2
  exit 1
fi

if [ -f "$working" ] && ! grep -q '(generator "ergogen")' "$working"; then
  echo "Refusing to replace a KiCad-owned board; merge geometry manually." >&2
  exit 1
fi

cp "$generated" "$working"
# Ergogen's footprint templates contain whitespace-only padding. Normalize the
# tracked snapshot so refreshes remain reviewable and pass git diff --check.
perl -pi -e 's/[ \t]+$//' "$working"
perl -0777 -pi -e 's/\s+\z/\n/' "$working"
echo "Refreshed hardware/kicad/focalpoint_matrix.kicad_pcb"
