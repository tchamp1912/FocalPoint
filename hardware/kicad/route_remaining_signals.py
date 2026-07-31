#!/Applications/KiCad/KiCad.app/Contents/Frameworks/Python.framework/Versions/3.9/bin/python3.9
"""Route the final escaped signal components on sparse internal layers."""

from __future__ import annotations

import heapq
import math
import shutil
from pathlib import Path

import pcbnew

import route_internal_signals as internal


ROOT = Path(__file__).resolve().parent
SOURCE = ROOT / "focalpoint_radio_bottomright_6layer_vip_candidate.kicad_pcb"
OUTPUT = ROOT / "focalpoint_radio_bottomright_6layer_zero_open_candidate.kicad_pcb"
REPORT = ROOT / "remaining_signal_route_report.txt"
MM = pcbnew.FromMM
EDGE_MIN, EDGE_MAX = 100.0, 216.0
CLEARANCE = 0.15
ROUTE_RADIUS = 0.13  # Conservative for the 0.26 mm USB route.


def board_point(ix, iy, grid):
    return EDGE_MIN + 0.5 + ix * grid, EDGE_MIN + 0.5 + iy * grid


def grid_shape(grid):
    count = int(math.floor((EDGE_MAX - EDGE_MIN - 1.0) / grid)) + 1
    return count, count


def raster_obstacles(board, netcode, layer, grid):
    internal.RADIUS = ROUTE_RADIUS
    circles, segments, _ = internal.layer_obstacles(board, netcode, layer)
    nx, ny = grid_shape(grid)
    blocked = set()
    guard = grid * math.sqrt(2) / 2

    def index_bounds(x0, y0, x1, y1):
        ix0 = max(0, int(math.floor((x0 - EDGE_MIN - 0.5) / grid)))
        iy0 = max(0, int(math.floor((y0 - EDGE_MIN - 0.5) / grid)))
        ix1 = min(nx - 1, int(math.ceil((x1 - EDGE_MIN - 0.5) / grid)))
        iy1 = min(ny - 1, int(math.ceil((y1 - EDGE_MIN - 0.5) / grid)))
        return ix0, iy0, ix1, iy1

    for x, y, radius in circles:
        limit = radius + guard
        ix0, iy0, ix1, iy1 = index_bounds(x - limit, y - limit, x + limit, y + limit)
        for ix in range(ix0, ix1 + 1):
            for iy in range(iy0, iy1 + 1):
                px, py = board_point(ix, iy, grid)
                if math.hypot(px - x, py - y) < limit:
                    blocked.add((ix, iy))
    for ax, ay, bx, by, radius in segments:
        limit = radius + guard
        ix0, iy0, ix1, iy1 = index_bounds(
            min(ax, bx) - limit,
            min(ay, by) - limit,
            max(ax, bx) + limit,
            max(ay, by) + limit,
        )
        for ix in range(ix0, ix1 + 1):
            for iy in range(iy0, iy1 + 1):
                px, py = board_point(ix, iy, grid)
                if internal.geometry.point_segment_distance(px, py, ax, ay, bx, by) < limit:
                    blocked.add((ix, iy))
    return blocked, nx, ny


def endpoint_nodes(board, netcode, layer, point, grid, blocked, nx, ny, obstacles=None):
    internal.RADIUS = ROUTE_RADIUS
    if obstacles is None:
        obstacles = internal.layer_obstacles(board, netcode, layer)
    circles, segments, edges = obstacles
    x, y = point
    center_ix = int(round((x - EDGE_MIN - 0.5) / grid))
    center_iy = int(round((y - EDGE_MIN - 0.5) / grid))
    radius = max(2, int(math.ceil(1.5 / grid)))
    result = {}
    for ix in range(max(0, center_ix - radius), min(nx, center_ix + radius + 1)):
        for iy in range(max(0, center_iy - radius), min(ny, center_iy + radius + 1)):
            node = (ix, iy)
            if node in blocked:
                continue
            px, py = board_point(ix, iy, grid)
            if math.hypot(px - x, py - y) > 1.5:
                continue
            if internal.clear_segment(x, y, px, py, circles, segments, edges):
                result[node] = math.hypot(px - x, py - y)
    return result


