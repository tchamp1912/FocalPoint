#!/Applications/KiCad/KiCad.app/Contents/Frameworks/Python.framework/Versions/3.9/bin/python3.9
"""Repair native-DRC copper errors on the corrected Rev A candidate.

The first native DRC found tracks crossing the reverse-mount LED Edge.Cuts
apertures plus one marginal GND-via clearance. This script matches the exact
reported track objects, replaces each connected offending chain with a
visibility-graph detour around every LED aperture, and moves the one GND via.
It never overwrites the input board.
"""

from __future__ import annotations

import argparse
import heapq
import math
import re
import shutil
from collections import defaultdict
from pathlib import Path
from typing import Any

import pcbnew

import route_power_escapes as geometry


MM = pcbnew.FromMM
EDGE_CLEARANCE = 0.20
EXTRA_MARGIN = 0.03
BOARD_MIN = 100.0
BOARD_MAX = 216.0


def point(item: pcbnew.BOARD_ITEM, which: str) -> tuple[float, float]:
    value = item.GetStart() if which == "start" else item.GetEnd()
    return value.x / 1e6, value.y / 1e6


def uuid(item: pcbnew.BOARD_ITEM) -> str:
    return str(item.m_Uuid.AsString())


def point_segment_distance(
    p: tuple[float, float], a: tuple[float, float], b: tuple[float, float]
) -> float:
    return geometry.point_segment_distance(p[0], p[1], a[0], a[1], b[0], b[1])


def parse_edge_track_markers(report: Path) -> list[tuple[float, float, str, str, float]]:
    markers = []
    text = report.read_text()
    for block in re.split(r"(?=^\[)", text, flags=re.MULTILINE)[1:]:
        if not block.startswith("[copper_edge_clearance]"):
            continue
        match = re.search(
            r"@\(([0-9.]+) mm, ([0-9.]+) mm\): "
            r"Track \[([^]]+)\] on ([^,]+), length ([0-9.]+)",
            block,
        )
        if not match:
            raise RuntimeError(f"could not parse edge violation:\n{block}")
        markers.append(
            (
                float(match.group(1)),
                float(match.group(2)),
                match.group(3),
                match.group(4),
                float(match.group(5)),
            )
        )
    return markers


def match_tracks(
    board: pcbnew.BOARD, report: Path, ignore_nets: set[str] | None = None
) -> list[pcbnew.PCB_TRACK]:
    ignore_nets = ignore_nets or set()
    tracks = [
        item for item in board.GetTracks() if type(item).__name__ == "PCB_TRACK"
    ]
    matched = {}
    for x, y, net, layer, length in parse_edge_track_markers(report):
        if net in ignore_nets:
            continue
        candidates = []
        for track in tracks:
            if track.GetNetname() != net or board.GetLayerName(track.GetLayer()) != layer:
                continue
            start, end = point(track, "start"), point(track, "end")
            if abs(math.dist(start, end) - length) > 0.01:
                continue
            distance = point_segment_distance((x, y), start, end)
            if distance < 0.25:
                candidates.append((distance, uuid(track), track))
        if not candidates:
            raise RuntimeError(
                f"could not match DRC track {net} {layer} at {x:.4f},{y:.4f}"
            )
        _, _, track = min(candidates)
        matched[uuid(track)] = track
    return list(matched.values())


def connected_groups(
    tracks: list[pcbnew.PCB_TRACK],
) -> list[list[pcbnew.PCB_TRACK]]:
    by_class: dict[tuple[int, int], list[pcbnew.PCB_TRACK]] = defaultdict(list)
    for track in tracks:
        by_class[(track.GetNetCode(), track.GetLayer())].append(track)

    groups = []
    for class_tracks in by_class.values():
        remaining = {uuid(track): track for track in class_tracks}
        while remaining:
            _, seed = remaining.popitem()
            group = [seed]
            nodes = {point(seed, "start"), point(seed, "end")}
            changed = True
            while changed:
                changed = False
                for key, track in list(remaining.items()):
                    if point(track, "start") in nodes or point(track, "end") in nodes:
                        group.append(track)
                        nodes.update((point(track, "start"), point(track, "end")))
                        del remaining[key]
                        changed = True
            groups.append(group)
    return groups


