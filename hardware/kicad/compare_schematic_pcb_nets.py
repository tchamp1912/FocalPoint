#!/usr/bin/env python3
"""Compare every numbered PCB pad net against a KiCad XML schematic netlist."""

from pathlib import Path
import sys
import xml.etree.ElementTree as ET

import pcbnew


def schematic_map(xml_path: Path):
    result = {}
    root = ET.parse(xml_path).getroot()
    board_refs = {
        comp.get("ref", "")
        for comp in root.findall("./components/comp")
        if (comp.findtext("footprint") or "").strip()
    }
    for net in root.findall("./nets/net"):
        name = net.get("name", "")
        for node in net.findall("node"):
            if node.get("ref", "") not in board_refs:
                continue
            key = (node.get("ref", ""), node.get("pin", ""))
            previous = result.setdefault(key, name)
            if previous != name:
                raise RuntimeError(f"schematic pin {key} appears on {previous!r} and {name!r}")
    return result


def board_map(board_path: Path):
    board = pcbnew.LoadBoard(str(board_path))
    result = {}
    for footprint in board.GetFootprints():
        ref = footprint.GetReference()
        for pad in footprint.Pads():
            number = pad.GetNumber()
            if not number:
                continue
            key = (ref, number)
            net = pad.GetNetname()
            previous = result.setdefault(key, net)
            if previous != net:
                raise RuntimeError(f"PCB duplicate pad {key} has nets {previous!r} and {net!r}")
    return result


def main():
    if len(sys.argv) != 4:
        raise SystemExit("usage: compare_schematic_pcb_nets.py NETLIST.xml BOARD.kicad_pcb REPORT.txt")
    expected = schematic_map(Path(sys.argv[1]))
    actual = board_map(Path(sys.argv[2]))
    mismatches = []
    for key in sorted(expected.keys() | actual.keys()):
        schematic_net = expected.get(key, "")
        board_net = actual.get(key, "")
        if schematic_net != board_net:
            mismatches.append(f"{key[0]}.{key[1]} schematic={schematic_net!r} pcb={board_net!r}")
    report = (
        f"schematic_numbered_pins={len(expected)}\n"
        f"pcb_numbered_pads={len(actual)}\n"
        f"mismatches={len(mismatches)}\n"
    )
    if mismatches:
        report += "\n".join(mismatches) + "\n"
    Path(sys.argv[3]).write_text(report)
    print(report, end="")
    if mismatches:
        raise RuntimeError("schematic/PCB net comparison failed")


if __name__ == "__main__":
    main()
