#!/Applications/KiCad/KiCad.app/Contents/Frameworks/Python.framework/Versions/Current/bin/python3
"""Refresh project-local Release_* footprints from an authoritative board."""

from __future__ import annotations

import argparse
from pathlib import Path

import pcbnew


def main() -> None:
    parser = argparse.ArgumentParser()
    parser.add_argument("board", type=Path)
    parser.add_argument("library", type=Path)
    args = parser.parse_args()

    board = pcbnew.LoadBoard(str(args.board.resolve()))
    library = args.library.resolve()
    library.mkdir(parents=True, exist_ok=True)
    plugin = pcbnew.PCB_IO_KICAD_SEXPR()
    refreshed = []
    for footprint in board.GetFootprints():
        fpid = footprint.GetFPID()
        if str(fpid.GetLibNickname()) != "FocalPoint":
            continue
        if not str(fpid.GetLibItemName()).startswith("Release_"):
            continue
        plugin.FootprintSave(str(library), footprint)
        refreshed.append(footprint.GetReference())

    print(f"refreshed_release_footprints={len(refreshed)}")
    print("references=" + ",".join(sorted(refreshed)))


if __name__ == "__main__":
    main()
