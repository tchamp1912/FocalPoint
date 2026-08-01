#!/usr/bin/env python3
"""Audit rectangular KiCad boards for external copper-edge clearance."""

from __future__ import annotations

import argparse
import re
from dataclasses import dataclass
from pathlib import Path

import pcbnew


MM = 1_000_000


@dataclass(order=True)
class Finding:
    clearance: float
    kind: str
    label: str
    side: str
    detail: str


def edge_bounds(board: pcbnew.BOARD) -> tuple[float, float, float, float]:
    points = []
    for drawing in board.GetDrawings():
        if drawing.GetLayer() != pcbnew.Edge_Cuts:
            continue
        for getter in ("GetStart", "GetEnd"):
            if hasattr(drawing, getter):
                point = getattr(drawing, getter)()
                points.append((point.x / MM, point.y / MM))
    if not points:
        raise SystemExit("no Edge.Cuts geometry")
    return (
        min(point[0] for point in points),
        min(point[1] for point in points),
        max(point[0] for point in points),
        max(point[1] for point in points),
    )


def nearest_side(
    left: float, top: float, right: float, bottom: float,
    bounds: tuple[float, float, float, float],
) -> tuple[str, float]:
    x0, y0, x1, y1 = bounds
    distances = {
        "left": left - x0,
        "right": x1 - right,
        "top": top - y0,
        "bottom": y1 - bottom,
    }
    side = min(distances, key=distances.get)
    return side, distances[side]


def allowed(finding: Finding, patterns: list[re.Pattern[str]]) -> bool:
    text = f"{finding.kind}:{finding.label}:{finding.side}"
    return any(pattern.search(text) for pattern in patterns)


def main() -> None:
    parser = argparse.ArgumentParser(
        description="Rectangular-outline audit; intentional edge features require --allow."
    )
    parser.add_argument("board", type=Path)
    parser.add_argument("--min-track", type=float, default=1.0)
    parser.add_argument("--min-via", type=float, default=1.0)
    parser.add_argument("--min-pad", type=float, default=1.0)
    parser.add_argument("--min-zone", type=float, default=0.5)
    parser.add_argument("--allow", action="append", default=[], help="regex matched against kind:label:side")
    args = parser.parse_args()
    patterns = [re.compile(pattern) for pattern in args.allow]
    board = pcbnew.LoadBoard(str(args.board.resolve()))
    bounds = edge_bounds(board)
    findings: list[Finding] = []

    for item in board.GetTracks():
        if isinstance(item, pcbnew.PCB_VIA):
            point = item.GetPosition()
            radius = item.GetWidth(pcbnew.F_Cu) / MM / 2
            x, y = point.x / MM, point.y / MM
            side, clearance = nearest_side(x - radius, y - radius, x + radius, y + radius, bounds)
            if clearance < args.min_via:
                findings.append(Finding(clearance, "via", item.GetNetname(), side, f"at={x:.3f},{y:.3f} diameter={2*radius:.3f}"))
            continue
        start, end = item.GetStart(), item.GetEnd()
        radius = item.GetWidth() / MM / 2
        ax, ay = start.x / MM, start.y / MM
        bx, by = end.x / MM, end.y / MM
        side, clearance = nearest_side(min(ax, bx) - radius, min(ay, by) - radius, max(ax, bx) + radius, max(ay, by) + radius, bounds)
        if clearance < args.min_track:
            findings.append(Finding(clearance, "track", item.GetNetname(), side, f"{ax:.3f},{ay:.3f}->{bx:.3f},{by:.3f}"))

    copper_layers = {pcbnew.F_Cu, pcbnew.B_Cu}
    for index in range(1, 31):
        layer = board.GetLayerID(f"In{index}.Cu")
        if layer >= 0 and board.IsLayerEnabled(layer):
            copper_layers.add(layer)
    for footprint in board.GetFootprints():
        for pad in footprint.Pads():
            if not copper_layers.intersection(pad.GetLayerSet().Seq()):
                continue
            box = pad.GetBoundingBox()
            side, clearance = nearest_side(box.GetLeft()/MM, box.GetTop()/MM, box.GetRight()/MM, box.GetBottom()/MM, bounds)
            if clearance < args.min_pad:
                label = f"{footprint.GetReference()}.{pad.GetNumber()}:{pad.GetNetname()}"
                findings.append(Finding(clearance, "pad", label, side, "bounding-box clearance"))

    for zone in board.Zones():
        box = zone.GetBoundingBox()
        side, clearance = nearest_side(box.GetLeft()/MM, box.GetTop()/MM, box.GetRight()/MM, box.GetBottom()/MM, bounds)
        if clearance < args.min_zone:
            findings.append(Finding(clearance, "zone", zone.GetNetname(), side, board.GetLayerName(zone.GetLayer())))

    failures = [finding for finding in findings if not allowed(finding, patterns)]
    print(f"board_bounds_mm={bounds[0]:.3f},{bounds[1]:.3f}..{bounds[2]:.3f},{bounds[3]:.3f}")
    print(f"findings={len(findings)}")
    print(f"allowed={len(findings) - len(failures)}")
    print(f"failures={len(failures)}")
    for finding in sorted(findings):
        disposition = "ALLOWED" if allowed(finding, patterns) else "FAIL"
        print(f"{disposition} clearance={finding.clearance:.3f} kind={finding.kind} side={finding.side} label={finding.label} {finding.detail}")
    if failures:
        raise SystemExit("external copper-edge audit failed")


if __name__ == "__main__":
    main()
