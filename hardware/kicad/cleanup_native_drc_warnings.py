#!/Applications/KiCad/KiCad.app/Contents/Frameworks/Python.framework/Versions/3.9/bin/python3.9
"""Remove native-DRC dangling stubs and redundant/overlapping vias safely.

Every deletion is tested against KiCad connectivity. An item is restored when
removing it increases the unconnected count, so warning cleanup cannot silently
turn a routed board into an unrouted one.
"""

from __future__ import annotations

import argparse
import math
import re
import shutil
from pathlib import Path

import pcbnew

import route_power_escapes as geometry


REDUNDANT_VIAS = [
    ("GND", 146.1625, 207.3500),
    ("GND", 145.8375, 207.8500),
    ("GND", 146.1625, 208.3500),
    ("+BAT", 122.5125, 208.1000),
    ("+5V_LED", 205.8125, 153.8500),
]

CLOSE_VIA_PAIRS = [
    ("+BAT", (110.0375, 186.6000), (110.0375, 187.1000)),
    ("SYS", (117.4875, 207.6000), (117.4875, 208.1000)),
]
CLOSE_PAIR_DRILL_MM = 0.25

BREAKOUT_TRACKS = [
    ("GND", "B.Cu", (108.9875, 186.2500), (108.0875, 186.2500), 0.40),
    ("GND", "B.Cu", (108.0875, 186.2500), (107.9375, 186.1000), 0.40),
    ("+5V_LED", "B.Cu", (206.8625, 154.0000), (205.9625, 154.0000), 0.50),
    ("SYS", "B.Cu", (162.1500, 204.0000), (161.2500, 204.0000), 0.30),
]

BRIDGE_TRACKS = [
    ("+5V_LED", "B.Cu", (205.9625, 154.0000), (205.9625, 153.6500), 0.50),
]


def point(item, which):
    value = item.GetStart() if which == "start" else item.GetEnd()
    return value.x / 1e6, value.y / 1e6


def distance_to_track(position, track):
    start, end = point(track, "start"), point(track, "end")
    return geometry.point_segment_distance(
        position[0], position[1], start[0], start[1], end[0], end[1]
    )


def warning_blocks(report: Path, category: str) -> list[str]:
    text = report.read_text()
    return [
        block
        for block in re.split(r"(?=^\[)", text, flags=re.MULTILINE)[1:]
        if block.startswith(f"[{category}]")
    ]


def match_dangling_tracks(board, report):
    result = {}
    tracks = [
        item for item in board.GetTracks() if type(item).__name__ == "PCB_TRACK"
    ]
    for block in warning_blocks(report, "track_dangling"):
        match = re.search(
            r"@\(([0-9.]+) mm, ([0-9.]+) mm\): "
            r"Track \[([^]]+)\] on ([^,]+), length ([0-9.]+)",
            block,
        )
        if not match:
            raise RuntimeError(f"could not parse dangling track:\n{block}")
        x, y = float(match.group(1)), float(match.group(2))
        net, layer, length = match.group(3), match.group(4), float(match.group(5))
        candidates = []
        for track in tracks:
            if track.GetNetname() != net or board.GetLayerName(track.GetLayer()) != layer:
                continue
            actual_length = math.dist(point(track, "start"), point(track, "end"))
            if abs(actual_length - length) > 0.01:
                continue
            distance = distance_to_track((x, y), track)
            if distance < 0.25:
                candidates.append((distance, str(track.m_Uuid.AsString()), track))
        if not candidates:
            raise RuntimeError(f"dangling track not found: {net} {layer} {x},{y}")
        _, key, track = min(candidates)
        result[key] = track
    return list(result.values())


def match_dangling_vias(board, report):
    result = {}
    vias = [item for item in board.GetTracks() if isinstance(item, pcbnew.PCB_VIA)]
    for block in warning_blocks(report, "via_dangling"):
        match = re.search(
            r"@\(([0-9.]+) mm, ([0-9.]+) mm\): "
            r"Via \[([^]]+)\]",
            block,
        )
        if not match:
            raise RuntimeError(f"could not parse dangling via:\n{block}")
        x, y, net = float(match.group(1)), float(match.group(2)), match.group(3)
        candidates = []
        for via in vias:
            if via.GetNetname() != net:
                continue
            position = via.GetPosition()
            distance = math.hypot(position.x / 1e6 - x, position.y / 1e6 - y)
            if distance < 0.01:
                candidates.append((str(via.m_Uuid.AsString()), via))
        if not candidates:
            # A prior deterministic repair may already have removed this via.
            continue
        key, via = min(candidates)
        result[key] = via
    return list(result.values())


def match_redundant_vias(board):
    result = {}
    for net, x, y in REDUNDANT_VIAS:
        candidates = []
        for item in board.GetTracks():
            if not isinstance(item, pcbnew.PCB_VIA) or item.GetNetname() != net:
                continue
            position = item.GetPosition()
            distance = math.hypot(position.x / 1e6 - x, position.y / 1e6 - y)
            if distance < 0.01:
                candidates.append((str(item.m_Uuid.AsString()), item))
        if candidates:
            key, via = min(candidates)
            result[key] = via
    return list(result.values())


