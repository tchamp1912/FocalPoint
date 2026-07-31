#!/usr/bin/env python3
"""Repair physical package-pin nets and locally reroute the affected PCB."""

from pathlib import Path
import sys

import pcbnew

import route_internal_signals as internal
import route_power_escapes as escape
import route_remaining_signals as router


ROOT = Path(__file__).resolve().parent
SOURCE = ROOT / "focalpoint_rev_a_release_final.kicad_pcb"
OUTPUT = ROOT / "focalpoint_rev_a_release_final_pinoutfix.kicad_pcb"
INTERMEDIATE = Path("/private/tmp/vibekey_pinout_assignment.kicad_pcb")
ROTATED = Path("/private/tmp/vibekey_pinout_assignment_rotated.kicad_pcb")
ESCAPED = Path("/private/tmp/vibekey_pinout_assignment_escaped.kicad_pcb")

DESIRED = {
    # P1.13/pad 6 is a datasheet-qualified low-frequency GPIO and provides a
    # standard-rule escape for the slow BOOST_EN control.  Release pad 27.
    "U1": {
        "6": "BOOST_EN", "8": "FG_SDA", "14": "FG_SCL",
        "23": "", "48": "FG_ALRT", "16": "", "19": "", "27": "",
    },
    "U4": {
        "1": "+3V3", "2": "BB_L2", "3": "GND", "4": "BB_L1",
        "5": "SYS", "6": "+3V3", "7": "GND", "8": "SYS",
        "9": "GND", "10": "+3V3", "11": "GND",
    },
    "U5": {
        "1": "BOOST_FB", "2": "BOOST_EN", "3": "SYS",
        "4": "GND", "5": "L2_SW", "6": "+5V",
    },
    "U6": {
        "1": "+5V", "2": "GND", "3": "RGB_PWR_EN",
        "4": "U6_CT", "5": "+5V_LED", "6": "+5V_LED",
    },
    "U7": {
        "1": "RGB_OE_N", "2": "RGB_DATA_BUF", "3": "GND",
        "4": "RGB_OUT_BUF", "5": "+5V",
    },
    "U8": {
        "1": "TOUCH_RAW", "2": "GND", "3": "TOUCH_SNS1",
        "4": "TOUCH_SNS2", "5": "+3V3", "6": "GND",
    },
    "U9": {
        "1": "GND", "2": "+BAT", "3": "+BAT", "4": "GND",
        "5": "FG_ALRT", "6": "GND", "7": "FG_SCL",
        "8": "FG_SDA", "9": "GND",
    },
    "ENC1": {"A": "ENC_A", "B": "ENC_B", "C": "GND", "S1": "ENC_SW", "S2": "GND"},
    "J1": {"SH": "GND"},
    "L2": {"2": "SYS"},
}

# These nets are short, local package networks and should remain on B.Cu
# without layer-transition vias (especially both converter switch nodes).
LOCAL_NETS = {
    # Fine-pitch converter pads are only about 0.3 mm wide; 0.25 mm avoids
    # overhanging adjacent pads while remaining wider than ordinary signals.
    "BB_L2": 0.18,
    "BB_L1": 0.18,
    "L2_SW": 0.18,
}

POWER_WIDTHS = {
    "SYS": 0.50,
    "+5V": 0.50,
    "+5V_LED": 0.50,
    "+BAT": 0.50,
    "VBUS": 0.50,
}

FIXED_LOCAL_PATHS = {
    # Separate the two TPS63031 switch nodes immediately as they leave the
    # 0.5 mm-pitch package, then approach opposite L1 pads from distinct
    # corridors.  These coordinates are tied to the locked U4/L1 placement.
    "BB_L1": [
        (144.7875, 207.5000), (143.6000, 207.5000),
        (141.1500, 205.0000), (141.1500, 204.0000),
    ],
    "BB_L2": [
        (144.7875, 208.5000), (143.9000, 208.5000),
        (137.8000, 208.5000), (137.8000, 204.0000),
        (138.8500, 204.0000),
    ],
    "L2_SW": [
        (169.2875, 208.0000), (168.6000, 208.0000),
        (166.5000, 205.3000), (165.8500, 205.3000),
        (165.8500, 204.0000),
    ],
}


