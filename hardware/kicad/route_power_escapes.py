#!/Applications/KiCad/KiCad.app/Contents/Frameworks/Python.framework/Versions/3.9/bin/python3.9
"""Route bent GND/+3V3 dogbones to their internal planes on a 45-degree grid."""

from __future__ import annotations

import heapq
import math
import shutil
from pathlib import Path

import pcbnew


ROOT = Path(__file__).resolve().parent
SOURCE = ROOT / "focalpoint_radio_bottomright_6layer_powerescape_pass3_candidate.kicad_pcb"
OUTPUT = ROOT / "focalpoint_radio_bottomright_6layer_powerescape_pass4_candidate.kicad_pcb"
REPORT = ROOT / "power_escape_report.txt"

MM = pcbnew.FromMM
GRID = 0.15
MAX_RADIUS = 18.0
CLEARANCE = 0.15
TRACK_WIDTH = 0.18
TRACK_RADIUS = TRACK_WIDTH / 2
VIA_DIAMETER = 0.60
VIA_RADIUS = VIA_DIAMETER / 2
VIA_DRILL = 0.40
EDGE_MIN, EDGE_MAX = 100.0, 216.0


def point_segment_distance(px, py, ax, ay, bx, by):
    dx, dy = bx - ax, by - ay
    denominator = dx * dx + dy * dy
    if denominator == 0:
        return math.hypot(px - ax, py - ay)
    t = max(0.0, min(1.0, ((px - ax) * dx + (py - ay) * dy) / denominator))
    return math.hypot(px - ax - t * dx, py - ay - t * dy)


def segments_intersect(ax, ay, bx, by, cx, cy, dx, dy):
    def orient(px, py, qx, qy, rx, ry):
        value = (qy - py) * (rx - qx) - (qx - px) * (ry - qy)
        if abs(value) < 1e-9:
            return 0
        return 1 if value > 0 else 2

    return (
        orient(ax, ay, bx, by, cx, cy) != orient(ax, ay, bx, by, dx, dy)
        and orient(cx, cy, dx, dy, ax, ay) != orient(cx, cy, dx, dy, bx, by)
    )


def segment_distance(ax, ay, bx, by, cx, cy, dx, dy):
    if segments_intersect(ax, ay, bx, by, cx, cy, dx, dy):
        return 0.0
    return min(
        point_segment_distance(ax, ay, cx, cy, dx, dy),
        point_segment_distance(bx, by, cx, cy, dx, dy),
        point_segment_distance(cx, cy, ax, ay, bx, by),
        point_segment_distance(dx, dy, ax, ay, bx, by),
    )


def segment_intersects_rect(ax, ay, bx, by, x0, y0, x1, y1):
    """Liang-Barsky intersection against an axis-aligned rectangle."""
    dx, dy = bx - ax, by - ay
    lower, upper = 0.0, 1.0
    for p, q in ((-dx, ax - x0), (dx, x1 - ax), (-dy, ay - y0), (dy, y1 - ay)):
        if abs(p) < 1e-12:
            if q < 0:
                return False
            continue
        ratio = q / p
        if p < 0:
            lower = max(lower, ratio)
        else:
            upper = min(upper, ratio)
        if lower > upper:
            return False
    return True


def copper_layers(item):
    return set(item.GetLayerSet().Seq())


def primary_layer(pad):
    layers = copper_layers(pad)
    if pcbnew.F_Cu in layers and pcbnew.B_Cu not in layers:
        return pcbnew.F_Cu
    if pcbnew.B_Cu in layers and pcbnew.F_Cu not in layers:
        return pcbnew.B_Cu
    return None


def isolated_power_targets(board):
    board.BuildConnectivity()
    connectivity = board.GetConnectivity()
    seen = set()
    targets = []
    for footprint in board.GetFootprints():
        for pad in footprint.Pads():
            if pad.GetNetname() not in {"GND", "+3V3"}:
                continue
            items = list(connectivity.GetConnectedItems(pad))
            component = tuple(
                sorted(str(item.m_Uuid.AsString()) for item in items if hasattr(item, "m_Uuid"))
            )
            if component in seen or any(isinstance(item, pcbnew.ZONE) for item in items):
                continue
            seen.add(component)
            pads = sorted(
                (item for item in items if isinstance(item, pcbnew.PAD)),
                key=lambda item: (item.GetParentFootprint().GetReference(), item.GetNumber()),
            )
            targets.append(pads[0] if pads else pad)
    return sorted(
        targets,
        key=lambda pad: (pad.GetNetname(), pad.GetParentFootprint().GetReference(), pad.GetNumber()),
    )


def edge_segments(board):
    shapes = list(board.GetDrawings())
    for footprint in board.GetFootprints():
        shapes.extend(footprint.GraphicalItems())
    result = []
    for shape in shapes:
        if shape.GetLayer() != pcbnew.Edge_Cuts:
            continue
        bbox = shape.GetBoundingBox()
        if bbox.GetWidth() / 1e6 > 50 or bbox.GetHeight() / 1e6 > 50:
            continue
        try:
            start, end = shape.GetStart(), shape.GetEnd()
            result.append((start.x / 1e6, start.y / 1e6, end.x / 1e6, end.y / 1e6))
        except AttributeError:
            pass
    return result


