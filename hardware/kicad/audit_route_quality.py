#!/usr/bin/env python3
import collections
import math
import sys

import pcbnew


board = pcbnew.LoadBoard(sys.argv[1])
edge_points = []
for drawing in board.GetDrawings():
    if drawing.GetLayer() != pcbnew.Edge_Cuts:
        continue
    for getter in ("GetStart", "GetEnd"):
        if hasattr(drawing, getter):
            point = getattr(drawing, getter)()
            edge_points.append((point.x / 1e6, point.y / 1e6))
if not edge_points:
    raise SystemExit("no Edge.Cuts geometry")
x0 = min(point[0] for point in edge_points)
y0 = min(point[1] for point in edge_points)
x1 = max(point[0] for point in edge_points)
y1 = max(point[1] for point in edge_points)

tracks = [item for item in board.GetTracks() if type(item).__name__ == "PCB_TRACK"]
vias = [item for item in board.GetTracks() if type(item).__name__ == "PCB_VIA"]

layer_stats = collections.defaultdict(lambda: [0, 0.0])
edge_hits = []
side_minima = {side: (float("inf"), None) for side in ("left", "right", "top", "bottom")}
short_1 = short_2 = 0
nodes = collections.defaultdict(list)
net_lengths = collections.defaultdict(float)

for track in tracks:
    a = track.GetStart()
    b = track.GetEnd()
    ax, ay = a.x / 1e6, a.y / 1e6
    bx, by = b.x / 1e6, b.y / 1e6
    width = track.GetWidth() / 1e6
    length = math.hypot(bx - ax, by - ay)
    layer = board.GetLayerName(track.GetLayer())
    net = track.GetNetname()
    layer_stats[layer][0] += 1
    layer_stats[layer][1] += length
    net_lengths[net] += length
    short_1 += length < 1.0
    short_2 += length < 2.0
    side_distances = {
        "left": min(ax, bx) - x0 - width / 2,
        "right": x1 - max(ax, bx) - width / 2,
        "top": min(ay, by) - y0 - width / 2,
        "bottom": y1 - max(ay, by) - width / 2,
    }
    for side, distance in side_distances.items():
        if distance < side_minima[side][0]:
            side_minima[side] = (distance, (net, layer, ax, ay, bx, by, width))
    clearance = min(side_distances.values())
    if clearance < 0.50:
        side = min(side_distances, key=side_distances.get)
        edge_hits.append((clearance, side, net, layer, ax, ay, bx, by, width))
    key_a = (net, layer, a.x, a.y)
    key_b = (net, layer, b.x, b.y)
    nodes[key_a].append((bx - ax, by - ay))
    nodes[key_b].append((ax - bx, ay - by))

corner_counts = collections.Counter()
for vectors in nodes.values():
    if len(vectors) != 2:
        continue
    (ax, ay), (bx, by) = vectors
    denom = math.hypot(ax, ay) * math.hypot(bx, by)
    if not denom:
        continue
    angle = math.degrees(math.acos(max(-1.0, min(1.0, (ax * bx + ay * by) / denom))))
    turn = 180.0 - angle
    if turn < 1.0:
        corner_counts["straight_redundant"] += 1
    elif 40 <= turn <= 50:
        corner_counts["45_degree"] += 1
    elif 85 <= turn <= 95:
        corner_counts["90_degree"] += 1
    elif turn > 95:
        corner_counts[">95_degree"] += 1
    else:
        corner_counts["other"] += 1

def pad_points(netname):
    pts = []
    for fp in board.GetFootprints():
        for pad in fp.Pads():
            if pad.GetNetname() == netname:
                p = pad.GetPosition()
                pts.append((p.x / 1e6, p.y / 1e6))
    return list(dict.fromkeys(pts))

detours = []
for net, length in net_lengths.items():
    pts = pad_points(net)
    if len(pts) != 2:
        continue
    direct = math.dist(pts[0], pts[1])
    if direct > 1.0 and length > direct:
        detours.append((length / direct, net, length, direct))

print(f"board_bounds_mm={x0:.3f},{y0:.3f}..{x1:.3f},{y1:.3f}")
print(f"track_segments={len(tracks)}")
print(f"vias={len(vias)}")
print(f"segments_under_1mm={short_1}")
print(f"segments_under_2mm={short_2}")
print("corner_counts=" + ",".join(f"{key}:{value}" for key, value in sorted(corner_counts.items())))
print("layer_usage:")
for layer, (count, length) in sorted(layer_stats.items()):
    print(f"  {layer}: segments={count} length_mm={length:.1f}")
print(f"copper_segments_under_0.50mm_from_edge={len(edge_hits)}")
print("minimum_track_edge_clearance_by_side:")
for side, (distance, item) in side_minima.items():
    net, layer, ax, ay, bx, by, width = item
    print(f"  {side}: clearance={distance:.3f} net={net} layer={layer} width={width:.3f} from=({ax:.3f},{ay:.3f}) to=({bx:.3f},{by:.3f})")
print("closest_edge_segments:")
for hit in sorted(edge_hits)[:20]:
    clearance, side, net, layer, ax, ay, bx, by, width = hit
    print(f"  clearance={clearance:.3f} side={side} net={net} layer={layer} width={width:.3f} from=({ax:.3f},{ay:.3f}) to=({bx:.3f},{by:.3f})")
print("largest_two_pad_detour_ratios:")
for ratio, net, length, direct in sorted(detours, reverse=True)[:25]:
    print(f"  ratio={ratio:.2f} net={net} routed_mm={length:.1f} direct_mm={direct:.1f}")