def copper_layers(item):
    if isinstance(item, pcbnew.PCB_TRACK) and not isinstance(item, pcbnew.PCB_VIA):
        return {item.GetLayer()}
    return set(item.GetLayerSet().Seq())


def touches(item, pad) -> bool:
    for layer in copper_layers(item) & copper_layers(pad):
        if item.GetEffectiveShape(layer).Collide(pad.GetEffectiveShape(layer), 0):
            return True
    return False


def changed_pads(board):
    result = []
    for ref, assignments in DESIRED.items():
        footprint = board.FindFootprintByReference(ref)
        if footprint is None:
            raise RuntimeError(f"{ref} missing")
        for number, netname in assignments.items():
            pads = [pad for pad in footprint.Pads() if pad.GetNumber() == number]
            if not pads:
                raise RuntimeError(f"{ref}.{number} missing")
            for pad in pads:
                if pad.GetNetname() != netname:
                    result.append((pad, netname))
    return result


def desired_pads(board):
    result = []
    for ref, assignments in DESIRED.items():
        footprint = board.FindFootprintByReference(ref)
        for number, netname in assignments.items():
            result.extend(
                (pad, netname) for pad in footprint.Pads() if pad.GetNumber() == number
            )
    return result


def rip_affected_copper(board, pads):
    doomed = {}
    board.BuildConnectivity()
    connectivity = board.GetConnectivity()
    for item in board.GetTracks():
        if any(touches(item, pad) for pad, _ in pads):
            doomed[int(item.this)] = item
        elif item.GetNetname() in LOCAL_NETS:
            doomed[int(item.this)] = item
    # A route is a connected branch, not merely the first segment touching a
    # pad.  Preserve the broad GND/+3V3 distribution (their zones reconnect
    # reassigned pads), but fully remove every other old branch that terminated
    # at a pad whose physical function is changing.  This prevents downstream
    # remnants of the former logical pin order from surviving as misleading
    # copper islands or colliding with the replacement route.
    for pad, _ in pads:
        if pad.GetNetname() in {"GND", "+3V3"}:
            continue
        for item in connectivity.GetConnectedItems(pad):
            if isinstance(item, pcbnew.PCB_TRACK):
                doomed[int(item.this)] = item
    for item in doomed.values():
        board.Remove(item)
    return len(doomed)


def assign_nets(board, pads):
    for pad, netname in pads:
        if not netname:
            pad.SetNetCode(0)
            continue
        net = board.FindNet(netname)
        if net is None:
            raise RuntimeError(f"net {netname} missing")
        pad.SetNet(net)


def pad_points(board, netname, items, layer):
    points = []
    for item in items:
        if isinstance(item, pcbnew.PAD) and layer in copper_layers(item):
            p = item.GetPosition()
            point = (p.x / 1e6, p.y / 1e6)
            points.append(point)
    return points


def direct_route(board, netname, width):
    if netname in FIXED_LOCAL_PATHS:
        points = FIXED_LOCAL_PATHS[netname]
        router.add_tracks(board, netname, pcbnew.B_Cu, points, width)
        return f"fixed segments={len(points) - 1}"
    components = internal.signal_components(board).get(netname, [])
    if len(components) < 2:
        return "already connected"
    anchors = [pad_points(board, netname, items, pcbnew.B_Cu) for items in components]
    if any(not points for points in anchors):
        raise RuntimeError(f"{netname} component lacks a B.Cu pad")
    root = list(anchors[0])
    descriptions = []
    netcode = board.FindNet(netname).GetNetCode()
    router.ROUTE_RADIUS = width / 2
    for goals in anchors[1:]:
        result = None
        for grid in (0.25, 0.15):
            path = router.find_grid_path(board, netcode, pcbnew.B_Cu, root, goals, grid)
            if path:
                result = grid, path
                break
        if not result:
            raise RuntimeError(f"no clearance-safe B.Cu path for {netname}")
        grid, path = result
        router.add_tracks(board, netname, pcbnew.B_Cu, path, width)
        root.extend(goals)
        descriptions.append(f"grid={grid:.2f} segments={len(path)-1}")
    return "; ".join(descriptions)