def led_cutouts(board: pcbnew.BOARD) -> list[tuple[float, float, float, float]]:
    result = []
    for footprint in board.GetFootprints():
        shapes = [
            item
            for item in footprint.GraphicalItems()
            if item.GetLayer() == pcbnew.Edge_Cuts
        ]
        if not shapes:
            continue
        xs: list[float] = []
        ys: list[float] = []
        for shape in shapes:
            box = shape.GetBoundingBox()
            xs.extend((box.GetX() / 1e6, (box.GetX() + box.GetWidth()) / 1e6))
            ys.extend((box.GetY() / 1e6, (box.GetY() + box.GetHeight()) / 1e6))
        # The only footprint-owned apertures in Rev A are the LED windows.
        if max(xs) - min(xs) < 10 and max(ys) - min(ys) < 10:
            result.append((min(xs), min(ys), max(xs), max(ys)))
    if len(result) != 13:
        raise RuntimeError(f"expected 13 LED cutouts, found {len(result)}")
    return result


def path_endpoints(group: list[pcbnew.PCB_TRACK]) -> tuple[tuple[float, float], tuple[float, float]]:
    degree: dict[tuple[float, float], int] = defaultdict(int)
    for track in group:
        degree[point(track, "start")] += 1
        degree[point(track, "end")] += 1
    endpoints = [position for position, count in degree.items() if count == 1]
    if len(endpoints) != 2:
        raise RuntimeError(
            f"offending track group is not a chain: {len(group)} segments, "
            f"{len(endpoints)} endpoints"
        )
    return endpoints[0], endpoints[1]


def segment_hits_rect(
    a: tuple[float, float],
    b: tuple[float, float],
    rect: tuple[float, float, float, float],
) -> bool:
    return geometry.segment_intersects_rect(
        a[0], a[1], b[0], b[1], rect[0], rect[1], rect[2], rect[3]
    )


def clear_segment(
    board: pcbnew.BOARD,
    netcode: int,
    layer: int,
    width: float,
    a: tuple[float, float],
    b: tuple[float, float],
    cutouts: list[tuple[float, float, float, float]],
    obstacles: dict[str, Any],
) -> bool:
    radius = width / 2
    if not (
        BOARD_MIN + EDGE_CLEARANCE + radius <= b[0] <= BOARD_MAX - EDGE_CLEARANCE - radius
        and BOARD_MIN + EDGE_CLEARANCE + radius <= b[1] <= BOARD_MAX - EDGE_CLEARANCE - radius
    ):
        return False

    cutout_margin = EDGE_CLEARANCE + radius
    for x0, y0, x1, y1 in cutouts:
        expanded = (
            x0 - cutout_margin,
            y0 - cutout_margin,
            x1 + cutout_margin,
            y1 + cutout_margin,
        )
        if segment_hits_rect(a, b, expanded):
            return False

    pad_rects = obstacles["pads"]
    via_circles = obstacles["vias"]
    track_segments = obstacles["tracks"]
    cell = obstacles["cell"]
    x0, x1 = sorted((a[0], b[0]))
    y0, y1 = sorted((a[1], b[1]))
    cells = [
        (ix, iy)
        for ix in range(math.floor(x0 / cell), math.floor(x1 / cell) + 1)
        for iy in range(math.floor(y0 / cell), math.floor(y1 / cell) + 1)
    ]
    pad_indices = {
        index for key in cells for index in obstacles["pad_index"].get(key, ())
    }
    via_indices = {
        index for key in cells for index in obstacles["via_index"].get(key, ())
    }
    track_indices = {
        index for key in cells for index in obstacles["track_index"].get(key, ())
    }
    for index in pad_indices:
        rect = pad_rects[index]
        if segment_hits_rect(a, b, rect):
            return False
    for index in via_indices:
        x, y, obstacle_radius = via_circles[index]
        if point_segment_distance((x, y), a, b) < obstacle_radius:
            return False
    for index in track_indices:
        x0, y0, x1, y1, obstacle_radius = track_segments[index]
        if (
            geometry.segment_distance(
                a[0], a[1], b[0], b[1], x0, y0, x1, y1
            )
            < obstacle_radius
        ):
            return False
    return True


