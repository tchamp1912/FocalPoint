# KiCad CLI automation

## Discover tools

Prefer `kicad-cli` on `PATH`. On macOS, also check:

```sh
/Applications/KiCad/KiCad.app/Contents/MacOS/kicad-cli
/Applications/KiCad/KiCad.app/Contents/Frameworks/Python.framework/Versions/Current/bin/python3
```

Use the Python bundled with the same KiCad installation for `pcbnew`. A system
Python commonly lacks the module or loads an incompatible ABI.

## Core checks

```sh
kicad-cli sch erc --exit-code-violations \
  --output final_ERC.rpt design.kicad_sch

kicad-cli sch export netlist --format kicadxml \
  --output schematic.xml design.kicad_sch

kicad-cli pcb drc --exit-code-violations --all-track-errors \
  --output final_DRC.rpt design.kicad_pcb
```

The net-parity helper expects `kicadxml`, not the default KiCad s-expression
netlist.

## Manufacturing exports

```sh
kicad-cli pcb export gerbers \
  --layers F.Cu,In1.Cu,In2.Cu,B.Cu,F.Paste,B.Paste,F.Silkscreen,B.Silkscreen,F.Mask,B.Mask,Edge.Cuts \
  --subtract-soldermask --output gerbers design.kicad_pcb

kicad-cli pcb export drill --format excellon --excellon-units mm \
  --excellon-separate-th --generate-map --map-format pdf \
  --generate-report --report-path gerbers/drill_report.rpt \
  --output gerbers design.kicad_pcb

kicad-cli pcb export pos --format csv --units mm --side both --exclude-dnp \
  --output positions.csv design.kicad_pcb
```

Adapt the Gerber layer list to the actual stack. Never export nonexistent inner
layers or omit an existing copper layer.

## Zone refill

Native DRC does not reliably make stale saved fills authoritative after text or
script edits. Refill and save in PCB Editor, or use matching KiCad Python:

```python
import pcbnew

path = "design.kicad_pcb"
board = pcbnew.LoadBoard(path)
pcbnew.ZONE_FILLER(board).Fill(board.Zones())
pcbnew.SaveBoard(path, board)
```

Expect KiCad serialization to reorder some generated data and refill polygons.
Review the semantic copper change separately from the large filled-zone diff.

## GUI reliability

Open the specific `.kicad_pcb` in `pcbnew`, not only the project manager. If an
already-open window caches the prior file, open a fresh editor instance or use
File > Revert only after confirming there are no unsaved user edits. Do not use
GUI automation that can dismiss warnings or overwrite unsaved work blindly.
