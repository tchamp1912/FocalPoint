#!/usr/bin/env python3
"""Create a clean four-layer routing baseline from the accepted Rev A PCB."""

from __future__ import annotations

import json
import re
from pathlib import Path


ROOT = Path(__file__).resolve().parent
SOURCE_BOARD = ROOT / "focalpoint_rev_a_release_candidate.kicad_pcb"
SOURCE_PROJECT = ROOT / "focalpoint_rev_a_release_candidate.kicad_pro"
OUTPUT_BOARD = ROOT / "focalpoint_rev_b_4layer_working.kicad_pcb"
OUTPUT_PROJECT = ROOT / "focalpoint_rev_b_4layer_working.kicad_pro"
REPORT = ROOT / "focalpoint_rev_b_4layer_baseline.txt"


LAYERS = '''(layers
		(0 "F.Cu" signal)
		(4 "In1.Cu" power "GND plane")
		(6 "In2.Cu" signal "GND + slow routing")
		(2 "B.Cu" signal)
		(9 "F.Adhes" user "F.Adhesive")
		(11 "B.Adhes" user "B.Adhesive")
		(13 "F.Paste" user)
		(15 "B.Paste" user)
		(5 "F.SilkS" user "F.Silkscreen")
		(7 "B.SilkS" user "B.Silkscreen")
		(1 "F.Mask" user)
		(3 "B.Mask" user)
		(17 "Dwgs.User" user "User.Drawings")
		(19 "Cmts.User" user "User.Comments")
		(21 "Eco1.User" user "User.Eco1")
		(23 "Eco2.User" user "User.Eco2")
		(25 "Edge.Cuts" user)
		(27 "Margin" user)
		(31 "F.CrtYd" user "F.Courtyard")
		(29 "B.CrtYd" user "B.Courtyard")
		(35 "F.Fab" user)
		(33 "B.Fab" user)
	)'''

STACKUP = '''(stackup
			(layer "F.SilkS" (type "Top Silk Screen"))
			(layer "F.Paste" (type "Top Solder Paste"))
			(layer "F.Mask" (type "Top Solder Mask") (thickness 0.01))
			(layer "F.Cu" (type "copper") (thickness 0.035))
			(layer "dielectric 1" (type "prepreg") (thickness 0.2104)
				(material "NP-155F 7628") (epsilon_r 4.4) (loss_tangent 0.014))
			(layer "In1.Cu" (type "copper") (thickness 0.0152))
			(layer "dielectric 2" (type "core") (thickness 1.065)
				(material "NP-155F") (epsilon_r 4.43) (loss_tangent 0.014))
			(layer "In2.Cu" (type "copper") (thickness 0.0152))
			(layer "dielectric 3" (type "prepreg") (thickness 0.2104)
				(material "NP-155F 7628") (epsilon_r 4.4) (loss_tangent 0.014))
			(layer "B.Cu" (type "copper") (thickness 0.035))
			(layer "B.Mask" (type "Bottom Solder Mask") (thickness 0.01))
			(layer "B.Paste" (type "Bottom Solder Paste"))
			(layer "B.SilkS" (type "Bottom Silk Screen"))
			(copper_finish "ENIG")
			(dielectric_constraints no)
		)'''


def zone(layer: str, uuid: str) -> str:
    return f'''(zone
		(net "GND")
		(layer "{layer}")
		(uuid "{uuid}")
		(name "Continuous GND reference")
		(hatch edge 0.5)
		(connect_pads (clearance 0.25))
		(min_thickness 0.25)
		(fill yes (thermal_gap 0.3) (thermal_bridge_width 0.3)
			(island_removal_mode 0))
		(polygon
			(pts (xy 101 101) (xy 215 101) (xy 215 215) (xy 101 215))
		)
	)'''