def build_obstacles(
    board: pcbnew.BOARD, netcode: int, layer: int, width: float
) -> dict[str, Any]:
    clearance = 0.15 + width / 2
    pad_rects = []
    via_circles = []
    track_segments = []
    for footprint in board.GetFootprints():
        for pad in footprint.Pads():
            if pad.GetNetCode() == netcode or layer not in set(pad.GetLayerSet().Seq()):
                continue
            box = pad.GetBoundingBox()
            pad_rects.append(
                (
                    box.GetX() / 1e6 - clearance,
                    box.GetY() / 1e6 - clearance,
                    (box.GetX() + box.GetWidth()) / 1e6 + clearance,
                    (box.GetY() + box.GetHeight()) / 1e6 + clearance,
                )
            )
    for item in board.GetTracks():
        if item.GetNetCode() == netcode:
            continue
        if isinstance(item, pcbnew.PCB_VIA):
            if layer not in set(item.GetLayerSet().Seq()):
                continue
            position = item.GetPosition()
            via_circles.append(
                (
                    position.x / 1e6,
                    position.y / 1e6,
                    item.GetWidth(layer) / 2e6 + clearance,
                )
            )
        elif type(item).__name__ == "PCB_TRACK" and item.GetLayer() == layer:
            start, end = point(item, "start"), point(item, "end")
            track_segments.append(
                (
                    start[0],
                    start[1],
                    end[0],
                    end[1],
                    item.GetWidth() / 2e6 + clearance,
                )
            )
    cell = 2.0

    def make_index(items, bounds):
        index: dict[tuple[int, int], list[int]] = defaultdict(list)
        for number, item in enumerate(items):
            x0, y0, x1, y1 = bounds(item)
            for ix in range(math.floor(x0 / cell), math.floor(x1 / cell) + 1):
                for iy in range(math.floor(y0 / cell), math.floor(y1 / cell) + 1):
                    index[(ix, iy)].append(number)
        return index

    return {
        "pads": pad_rects,
        "vias": via_circles,
        "tracks": track_segments,
        "cell": cell,
        "pad_index": make_index(pad_rects, lambda item: item),
        "via_index": make_index(
            via_circles,
            lambda item: (
                item[0] - item[2],
                item[1] - item[2],
                item[0] + item[2],
                item[1] + item[2],
            ),
        ),
        "track_index": make_index(
            track_segments,
            lambda item: (
                min(item[0], item[2]) - item[4],
                min(item[1], item[3]) - item[4],
                max(item[0], item[2]) + item[4],
                max(item[1], item[3]) + item[4],
            ),
        ),
    }


def find_detour(
    board: pcbnew.BOARD,
    netcode: int,
    layer: int,
    width: float,
    start: tuple[float, float],
    goal: tuple[float, float],
    cutouts: list[tuple[float, float, float, float]],
) -> list[tuple[float, float]]:
    obstacles = build_obstacles(board, netcode, layer, width)
    waypoint_margin = EDGE_CLEARANCE + width / 2 + 0.30
    nodes = [start, goal]
    for x0, y0, x1, y1 in cutouts:
        nodes.extend(
            [
                (x0 - waypoint_margin, y0 - waypoint_margin),
                (x0 - waypoint_margin, y1 + waypoint_margin),
                (x1 + waypoint_margin, y0 - waypoint_margin),
                (x1 + waypoint_margin, y1 + waypoint_margin),
            ]
        )

    adjacency: list[list[tuple[float, int]]] = [[] for _ in nodes]
    for left in range(len(nodes)):
        for right in range(left + 1, len(nodes)):
            if clear_segment(
                board,
                netcode,
                layer,
                width,
                nodes[left],
                nodes[right],
                cutouts,
                obstacles,
            ):
                distance = math.dist(nodes[left], nodes[right])
                adjacency[left].append((distance, right))
                adjacency[right].append((distance, left))

    distances = [math.inf] * len(nodes)
    previous = [-1] * len(nodes)
    distances[0] = 0.0
    queue = [(0.0, 0)]
    while queue:
        distance, node = heapq.heappop(queue)
        if distance != distances[node]:
            continue
        if node == 1:
            break
        for cost, neighbor in adjacency[node]:
            candidate = distance + cost
            if candidate < distances[neighbor]:
                distances[neighbor] = candidate
                previous[neighbor] = node
                heapq.heappush(queue, (candidate, neighbor))
    if math.isinf(distances[1]):
        return find_grid_detour(
            board, netcode, layer, width, start, goal, cutouts, obstacles
        )

    indices = []
    cursor = 1
    while cursor >= 0:
        indices.append(cursor)
        cursor = previous[cursor]
    return [nodes[index] for index in reversed(indices)]


