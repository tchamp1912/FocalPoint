#!/Applications/KiCad/KiCad.app/Contents/Frameworks/Python.framework/Versions/3.9/bin/python3.9
"""Join escaped signal components across the sparse In2/In4 copper layers."""

from __future__ import annotations

import math
import shutil
from pathlib import Path

import pcbnew

import route_power_escapes as geometry


ROOT = Path(__file__).resolve().parent
SOURCE = ROOT / "focalpoint_radio_bottomright_6layer_signal_escapes_candidate.kicad_pcb"
OUTPUT = ROOT / "focalpoint_radio_bottomright_6layer_internal_routed_candidate.kicad_pcb"
REPORT = ROOT / "internal_signal_route_report.txt"

MM = pcbnew.FromMM
GRID = 0.50
WIDTH = 0.20
CLEARANCE = 0.15
RADIUS = WIDTH / 2
EDGE_MIN, EDGE_MAX = 100.0, 216.0


def count_unconnected(board):
    board.BuildConnectivity()
    connectivity = board.GetConnectivity()
    connectivity.RecalculateRatsnest()
    return connectivity.GetUnconnectedCount(False)


def signal_components(board):
    board.BuildConnectivity()
    connectivity = board.GetConnectivity()
    by_net = {}
    for footprint in board.GetFootprints():
        for pad in footprint.Pads():
            net = pad.GetNetname()
            if not net or net in {"GND", "+3V3"}:
                continue
            items = list(connectivity.GetConnectedItems(pad))
            component = tuple(
                sorted(str(item.m_Uuid.AsString()) for item in items if hasattr(item, "m_Uuid"))
            )
            by_net.setdefault(net, {}).setdefault(component, items)
    return {
        net: list(components.values())
        for net, components in by_net.items()
        if len(components) > 1
    }


def component_vias(board, connectivity, items):
    """Find vias touching a component; KiCad's pad query omits vias asymmetrically."""
    item_ids = {
        str(item.m_Uuid.AsString()) for item in items if hasattr(item, "m_Uuid")
    }
    netcodes = {item.GetNetCode() for item in items if hasattr(item, "GetNetCode")}
    result = []
    for via in board.GetTracks():
        if not isinstance(via, pcbnew.PCB_VIA) or via.GetNetCode() not in netcodes:
            continue
        connected_ids = {
            str(item.m_Uuid.AsString())
            for item in connectivity.GetConnectedItems(via)
            if hasattr(item, "m_Uuid")
        }
        if item_ids & connected_ids:
            result.append(via)
    return result


def layer_obstacles(board, netcode, layer):
    circles = []
    segments = []
    for footprint in board.GetFootprints():
        for pad in footprint.Pads():
            if pad.GetNetCode() == netcode or layer not in set(pad.GetLayerSet().Seq()):
                continue
            position = pad.GetPosition()
            # A max(width,height)/2 circle is inscribed for rectangular pads
            # and permits routes to clip their corners.  Use the circumscribed
            # radius so the raster router is conservative for every rotation.
            size = pad.GetSize()
            radius = math.hypot(size.x, size.y) / 2e6 + RADIUS + CLEARANCE
            circles.append((position.x / 1e6, position.y / 1e6, radius))
    for item in board.GetTracks():
        if item.GetNetCode() == netcode:
            continue
        if isinstance(item, pcbnew.PCB_VIA):
            if layer not in set(item.GetLayerSet().Seq()):
                continue
            position = item.GetPosition()
            radius = item.GetWidth(layer) / 2e6 + RADIUS + CLEARANCE
            circles.append((position.x / 1e6, position.y / 1e6, radius))
        elif type(item).__name__ == "PCB_TRACK" and item.GetLayer() == layer:
            start, end = item.GetStart(), item.GetEnd()
            segments.append(
                (
                    start.x / 1e6,
                    start.y / 1e6,
                    end.x / 1e6,
                    end.y / 1e6,
                    item.GetWidth() / 2e6 + RADIUS + CLEARANCE,
                )
            )
    return circles, segments, geometry.edge_segments(board)


def clear_segment(ax, ay, bx, by, circles, segments, edges):
    if not (
        EDGE_MIN + RADIUS + CLEARANCE <= bx <= EDGE_MAX - RADIUS - CLEARANCE
        and EDGE_MIN + RADIUS + CLEARANCE <= by <= EDGE_MAX - RADIUS - CLEARANCE
    ):
        return False
    for x, y, radius in circles:
        if geometry.point_segment_distance(x, y, ax, ay, bx, by) < radius:
            return False
    for cx, cy, dx, dy, radius in segments:
        if geometry.segment_distance(ax, ay, bx, by, cx, cy, dx, dy) < radius:
            return False
    for cx, cy, dx, dy in edges:
        if geometry.segment_distance(ax, ay, bx, by, cx, cy, dx, dy) < RADIUS + CLEARANCE:
            return False
    return True


