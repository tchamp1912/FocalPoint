#!/Applications/KiCad/KiCad.app/Contents/Frameworks/Python.framework/Versions/3.9/bin/python3.9
"""Verify every vendored release footprint matches its embedded board copy.

KiCad regenerates property UUID metadata when exporting J3 and U1, so UUID
lines are intentionally excluded from the comparison.  All manufacturing
geometry, layers, properties, pads, models, and attributes remain compared.
"""

from __future__ import annotations

import re
import tempfile
from pathlib import Path

import pcbnew


ROOT = Path(__file__).resolve().parent
BOARD = ROOT / "focalpoint_rev_a_release_candidate.kicad_pcb"
LIBRARY = ROOT / "FocalPoint.pretty"
REPORT = ROOT / "release_candidate_footprint_audit.txt"
EXPECTED_RELEASE_FOOTPRINTS = 37


def normalized(path: Path) -> str:
    return "\n".join(
        line
        for line in path.read_text().splitlines()
        if not re.match(r"\s*\(uuid \"[0-9a-f-]+\"\)\s*$", line)
    )


def main() -> None:
    board = pcbnew.LoadBoard(str(BOARD))
    footprints = [
        footprint
        for footprint in board.GetFootprints()
        if str(footprint.GetFPID().GetLibNickname()) == "FocalPoint"
        and str(footprint.GetFPID().GetLibItemName()).startswith("Release_")
    ]
    failures: list[str] = []
    with tempfile.TemporaryDirectory(prefix="focalpoint-footprint-audit-") as raw:
        exported = Path(raw)
        plugin = pcbnew.PCB_IO_KICAD_SEXPR()
        for footprint in footprints:
            reference = footprint.GetReference()
            name = str(footprint.GetFPID().GetLibItemName())
            library_path = LIBRARY / f"{name}.kicad_mod"
            if not library_path.is_file():
                failures.append(f"{reference}: missing {library_path.name}")
                continue
            plugin.FootprintSave(str(exported), footprint)
            exported_path = exported / f"{name}.kicad_mod"
            if normalized(exported_path) != normalized(library_path):
                failures.append(f"{reference}: embedded geometry differs from {library_path.name}")

    if len(footprints) != EXPECTED_RELEASE_FOOTPRINTS:
        failures.append(
            f"expected {EXPECTED_RELEASE_FOOTPRINTS} vendored footprints, "
            f"found {len(footprints)}"
        )
    lines = [
        f"board={BOARD.name}",
        f"vendored_release_footprints={len(footprints)}",
        "uuid_metadata_ignored=yes",
        f"geometry_mismatches={len(failures)}",
        *failures,
    ]
    REPORT.write_text("\n".join(lines) + "\n")
    print("\n".join(lines))
    if failures:
        raise RuntimeError("project-local footprint audit failed")


if __name__ == "__main__":
    main()