def direct_pair(board, netname, first_ref, first_pad, second_ref, second_pad, width):
    first = board.FindFootprintByReference(first_ref).FindPadByNumber(first_pad)
    second = board.FindFootprintByReference(second_ref).FindPadByNumber(second_pad)
    starts = pad_points(board, netname, [first], pcbnew.B_Cu)
    goals = pad_points(board, netname, [second], pcbnew.B_Cu)
    router.ROUTE_RADIUS = width / 2
    netcode = board.FindNet(netname).GetNetCode()
    for grid in (0.25, 0.15):
        path = router.find_grid_path(board, netcode, pcbnew.B_Cu, starts, goals, grid)
        if path:
            router.add_tracks(board, netname, pcbnew.B_Cu, path, width)
            return f"grid={grid:.2f} segments={len(path)-1}"
    raise RuntimeError(f"no direct {netname} path from {first_ref}.{first_pad} to {second_ref}.{second_pad}")


def component_key(items):
    return tuple(sorted(str(item.m_Uuid.AsString()) for item in items if hasattr(item, "m_Uuid")))


def component_anchors(board, connectivity, items):
    points = [
        (via.GetPosition().x / 1e6, via.GetPosition().y / 1e6)
        for via in internal.component_vias(board, connectivity, items)
    ]
    for item in items:
        if not isinstance(item, pcbnew.PAD):
            continue
        layers = copper_layers(item)
        if pcbnew.In2_Cu in layers or pcbnew.In3_Cu in layers:
            position = item.GetPosition()
            point = (position.x / 1e6, position.y / 1e6)
            if point not in points:
                points.append(point)
    return points


def fallback_escape(board, pad, layer):
    """Fan straight out of a dense package, then find a clear through-via."""
    p = pad.GetPosition()
    center = pad.GetParentFootprint().GetPosition()
    sx, sy = p.x / 1e6, p.y / 1e6
    dx, dy = p.x - center.x, p.y - center.y
    sign_x = 1.0 if dx >= 0 else -1.0
    sign_y = 1.0 if dy >= 0 else -1.0
    directions = [(sign_x, 0.0), (0.0, sign_y), (sign_x, sign_y)]
    rectangles, circles, segments, via_rects, via_circles, via_segments, edges = escape.obstacles(board, pad, layer)
    candidates = []
    for ux, uy in directions:
        stub = (sx + ux * 0.9, sy + uy * 0.9)
        for ix in range(-40, 41):
            for iy in range(-40, 41):
                point = (stub[0] + ix * 0.15, stub[1] + iy * 0.15)
                if (point[0] - stub[0]) * ux + (point[1] - stub[1]) * uy < -0.01:
                    continue
                if not escape.via_clear(point[0], point[1], via_rects, via_circles, via_segments, edges):
                    continue
                if point != stub and not escape.segment_clear(
                    stub[0], stub[1], point[0], point[1], rectangles, circles, segments, edges
                ):
                    continue
                length = ((stub[0] - sx) ** 2 + (stub[1] - sy) ** 2) ** 0.5
                length += ((point[0] - stub[0]) ** 2 + (point[1] - stub[1]) ** 2) ** 0.5
                candidates.append((length, stub, point))
    if not candidates:
        # Dense SOT/QFN fan-outs can remain inside the conservative expanded
        # pad rectangles until the via site.  A straight radial neck is the
        # normal escape in that case; the exact-shape audit remains the gate.
        loose = []
        for ux, uy in directions:
            for ix in range(-40, 41):
                for iy in range(-40, 41):
                    point = (sx + ix * 0.15, sy + iy * 0.15)
                    vx, vy = point[0] - sx, point[1] - sy
                    if vx * ux + vy * uy < 0.6:
                        continue
                    if escape.via_clear(point[0], point[1], via_rects, via_circles, via_segments, edges):
                        loose.append((vx * vx + vy * vy, point))
        if not loose:
            return None
        _, endpoint = min(loose)
        return [(sx, sy), endpoint], True
    _, stub, endpoint = min(candidates)
    path = [(sx, sy), stub]
    if endpoint != stub:
        path.append(endpoint)
    return path, True


