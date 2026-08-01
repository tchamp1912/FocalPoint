#!/usr/bin/env python3
"""Apply the selected JLC 4-layer stack and rebuild the long USB FS pair."""

from pathlib import Path
import json
import shutil

import pcbnew

from make_four_layer_baseline import direct_forms, form_name
import route_internal_signals as internal
import route_remaining_signals as grid_router
from route_four_layer_final_connections import simplify


ROOT = Path(__file__).resolve().parent
SOURCE = ROOT / "focalpoint_rev_b_4layer_final_candidate.kicad_pcb"
STRIPPED = ROOT / "focalpoint_rev_b_4layer_usb_removed.kicad_pcb"
OUTPUT = ROOT / "focalpoint_rev_b_4layer_release_candidate.kicad_pcb"
REPORT = ROOT / "focalpoint_rev_b_4layer_usb_report.txt"
MM = pcbnew.FromMM
WIDTH = 0.2332
GAP = 0.1500
CENTER_SPACING = WIDTH + GAP


def add_track(board, netcode, layer, start, end, width=WIDTH):
    track = pcbnew.PCB_TRACK(board)
    track.SetStart(pcbnew.VECTOR2I(MM(start[0]), MM(start[1])))
    track.SetEnd(pcbnew.VECTOR2I(MM(end[0]), MM(end[1])))
    track.SetWidth(MM(width))
    track.SetLayer(layer)
    track.SetNetCode(netcode)
    board.Add(track)


def add_path(board, netcode, layer, points, width=WIDTH):
    for start, end in zip(points, points[1:]):
        add_track(board, netcode, layer, start, end, width)


def add_via(board, netcode, position):
    via = pcbnew.PCB_VIA(board)
    via.SetPosition(pcbnew.VECTOR2I(MM(position[0]), MM(position[1])))
    via.SetWidth(MM(0.60))
    via.SetDrill(MM(0.30))
    via.SetLayerPair(pcbnew.F_Cu, pcbnew.B_Cu)
    via.SetNetCode(netcode)
    board.Add(via)


def add_clear_inner_fanout(board, net_name, start, goal):
    netcode = board.FindNet(net_name).GetNetCode()
    grid_router.ROUTE_RADIUS = WIDTH / 2
    for grid in (0.50, 0.25):
        path = grid_router.find_grid_path(
            board, netcode, pcbnew.In1_Cu, [start], [goal], grid,
        )
        if path:
            path = simplify(board, netcode, pcbnew.In1_Cu, path, WIDTH)
            add_path(board, netcode, pcbnew.In1_Cu, path)
            return len(path) - 1
    raise RuntimeError(f"no clear inner fanout for {net_name}")


def remove_old_long_pair():
    forms = direct_forms(SOURCE.read_text(), "kicad_pcb")
    usb_nets = {"USB_DP_ESD", "USB_DN_ESD"}
    kept = []
    removed = 0
    for form in forms:
        name = form_name(form)
        net = next((n for n in usb_nets if f'(net "{n}")' in form), None)
        remove = False
        if net and name == "segment":
            # Retain the DRC-clean B.Cu launch/fanout at both ends; replace only
            # the long, separated In2 routes between their through-vias.
            remove = '(layer "B.Cu")' not in form
        if remove:
            removed += 1
        else:
            kept.append(form)
    STRIPPED.write_text("(kicad_pcb\n\t" + "\n\t".join(
        form.replace("\n", "\n\t") for form in kept
    ) + "\n)\n")
    return removed


def update_stackup_text(path):
    text = path.read_text()
    text = text.replace('(thickness 0.2)\n\t\t\t\t(material "FR-4")\n\t\t\t\t(epsilon_r 4.3)',
                        '(thickness 0.2104)\n\t\t\t\t(material "Nan Ya NP-155F / 7628")\n\t\t\t\t(epsilon_r 4.4)', 1)
    text = text.replace('(layer "In1.Cu"\n\t\t\t\t(type "copper")\n\t\t\t\t(thickness 0.0175)',
                        '(layer "In1.Cu"\n\t\t\t\t(type "copper")\n\t\t\t\t(thickness 0.0152)')
    text = text.replace('(thickness 1.065)\n\t\t\t\t(material "FR-4")\n\t\t\t\t(epsilon_r 4.3)',
                        '(thickness 1.065)\n\t\t\t\t(material "Nan Ya NP-155F core")\n\t\t\t\t(epsilon_r 4.43)', 1)
    text = text.replace('(layer "In2.Cu"\n\t\t\t\t(type "copper")\n\t\t\t\t(thickness 0.0175)',
                        '(layer "In2.Cu"\n\t\t\t\t(type "copper")\n\t\t\t\t(thickness 0.0152)')
    # Replace the second outer prepreg occurrence.
    index = text.find('(thickness 0.2)\n\t\t\t\t(material "FR-4")\n\t\t\t\t(epsilon_r 4.3)')
    if index >= 0:
        old = '(thickness 0.2)\n\t\t\t\t(material "FR-4")\n\t\t\t\t(epsilon_r 4.3)'
        new = '(thickness 0.2104)\n\t\t\t\t(material "Nan Ya NP-155F / 7628")\n\t\t\t\t(epsilon_r 4.4)'
        text = text[:index] + text[index:].replace(old, new, 1)
    text = text.replace('(title "FocalPoint Rev B Four-Layer Routing Working Board")',
                        '(title "FocalPoint Rev B JLC04161H-7628 Release Candidate")')
    text = text.replace('(rev "B-4L-unrouted")', '(rev "B-4L-RC1")')
    path.write_text(text)


