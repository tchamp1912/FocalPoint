#!/usr/bin/env python3
"""Clear U4 pin escapes and add short neck-downs for fine-pitch power ICs."""

from pathlib import Path
import re

import pcbnew

from make_four_layer_baseline import direct_forms, form_name


ROOT = Path(__file__).resolve().parent
SOURCE = ROOT / "focalpoint_rev_b_4layer_connected.kicad_pcb"
OUTPUT = ROOT / "focalpoint_rev_b_4layer_local_escapes.kicad_pcb"
REPORT = ROOT / "focalpoint_rev_b_4layer_local_escapes.txt"
STRIPPED = ROOT / "focalpoint_rev_b_4layer_u4_vias_removed.kicad_pcb"
MM = pcbnew.FromMM


def at(point, target, tolerance=0.002):
    return abs(point.x / 1e6 - target[0]) <= tolerance and abs(point.y / 1e6 - target[1]) <= tolerance


def add_track(board, netcode, start, end, width=0.20):
    track = pcbnew.PCB_TRACK(board)
    track.SetStart(pcbnew.VECTOR2I(MM(start[0]), MM(start[1])))
    track.SetEnd(pcbnew.VECTOR2I(MM(end[0]), MM(end[1])))
    track.SetWidth(MM(width))
    track.SetLayer(pcbnew.B_Cu)
    track.SetNetCode(netcode)
    board.Add(track)


def main():
    source_text = SOURCE.read_text()
    forms = direct_forms(source_text, "kicad_pcb")
    remove_positions_text = {
        "143.888 208", "148.112 207.5", "148.112 208.5",
        "171.675 208",
    }
    kept = []
    removed_count = 0
    for form in forms:
        name = form_name(form)
        remove = False
        if name == "via" and '(net "GND")' in form:
            remove = any(f"(at {position})" in form for position in remove_positions_text)
        elif name == "segment" and '(net "GND")' in form:
            remove = any(
                f"(start {position})" in form or f"(end {position})" in form
                for position in remove_positions_text
            )
        elif name == "segment" and any(
            marker in form for marker in (
                '(net "+5V")', '(net "SYS")', '(net "BB_L2")', '(net "BB_L1")',
            )
        ):
            # Make this regeneration idempotent by removing the prior local
            # neck-downs before adding the current geometry.
            remove = any(
                marker in form for marker in (
                    "(start 169.288 207.5)", "(start 170.712 208.5)",
                    "(start 147.212 208)", "(start 144.788 208.5)",
                    "(start 144.788 207.5)",
                )
            )
        if remove:
            removed_count += 1
        else:
            kept.append(form)
    STRIPPED.write_text("(kicad_pcb\n\t" + "\n\t".join(
        form.replace("\n", "\n\t") for form in kept
    ) + "\n)\n")
    board = pcbnew.LoadBoard(str(STRIPPED))
    netcodes = {
        name: board.FindNet(name).GetNetCode()
        for name in ("GND", "+5V", "SYS", "BB_L2", "BB_L1", "BOOST_EN")
    }
    # U4 ground pins connect inward to the exposed pad, whose plated thermal
    # vias already connect to both inner GND planes.
    add_track(board, netcodes["GND"], (144.7875, 208.0000), (145.4000, 208.0000), 0.30)
    add_track(board, netcodes["GND"], (147.2125, 207.5000), (146.6000, 207.5000), 0.30)
    add_track(board, netcodes["GND"], (147.2125, 208.5000), (146.6000, 208.5000), 0.30)

    escapes = [
        ("+5V", (169.2875, 207.5000), (168.1000, 207.5000)),
        ("SYS", (170.7125, 208.5000), (171.5000, 208.5000)),
        ("SYS", (147.2125, 208.0000), (148.5000, 208.0000)),
        ("BB_L2", (144.7875, 208.5000), (143.5000, 208.5000)),
        ("BB_L1", (144.7875, 207.5000), (143.5000, 207.5000)),
    ]
    for net, start, end in escapes:
        add_track(board, netcodes[net], start, end, 0.20)

    pcbnew.ZONE_FILLER(board).Fill(board.Zones())
    board.BuildConnectivity()
    unconnected = board.GetConnectivity().GetUnconnectedCount(False)
    pcbnew.SaveBoard(str(OUTPUT), board)
    REPORT.write_text(
        f"source={SOURCE.name}\noutput={OUTPUT.name}\n"
        f"removed_u4_fanout_items={removed_count}\n"
        "u4_ground_connections_moved_inward=3\n"
        f"fine_pitch_escape_necks_added={len(escapes)}\n"
        f"unconnected={unconnected}\n"
    )
    print(REPORT.read_text(), end="")


if __name__ == "__main__":
    main()