def find_grid_detour(
    board: pcbnew.BOARD,
    netcode: int,
    layer: int,
    width: float,
    start: tuple[float, float],
    goal: tuple[float, float],
    cutouts: list[tuple[float, float, float, float]],
    obstacles: dict[str, Any],
) -> list[tuple[float, float]]:
    """A bounded 0.5 mm A* fallback for paths that must dodge nearby vias."""
    grid = 0.5
    for margin in (6.0, 12.0, 24.0):
        x_min = max(BOARD_MIN + 0.5, math.floor((min(start[0], goal[0]) - margin) / grid) * grid)
        x_max = min(BOARD_MAX - 0.5, math.ceil((max(start[0], goal[0]) + margin) / grid) * grid)
        y_min = max(BOARD_MIN + 0.5, math.floor((min(start[1], goal[1]) - margin) / grid) * grid)
        y_max = min(BOARD_MAX - 0.5, math.ceil((max(start[1], goal[1]) + margin) / grid) * grid)

        def snap_neighbors(position: tuple[float, float]) -> list[tuple[float, float]]:
            base_x = math.floor(position[0] / grid) * grid
            base_y = math.floor(position[1] / grid) * grid
            result = []
            for ix in range(-1, 3):
                for iy in range(-1, 3):
                    candidate = (base_x + ix * grid, base_y + iy * grid)
                    if (
                        x_min <= candidate[0] <= x_max
                        and y_min <= candidate[1] <= y_max
                        and math.dist(position, candidate) <= 1.1
                    ):
                        result.append(candidate)
            return result

        open_set: list[tuple[float, float, tuple[float, float]]] = []
        heapq.heappush(open_set, (math.dist(start, goal), 0.0, start))
        best = {start: 0.0}
        previous: dict[tuple[float, float], tuple[float, float]] = {}
        closed = set()
        found = False
        while open_set:
            _, cost, current = heapq.heappop(open_set)
            if current in closed:
                continue
            closed.add(current)
            if current == goal:
                found = True
                break
            if current == start:
                neighbors = snap_neighbors(start)
            else:
                neighbors = [
                    (current[0] + dx * grid, current[1] + dy * grid)
                    for dx in (-1, 0, 1)
                    for dy in (-1, 0, 1)
                    if dx or dy
                ]
                if math.dist(current, goal) <= 1.1:
                    neighbors.append(goal)
            for neighbor in neighbors:
                if not (
                    x_min <= neighbor[0] <= x_max
                    and y_min <= neighbor[1] <= y_max
                ):
                    continue
                if neighbor in closed or not clear_segment(
                    board,
                    netcode,
                    layer,
                    width,
                    current,
                    neighbor,
                    cutouts,
                    obstacles,
                ):
                    continue
                next_cost = cost + math.dist(current, neighbor)
                if next_cost >= best.get(neighbor, math.inf):
                    continue
                best[neighbor] = next_cost
                previous[neighbor] = current
                priority = next_cost + math.dist(neighbor, goal)
                heapq.heappush(open_set, (priority, next_cost, neighbor))
        if found:
            path = [goal]
            while path[-1] != start:
                path.append(previous[path[-1]])
            path.reverse()
            # Collapse collinear grid steps to keep the PCB readable.
            compact = [path[0]]
            for position in path[1:]:
                if len(compact) >= 2:
                    a, b = compact[-2], compact[-1]
                    cross = (
                        (b[0] - a[0]) * (position[1] - b[1])
                        - (b[1] - a[1]) * (position[0] - b[0])
                    )
                    if abs(cross) < 1e-9:
                        compact[-1] = position
                        continue
                compact.append(position)
            return compact
    raise RuntimeError(
        f"no legal detour on {board.GetLayerName(layer)} from {start} to {goal}"
    )


