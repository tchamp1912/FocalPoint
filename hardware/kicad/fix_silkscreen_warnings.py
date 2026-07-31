#!/Applications/KiCad/KiCad.app/Contents/Frameworks/Python.framework/Versions/3.9/bin/python3.9
"""Resolve native-DRC silkscreen warnings without changing copper geometry.

Reference fields explicitly named by DRC are hidden.  For footprints whose
graphical outlines are named by DRC, only their silkscreen graphical items are
moved to the corresponding fabrication layer.  Pads, copper, mask, paste,
placement, and unflagged footprint markings are untouched.
"""

from __future__ import annotations

import argparse
import re
import shutil
from pathlib import Path

import pcbnew


def warning_blocks(text: str, category: str) -> list[str]:
    return [
        block
        for block in re.split(r"(?=^\[)", text, flags=re.MULTILINE)[1:]
        if block.startswith(f"[{category}]")
    ]


def affected_references(report: Path) -> tuple[set[str], set[str]]:
    hidden_refs: set[str] = set()
    graphic_refs: set[str] = set()
    for category in ("silk_over_copper", "silk_overlap"):
        for block in warning_blocks(report.read_text(), category):
            for match in re.finditer(
                r": (Reference field|Segment|Polygon) of ([A-Z]+[0-9]+)",
                block,
            ):
                kind, reference = match.groups()
                if kind == "Reference field":
                    hidden_refs.add(reference)
                else:
                    graphic_refs.add(reference)
    return hidden_refs, graphic_refs


def main() -> None:
    parser = argparse.ArgumentParser()
    parser.add_argument("source", type=Path)
    parser.add_argument("report", type=Path)
    parser.add_argument("output", type=Path)
    args = parser.parse_args()
    source = args.source.resolve()
    output = args.output.resolve()
    if source == output:
        parser.error("output must differ from source")

    hidden_refs, graphic_refs = affected_references(args.report.resolve())
    board = pcbnew.LoadBoard(str(source))
    found: set[str] = set()
    hidden = 0
    moved = 0
    layer_map = {
        pcbnew.F_SilkS: pcbnew.F_Fab,
        pcbnew.B_SilkS: pcbnew.B_Fab,
    }
    for footprint in board.GetFootprints():
        reference = footprint.GetReference()
        if reference in hidden_refs:
            found.add(reference)
            if footprint.Reference().IsVisible():
                footprint.Reference().SetVisible(False)
                hidden += 1
        if reference in graphic_refs:
            found.add(reference)
            for item in footprint.GraphicalItems():
                destination = layer_map.get(item.GetLayer())
                if destination is not None:
                    item.SetLayer(destination)
                    moved += 1

    missing = sorted((hidden_refs | graphic_refs) - found)
    if missing:
        raise RuntimeError(f"DRC references absent from board: {missing}")
    if not pcbnew.SaveBoard(str(output), board):
        raise RuntimeError(f"could not save {output}")
    for suffix in (".kicad_pro", ".rules"):
        companion = source.with_suffix(suffix)
        if companion.exists():
            shutil.copy2(companion, output.with_suffix(suffix))
    print(f"hidden_reference_fields={hidden}")
    print(f"footprints_with_silkscreen_moved={len(graphic_refs)}")
    print(f"silkscreen_graphics_moved_to_fab={moved}")
    print(f"output={output}")


if __name__ == "__main__":
    main()