def find_path(board, netcode, layer, start, goal, margin):
    circles, segments, edges = layer_obstacles(board, netcode, layer)
    sx, sy = start
    gx, gy = goal
    candidates = [[start, goal], [start, (gx, sy), goal], [start, (sx, gy), goal]]

    dx, dy = gx - sx, gy - sy
    if dx and dy:
        sign_x = 1 if dx > 0 else -1
        sign_y = 1 if dy > 0 else -1
        if abs(dx) >= abs(dy):
            candidates.append([start, (sx + sign_x * abs(dy), gy), goal])
            candidates.append([start, (gx - sign_x * abs(dy), sy), goal])
        else:
            candidates.append([start, (gx, sy + sign_y * abs(dx)), goal])
            candidates.append([start, (sx, gy - sign_y * abs(dx)), goal])

    min_x = max(EDGE_MIN + 1.0, min(sx, gx) - margin)
    max_x = min(EDGE_MAX - 1.0, max(sx, gx) + margin)
    min_y = max(EDGE_MIN + 1.0, min(sy, gy) - margin)
    max_y = min(EDGE_MAX - 1.0, max(sy, gy) + margin)
    value = math.ceil(min_x / 2.0) * 2.0
    while value <= max_x:
        candidates.append([start, (value, sy), (value, gy), goal])
        value += 2.0
    value = math.ceil(min_y / 2.0) * 2.0
    while value <= max_y:
        candidates.append([start, (sx, value), (gx, value), goal])
        value += 2.0

    # A bounded set of two-segment corridors catches sparse internal-layer
    # routes that the orthogonal/45-degree templates cannot reach.  These are
    # ordinary straight PCB segments; the coarse 4 mm grid keeps this finite.
    x = math.ceil(min_x / 4.0) * 4.0
    while x <= max_x:
        y = math.ceil(min_y / 4.0) * 4.0
        while y <= max_y:
            candidates.append([start, (x, y), goal])
            y += 4.0
        x += 4.0

    valid = []
    for points in candidates:
        compact = [points[0]]
        for point in points[1:]:
            if point != compact[-1]:
                compact.append(point)
        if all(
            clear_segment(a[0], a[1], b[0], b[1], circles, segments, edges)
            for a, b in zip(compact, compact[1:])
        ):
            length = sum(math.hypot(b[0] - a[0], b[1] - a[1]) for a, b in zip(compact, compact[1:]))
            valid.append((length, compact))
    return min(valid, key=lambda item: item[0])[1] if valid else None


def find_best_path(board, netcode, starts, goals):
    """Choose the shortest valid path across every available escape-via pair."""
    valid = []
    for start in starts:
        for goal in goals:
            for layer in (pcbnew.In2_Cu, pcbnew.In4_Cu):
                for margin in (8.0, 16.0, 30.0):
                    path = find_path(board, netcode, layer, start, goal, margin)
                    if path:
                        length = sum(
                            math.hypot(b[0] - a[0], b[1] - a[1])
                            for a, b in zip(path, path[1:])
                        )
                        valid.append((length, layer, path))
                        break
    return min(valid, key=lambda item: item[0]) if valid else None


def add_tracks(board, netcode, layer, points):
    for start, end in zip(points, points[1:]):
        track = pcbnew.PCB_TRACK(board)
        track.SetStart(pcbnew.VECTOR2I(MM(start[0]), MM(start[1])))
        track.SetEnd(pcbnew.VECTOR2I(MM(end[0]), MM(end[1])))
        track.SetLayer(layer)
        track.SetWidth(MM(WIDTH))
        track.SetNetCode(netcode)
        board.Add(track)


def main():
    board = pcbnew.LoadBoard(str(SOURCE))
    before = count_unconnected(board)
    board.BuildConnectivity()
    connectivity = board.GetConnectivity()
    routed = []
    skipped = []
    for net, components in sorted(signal_components(board).items()):
        anchor_sets = []
        complete = True
        for items in components:
            vias = component_vias(board, connectivity, items)
            if not vias:
                complete = False
                break
            anchor_sets.append(
                [
                    (via.GetPosition().x / 1e6, via.GetPosition().y / 1e6)
                    for via in vias
                ]
            )
        if not complete:
            skipped.append(f"{net}: not every component has an escape via")
            continue
        root = anchor_sets[0]
        netcode = board.FindNet(net).GetNetCode()
        success = True
        net_routes = []
        for anchors in anchor_sets[1:]:
            result = find_best_path(board, netcode, anchors, root)
            if not result:
                success = False
                break
            _, selected_layer, path = result
            add_tracks(board, netcode, selected_layer, path)
            net_routes.append((selected_layer, len(path) - 1))
            root.extend(anchors)
        if success:
            details = ", ".join(
                f"{board.GetLayerName(layer)}:{segments}" for layer, segments in net_routes
            )
            routed.append(f"{net}: {len(anchor_sets)} components ({details})")
        else:
            skipped.append(f"{net}: no internal-layer path")
    if not pcbnew.ZONE_FILLER(board).Fill(board.Zones()):
        raise RuntimeError("zone fill failed")
    after = count_unconnected(board)
    text = (
        f"unconnected_before={before}\nunconnected_after={after}\n"
        f"routed={len(routed)}\n" + "\n".join(routed) + "\n\n"
        f"skipped={len(skipped)}\n" + "\n".join(skipped) + "\n"
    )
    REPORT.write_text(text)
    print(text)
    if after >= before:
        raise RuntimeError(f"internal routing did not improve connectivity: {before} -> {after}")
    if not pcbnew.SaveBoard(str(OUTPUT), board):
        raise RuntimeError("save failed")
    for suffix in (".kicad_pro", ".rules"):
        companion = SOURCE.with_suffix(suffix)
        if companion.exists():
            shutil.copy2(companion, OUTPUT.with_suffix(suffix))


if __name__ == "__main__":
    main()