def via_location_clear(
    position: tuple[float, float],
    cutouts: list[tuple[float, float, float, float]],
    obstacle_sets: dict[int, dict[str, Any]],
) -> bool:
    via_radius = 0.45 / 2
    for x0, y0, x1, y1 in cutouts:
        margin = EDGE_CLEARANCE + via_radius
        if (
            x0 - margin <= position[0] <= x1 + margin
            and y0 - margin <= position[1] <= y1 + margin
        ):
            return False
    for obstacles in obstacle_sets.values():
        cell = obstacles["cell"]
        key = (math.floor(position[0] / cell), math.floor(position[1] / cell))
        for index in obstacles["pad_index"].get(key, ()):
            x0, y0, x1, y1 = obstacles["pads"][index]
            if x0 <= position[0] <= x1 and y0 <= position[1] <= y1:
                return False
        for index in obstacles["via_index"].get(key, ()):
            x, y, radius = obstacles["vias"][index]
            if math.hypot(position[0] - x, position[1] - y) < radius:
                return False
        for index in obstacles["track_index"].get(key, ()):
            x0, y0, x1, y1, radius = obstacles["tracks"][index]
            if (
                geometry.point_segment_distance(
                    position[0], position[1], x0, y0, x1, y1
                )
                < radius
            ):
                return False
    return True


