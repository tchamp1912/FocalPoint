#!/usr/bin/env python3
"""Join the few components left after signal routing and GND fanout."""

from __future__ import annotations

import math
from pathlib import Path

import pcbnew

import route_internal_signals as router


ROOT = Path(__file__).resolve().parent
SOURCE = ROOT / "focalpoint_rev_b_4layer_routed_working.kicad_pcb"
OUTPUT = ROOT / "focalpoint_rev_b_4layer_complete_raw.kicad_pcb"
REPORT = ROOT / "focalpoint_rev_b_4layer_remaining_routes.txt"


def item_id(item):
    return item.m_Uuid.AsString() if hasattr(item, "m_Uuid") else str(id(item))


def components(board, net_name):
    board.BuildConnectivity()
    connectivity = board.GetConnectivity()
    pads = [pad for fp in board.GetFootprints() for pad in fp.Pads()
            if pad.GetNetname() == net_name]
    by_signature = {}
    for pad in pads:
        items = list(connectivity.GetConnectedItems(pad))
        signature = tuple(sorted(item_id(item) for item in items)) or (item_id(pad),)
        group = by_signature.setdefault(signature, {"pads": [], "items": items})
        group["pads"].append(pad)
    return list(by_signature.values())


def anchors(group, layer):
    points = []
    for pad in group["pads"]:
        if pad.IsOnLayer(layer):
            p = pad.GetPosition()
            points.append((p.x / 1e6, p.y / 1e6))
    for item in group["items"]:
        if isinstance(item, pcbnew.PCB_VIA):
            p = item.GetPosition()
            points.append((p.x / 1e6, p.y / 1e6))
        elif isinstance(item, pcbnew.PCB_TRACK) and item.GetLayer() == layer:
            for p in (item.GetStart(), item.GetEnd()):
                points.append((p.x / 1e6, p.y / 1e6))
    # Stable de-duplication keeps the path search bounded.
    return list(dict.fromkeys(points))


def pad_layer(pad):
    if pad.IsOnLayer(pcbnew.B_Cu):
        return pcbnew.B_Cu
    return pcbnew.F_Cu


def join_net(board, net_name, width):
    routed = []
    while True:
        groups = components(board, net_name)
        if len(groups) <= 1:
            return routed
        root = max(groups, key=lambda group: len(group["items"]) + len(group["pads"]))
        others = [group for group in groups if group is not root]
        progress = False
        router.WIDTH = width
        router.RADIUS = width / 2
        router.CLEARANCE = 0.15
        netcode = board.FindNet(net_name).GetNetCode()
        for group in sorted(others, key=lambda value: len(value["pads"])):
            source_pad = group["pads"][0]
            layer = pad_layer(source_pad)
            starts = anchors(group, layer)
            goals = anchors(root, layer)
            candidates = []
            # Nearby same-net anchors produce the cleanest local fanout and
            # avoid an expensive all-pairs search over the full GND plane.
            for start in starts[:4]:
                for goal in sorted(goals, key=lambda p: math.dist(start, p))[:6]:
                    path = router.find_path(board, netcode, layer, start, goal, 16.0)
                    if path:
                        length = sum(math.dist(a, b) for a, b in zip(path, path[1:]))
                        candidates.append((length, path))
            if not candidates:
                continue
            _, path = min(candidates, key=lambda value: value[0])
            router.add_tracks(board, netcode, layer, path)
            routed.append(
                f"{net_name}:{source_pad.GetParentFootprint().GetReference()}."
                f"{source_pad.GetNumber()} {board.GetLayerName(layer)} "
                f"segments={len(path) - 1} length_mm="
                f"{sum(math.dist(a, b) for a, b in zip(path, path[1:])):.3f}"
            )
            progress = True
            break
        if not progress:
            return routed


def main():
    board = pcbnew.LoadBoard(str(SOURCE))
    before = router.count_unconnected(board)
    routes = []
    routes += join_net(board, "GND", 0.30)
    routes += join_net(board, "+5V", 0.50)
    routes += join_net(board, "SYS", 0.50)
    routes += join_net(board, "BB_L2", 0.30)
    routes += join_net(board, "LED1_DIN", 0.20)
    routes += join_net(board, "BOOST_EN", 0.20)
    pcbnew.ZONE_FILLER(board).Fill(board.Zones())
    after = router.count_unconnected(board)
    pcbnew.SaveBoard(str(OUTPUT), board)
    REPORT.write_text(
        f"source={SOURCE.name}\noutput={OUTPUT.name}\n"
        f"unconnected_before={before}\nunconnected_after={after}\n"
        f"routes_added={len(routes)}\n" + "\n".join(routes) + "\n"
    )
    print(REPORT.read_text(), end="")


if __name__ == "__main__":
    main()