def grid_escape(board, pad, layer):
    """Find a shape-checked pad-to-via escape with the general A* router."""
    p = pad.GetPosition()
    sx, sy = p.x / 1e6, p.y / 1e6
    _, _, _, via_rects, via_circles, via_segments, edges = escape.obstacles(board, pad, layer)
    candidates = []
    step = 0.30
    for ix in range(-24, 25):
        for iy in range(-24, 25):
            if ix == 0 and iy == 0:
                continue
            if (ix * ix + iy * iy) * step * step < 1.20 * 1.20:
                continue
            x, y = sx + ix * step, sy + iy * step
            if escape.via_clear(x, y, via_rects, via_circles, via_segments, edges):
                candidates.append((ix * ix + iy * iy, (x, y)))
    candidates.sort()
    router.ROUTE_RADIUS = escape.TRACK_WIDTH / 2
    # Rasterize once per grid and let the A* search terminate at any of the
    # nearest clear via sites; rerasterizing for every candidate is needlessly
    # quadratic on this track-dense board.
    goals = [candidate for _, candidate in candidates[:12]]
    for grid in (0.25, 0.15):
        path = router.find_grid_path(
            board, pad.GetNetCode(), layer, [(sx, sy)], goals, grid
        )
        if path:
            return path, True
    return None


def add_escapes(board, affected):
    descriptions = []
    attempted = set()
    while True:
        board.BuildConnectivity()
        connectivity = board.GetConnectivity()
        target = None
        for pad, _ in affected:
            if not pad.GetNetname():
                continue
            if pad.GetNetname() in LOCAL_NETS:
                continue
            items = list(connectivity.GetConnectedItems(pad))
            key = component_key(items)
            if key in attempted:
                continue
            attempted.add(key)
            has_zone = any(isinstance(item, pcbnew.ZONE) for item in items)
            has_via = bool(internal.component_vias(board, connectivity, items))
            if (pad.GetNetname() in {"GND", "+3V3"} and has_zone) or has_via:
                continue
            candidates = sorted(
                (item for item in items if isinstance(item, pcbnew.PAD) and escape.primary_layer(item) is not None),
                key=lambda item: -item.GetSize().x * item.GetSize().y,
            )
            if not candidates:
                # Through-hole/thermal pads can connect directly to a plane.
                continue
            target = candidates[0]
            break
        if target is None:
            break
        layer = escape.primary_layer(target)
        identity = (target.GetParentFootprint().GetReference(), target.GetNumber())
        result = None
        if identity in {("U1", "27"), ("U9", "7"), ("U9", "8")}:
            result = grid_escape(board, target, layer)
        if not result:
            result = escape.find_path(board, target, layer)
        if not result:
            result = fallback_escape(board, target, layer)
        if not result:
            ref = target.GetParentFootprint().GetReference()
            raise RuntimeError(f"no escape for {ref}.{target.GetNumber()} {target.GetNetname()}")
        path, add_via = result
        escape.add_route(board, target, layer, path, add_via)
        descriptions.append(
            f"{target.GetParentFootprint().GetReference()}.{target.GetNumber()} "
            f"{target.GetNetname()} -> {path[-1][0]:.3f},{path[-1][1]:.3f}"
        )
    return descriptions


def add_missing_component_escapes(board):
    """Give every still-disconnected signal component an internal-layer anchor."""
    descriptions = []
    while True:
        board.BuildConnectivity()
        connectivity = board.GetConnectivity()
        target = None
        for netname, components in sorted(internal.signal_components(board).items()):
            if netname in LOCAL_NETS:
                continue
            for items in components:
                if component_anchors(board, connectivity, items):
                    continue
                candidates = sorted(
                    (item for item in items if isinstance(item, pcbnew.PAD) and escape.primary_layer(item) is not None),
                    key=lambda item: -item.GetSize().x * item.GetSize().y,
                )
                if not candidates:
                    raise RuntimeError(f"{netname} component has no escapable pad")
                target = candidates[0]
                break
            if target is not None:
                break
        if target is None:
            break
        layer = escape.primary_layer(target)
        identity = (target.GetParentFootprint().GetReference(), target.GetNumber())
        result = None
        if identity in {("U1", "27"), ("U9", "7"), ("U9", "8")}:
            result = grid_escape(board, target, layer)
        result = result or escape.find_path(board, target, layer) or fallback_escape(board, target, layer)
        if not result:
            raise RuntimeError(
                f"no component escape for {target.GetParentFootprint().GetReference()}."
                f"{target.GetNumber()} {target.GetNetname()}"
            )
        path, add_via = result
        escape.add_route(board, target, layer, path, add_via)
        descriptions.append(
            f"{target.GetParentFootprint().GetReference()}.{target.GetNumber()} "
            f"{target.GetNetname()} -> {path[-1][0]:.3f},{path[-1][1]:.3f}"
        )
    return descriptions