def find_multilayer_detour(
    board: pcbnew.BOARD,
    netcode: int,
    width: float,
    start: tuple[float, float],
    goal: tuple[float, float],
    cutouts: list[tuple[float, float, float, float]],
) -> list[tuple[float, float, int]]:
    layers = (pcbnew.In2_Cu, pcbnew.In3_Cu)
    track_obstacles = {
        layer: build_obstacles(board, netcode, layer, width) for layer in layers
    }
    via_obstacles = {
        layer: build_obstacles(board, netcode, layer, 0.45)
        for layer in (pcbnew.F_Cu, pcbnew.In2_Cu, pcbnew.In3_Cu, pcbnew.B_Cu)
    }
    grid = 0.5
    x_min = max(BOARD_MIN + 0.5, math.floor((min(start[0], goal[0]) - 28) / grid) * grid)
    x_max = min(BOARD_MAX - 0.5, math.ceil((max(start[0], goal[0]) + 28) / grid) * grid)
    y_min = max(BOARD_MIN + 0.5, math.floor((min(start[1], goal[1]) - 28) / grid) * grid)
    y_max = min(BOARD_MAX - 0.5, math.ceil((max(start[1], goal[1]) + 28) / grid) * grid)

    start_states = [(start[0], start[1], layer) for layer in layers]
    goal_states = {(goal[0], goal[1], layer) for layer in layers}
    queue = []
    best = {}
    previous = {}
    for state in start_states:
        best[state] = 0.0
        heapq.heappush(queue, (math.dist(start, goal), 0.0, state))
    closed = set()
    reached = None

    def nearby_grid(position: tuple[float, float]) -> list[tuple[float, float]]:
        base_x = math.floor(position[0] / grid) * grid
        base_y = math.floor(position[1] / grid) * grid
        return [
            (base_x + ix * grid, base_y + iy * grid)
            for ix in range(-1, 3)
            for iy in range(-1, 3)
            if math.dist(position, (base_x + ix * grid, base_y + iy * grid)) <= 1.1
        ]

    while queue:
        _, cost, state = heapq.heappop(queue)
        if state in closed:
            continue
        closed.add(state)
        x, y, layer = state
        if state in goal_states:
            reached = state
            break
        position = (x, y)
        if position == start:
            planar = nearby_grid(start)
        else:
            planar = [
                (x + dx * grid, y + dy * grid)
                for dx in (-1, 0, 1)
                for dy in (-1, 0, 1)
                if dx or dy
            ]
            if math.dist(position, goal) <= 1.1:
                planar.append(goal)
        neighbors = []
        for neighbor_position in planar:
            if not (
                x_min <= neighbor_position[0] <= x_max
                and y_min <= neighbor_position[1] <= y_max
            ):
                continue
            if clear_segment(
                board,
                netcode,
                layer,
                width,
                position,
                neighbor_position,
                cutouts,
                track_obstacles[layer],
            ):
                neighbors.append(
                    (
                        math.dist(position, neighbor_position),
                        (neighbor_position[0], neighbor_position[1], layer),
                    )
                )
        if position not in {start, goal} and via_location_clear(
            position, cutouts, via_obstacles
        ):
            other = layers[1] if layer == layers[0] else layers[0]
            neighbors.append((3.0, (x, y, other)))
        for step_cost, neighbor in neighbors:
            if neighbor in closed:
                continue
            candidate = cost + step_cost
            if candidate >= best.get(neighbor, math.inf):
                continue
            best[neighbor] = candidate
            previous[neighbor] = state
            heuristic = math.dist((neighbor[0], neighbor[1]), goal)
            heapq.heappush(queue, (candidate + heuristic, candidate, neighbor))
    if reached is None:
        raise RuntimeError(f"no legal two-layer detour from {start} to {goal}")
    path = [reached]
    while path[-1] not in start_states:
        path.append(previous[path[-1]])
    path.reverse()
    compact = [path[0]]
    for state in path[1:]:
        if len(compact) >= 2 and compact[-2][2] == compact[-1][2] == state[2]:
            a, b = compact[-2], compact[-1]
            cross = (
                (b[0] - a[0]) * (state[1] - b[1])
                - (b[1] - a[1]) * (state[0] - b[0])
            )
            if abs(cross) < 1e-9:
                compact[-1] = state
                continue
        compact.append(state)
    return compact


def add_multilayer_path(
    board: pcbnew.BOARD,
    netcode: int,
    width: int,
    states: list[tuple[float, float, int]],
) -> int:
    vias = 0
    for left, right in zip(states, states[1:]):
        if left[2] != right[2]:
            vias += int(add_via_if_needed(board, netcode, (left[0], left[1])))
        else:
            add_path(
                board,
                netcode,
                left[2],
                width,
                [(left[0], left[1]), (right[0], right[1])],
            )
    return vias


def add_path(
    board: pcbnew.BOARD,
    netcode: int,
    layer: int,
    width: int,
    points: list[tuple[float, float]],
) -> None:
    for start, end in zip(points, points[1:]):
        track = pcbnew.PCB_TRACK(board)
        track.SetStart(pcbnew.VECTOR2I(MM(start[0]), MM(start[1])))
        track.SetEnd(pcbnew.VECTOR2I(MM(end[0]), MM(end[1])))
        track.SetLayer(layer)
        track.SetWidth(width)
        track.SetNetCode(netcode)
        board.Add(track)


def add_via_if_needed(
    board: pcbnew.BOARD,
    netcode: int,
    position: tuple[float, float],
) -> bool:
    for item in board.GetTracks():
        if not isinstance(item, pcbnew.PCB_VIA) or item.GetNetCode() != netcode:
            continue
        existing = item.GetPosition()
        if math.hypot(existing.x / 1e6 - position[0], existing.y / 1e6 - position[1]) < 0.01:
            return False
    via = pcbnew.PCB_VIA(board)
    via.SetPosition(pcbnew.VECTOR2I(MM(position[0]), MM(position[1])))
    via.SetLayerPair(pcbnew.F_Cu, pcbnew.B_Cu)
    via.SetWidth(MM(0.45))
    via.SetDrill(MM(0.25))
    via.SetNetCode(netcode)
    board.Add(via)
    return True