def find_grid_path(board, netcode, layer, starts, goals, grid):
    blocked, nx, ny = raster_obstacles(board, netcode, layer, grid)
    endpoint_obstacles = internal.layer_obstacles(board, netcode, layer)
    source_nodes = {}
    for point in starts:
        for node, cost in endpoint_nodes(
            board, netcode, layer, point, grid, blocked, nx, ny, endpoint_obstacles
        ).items():
            if node not in source_nodes or cost < source_nodes[node][0]:
                source_nodes[node] = (cost, point)
    goal_nodes = {}
    for point in goals:
        for node, cost in endpoint_nodes(
            board, netcode, layer, point, grid, blocked, nx, ny, endpoint_obstacles
        ).items():
            if node not in goal_nodes or cost < goal_nodes[node][0]:
                goal_nodes[node] = (cost, point)
    if not source_nodes or not goal_nodes:
        return None

    goal_points = list(goals)

    def heuristic(node):
        x, y = board_point(node[0], node[1], grid)
        return min(math.hypot(x - gx, y - gy) for gx, gy in goal_points)

    queue = []
    distance = {}
    parent = {}
    origin = {}
    for node, (cost, point) in source_nodes.items():
        distance[node] = cost
        parent[node] = None
        origin[node] = point
        heapq.heappush(queue, (cost + heuristic(node), cost, node))

    directions = (
        (-1, -1), (-1, 0), (-1, 1),
        (0, -1), (0, 1),
        (1, -1), (1, 0), (1, 1),
    )
    reached = None
    while queue:
        _, cost, current = heapq.heappop(queue)
        if cost != distance.get(current):
            continue
        if current in goal_nodes:
            reached = current
            break
        for dx, dy in directions:
            neighbor = (current[0] + dx, current[1] + dy)
            if not (0 <= neighbor[0] < nx and 0 <= neighbor[1] < ny):
                continue
            if neighbor in blocked:
                continue
            step = grid * (math.sqrt(2) if dx and dy else 1.0)
            new_cost = cost + step
            if new_cost + 1e-9 < distance.get(neighbor, math.inf):
                distance[neighbor] = new_cost
                parent[neighbor] = current
                origin[neighbor] = origin[current]
                heapq.heappush(queue, (new_cost + heuristic(neighbor), new_cost, neighbor))
    if reached is None:
        return None

    nodes = []
    current = reached
    while current is not None:
        nodes.append(current)
        current = parent[current]
    nodes.reverse()
    points = [origin[reached]] + [board_point(ix, iy, grid) for ix, iy in nodes]
    points.append(goal_nodes[reached][1])
    compact = [points[0]]
    for point in points[1:]:
        if point != compact[-1]:
            compact.append(point)
    simplified = [compact[0]]
    for index in range(1, len(compact) - 1):
        ax, ay = simplified[-1]
        bx, by = compact[index]
        cx, cy = compact[index + 1]
        if abs((bx - ax) * (cy - by) - (by - ay) * (cx - bx)) > 1e-9:
            simplified.append((bx, by))
    simplified.append(compact[-1])
    return simplified


def add_tracks(board, net, layer, points, width=None):
    if width is None:
        width = 0.26 if net.startswith("USB_D") else 0.20
    netcode = board.FindNet(net).GetNetCode()
    for start, end in zip(points, points[1:]):
        track = pcbnew.PCB_TRACK(board)
        track.SetStart(pcbnew.VECTOR2I(MM(start[0]), MM(start[1])))
        track.SetEnd(pcbnew.VECTOR2I(MM(end[0]), MM(end[1])))
        track.SetLayer(layer)
        track.SetWidth(MM(width))
        track.SetNetCode(netcode)
        board.Add(track)


def main():
    board = pcbnew.LoadBoard(str(SOURCE))
    before = internal.count_unconnected(board)
    routed = []
    skipped = []
    board.BuildConnectivity()
    connectivity = board.GetConnectivity()

    for net, components in sorted(internal.signal_components(board).items()):
        anchor_sets = []
        for items in components:
            vias = internal.component_vias(board, connectivity, items)
            anchors = [
                (via.GetPosition().x / 1e6, via.GetPosition().y / 1e6)
                for via in vias
            ]
            if not anchors:
                break
            anchor_sets.append(anchors)
        if len(anchor_sets) != len(components):
            skipped.append(f"{net}: component without via")
            continue

        root = list(anchor_sets[0])
        net_routes = []
        success = True
        for anchors in anchor_sets[1:]:
            result = None
            for grid in (0.50, 0.25):
                for layer in (pcbnew.In2_Cu, pcbnew.In4_Cu):
                    path = find_grid_path(
                        board,
                        board.FindNet(net).GetNetCode(),
                        layer,
                        anchors,
                        root,
                        grid,
                    )
                    if path:
                        result = (layer, grid, path)
                        break
                if result:
                    break
            if not result:
                success = False
                break
            layer, grid, path = result
            add_tracks(board, net, layer, path)
            net_routes.append((layer, grid, len(path) - 1))
            root.extend(anchors)
        if success:
            routed.append(
                f"{net}: " + ", ".join(
                    f"{board.GetLayerName(layer)} grid={grid:.2f} segments={segments}"
                    for layer, grid, segments in net_routes
                )
            )
        else:
            skipped.append(f"{net}: no clearance-safe internal path")
        print(f"processed {net}: {'routed' if success else 'skipped'}", flush=True)

    if not pcbnew.ZONE_FILLER(board).Fill(board.Zones()):
        raise RuntimeError("zone fill failed")
    after = internal.count_unconnected(board)
    text = (
        f"unconnected_before={before}\nunconnected_after={after}\n"
        f"routed={len(routed)}\n" + "\n".join(routed) + "\n\n"
        f"skipped={len(skipped)}\n" + "\n".join(skipped) + "\n"
    )
    REPORT.write_text(text)
    print(text)
    if after >= before:
        raise RuntimeError(f"routing did not improve connectivity: {before} -> {after}")
    if not pcbnew.SaveBoard(str(OUTPUT), board):
        raise RuntimeError("save failed")
    for suffix in (".kicad_pro", ".rules"):
        companion = SOURCE.with_suffix(suffix)
        if companion.exists():
            shutil.copy2(companion, OUTPUT.with_suffix(suffix))


if __name__ == "__main__":
    main()
