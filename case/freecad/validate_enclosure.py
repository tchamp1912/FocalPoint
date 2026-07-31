"""Validate the generated FocalPoint enclosure/PCB assembly deterministically.

Run from the repository root:
  /Applications/FreeCAD.app/Contents/Resources/bin/freecadcmd \
    case/freecad/validate_enclosure.py
"""

from pathlib import Path

import FreeCAD as App
import Part


REPO = Path(__file__).resolve().parents[2]
MODEL = REPO / "case" / "output" / "focalpoint-rev-a.FCStd"
REPORT = REPO / "case" / "output" / "focalpoint-enclosure-validation.txt"


def dimensions(shape):
    box = shape.BoundBox
    return box.XLength, box.YLength, box.ZLength


def solid_summary(label, shape, limit=24):
    """Return the largest overlap solids so mechanical fixes are actionable."""
    solids = sorted(shape.Solids, key=lambda solid: solid.Volume, reverse=True)
    lines = [f"{label}_solid_count={len(solids)}"]
    for index, solid in enumerate(solids[:limit], start=1):
        box = solid.BoundBox
        lines.append(
            f"{label}_solid_{index}: volume={solid.Volume:.6f}mm3 "
            f"bbox={box.XLength:.3f}x{box.YLength:.3f}x{box.ZLength:.3f}mm "
            f"min=({box.XMin:.3f},{box.YMin:.3f},{box.ZMin:.3f})mm"
        )
    if len(solids) > limit:
        lines.append(f"{label}_solid_details_truncated={len(solids) - limit}")
    return lines


def main():
    document = App.openDocument(str(MODEL))
    names = [
        "BottomShell",
        "TopPlateShell",
        "BottomGrommet",
        "BatteryEnvelope_PLACEHOLDER",
        "AntennaKeepout_PLACEHOLDER",
        "PopulatedPCB_REFERENCE",
    ]
    objects = {}
    lines = [f"model={MODEL.name}"]
    failures = []

    for name in names:
        obj = document.getObject(name)
        if obj is None:
            failures.append(f"missing object: {name}")
            continue
        objects[name] = obj
        valid = obj.Shape.isValid()
        x, y, z = dimensions(obj.Shape)
        lines.append(
            f"{name}: valid={valid} solids={len(obj.Shape.Solids)} "
            f"bbox={x:.3f}x{y:.3f}x{z:.3f}mm volume={obj.Shape.Volume:.3f}mm3"
        )
        if not valid:
            failures.append(f"invalid shape: {name}")

    pcb = objects.get("PopulatedPCB_REFERENCE")
    if pcb:
        x, y, _ = dimensions(pcb.Shape)
        # The tilted populated assembly includes components, but its XY board
        # footprint must still be at least the exact 116 x 116 mm outline.
        if x < 115.99 or y < 115.99:
            failures.append(f"PCB reference bbox unexpectedly small: {x:.3f}x{y:.3f}")

    pair_checks = [
        ("pcb_bottom_intersection", "PopulatedPCB_REFERENCE", "BottomShell"),
        ("pcb_top_intersection", "PopulatedPCB_REFERENCE", "TopPlateShell"),
        ("battery_pcb_intersection", "BatteryEnvelope_PLACEHOLDER", "PopulatedPCB_REFERENCE"),
        ("battery_bottom_intersection", "BatteryEnvelope_PLACEHOLDER", "BottomShell"),
        ("top_bottom_intersection", "TopPlateShell", "BottomShell"),
        ("grommet_bottom_intersection", "BottomGrommet", "BottomShell"),
    ]
    for label, first, second in pair_checks:
        if first not in objects or second not in objects:
            continue
        a = objects[first].Shape
        b = objects[second].Shape
        common = a.common(b)
        distance = a.distToShape(b)[0]
        if common.Volume > 0.01:
            common_box = common.BoundBox
            lines.append(
                f"{label}: common_volume={common.Volume:.6f}mm3 "
                f"minimum_distance={distance:.6f}mm "
                f"common_bbox={common_box.XLength:.3f}x{common_box.YLength:.3f}x"
                f"{common_box.ZLength:.3f}mm "
                f"common_min=({common_box.XMin:.3f},{common_box.YMin:.3f},"
                f"{common_box.ZMin:.3f})mm"
            )
            lines.extend(solid_summary(label, common))
        else:
            lines.append(
                f"{label}: common_volume={common.Volume:.6f}mm3 "
                f"minimum_distance={distance:.6f}mm"
            )
        if common.Volume > 0.01:
            Part.export(
                [common],
                str(REPORT.parent / f"focalpoint-{label}.step"),
            )
            failures.append(
                f"{label} has {common.Volume:.6f} mm3 overlap; inspect assembly"
            )

    lines.append(f"failures={len(failures)}")
    lines.extend(f"FAIL: {failure}" for failure in failures)
    REPORT.write_text("\n".join(lines) + "\n")
    print("\n".join(lines))
    App.closeDocument(document.Name)
    if failures:
        raise RuntimeError("enclosure validation found failures")


if __name__ == "__main__":
    main()