def update_project():
    source = ROOT / "focalpoint_rev_b_4layer_working.kicad_pro"
    data = json.loads(source.read_text())
    data["meta"]["filename"] = OUTPUT.with_suffix(".kicad_pro").name
    for cls in data["net_settings"]["classes"]:
        if cls["name"] == "USB2_FS_4L_STACKUP_PENDING":
            cls["name"] = "USB2_FS_JLC04161H_7628_90R"
            cls["track_width"] = WIDTH
            cls["diff_pair_width"] = WIDTH
            cls["diff_pair_gap"] = GAP
            cls["clearance"] = 0.15
    for net, names in data["net_settings"]["netclass_assignments"].items():
        data["net_settings"]["netclass_assignments"][net] = [
            "USB2_FS_JLC04161H_7628_90R"
            if name == "USB2_FS_4L_STACKUP_PENDING" else name
            for name in names
        ]
    OUTPUT.with_suffix(".kicad_pro").write_text(json.dumps(data, indent=2) + "\n")


def main():
    removed = remove_old_long_pair()
    board = pcbnew.LoadBoard(str(STRIPPED))
    before = internal.count_unconnected(board)
    dp = board.FindNet("USB_DP_ESD").GetNetCode()
    dn = board.FindNet("USB_DN_ESD").GetNetCode()

    # F.Cu is referenced directly to the continuous In1 GND plane.  Keep the
    # long vertical span coupled; only the launch and MCU fanout spread apart.
    add_path(board, dn, pcbnew.F_Cu, [
        (168.0584, 118.8905), (168.0584, 112.5000),
        (211.5000, 112.5000), (213.1332, 113.5000),
        (213.1332, 184.3832),
    ])
    add_path(board, dp, pcbnew.F_Cu, [
        (179.2319, 119.6495), (179.2319, 115.0000),
        (180.5000, 113.8832), (212.7500, 113.8832),
        (212.7500, 184.0000), (204.0000, 184.0000),
    ])
    dn_split = (214.0000, 186.0000)
    dp_split = (204.0000, 184.0000)
    add_path(board, dn, pcbnew.F_Cu, [
        (213.1332, 184.3832), dn_split,
    ])
    add_via(board, dn, dn_split)
    add_via(board, dp, dp_split)
    dp_segments = add_clear_inner_fanout(
        board, "USB_DP_ESD", dp_split, (185.9360, 196.8264),
    )
    dn_segments = add_clear_inner_fanout(
        board, "USB_DN_ESD", dn_split, (176.3135, 197.1050),
    )

    pcbnew.ZONE_FILLER(board).Fill(board.Zones())
    after = internal.count_unconnected(board)
    if not pcbnew.SaveBoard(str(OUTPUT), board):
        raise RuntimeError("save failed")
    update_stackup_text(OUTPUT)
    update_project()
    for suffix in (".rules",):
        companion = SOURCE.with_suffix(suffix)
        if companion.exists():
            shutil.copy2(companion, OUTPUT.with_suffix(suffix))
    REPORT.write_text(
        f"source={SOURCE.name}\noutput={OUTPUT.name}\n"
        f"old_usb_items_removed={removed}\n"
        f"unconnected_before={before}\nunconnected_after={after}\n"
        "stackup=JLC04161H-7628 1.6mm 1oz/0.5oz\n"
        f"usb_pair_width_mm={WIDTH}\nusb_pair_gap_mm={GAP}\n"
        "target_differential_impedance_ohm=90\n"
        f"usb_inner_fanout_segments={dp_segments + dn_segments}\n"
    )
    print(REPORT.read_text(), end="")
    if after:
        raise RuntimeError(f"USB rebuild remains incomplete: {after}")


if __name__ == "__main__":
    main()
