#!/usr/bin/env python3
"""Add short, manufacturable GND fanouts from SMD pads to the inner planes."""

from __future__ import annotations

import math
from pathlib import Path

import pcbnew


ROOT = Path(__file__).resolve().parent
SOURCE = ROOT / "focalpoint_rev_b_4layer_working.kicad_pcb"
OUTPUT = ROOT / "focalpoint_rev_b_4layer_ground_fanout_baseline.kicad_pcb"
REPORT = ROOT / "focalpoint_rev_b_4layer_ground_fanout_baseline.txt"

VIA_DIAMETER_MM = 0.6
VIA_DRILL_MM = 0.3
TRACK_WIDTH_MM = 0.3
CLEARANCE_MM = 0.15
EDGE_CLEARANCE_MM = 1.0


def mm(value: float) -> int:
    return pcbnew.FromMM(value)


def distance_to_segment(px, py, ax, ay, bx, by) -> float:
    dx, dy = bx - ax, by - ay
    if dx == 0 and dy == 0:
        return math.hypot(px - ax, py - ay)
    t = max(0.0, min(1.0, ((px - ax) * dx + (py - ay) * dy) / (dx * dx + dy * dy)))
    return math.hypot(px - (ax + t * dx), py - (ay + t * dy))


def copper_layers(pad):
    return {layer for layer in (pcbnew.F_Cu, pcbnew.In1_Cu, pcbnew.In2_Cu, pcbnew.B_Cu)
            if pad.IsOnLayer(layer)}


def candidate_clear(board, source_pad, x_mm: float, y_mm: float) -> bool:
    via_radius = VIA_DIAMETER_MM / 2
    if not (100 + EDGE_CLEARANCE_MM + via_radius <= x_mm <= 216 - EDGE_CLEARANCE_MM - via_radius):
        return False
    if not (100 + EDGE_CLEARANCE_MM + via_radius <= y_mm <= 216 - EDGE_CLEARANCE_MM - via_radius):
        return False

    for footprint in board.GetFootprints():
        for pad in footprint.Pads():
            if pad.m_Uuid == source_pad.m_Uuid or not copper_layers(pad):
                continue
            if pad.GetNetCode() == source_pad.GetNetCode():
                continue
            box = pad.GetBoundingBox()
            margin = mm(via_radius + CLEARANCE_MM)
            box.Inflate(margin)
            if box.Contains(pcbnew.VECTOR2I(mm(x_mm), mm(y_mm))):
                return False

    for item in board.GetTracks():
        if item.GetNetCode() == source_pad.GetNetCode():
            continue
        if isinstance(item, pcbnew.PCB_VIA):
            pos = item.GetPosition()
            required = via_radius + item.GetWidth(pcbnew.F_Cu) / 2e6 + CLEARANCE_MM
            if math.hypot(x_mm - pos.x / 1e6, y_mm - pos.y / 1e6) < required:
                return False
        else:
            a, b = item.GetStart(), item.GetEnd()
            required = via_radius + item.GetWidth() / 2e6 + CLEARANCE_MM
            if distance_to_segment(x_mm, y_mm, a.x / 1e6, a.y / 1e6,
                                   b.x / 1e6, b.y / 1e6) < required:
                return False
    return True


def trace_clear(board, source_pad, x_mm: float, y_mm: float) -> bool:
    start = source_pad.GetPosition()
    ax, ay = start.x / 1e6, start.y / 1e6
    trace_radius = TRACK_WIDTH_MM / 2
    layer = pcbnew.F_Cu if source_pad.IsOnLayer(pcbnew.F_Cu) else pcbnew.B_Cu
    for footprint in board.GetFootprints():
        for pad in footprint.Pads():
            if pad.m_Uuid == source_pad.m_Uuid or not pad.IsOnLayer(layer):
                continue
            if pad.GetNetCode() == source_pad.GetNetCode():
                continue
            box = pad.GetBoundingBox()
            box.Inflate(mm(trace_radius + CLEARANCE_MM))
            # Axis-aligned bounding boxes are conservative for rotated pads,
            # but unlike a circumscribed circle they preserve the legal escape
            # channel between adjacent fine-pitch pins.
            for step in range(1, 21):
                t = step / 20
                point = pcbnew.VECTOR2I(
                    mm(ax + t * (x_mm - ax)), mm(ay + t * (y_mm - ay))
                )
                if box.Contains(point):
                    return False
    for item in board.GetTracks():
        if item.GetNetCode() == source_pad.GetNetCode():
            continue
        if isinstance(item, pcbnew.PCB_VIA):
            pos = item.GetPosition()
            required = trace_radius + item.GetWidth(layer) / 2e6 + CLEARANCE_MM
            if distance_to_segment(pos.x / 1e6, pos.y / 1e6,
                                   ax, ay, x_mm, y_mm) < required:
                return False
        elif item.GetLayer() == layer:
            # Conservative sampled segment-to-segment check.
            a, b = item.GetStart(), item.GetEnd()
            required = trace_radius + item.GetWidth() / 2e6 + CLEARANCE_MM
            for step in range(11):
                t = step / 10
                px, py = ax + t * (x_mm - ax), ay + t * (y_mm - ay)
                if distance_to_segment(px, py, a.x / 1e6, a.y / 1e6,
                                       b.x / 1e6, b.y / 1e6) < required:
                    return False
    return True


