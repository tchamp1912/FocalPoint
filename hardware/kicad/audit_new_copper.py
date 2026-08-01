#!/Applications/KiCad/KiCad.app/Contents/Frameworks/Python.framework/Versions/3.9/bin/python3.9
"""Exact-shape static audit of copper added after the last GUI-clean baseline."""

from pathlib import Path
import sys

import pcbnew


ROOT = Path(__file__).resolve().parent
BASELINE = ROOT / "focalpoint_radio_bottomright_6layer_pass2_powerfixed_candidate.kicad_pcb"
RELEASE = Path(sys.argv[1]).resolve() if len(sys.argv) > 1 else ROOT / "focalpoint_rev_a_release_final.kicad_pcb"
REPORT = Path(sys.argv[2]).resolve() if len(sys.argv) > 2 else ROOT / "new_copper_static_audit.txt"
LAYERS = (
    pcbnew.F_Cu,
    pcbnew.In1_Cu,
    pcbnew.In2_Cu,
    pcbnew.In3_Cu,
    pcbnew.In4_Cu,
    pcbnew.B_Cu,
)
MM = pcbnew.FromMM
CLEARANCE = MM(0.15)


def uuid(item):
    return str(item.m_Uuid.AsString())


def label(item):
    if isinstance(item, pcbnew.PAD):
        return f"{item.GetParentFootprint().GetReference()}.{item.GetNumber()} pad"
    if isinstance(item, pcbnew.PCB_VIA):
        p = item.GetPosition()
        return f"{item.GetNetname()} via@{p.x/1e6:.3f},{p.y/1e6:.3f}"
    start, end = item.GetStart(), item.GetEnd()
    return (
        f"{item.GetNetname()} track@{start.x/1e6:.3f},{start.y/1e6:.3f}"
        f"->{end.x/1e6:.3f},{end.y/1e6:.3f}"
    )


def on_layer(item, layer):
    if isinstance(item, pcbnew.PCB_VIA):
        return layer in set(item.GetLayerSet().Seq())
    if isinstance(item, pcbnew.PAD):
        return layer in set(item.GetLayerSet().Seq())
    return item.GetLayer() == layer


def main():
    baseline = pcbnew.LoadBoard(str(BASELINE))
    release = pcbnew.LoadBoard(str(RELEASE))
    baseline_ids = {uuid(item) for item in baseline.GetTracks()}
    new_items = [item for item in release.GetTracks() if uuid(item) not in baseline_ids]
    all_items = list(release.GetTracks())
    for footprint in release.GetFootprints():
        all_items.extend(footprint.Pads())

    violations = []
    checked = 0
    seen = set()
    for layer in LAYERS:
        layer_items = [item for item in all_items if on_layer(item, layer)]
        for item in new_items:
            if not on_layer(item, layer):
                continue
            shape = item.GetEffectiveShape(layer)
            for other in layer_items:
                if uuid(item) == uuid(other) or item.GetNetCode() == other.GetNetCode():
                    continue
                pair = tuple(sorted((uuid(item), uuid(other)))) + (layer,)
                if pair in seen:
                    continue
                seen.add(pair)
                checked += 1
                if shape.Collide(other.GetEffectiveShape(layer), CLEARANCE):
                    violations.append(
                        f"{release.GetLayerName(layer)}: {label(item)} <> {label(other)}"
                    )

    fabrication = []
    for item in release.GetTracks():
        if isinstance(item, pcbnew.PCB_VIA):
            diameter = item.GetWidth(pcbnew.F_Cu) / 1e6
            drill = item.GetDrillValue() / 1e6
            annular = (diameter - drill) / 2
            if diameter < 0.25 - 1e-6 or drill < 0.15 - 1e-6 or annular < 0.05 - 1e-6:
                fabrication.append(
                    f"via geometry {label(item)} = {diameter:.3f}/{drill:.3f} mm"
                )
        elif item.GetWidth() / 1e6 < 0.09 - 1e-6:
            fabrication.append(
                f"track width {label(item)} = {item.GetWidth()/1e6:.3f} mm"
            )

    text = (
        f"baseline={BASELINE.name}\nrelease={RELEASE.name}\n"
        f"new_track_or_via_items={len(new_items)}\n"
        f"different-net_shape_pairs_checked={checked}\n"
        f"clearance_violations={len(violations)}\n"
    )
    if violations:
        text += "\n".join(violations) + "\n"
    text += f"fabrication_minimum_violations={len(fabrication)}\n"
    if fabrication:
        text += "\n".join(fabrication) + "\n"
    REPORT.write_text(text)
    print(text)
    if violations or fabrication:
        raise RuntimeError("static copper audit failed")


if __name__ == "__main__":
    main()