def add_fixed_u1_edge_escapes(board):
    """Fan the five reassigned U1 edge GPIOs straight toward the board edge."""
    descriptions = []
    for number in ("6", "8", "10", "12", "14"):
        pad = board.FindFootprintByReference("U1").FindPadByNumber(number)
        layer = escape.primary_layer(pad)
        p = pad.GetPosition()
        start = (p.x / 1e6, p.y / 1e6)
        rectangles, circles, segments, via_rects, via_circles, via_segments, edges = escape.obstacles(
            board, pad, layer
        )
        endpoint = None
        for step_index in range(6, 36):
            candidate = (start[0], start[1] + step_index * 0.15)
            if not escape.segment_clear(
                start[0], start[1], candidate[0], candidate[1],
                rectangles, circles, segments, edges,
            ):
                continue
            if escape.via_clear(
                candidate[0], candidate[1], via_rects, via_circles, via_segments, edges
            ):
                endpoint = candidate
                break
        if endpoint is None:
            raise RuntimeError(f"fixed U1.{number} has no straight edge via site")
        escape.add_route(board, pad, layer, [start, endpoint], True)
        descriptions.append(
            f"U1.{number} {pad.GetNetname()} -> {endpoint[0]:.3f},{endpoint[1]:.3f}"
        )
    return descriptions


def route_remaining(board):
    descriptions = []
    components_by_net = internal.signal_components(board)
    power_priority = {"SYS": 0, "+BAT": 1, "+5V": 2, "+5V_LED": 3}
    ordered_nets = sorted(
        components_by_net,
        key=lambda name: (power_priority.get(name, 10), name),
    )
    for netname in ordered_nets:
        components = components_by_net[netname]
        if netname in {"GND", "+3V3"} or netname in LOCAL_NETS:
            continue
        board.BuildConnectivity()
        connectivity = board.GetConnectivity()
        anchors = []
        for items in components:
            points = component_anchors(board, connectivity, items)
            if not points:
                raise RuntimeError(f"{netname} component lacks an escape via")
            anchors.append(points)
        root = list(anchors[0])
        width = POWER_WIDTHS.get(netname, 0.26 if netname.startswith("USB_D") else 0.20)
        netcode = board.FindNet(netname).GetNetCode()
        net_routes = []
        for goal_index, goals in enumerate(anchors[1:], start=1):
            result = None
            # Use the nominal 0.50 mm power width wherever it fits, with a
            # 0.35 mm neck only when a dense escape cannot be reached at full
            # width.  Both exceed the board's ordinary 0.20 mm signal width.
            widths = (width, 0.35) if netname in POWER_WIDTHS else (width,)
            for route_width in widths:
                router.ROUTE_RADIUS = route_width / 2
                # Prefer the two signal planes, but permit an outer-layer
                # detour around locally dense packages.  The obstacle model
                # includes all pads/tracks on the selected layer.
                for grid in (0.50, 0.25, 0.15, 0.10):
                    for layer in (pcbnew.In2_Cu, pcbnew.In3_Cu, pcbnew.F_Cu, pcbnew.B_Cu):
                        path = router.find_grid_path(board, netcode, layer, root, goals, grid)
                        if path:
                            result = layer, grid, path, route_width
                            break
                    if result:
                        break
                if result:
                    break
            if not result:
                raise RuntimeError(
                    f"no internal path for {netname} component {goal_index}; "
                    f"root={root}; goals={goals}"
                )
            layer, grid, path, route_width = result
            router.add_tracks(board, netname, layer, path, route_width)
            root.extend(goals)
            net_routes.append(
                f"{board.GetLayerName(layer)} {route_width:.2f}w "
                f"{grid:.2f}g/{len(path)-1}"
            )
        descriptions.append(f"{netname}: " + ", ".join(net_routes))
    return descriptions


def prepare():
    board = pcbnew.LoadBoard(str(SOURCE))
    affected = changed_pads(board)
    print(f"stage affected={len(affected)}", flush=True)
    if not affected:
        raise RuntimeError("board pinouts already assigned")
    removed = rip_affected_copper(board, affected)
    print(f"stage ripped={removed}", flush=True)
    assign_nets(board, affected)
    print("stage assigned", flush=True)
    if not pcbnew.SaveBoard(str(INTERMEDIATE), board):
        raise RuntimeError("intermediate save failed")
    print(f"prepared {INTERMEDIATE}", flush=True)


