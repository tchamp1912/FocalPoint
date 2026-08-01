#!/usr/bin/env python3
"""Route the final small set with A* followed by line-of-sight simplification."""

from __future__ import annotations

import math
from pathlib import Path

import pcbnew

import finish_four_layer_remaining as remaining
import route_internal_signals as internal
import route_remaining_signals as grid_router


ROOT = Path(__file__).resolve().parent
SOURCE = ROOT / "focalpoint_rev_b_4layer_local_escapes.kicad_pcb"
OUTPUT = ROOT / "focalpoint_rev_b_4layer_connected.kicad_pcb"
REPORT = ROOT / "focalpoint_rev_b_4layer_final_connections.txt"
WIDTHS = {
    "GND": 0.30,
    "+5V": 0.50,
    "SYS": 0.50,
    "BB_L2": 0.30,
    "BB_L1": 0.30,
    "LED1_DIN": 0.20,
    "BOOST_EN": 0.20,
    "ENC_B": 0.20,
}


def group_points(group, layer):
    points = []
    for pad in group["pads"]:
        if pad.IsOnLayer(layer):
            p = pad.GetPosition()
            points.append((p.x / 1e6, p.y / 1e6))
    for item in group["items"]:
        if isinstance(item, pcbnew.PCB_TRACK) and item.GetLayer() == layer:
            for p in (item.GetStart(), item.GetEnd()):
                points.append((p.x / 1e6, p.y / 1e6))
    return list(dict.fromkeys(points))


def simplify(board, netcode, layer, points, width):
    internal.WIDTH = width
    internal.RADIUS = width / 2
    internal.CLEARANCE = 0.15
    obstacles = internal.layer_obstacles(board, netcode, layer)
    result = [points[0]]
    index = 0
    while index < len(points) - 1:
        selected = index + 1
        for candidate in range(len(points) - 1, index, -1):
            if internal.clear_segment(
                points[index][0], points[index][1],
                points[candidate][0], points[candidate][1],
                *obstacles,
            ):
                selected = candidate
                break
        result.append(points[selected])
        index = selected
    return result


def main():
    board = pcbnew.LoadBoard(str(SOURCE))
    before = internal.count_unconnected(board)
    routes = []
    # Keep every grid node at least 1.25 mm inside the nominal square outline.
    grid_router.EDGE_MIN = 100.75
    grid_router.EDGE_MAX = 215.25
    for net_name, width in WIDTHS.items():
        while True:
            groups = remaining.components(board, net_name)
            if len(groups) <= 1:
                break
            root = max(groups, key=lambda g: len(g["items"]) + len(g["pads"]))
            group = min((g for g in groups if g is not root), key=lambda g: len(g["pads"]))
            layer = pcbnew.B_Cu if group["pads"][0].IsOnLayer(pcbnew.B_Cu) else pcbnew.F_Cu
            starts, goals = group_points(group, layer), group_points(root, layer)
            grid_router.ROUTE_RADIUS = width / 2
            path = None
            used_grid = None
            for grid in (0.50, 0.25):
                path = grid_router.find_grid_path(
                    board, board.FindNet(net_name).GetNetCode(), layer,
                    starts, goals, grid,
                )
                if path:
                    used_grid = grid
                    break
            if not path:
                routes.append(f"FAILED {net_name}:{remaining.anchors(group, layer)[0]}")
                break
            path = simplify(board, board.FindNet(net_name).GetNetCode(), layer, path, width)
            grid_router.add_tracks(board, net_name, layer, path, width)
            routes.append(
                f"{net_name} {board.GetLayerName(layer)} grid={used_grid:.2f} "
                f"segments={len(path)-1} length_mm="
                f"{sum(math.dist(a,b) for a,b in zip(path,path[1:])):.3f}"
            )
    pcbnew.ZONE_FILLER(board).Fill(board.Zones())
    after = internal.count_unconnected(board)
    pcbnew.SaveBoard(str(OUTPUT), board)
    REPORT.write_text(
        f"source={SOURCE.name}\noutput={OUTPUT.name}\n"
        f"unconnected_before={before}\nunconnected_after={after}\n"
        + "\n".join(routes) + "\n"
    )
    print(REPORT.read_text(), end="")


if __name__ == "__main__":
    main()
