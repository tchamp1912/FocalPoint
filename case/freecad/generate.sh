#!/bin/sh
set -eu

repo_root=$(CDPATH= cd -- "$(dirname -- "$0")/../.." && pwd)
freecadcmd=/Applications/FreeCAD.app/Contents/Resources/bin/freecadcmd

if [ ! -x "$freecadcmd" ]; then
  echo "FreeCAD CLI not found at $freecadcmd" >&2
  exit 1
fi

cd "$repo_root"
exec "$freecadcmd" case/freecad/enclosure.py