def remove_clearance_via(board: pcbnew.BOARD) -> None:
    candidates = []
    for item in board.GetTracks():
        if not isinstance(item, pcbnew.PCB_VIA) or item.GetNetname() != "GND":
            continue
        position = item.GetPosition()
        distance = math.hypot(position.x / 1e6 - 207.962, position.y / 1e6 - 163.050)
        if distance < 0.01:
            candidates.append(item)
    if len(candidates) != 1:
        raise RuntimeError(f"expected one GND clearance via, found {len(candidates)}")
    board.Remove(candidates[0])


def replace_encoder_switch_route(
    board: pcbnew.BOARD,
    cutouts: list[tuple[float, float, float, float]],
) -> str:
    """Replace the autorouter's board-spanning ENC_SW front-layer meander."""
    net = board.FindNet("ENC_SW")
    netcode = net.GetNetCode()
    start = None
    for footprint in board.GetFootprints():
        if footprint.GetReference() != "ENC1":
            continue
        for pad in footprint.Pads():
            if pad.GetNetCode() == netcode:
                position = pad.GetPosition()
                start = (position.x / 1e6, position.y / 1e6)
                break
    vias = [
        item
        for item in board.GetTracks()
        if isinstance(item, pcbnew.PCB_VIA) and item.GetNetCode() == netcode
    ]
    if start is None or len(vias) != 1:
        raise RuntimeError(
            f"ENC_SW route anchors invalid: start={start}, vias={len(vias)}"
        )
    via_position = vias[0].GetPosition()
    goal = (via_position.x / 1e6, via_position.y / 1e6)
    removed = [
        item
        for item in board.GetTracks()
        if type(item).__name__ == "PCB_TRACK"
        and item.GetNetCode() == netcode
        and item.GetLayer() != pcbnew.B_Cu
    ]
    detour = None
    selected_layer = None
    for layer in (pcbnew.In2_Cu, pcbnew.In3_Cu):
        try:
            detour = find_detour(
                board, netcode, layer, 0.20, start, goal, cutouts
            )
            selected_layer = layer
            break
        except RuntimeError:
            continue
    if detour is None or selected_layer is None:
        raise RuntimeError("could not replace full ENC_SW route")
    for item in removed:
        board.Remove(item)
    add_path(board, netcode, selected_layer, MM(0.20), detour)
    return (
        f"ENC_SW full route -> {board.GetLayerName(selected_layer)}: "
        f"{len(removed)} removed, {len(detour) - 1} added"
    )


def replace_two_via_route(
    board: pcbnew.BOARD,
    net_name: str,
    cutouts: list[tuple[float, float, float, float]],
) -> str:
    netcode = board.FindNet(net_name).GetNetCode()
    vias = [
        item
        for item in board.GetTracks()
        if isinstance(item, pcbnew.PCB_VIA) and item.GetNetCode() == netcode
    ]
    if len(vias) != 2:
        raise RuntimeError(f"{net_name}: expected two anchor vias, found {len(vias)}")
    anchors = []
    for via in vias:
        position = via.GetPosition()
        anchors.append((position.x / 1e6, position.y / 1e6))
    removed = [
        item
        for item in board.GetTracks()
        if type(item).__name__ == "PCB_TRACK"
        and item.GetNetCode() == netcode
        and item.GetLayer() != pcbnew.B_Cu
    ]
    detour = None
    selected_layer = None
    for layer in (pcbnew.In2_Cu, pcbnew.In3_Cu):
        try:
            detour = find_detour(
                board, netcode, layer, 0.20, anchors[0], anchors[1], cutouts
            )
            selected_layer = layer
            break
        except RuntimeError:
            continue
    multilayer = None
    if detour is None or selected_layer is None:
        multilayer = find_multilayer_detour(
            board, netcode, 0.20, anchors[0], anchors[1], cutouts
        )
    for item in removed:
        board.Remove(item)
    if multilayer is not None:
        vias_added = add_multilayer_path(board, netcode, MM(0.20), multilayer)
        route_description = (
            f"In2/In3: {len(multilayer) - 1} added, {vias_added} vias"
        )
    else:
        add_path(board, netcode, selected_layer, MM(0.20), detour)
        route_description = (
            f"{board.GetLayerName(selected_layer)}: {len(detour) - 1} added"
        )
    return (
        f"{net_name} full route -> {route_description}; "
        f"{len(removed)} removed"
    )