def obstacles(board, pad, layer):
    net = pad.GetNetCode()
    rectangles = []
    segments = []
    via_rectangles = []
    track_circles = []
    via_circles = []
    via_segments = []
    for footprint in board.GetFootprints():
        for other in footprint.Pads():
            if other is pad or other.GetNetCode() == net:
                continue
            layers = copper_layers(other)
            bbox = other.GetBoundingBox()
            x0, y0 = bbox.GetX() / 1e6, bbox.GetY() / 1e6
            x1, y1 = x0 + bbox.GetWidth() / 1e6, y0 + bbox.GetHeight() / 1e6
            if layer in layers:
                margin = TRACK_RADIUS + CLEARANCE
                rectangles.append((x0 - margin, y0 - margin, x1 + margin, y1 + margin))
            if pcbnew.F_Cu in layers or pcbnew.B_Cu in layers:
                margin = VIA_RADIUS + CLEARANCE
                via_rectangles.append((x0 - margin, y0 - margin, x1 + margin, y1 + margin))
    for item in board.GetTracks():
        if item.GetNetCode() == net:
            continue
        if isinstance(item, pcbnew.PCB_VIA):
            position = item.GetPosition()
            radius = item.GetWidth(pcbnew.F_Cu) / 2e6
            if layer in copper_layers(item):
                track_circles.append((position.x / 1e6, position.y / 1e6, radius + TRACK_RADIUS + CLEARANCE))
            via_circles.append((position.x / 1e6, position.y / 1e6, radius + VIA_RADIUS + CLEARANCE))
        elif type(item).__name__ == "PCB_TRACK":
            start, end = item.GetStart(), item.GetEnd()
            geometry = (
                start.x / 1e6,
                start.y / 1e6,
                end.x / 1e6,
                end.y / 1e6,
                item.GetWidth() / 2e6,
            )
            if item.GetLayer() == layer:
                segments.append((*geometry[:4], geometry[4] + TRACK_RADIUS + CLEARANCE))
            # A through via occupies every copper layer, not only the two
            # outer layers.  Earlier routing could therefore select a via
            # site that clipped an internal signal trace.
            if pcbnew.IsCopperLayer(item.GetLayer()):
                via_segments.append((*geometry[:4], geometry[4] + VIA_RADIUS + CLEARANCE))
    return rectangles, track_circles, segments, via_rectangles, via_circles, via_segments, edge_segments(board)


def segment_clear(ax, ay, bx, by, rectangles, circles, segments, edges):
    if not (
        EDGE_MIN + TRACK_RADIUS + CLEARANCE <= bx <= EDGE_MAX - TRACK_RADIUS - CLEARANCE
        and EDGE_MIN + TRACK_RADIUS + CLEARANCE <= by <= EDGE_MAX - TRACK_RADIUS - CLEARANCE
    ):
        return False
    for x0, y0, x1, y1 in rectangles:
        if segment_intersects_rect(ax, ay, bx, by, x0, y0, x1, y1):
            return False
    for x, y, radius in circles:
        if point_segment_distance(x, y, ax, ay, bx, by) < radius:
            return False
    for cx, cy, dx, dy, radius in segments:
        if segment_distance(ax, ay, bx, by, cx, cy, dx, dy) < radius:
            return False
    for cx, cy, dx, dy in edges:
        if segment_distance(ax, ay, bx, by, cx, cy, dx, dy) < TRACK_RADIUS + CLEARANCE:
            return False
    return True


def via_clear(x, y, via_rectangles, via_circles, via_segments, edges):
    if not (
        EDGE_MIN + VIA_RADIUS + CLEARANCE <= x <= EDGE_MAX - VIA_RADIUS - CLEARANCE
        and EDGE_MIN + VIA_RADIUS + CLEARANCE <= y <= EDGE_MAX - VIA_RADIUS - CLEARANCE
    ):
        return False
    if any(x0 <= x <= x1 and y0 <= y <= y1 for x0, y0, x1, y1 in via_rectangles):
        return False
    if any(math.hypot(x - cx, y - cy) < radius for cx, cy, radius in via_circles):
        return False
    if any(point_segment_distance(x, y, ax, ay, bx, by) < radius for ax, ay, bx, by, radius in via_segments):
        return False
    if any(point_segment_distance(x, y, ax, ay, bx, by) < VIA_RADIUS + CLEARANCE for ax, ay, bx, by in edges):
        return False
    return True


