#!/usr/bin/env python3
"""Finish the 4-layer regulator cluster without copper crossings or shorts."""

from pathlib import Path
import shutil

import pcbnew

import route_internal_signals as internal
import route_remaining_signals as grid_router
from make_four_layer_baseline import direct_forms, form_name


ROOT = Path(__file__).resolve().parent
SOURCE = ROOT / "focalpoint_rev_b_4layer_local_escapes.kicad_pcb"
OUTPUT = ROOT / "focalpoint_rev_b_4layer_final_candidate.kicad_pcb"
REPORT = ROOT / "focalpoint_rev_b_4layer_local_power.txt"
STRIPPED = ROOT / "focalpoint_rev_b_4layer_l2sw_removed.kicad_pcb"
MM = pcbnew.FromMM
NETCODES = {}


def add_track(board, net_name, layer, width, start, end):
    track = pcbnew.PCB_TRACK(board)
    track.SetStart(pcbnew.VECTOR2I(MM(start[0]), MM(start[1])))
    track.SetEnd(pcbnew.VECTOR2I(MM(end[0]), MM(end[1])))
    track.SetWidth(MM(width))
    track.SetLayer(layer)
    track.SetNetCode(NETCODES[net_name])
    board.Add(track)


def add_path(board, net_name, layer, width, points):
    for start, end in zip(points, points[1:]):
        add_track(board, net_name, layer, width, start, end)


def add_via(board, net_name, position, diameter=0.50, drill=0.20):
    via = pcbnew.PCB_VIA(board)
    via.SetPosition(pcbnew.VECTOR2I(MM(position[0]), MM(position[1])))
    via.SetWidth(MM(diameter))
    via.SetDrill(MM(drill))
    via.SetLayerPair(pcbnew.F_Cu, pcbnew.B_Cu)
    via.SetNetCode(NETCODES[net_name])
    board.Add(via)


def add_grid_route(board, net_name, start, goal, width=0.20):
    """Route one inner-layer span using the existing clearance-aware A*."""
    grid_router.ROUTE_RADIUS = width / 2
    netcode = NETCODES[net_name]
    for layer in (pcbnew.In2_Cu, pcbnew.In1_Cu):
        for grid in (0.50, 0.25):
            path = grid_router.find_grid_path(
                board, netcode, layer, [start], [goal], grid,
            )
            if path:
                add_path(board, net_name, layer, width, path)
                return board.GetLayerName(layer), grid, len(path) - 1
    raise RuntimeError(f"no clearance-safe inner route for {net_name}")