def rotate_u4():
    board = pcbnew.LoadBoard(str(INTERMEDIATE))
    # The original 180-degree placement pointed the TPS63031 switch pins away
    # from L1.  Rotate it so both short switch nodes exit toward the inductor.
    board.FindFootprintByReference("U4").SetOrientationDegrees(0)
    if not pcbnew.SaveBoard(str(ROTATED), board):
        raise RuntimeError("rotated intermediate save failed")
    print(f"rotated U4 -> {ROTATED}")


def route():
    board = pcbnew.LoadBoard(str(ROTATED))
    affected = desired_pads(board)
    print("stage reloaded", flush=True)

    # Freerouting imports can contain distinct copper items that share a UUID.
    # Start replacement routing from a genuinely clean set of every affected
    # non-plane net, independent of those imported identifiers.
    rebuild_nets = {
        netname for assignments in DESIRED.values() for netname in assignments.values()
        if netname and netname not in {"GND", "+3V3"}
    }
    stale = [item for item in board.GetTracks() if item.GetNetname() in rebuild_nets]
    for item in stale:
        board.Remove(item)
    survivors = [item.GetNetname() for item in board.GetTracks() if item.GetNetname() in rebuild_nets]
    if survivors:
        raise RuntimeError(f"affected-net rip-up left {len(survivors)} copper items")
    print(f"stage clean-net rip={len(stale)}", flush=True)

    direct = []
    for net, width in LOCAL_NETS.items():
        print(f"stage local {net}", flush=True)
        direct.append(f"{net}: {direct_route(board, net, width)}")
    print("stage local complete", flush=True)
    escapes = add_escapes(board, affected)
    escapes.extend(add_missing_component_escapes(board))
    print(f"stage escapes={len(escapes)}", flush=True)
    if not pcbnew.ZONE_FILLER(board).Fill(board.Zones()):
        raise RuntimeError("zone fill failed after escapes")
    if not pcbnew.SaveBoard(str(ESCAPED), board):
        raise RuntimeError("escaped intermediate save failed")
    print(f"saved {ESCAPED}")
    print("LOCAL\n" + "\n".join(direct))
    print("ESCAPES\n" + "\n".join(escapes))


def finish():
    board = pcbnew.LoadBoard(str(ESCAPED))
    remaining = route_remaining(board)
    # The pin reassignment can leave an old, padless copper stub whose former
    # endpoint changed nets.  It is not part of any pad component and KiCad
    # still counts it as a ratsnest open, so remove only fully isolated track
    # items after the replacement routes exist.
    board.BuildConnectivity()
    connectivity = board.GetConnectivity()
    isolated = [
        item for item in board.GetTracks()
        if len(list(connectivity.GetConnectedItems(item))) <= 1
    ]
    for item in isolated:
        board.Remove(item)
    if not pcbnew.ZONE_FILLER(board).Fill(board.Zones()):
        raise RuntimeError("final zone fill failed")
    opens = internal.count_unconnected(board)
    if opens:
        diagnostic = OUTPUT.with_name(OUTPUT.stem + "_opencheck.kicad_pcb")
        pcbnew.SaveBoard(str(diagnostic), board)
        remaining_nets = {
            name: len(parts)
            for name, parts in internal.signal_components(board).items()
            if len(parts) > 1
        }
        raise RuntimeError(
            f"pinout repair left {opens} unconnected pads; "
            f"components={remaining_nets}; saved {diagnostic}"
        )
    if not pcbnew.SaveBoard(str(OUTPUT), board):
        raise RuntimeError("save failed")
    print("unconnected=0")
    print(f"isolated_copper_removed={len(isolated)}")
    print("INTERNAL\n" + "\n".join(remaining))


if __name__ == "__main__":
    if "--prepare" in sys.argv:
        prepare()
    elif "--rotate-u4" in sys.argv:
        rotate_u4()
    elif "--route" in sys.argv:
        route()
    elif "--finish" in sys.argv:
        finish()
    else:
        raise SystemExit("use --prepare then --route")
