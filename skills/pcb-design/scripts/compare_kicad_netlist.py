#!/usr/bin/env python3
"""Compare numbered PCB pad nets with a KiCad XML schematic netlist."""

from __future__ import annotations

import argparse
import xml.etree.ElementTree as ET
from pathlib import Path

import pcbnew


def schematic_map(path: Path) -> dict[tuple[str, str], str]:
    root = ET.parse(path).getroot()
    board_refs = {
        comp.get("ref", "")
        for comp in root.findall("./components/comp")
        if (comp.findtext("footprint") or "").strip()
    }
    result: dict[tuple[str, str], str] = {}
    for net in root.findall("./nets/net"):
        name = net.get("name", "")
        for node in net.findall("node"):
            key = (node.get("ref", ""), node.get("pin", ""))
            if key[0] not in board_refs:
                continue
            previous = result.setdefault(key, name)
            if previous != name:
                raise RuntimeError(f"schematic pin {key} occurs on two nets")
    return result


def board_map(path: Path) -> dict[tuple[str, str], str]:
    board = pcbnew.LoadBoard(str(path))
    result: dict[tuple[str, str], str] = {}
    for footprint in board.GetFootprints():
        for pad in footprint.Pads():
            number = pad.GetNumber()
            if not number:
                continue
            key = (footprint.GetReference(), number)
            net = pad.GetNetname()
            previous = result.setdefault(key, net)
            if previous != net:
                raise RuntimeError(f"PCB pad {key} occurs on two nets")
    return result


def main() -> None:
    parser = argparse.ArgumentParser()
    parser.add_argument("netlist", type=Path)
    parser.add_argument("board", type=Path)
    parser.add_argument("report", type=Path)
    args = parser.parse_args()
    expected = schematic_map(args.netlist)
    actual = board_map(args.board)
    mismatches = []
    for key in sorted(expected.keys() | actual.keys()):
        if expected.get(key, "") != actual.get(key, ""):
            mismatches.append(
                f"{key[0]}.{key[1]} schematic={expected.get(key, '')!r} "
                f"pcb={actual.get(key, '')!r}"
            )
    report = (
        f"schematic_numbered_pins={len(expected)}\n"
        f"pcb_numbered_pads={len(actual)}\n"
        f"mismatches={len(mismatches)}\n"
    )
    if mismatches:
        report += "\n".join(mismatches) + "\n"
    args.report.write_text(report)
    print(report, end="")
    if mismatches:
        raise SystemExit("schematic/PCB net comparison failed")


if __name__ == "__main__":
    main()
