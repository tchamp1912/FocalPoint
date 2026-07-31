#!/Applications/KiCad/KiCad.app/Contents/Frameworks/Python.framework/Versions/3.9/bin/python3.9
"""Vendor DRC-mismatched board footprints into a project-local library.

Each affected reference receives a unique release footprint.  This preserves
the exact embedded pad and artwork geometry while making KiCad's library
comparison deterministic and independent of future global-library updates.
"""

from __future__ import annotations

import argparse
import re
import shutil
from pathlib import Path

import pcbnew


def mismatch_references(report: Path) -> set[str]:
    return set(
        re.findall(
            r"@\([^\n]+\): Footprint ([A-Z]+[0-9]+)$",
            report.read_text(),
            flags=re.MULTILINE,
        )
    )


def safe_name(text: str) -> str:
    return re.sub(r"[^A-Za-z0-9_.+-]", "_", text)


def main() -> None:
    parser = argparse.ArgumentParser()
    parser.add_argument("source", type=Path)
    parser.add_argument("report", type=Path)
    parser.add_argument("output", type=Path)
    parser.add_argument("library", type=Path)
    args = parser.parse_args()
    source = args.source.resolve()
    output = args.output.resolve()
    library = args.library.resolve()
    if source == output:
        parser.error("output must differ from source")

    references = mismatch_references(args.report.resolve())
    if not references:
        raise RuntimeError("report contains no library-footprint mismatch warnings")
    library.mkdir(parents=True, exist_ok=True)
    board = pcbnew.LoadBoard(str(source))
    footprints = {footprint.GetReference(): footprint for footprint in board.GetFootprints()}
    missing = sorted(references - footprints.keys())
    if missing:
        raise RuntimeError(f"DRC references absent from board: {missing}")

    written = []
    for reference in sorted(references):
        footprint = footprints[reference]
        original = footprint.GetFPID().GetLibItemName()
        name = safe_name(f"Release_{reference}_{original}")
        footprint.SetFPID(pcbnew.LIB_ID("FocalPoint", name))
        written.append(name)

    if not pcbnew.SaveBoard(str(output), board):
        raise RuntimeError(f"could not save {output}")
    # Reload after saving. KiCad may regenerate duplicated property UUIDs while
    # serializing a board; saving the library second guarantees the library
    # copy contains those final UUIDs rather than the pre-save values.
    saved_board = pcbnew.LoadBoard(str(output))
    saved_footprints = {
        footprint.GetReference(): footprint for footprint in saved_board.GetFootprints()
    }
    plugin = pcbnew.PCB_IO_KICAD_SEXPR()
    for reference in sorted(references):
        plugin.FootprintSave(str(library), saved_footprints[reference])
    for suffix in (".kicad_pro", ".rules"):
        companion = source.with_suffix(suffix)
        if companion.exists():
            shutil.copy2(companion, output.with_suffix(suffix))
    print(f"vendored_release_footprints={len(written)}")
    print(f"library={library}")
    print(f"output={output}")


if __name__ == "__main__":
    main()