def find_path(board, pad, layer):
    sx, sy = pad.GetPosition().x / 1e6, pad.GetPosition().y / 1e6
    rectangles, circles, segments, via_rectangles, via_circles, via_segments, edges = obstacles(board, pad, layer)
    directions = ((1, 0), (-1, 0), (0, 1), (0, -1), (1, 1), (1, -1), (-1, 1), (-1, -1))
    start = (0, 0)
    queue = [(0.0, start)]
    distance = {start: 0.0}
    parent = {start: None}
    limit = int(MAX_RADIUS / GRID)
    board.BuildConnectivity()
    connectivity = board.GetConnectivity()
    existing_goals = []
    for item in board.GetTracks():
        if not isinstance(item, pcbnew.PCB_VIA) or item.GetNetCode() != pad.GetNetCode():
            continue
        connected = list(connectivity.GetConnectedItems(item))
        if any(isinstance(other, pcbnew.ZONE) for other in connected):
            position = item.GetPosition()
            existing_goals.append((position.x / 1e6, position.y / 1e6))
    goal = None
    exact_goal = None
    add_via = True
    while queue:
        cost, current = heapq.heappop(queue)
        if cost != distance[current]:
            continue
        ix, iy = current
        x, y = sx + ix * GRID, sy + iy * GRID
        for gx, gy in existing_goals:
            if math.hypot(gx - x, gy - y) <= GRID * 1.6 and segment_clear(
                x, y, gx, gy, rectangles, circles, segments, edges
            ):
                goal = current
                exact_goal = (gx, gy)
                add_via = False
                break
        if goal is not None:
            break
        if cost >= 1.10 and via_clear(x, y, via_rectangles, via_circles, via_segments, edges):
            goal = current
            break
        for dx, dy in directions:
            neighbor = (ix + dx, iy + dy)
            if max(abs(neighbor[0]), abs(neighbor[1])) > limit:
                continue
            nx, ny = sx + neighbor[0] * GRID, sy + neighbor[1] * GRID
            if not segment_clear(x, y, nx, ny, rectangles, circles, segments, edges):
                continue
            new_cost = cost + GRID * (math.sqrt(2) if dx and dy else 1)
            if new_cost + 1e-9 < distance.get(neighbor, math.inf):
                distance[neighbor] = new_cost
                parent[neighbor] = current
                heapq.heappush(queue, (new_cost, neighbor))
    if goal is None:
        return None
    indices = []
    current = goal
    while current is not None:
        indices.append(current)
        current = parent[current]
    indices.reverse()
    points = [(sx + ix * GRID, sy + iy * GRID) for ix, iy in indices]
    if exact_goal is not None and points[-1] != exact_goal:
        points.append(exact_goal)
    simplified = [points[0]]
    for index in range(1, len(points) - 1):
        ax, ay = simplified[-1]
        bx, by = points[index]
        cx, cy = points[index + 1]
        if abs((bx - ax) * (cy - by) - (by - ay) * (cx - bx)) > 1e-9:
            simplified.append((bx, by))
    simplified.append(points[-1])
    return simplified, add_via


def add_route(board, pad, layer, points, add_via):
    for start, end in zip(points, points[1:]):
        track = pcbnew.PCB_TRACK(board)
        track.SetStart(pcbnew.VECTOR2I(MM(start[0]), MM(start[1])))
        track.SetEnd(pcbnew.VECTOR2I(MM(end[0]), MM(end[1])))
        track.SetLayer(layer)
        track.SetWidth(MM(TRACK_WIDTH))
        track.SetNetCode(pad.GetNetCode())
        board.Add(track)
    if add_via:
        endpoint = points[-1]
        via = pcbnew.PCB_VIA(board)
        via.SetPosition(pcbnew.VECTOR2I(MM(endpoint[0]), MM(endpoint[1])))
        via.SetLayerPair(pcbnew.F_Cu, pcbnew.B_Cu)
        via.SetWidth(MM(VIA_DIAMETER))
        via.SetDrill(MM(VIA_DRILL))
        via.SetNetCode(pad.GetNetCode())
        board.Add(via)


def count_unconnected(board):
    board.BuildConnectivity()
    connectivity = board.GetConnectivity()
    connectivity.RecalculateRatsnest()
    return connectivity.GetUnconnectedCount(False)


def main():
    board = pcbnew.LoadBoard(str(SOURCE))
    before = count_unconnected(board)
    routed = []
    skipped = []
    for pad in isolated_power_targets(board):
        reference = pad.GetParentFootprint().GetReference()
        label = f"{reference}.{pad.GetNumber()} {pad.GetNetname()}"
        layer = primary_layer(pad)
        if layer is None:
            skipped.append(f"{label}: not a single-side SMD pad")
            continue
        result = find_path(board, pad, layer)
        if not result:
            skipped.append(f"{label}: no clearance-safe path within {MAX_RADIUS:.1f} mm")
            continue
        path, add_via = result
        add_route(board, pad, layer, path, add_via)
        routed.append(
            f"{label}: {len(path) - 1} segments to {path[-1][0]:.3f},{path[-1][1]:.3f} "
            f"({'new via' if add_via else 'existing via'})"
        )
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
        raise RuntimeError(f"power routing did not improve connectivity: {before} -> {after}")
    if not pcbnew.SaveBoard(str(OUTPUT), board):
        raise RuntimeError("save failed")
    for suffix in (".kicad_pro", ".rules"):
        companion = SOURCE.with_suffix(suffix)
        if companion.exists():
            shutil.copy2(companion, OUTPUT.with_suffix(suffix))


if __name__ == "__main__":
    main()