def resize_close_via_pairs(board):
    resized = {}
    for net, first, second in CLOSE_VIA_PAIRS:
        for x, y in (first, second):
            matches = []
            for item in board.GetTracks():
                if not isinstance(item, pcbnew.PCB_VIA) or item.GetNetname() != net:
                    continue
                position = item.GetPosition()
                distance = math.hypot(position.x / 1e6 - x, position.y / 1e6 - y)
                if distance < 0.01:
                    matches.append(item)
            if len(matches) != 1:
                raise RuntimeError(
                    f"expected one {net} via at {x:.4f},{y:.4f}, found {len(matches)}"
                )
            via = matches[0]
            if via.GetWidth(pcbnew.F_Cu) / 1e6 < 0.60 - 1e-6:
                raise RuntimeError(f"unexpectedly small via land for {net} at {x},{y}")
            via.SetDrill(pcbnew.FromMM(CLOSE_PAIR_DRILL_MM))
            resized[str(via.m_Uuid.AsString())] = via
    return list(resized.values())


def widen_breakout_tracks(board):
    widened = {}
    for net, layer, first, second, width in BREAKOUT_TRACKS:
        matches = []
        for item in board.GetTracks():
            if type(item).__name__ != "PCB_TRACK" or item.GetNetname() != net:
                continue
            if board.GetLayerName(item.GetLayer()) != layer:
                continue
            start = point(item, "start")
            end = point(item, "end")
            direct = math.dist(start, first) < 0.01 and math.dist(end, second) < 0.01
            reverse = math.dist(start, second) < 0.01 and math.dist(end, first) < 0.01
            if direct or reverse:
                matches.append(item)
        if len(matches) != 1:
            raise RuntimeError(
                f"expected one {net} breakout {first}->{second}, found {len(matches)}"
            )
        track = matches[0]
        track.SetWidth(pcbnew.FromMM(width))
        widened[str(track.m_Uuid.AsString())] = track
    return list(widened.values())


def add_bridge_tracks(board):
    added = []
    for net, layer, first, second, width in BRIDGE_TRACKS:
        for item in board.GetTracks():
            if type(item).__name__ != "PCB_TRACK" or item.GetNetname() != net:
                continue
            if board.GetLayerName(item.GetLayer()) != layer:
                continue
            start = point(item, "start")
            end = point(item, "end")
            direct = math.dist(start, first) < 0.01 and math.dist(end, second) < 0.01
            reverse = math.dist(start, second) < 0.01 and math.dist(end, first) < 0.01
            if direct or reverse:
                if item.GetWidth() / 1e6 < width - 1e-6:
                    item.SetWidth(pcbnew.FromMM(width))
                break
        else:
            track = pcbnew.PCB_TRACK(board)
            track.SetStart(pcbnew.VECTOR2I_MM(*first))
            track.SetEnd(pcbnew.VECTOR2I_MM(*second))
            track.SetLayer(board.GetLayerID(layer))
            track.SetWidth(pcbnew.FromMM(width))
            track.SetNetCode(board.FindNet(net).GetNetCode())
            board.Add(track)
            added.append(track)
    return added


def unconnected_count(board):
    board.BuildConnectivity()
    connectivity = board.GetConnectivity()
    connectivity.RecalculateRatsnest()
    return connectivity.GetUnconnectedCount(False)


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("source", type=Path)
    parser.add_argument("report", type=Path)
    parser.add_argument("output", type=Path)
    args = parser.parse_args()
    source, report, output = (
        args.source.resolve(),
        args.report.resolve(),
        args.output.resolve(),
    )
    if source == output:
        parser.error("output must differ from source")
    board = pcbnew.LoadBoard(str(source))
    tracks = match_dangling_tracks(board, report)
    vias = match_dangling_vias(board, report)
    redundant = match_redundant_vias(board)
    items = {}
    for item in tracks + vias + redundant:
        items[str(item.m_Uuid.AsString())] = item

    baseline_unconnected = unconnected_count(board)
    removed = []
    retained = []
    for key in sorted(items):
        item = items[key]
        board.Remove(item)
        after = unconnected_count(board)
        if after > baseline_unconnected:
            board.Add(item)
            restored = unconnected_count(board)
            if restored != baseline_unconnected:
                raise RuntimeError(
                    f"could not restore connectivity after retaining {key}: "
                    f"expected {baseline_unconnected}, got {restored}"
                )
            retained.append(item)
        else:
            removed.append(item)
            baseline_unconnected = after

    resized = resize_close_via_pairs(board)
    widened = widen_breakout_tracks(board)
    bridges = add_bridge_tracks(board)
    if not pcbnew.ZONE_FILLER(board).Fill(board.Zones()):
        raise RuntimeError("zone fill failed")
    final_unconnected = unconnected_count(board)
    if final_unconnected:
        raise RuntimeError(
            f"warning cleanup left {final_unconnected} unconnected items"
        )
    if not pcbnew.SaveBoard(str(output), board):
        raise RuntimeError(f"could not save {output}")
    for suffix in (".kicad_pro", ".rules"):
        companion = source.with_suffix(suffix)
        if companion.exists():
            shutil.copy2(companion, output.with_suffix(suffix))
    print(f"removed_dangling_tracks={len(tracks)}")
    print(f"removed_dangling_vias={len(vias)}")
    print(f"removed_redundant_vias={len(redundant)}")
    print(f"candidate_items={len(items)}")
    print(f"accepted_deletions={len(removed)}")
    print(f"connectivity_retained_items={len(retained)}")
    print(f"resized_close_pair_vias={len(resized)}")
    print(f"widened_breakout_tracks={len(widened)}")
    print(f"added_bridge_tracks={len(bridges)}")
    print(f"unconnected={final_unconnected}")
    print(f"output={output}")


if __name__ == "__main__":
    main()