def main() -> None:
    parser = argparse.ArgumentParser()
    parser.add_argument("source", type=Path)
    parser.add_argument("report", type=Path)
    parser.add_argument("output", type=Path)
    parser.add_argument("--encoder-only", action="store_true")
    parser.add_argument("--skip-encoder", action="store_true")
    parser.add_argument("--replace-two-via-net")
    parser.add_argument("--ignore-net", action="append", default=[])
    args = parser.parse_args()
    source, report, output = (
        args.source.resolve(),
        args.report.resolve(),
        args.output.resolve(),
    )
    if source == output:
        parser.error("output must differ from source")

    board = pcbnew.LoadBoard(str(source))
    cutouts = led_cutouts(board)
    repairs = []
    if args.encoder_only or args.replace_two_via_net:
        if args.encoder_only:
            repairs.append(replace_encoder_switch_route(board, cutouts))
        else:
            repairs.append(
                replace_two_via_route(board, args.replace_two_via_net, cutouts)
            )
        if not pcbnew.SaveBoard(str(output), board):
            raise RuntimeError(f"could not save {output}")
        for suffix in (".kicad_pro", ".rules"):
            companion = source.with_suffix(suffix)
            if companion.exists():
                shutil.copy2(companion, output.with_suffix(suffix))
        print("\n".join(repairs))
        print(f"output={output}")
        return

    ignored = set(args.ignore_net)
    if args.skip_encoder:
        ignored.add("ENC_SW")
    offending = match_tracks(
        board,
        report,
        ignore_nets=ignored,
    )
    groups = connected_groups(offending)
    for group in groups:
        start, goal = path_endpoints(group)
        netcode = group[0].GetNetCode()
        layer = group[0].GetLayer()
        width_iu = max(track.GetWidth() for track in group)
        width = width_iu / 1e6
        for track in group:
            board.Remove(track)
        selected_layer = layer
        vias_added = 0
        try:
            detour = find_detour(
                board, netcode, selected_layer, width, start, goal, cutouts
            )
        except RuntimeError as original_error:
            detour = None
            for alternate_layer in (pcbnew.In2_Cu, pcbnew.In3_Cu):
                if alternate_layer == layer:
                    continue
                try:
                    detour = find_detour(
                        board,
                        netcode,
                        alternate_layer,
                        width,
                        start,
                        goal,
                        cutouts,
                    )
                    selected_layer = alternate_layer
                    break
                except RuntimeError:
                    continue
            if detour is None:
                raise original_error
            vias_added += int(add_via_if_needed(board, netcode, start))
            vias_added += int(add_via_if_needed(board, netcode, goal))
        add_path(board, netcode, selected_layer, width_iu, detour)
        repairs.append(
            f"{board.FindNet(netcode).GetNetname()} "
            f"{board.GetLayerName(layer)}->{board.GetLayerName(selected_layer)}: "
            f"{len(group)} removed, {len(detour) - 1} added, "
            f"{vias_added} vias"
        )

    remove_clearance_via(board)
    if not pcbnew.SaveBoard(str(output), board):
        raise RuntimeError(f"could not save {output}")
    for suffix in (".kicad_pro", ".rules"):
        companion = source.with_suffix(suffix)
        if companion.exists():
            shutil.copy2(companion, output.with_suffix(suffix))
    print(f"matched_edge_tracks={len(offending)}")
    print(f"repaired_groups={len(groups)}")
    print("\n".join(repairs))
    print("removed_redundant_gnd_via=207.962,163.050")
    print(f"output={output}")


if __name__ == "__main__":
    main()