def candidates(pad):
    p = pad.GetPosition()
    fp = pad.GetParentFootprint()
    center = fp.GetPosition()
    dx, dy = p.x - center.x, p.y - center.y
    angle = math.atan2(dy, dx) if dx or dy else 0.0
    angles = [angle, angle + math.pi / 2, angle - math.pi / 2, angle + math.pi]
    angles += [index * math.pi / 8 for index in range(16)]
    for distance in (0.55, 0.7, 0.9, 1.2, 1.5, 1.8, 2.1, 2.5, 3.0, 3.5, 4.0):
        for theta in angles:
            yield (p.x / 1e6 + distance * math.cos(theta),
                   p.y / 1e6 + distance * math.sin(theta))


def main() -> None:
    board = pcbnew.LoadBoard(str(SOURCE))
    gnd = board.FindNet("GND")
    added = []
    failed = []
    processed = set()
    processed_positions = set()
    plated_pad_numbers = {
        (fp.GetReference(), pad.GetNumber())
        for fp in board.GetFootprints() for pad in fp.Pads()
        if pad.GetNetCode() == gnd.GetNetCode()
        and pad.GetAttribute() != pcbnew.PAD_ATTRIB_SMD
    }
    for footprint in board.GetFootprints():
        for pad in footprint.Pads():
            if pad.GetNetCode() != gnd.GetNetCode() or pad.GetAttribute() != pcbnew.PAD_ATTRIB_SMD:
                continue
            logical_pad = (footprint.GetReference(), pad.GetNumber())
            if logical_pad in processed or logical_pad in plated_pad_numbers:
                continue
            processed.add(logical_pad)
            position_key = (pad.GetPosition().x, pad.GetPosition().y, pad.GetNetCode())
            if position_key in processed_positions:
                continue
            processed_positions.add(position_key)
            choice = next(((x, y) for x, y in candidates(pad)
                           if candidate_clear(board, pad, x, y)
                           and trace_clear(board, pad, x, y)), None)
            label = f"{footprint.GetReference()}.{pad.GetNumber()}"
            if choice is None:
                failed.append(label)
                continue
            x_mm, y_mm = choice
            layer = pcbnew.F_Cu if pad.IsOnLayer(pcbnew.F_Cu) else pcbnew.B_Cu
            track = pcbnew.PCB_TRACK(board)
            track.SetStart(pad.GetPosition())
            track.SetEnd(pcbnew.VECTOR2I(mm(x_mm), mm(y_mm)))
            track.SetWidth(mm(TRACK_WIDTH_MM))
            track.SetLayer(layer)
            track.SetNetCode(gnd.GetNetCode())
            board.Add(track)

            via = pcbnew.PCB_VIA(board)
            via.SetPosition(pcbnew.VECTOR2I(mm(x_mm), mm(y_mm)))
            via.SetWidth(mm(VIA_DIAMETER_MM))
            via.SetDrill(mm(VIA_DRILL_MM))
            via.SetLayerPair(pcbnew.F_Cu, pcbnew.B_Cu)
            via.SetNetCode(gnd.GetNetCode())
            board.Add(via)
            added.append(f"{label}@{x_mm:.3f},{y_mm:.3f}")

    pcbnew.ZONE_FILLER(board).Fill(board.Zones())
    # Reserve the only radio-module fanout that the bulk router otherwise
    # boxes in.  The staggered 0.8 mm pitch needs a short neck before the via.
    enc_b_pad = next(
        pad for pad in board.FindFootprintByReference("U1").Pads()
        if pad.GetNumber() == "42"
    )
    enc_b_end = pcbnew.VECTOR2I(mm(204.1605), mm(199.2419))
    enc_b_track = pcbnew.PCB_TRACK(board)
    enc_b_track.SetStart(enc_b_pad.GetPosition())
    enc_b_track.SetEnd(enc_b_end)
    enc_b_track.SetWidth(mm(0.15))
    enc_b_track.SetLayer(pcbnew.B_Cu)
    enc_b_track.SetNetCode(enc_b_pad.GetNetCode())
    board.Add(enc_b_track)
    enc_b_via = pcbnew.PCB_VIA(board)
    enc_b_via.SetPosition(enc_b_end)
    enc_b_via.SetWidth(mm(0.45))
    enc_b_via.SetDrill(mm(0.20))
    enc_b_via.SetLayerPair(pcbnew.F_Cu, pcbnew.B_Cu)
    enc_b_via.SetNetCode(enc_b_pad.GetNetCode())
    board.Add(enc_b_via)
    pcbnew.ZONE_FILLER(board).Fill(board.Zones())
    board.BuildConnectivity()
    unconnected = board.GetConnectivity().GetUnconnectedCount(False)
    pcbnew.SaveBoard(str(OUTPUT), board)
    REPORT.write_text(
        f"source={SOURCE.name}\noutput={OUTPUT.name}\n"
        f"ground_fanouts_added={len(added)}\n"
        f"ground_fanouts_failed={len(failed)}\n"
        "reserved_signal_fanouts=ENC_B\n"
        f"unconnected_after_fill={unconnected}\n"
        + "failed=" + ",".join(failed) + "\n"
        + "added=\n" + "\n".join(added) + "\n"
    )
    print(REPORT.read_text(), end="")


if __name__ == "__main__":
    main()