def main():
    global NETCODES
    # Remove the old L2_SW segments textually before pcbnew owns them.  Removing
    # live SWIG track objects while iterating corrupts KiCad's Python wrappers.
    forms = direct_forms(SOURCE.read_text(), "kicad_pcb")
    kept = []
    for form in forms:
        name = form_name(form)
        remove = name == "segment" and '(net "L2_SW")' in form
        if name == "segment" and '(net "+5V")' in form:
            remove |= "(start 167.275 211)" in form and "(end 167.275 208)" in form
        if name == "segment" and '(net "GND")' in form:
            remove |= any(
                marker in form for marker in (
                    "(start 165.725 208)", "(end 165.725 208)",
                    "(start 165.175 208)", "(end 165.175 208)",
                )
            )
        if name == "segment" and '(net "FG_SCL")' in form:
            remove |= (
                "(start 188.1192 201.8813)" in form
                and "(end 117.2185 201.8813)" in form
            )
        if name == "segment" and '(net "+5V_LED")' in form:
            remove |= any(marker in form for marker in (
                "(start 149.0189 154.7338)", "(end 149.0189 154.7338)",
                "(start 169.0189 134.7338)", "(end 169.0189 134.7338)",
            ))
        if name == "segment" and '(net "LED7_DIN")' in form:
            remove |= any(marker in form for marker in (
                "(start 189.683 150.11)", "(end 189.683 150.11)",
                "(start 128.3493 170.1039)", "(end 128.3493 170.1039)",
            ))
        if name == "segment" and '(net "LED3_DIN")' in form:
            remove |= any(marker in form for marker in (
                "(start 169.648 130.095)", "(end 169.648 130.095)",
                "(start 129.7046 130.095)", "(end 129.7046 130.095)",
            ))
        if name == "segment" and '(net "FG_SDA")' in form:
            remove |= any(marker in form for marker in (
                "(start 122.441 190.1132)", "(end 122.441 190.1132)",
                "(start 181.8568 190.1132)", "(end 181.8568 190.1132)",
            ))
        if name == "segment" and '(net "GND")' in form:
            remove |= (
                "(start 107.012 187.25)" in form
                and "(end 107.912 187.25)" in form
            )
        if name == "via" and '(net "GND")' in form:
            remove |= "(at 165.175 208)" in form
            remove |= "(at 107.912 187.25)" in form
        if not remove:
            kept.append(form)
    STRIPPED.write_text("(kicad_pcb\n\t" + "\n\t".join(
        form.replace("\n", "\n\t") for form in kept
    ) + "\n)\n")
    board = pcbnew.LoadBoard(str(STRIPPED))
    c31 = next(fp for fp in board.GetFootprints() if fp.GetReference() == "C31")
    c31.SetPosition(pcbnew.VECTOR2I(MM(170.000), MM(202.000)))
    NETCODES = {
        name: board.FindNet(name).GetNetCode()
        for name in (
            "GND", "+5V", "SYS", "BB_L1", "BB_L2", "L2_SW", "FG_SCL",
            "+5V_LED", "LED7_DIN", "LED3_DIN", "FG_SDA",
        )
    }
    before = internal.count_unconnected(board)

    # Replace the provisional diagonal switch-node route; it crosses the only
    # viable short path from U5.6 to the output capacitor.
    l2sw_source = (167.8000, 208.000)
    l2sw_target = (165.8500, 205.000)
    add_path(board, "L2_SW", pcbnew.B_Cu, 0.20, [
        (169.2875, 208.000), l2sw_source,
    ])
    add_path(board, "L2_SW", pcbnew.B_Cu, 0.30, [
        l2sw_target, (165.8500, 204.000),
    ])
    add_via(board, "L2_SW", l2sw_source, diameter=0.45, drill=0.20)
    add_via(board, "L2_SW", l2sw_target)
    add_path(board, "L2_SW", pcbnew.In1_Cu, 0.30, [
        l2sw_source, l2sw_target,
    ])

    # U5 +5 V output to the relocated local capacitor above it.  C31 then joins
    # the existing +5 V trunk at the previously dangling B.Cu endpoint.
    add_path(board, "+5V", pcbnew.B_Cu, 0.30, [
        (168.100, 207.500), (167.100, 207.000),
        (167.100, 204.800), (170.775, 204.800),
        (170.775, 202.000),
    ])
    add_path(board, "+5V", pcbnew.B_Cu, 0.30, [
        (170.775, 202.000), (171.1255, 202.5337),
    ])
    c31_gnd_via = (169.225, 203.000)
    add_via(board, "GND", c31_gnd_via, diameter=0.60, drill=0.30)
    add_path(board, "GND", pcbnew.B_Cu, 0.30, [
        (169.225, 202.000), c31_gnd_via,
    ])

    # The original 70.9 mm FG_SCL segment ran through both C31 and a transverse
    # VBUS trunk.  Drop it to In1.Cu at its existing endpoints instead.
    fg_scl_left = (117.2185, 201.8813)
    fg_scl_right = (188.1192, 203.5000)
    add_via(board, "FG_SCL", fg_scl_left)
    add_via(board, "FG_SCL", fg_scl_right)
    add_path(board, "FG_SCL", pcbnew.B_Cu, 0.20, [
        fg_scl_right, (188.1192, 201.8813),
    ])
    add_path(board, "FG_SCL", pcbnew.In1_Cu, 0.20, [
        fg_scl_left, (118.000, 198.500),
        (190.000, 198.500), fg_scl_right,
    ])

    # Replace the almost-coincident U9 GND fanout vias with one shared via.
    add_path(board, "GND", pcbnew.B_Cu, 0.30, [
        (107.0125, 187.250), (107.800, 187.250),
    ])

    # Keep routed copper at least 0.20 mm from the reverse-LED apertures.  Each
    # detour is local to the DRC-reported aperture and retains the old endpoints.
    add_path(board, "+5V_LED", pcbnew.B_Cu, 0.50, [
        (148.775, 154.7338), (149.000, 155.100),
        (150.200, 155.100), (150.725, 153.0277),
    ])
    add_path(board, "+5V_LED", pcbnew.B_Cu, 0.50, [
        (168.775, 134.7338), (169.000, 135.100),
        (170.200, 135.100), (170.725, 133.0277),
    ])
    led7_left = (131.3556, 150.1579)
    led7_right = (190.7250, 148.5000)
    add_via(board, "LED7_DIN", led7_right)
    add_path(board, "LED7_DIN", pcbnew.B_Cu, 0.20, [
        led7_right, (190.725, 151.1520),
    ])
    add_path(board, "LED7_DIN", pcbnew.In1_Cu, 0.20, [
        led7_left, (137.000, 150.1579), (137.000, 135.500),
        (197.000, 135.500), (197.000, 148.500), led7_right,
    ])
    add_path(board, "LED7_DIN", pcbnew.In2_Cu, 0.20, [
        (124.9146, 170.1039), (125.500, 169.300),
        (129.500, 169.300), (130.4417, 168.0115),
    ])
    led3_left = (129.1552, 130.6444)
    led3_right = (172.0000, 130.5000)
    add_via(board, "LED3_DIN", led3_right)
    add_path(board, "LED3_DIN", pcbnew.B_Cu, 0.20, [
        led3_right, (170.725, 131.1720),
    ])
    add_path(board, "LED3_DIN", pcbnew.In1_Cu, 0.20, [
        led3_left, (141.000, 130.6444), (141.000, 118.000),
        (178.000, 118.000), (178.000, 130.500), led3_right,
    ])
    fg_sda_left = (117.6770, 186.5000)
    fg_sda_right = (182.1445, 190.4009)
    add_via(board, "FG_SDA", fg_sda_left)
    add_path(board, "FG_SDA", pcbnew.B_Cu, 0.20, [
        (117.6770, 185.3492), fg_sda_left,
    ])
    add_path(board, "FG_SDA", pcbnew.In1_Cu, 0.20, [
        fg_sda_left, (118.000, 183.500), (118.000, 175.500),
        (185.000, 175.500), (185.000, 190.4009), fg_sda_right,
    ])

    # The joystick shell's GND PTH sits on the edge of an In2 zone island;
    # make that specific inner-plane connection solid instead of starved thermal.
    for footprint in board.GetFootprints():
        if footprint.GetReference() != "JS1":
            continue
        for pad in footprint.Pads():
            if pad.GetNumber() == "2" and pad.GetNetname() == "GND":
                pad.SetLocalZoneConnection(pcbnew.ZONE_CONNECTION_FULL)

    # Join U5 SYS, its local C17/C30 branch, and the main SYS rail on In2.Cu.
    # Short B.Cu stubs keep the vias outside the fine-pitch package courtyard.
    sys_u5 = (170.900, 208.900)
    sys_local = (172.225, 209.750)
    sys_main = (162.150, 202.800)
    add_path(board, "SYS", pcbnew.B_Cu, 0.20, [
        (171.500, 208.500), sys_u5,
    ])
    add_path(board, "SYS", pcbnew.B_Cu, 0.30, [
        sys_local, (172.225, 210.500),
    ])
    add_path(board, "SYS", pcbnew.B_Cu, 0.30, [
        sys_main, (162.150, 204.000),
    ])
    for point in (sys_u5, sys_local, sys_main):
        add_via(board, "SYS", point)
    add_path(board, "SYS", pcbnew.In1_Cu, 0.30, [
        sys_u5, sys_local, (172.225, 211.800),
        (160.800, 211.800), sys_main,
    ])

    # Tie the second U4 SYS pin to the already-routed U4 SYS branch beneath it.
    sys_u4 = (148.500, 208.000)
    sys_u4_main = (140.000, 206.0773)
    for point in (sys_u4, sys_u4_main):
        add_via(board, "SYS", point)
    add_path(board, "SYS", pcbnew.In2_Cu, 0.30, [
        sys_u4, (149.000, 210.500), (140.000, 210.500), sys_u4_main,
    ])

    # Buck-boost switch nodes use separate internal-layer corridors.  They
    # diverge immediately, preserving clearance instead of crossing the SYS
    # rail and one another on B.Cu.
    bb_l1_source = (143.500, 207.500)
    bb_l1_target = (141.150, 203.000)
    bb_l2_source = (143.500, 208.500)
    bb_l2_target = (137.750, 203.000)
    for net_name, source, target, pad in (
        ("BB_L1", bb_l1_source, bb_l1_target, (141.150, 204.000)),
        ("BB_L2", bb_l2_source, bb_l2_target, (138.850, 204.000)),
    ):
        add_via(board, net_name, source)
        add_via(board, net_name, target)
        add_path(board, net_name, pcbnew.In1_Cu, 0.25, [source, target])
        add_path(board, net_name, pcbnew.B_Cu, 0.25, [target, pad])

    pcbnew.ZONE_FILLER(board).Fill(board.Zones())
    after = internal.count_unconnected(board)
    if not pcbnew.SaveBoard(str(OUTPUT), board):
        raise RuntimeError("save failed")
    # The intermediate boards may carry stale copied project settings.  The
    # working 4-layer project is the single source of truth for fabrication
    # minima and net classes.
    project_source = ROOT / "focalpoint_rev_b_4layer_working"
    for suffix in (".kicad_pro", ".rules"):
        companion = project_source.with_suffix(suffix)
        if companion.exists():
            shutil.copy2(companion, OUTPUT.with_suffix(suffix))
    REPORT.write_text(
        f"source={SOURCE.name}\noutput={OUTPUT.name}\n"
        f"unconnected_before={before}\nunconnected_after={after}\n"
        "remaining_nets_routed=+5V,SYS,BB_L1,BB_L2\n"
        "strategy=short B.Cu escapes plus In2.Cu corridors\n"
    )
    print(REPORT.read_text(), end="")
    if after:
        raise RuntimeError(f"routing remains incomplete: {after} unconnected")


if __name__ == "__main__":
    main()