def direct_forms(text: str, outer_name: str) -> list[str]:
    outer = text.find(f"({outer_name}")
    if outer < 0:
        raise ValueError(f"missing {outer_name}")
    forms: list[str] = []
    depth = 0
    start = None
    in_string = False
    escaped = False
    for index in range(outer, len(text)):
        char = text[index]
        if in_string:
            if escaped:
                escaped = False
            elif char == "\\":
                escaped = True
            elif char == '"':
                in_string = False
            continue
        if char == '"':
            in_string = True
        elif char == "(":
            depth += 1
            if depth == 2:
                start = index
        elif char == ")":
            if depth == 2 and start is not None:
                forms.append(text[start:index + 1])
                start = None
            depth -= 1
            if depth == 0:
                break
    return forms


def form_name(form: str) -> str:
    match = re.match(r"\(([^\s()]+)", form)
    if not match:
        raise ValueError("unnamed form")
    return match.group(1)


def matching_paren(text: str, start: int) -> int:
    depth = 0
    in_string = False
    escaped = False
    for index in range(start, len(text)):
        char = text[index]
        if in_string:
            if escaped:
                escaped = False
            elif char == "\\":
                escaped = True
            elif char == '"':
                in_string = False
            continue
        if char == '"':
            in_string = True
        elif char == "(":
            depth += 1
        elif char == ")":
            depth -= 1
            if depth == 0:
                return index
    raise ValueError("unterminated form")


def replace_nested_form(text: str, name: str, replacement: str) -> str:
    match = re.search(rf"\({re.escape(name)}(?:\s|\))", text)
    if not match:
        raise ValueError(f"missing nested form {name}")
    start = match.start()
    end = matching_paren(text, start) + 1
    return text[:start] + replacement + text[end:]


def relocate_footprint(form: str, reference: str, x_mm: float, y_mm: float,
                       angle_degrees: float = 0.0) -> str:
    if f'(property "Reference" "{reference}"' not in form:
        return form
    return re.sub(
        r"\(at\s+[-+0-9.]+\s+[-+0-9.]+(?:\s+[-+0-9.]+)?\)",
        f"(at {x_mm:g} {y_mm:g} {angle_degrees:g})" if angle_degrees else
        f"(at {x_mm:g} {y_mm:g})",
        form,
        count=1,
    )


def update_project() -> None:
    data = json.loads(SOURCE_PROJECT.read_text())
    # Reverse-mount LEDs use intentional Edge.Cuts apertures with copper much
    # closer than 1 mm.  Use the fab-compatible global rule for all cutouts,
    # then enforce a separate 1 mm target against the *external* outline in the
    # route-quality audit.
    data["board"]["design_settings"]["rules"]["min_copper_edge_clearance"] = 0.2
    for net_class in data["net_settings"]["classes"]:
        if net_class["name"] == "PWR_HIGH_CURRENT":
            # Use 0.5 mm escape/trunk routing; broad local distribution is done
            # with copper pours after signal routing instead of 1 mm meanders.
            net_class["track_width"] = 0.5
            net_class["via_diameter"] = 0.8
            net_class["via_drill"] = 0.4
        elif net_class["name"] == "PWR_3V3_PLANE":
            # Rev B has no dedicated 3V3 plane.  This is a routed supply.
            net_class["track_width"] = 0.3
            net_class["via_diameter"] = 0.6
            net_class["via_drill"] = 0.3
            net_class["name"] = "PWR_3V3_ROUTED"
        elif net_class["name"] == "USB2_FS_JLC06161H_90R_TARGET":
            # The geometry is provisional until the selected JLCPCB four-layer
            # stackup is entered and the 90-ohm differential pair recalculated.
            net_class["name"] = "USB2_FS_4L_STACKUP_PENDING"
    data["net_settings"]["classes"].append({
        "bus_width": 12,
        "clearance": 0.15,
        "diff_pair_gap": 0.25,
        "diff_pair_via_gap": 0.25,
        "diff_pair_width": 0.2,
        "line_style": 0,
        "microvia_diameter": 0.3,
        "microvia_drill": 0.1,
        "name": "GND_PLANE",
        "pcb_color": "rgba(0, 0, 0, 0.000)",
        "priority": 2147483647,
        "schematic_color": "rgba(0, 0, 0, 0.000)",
        "track_width": 0.3,
        "tuning_profile": "",
        "via_diameter": 0.6,
        "via_drill": 0.3,
        "wire_width": 6,
    })
    assignments = data["net_settings"]["netclass_assignments"]
    for net_name, class_names in assignments.items():
        assignments[net_name] = [
            "PWR_3V3_ROUTED" if name == "PWR_3V3_PLANE"
            else "USB2_FS_4L_STACKUP_PENDING"
            if name == "USB2_FS_JLC06161H_90R_TARGET"
            else name
            for name in class_names
        ]
    assignments["GND"] = ["GND_PLANE"]
    OUTPUT_PROJECT.write_text(json.dumps(data, indent=2) + "\n")


def main() -> None:
    source = SOURCE_BOARD.read_text()
    forms = direct_forms(source, "kicad_pcb")
    output_forms = []
    removed_tracks = 0
    removed_zones = 0
    for form in forms:
        name = form_name(form)
        if name in {"segment", "via"} or (name == "arc" and "\n\t\t(net " in form):
            removed_tracks += 1
            continue
        if name == "zone":
            removed_zones += 1
            continue
        if name == "layers":
            form = LAYERS
        elif name == "setup":
            form = replace_nested_form(form, "stackup", STACKUP)
        elif name == "title_block":
            form = re.sub(r'\(title "[^"]*"\)',
                          '(title "FocalPoint Rev B Four-Layer Routing Working Board")', form)
            form = re.sub(r'\(rev "[^"]*"\)', '(rev "B-4L-unrouted")', form)
            form = re.sub(r'\(date "[^"]*"\)', '(date "2026-07-31")', form)
        elif name == "footprint":
            # Put the boost output capacitors on the output-pin side of U5 and
            # move the SYS bypass to the input side.  The Rev A placement put
            # C31's GND pad directly in front of U5 pins 2/3 and forced shorts.
            for reference, x_mm, y_mm, angle in (
                ("C31", 166.5, 208.0, 180.0),
                ("C32", 166.5, 211.0, 180.0),
                ("C17", 173.0, 210.5, 0.0),
            ):
                form = relocate_footprint(form, reference, x_mm, y_mm, angle)
        output_forms.append(form)
    output_forms.extend([
        zone("In1.Cu", "86f7c12d-85b7-4bd4-8b4b-05ca2aa93210"),
        zone("In2.Cu", "7b5fe41d-f72b-4a03-a8fb-0ce211a83e6f"),
    ])
    OUTPUT_BOARD.write_text("(kicad_pcb\n\t" + "\n\t".join(
        form.replace("\n", "\n\t") for form in output_forms
    ) + "\n)\n")
    update_project()

    REPORT.write_text(
        f"source={SOURCE_BOARD.name}\n"
        f"output={OUTPUT_BOARD.name}\n"
        "copper_layers=4\n"
        f"removed_track_and_via_items={removed_tracks}\n"
        f"removed_board_zones={removed_zones}\n"
        "new_ground_zones=2\n"
        "global_copper_to_edge_rule_mm=0.200\n"
        "external_outline_track_target_mm=1.000\n"
        "stack=F.Cu / continuous GND / GND plus optional slow routing / B.Cu\n"
        "dedicated_3v3_plane=no\n"
        "dedicated_5v_plane=no\n"
        "power_escape_width_mm=0.500\n"
        "3v3_route_width_mm=0.300\n"
        "usb_geometry_status=pending_selected_4_layer_fab_stackup\n"
    )
    print(REPORT.read_text(), end="")


if __name__ == "__main__":
    main()
