"""Generate the parametric FocalPoint Rev A enclosure with FreeCAD.

Run from the repository root:
  /Applications/FreeCAD.app/Contents/Resources/bin/freecadcmd case/freecad/enclosure.py

The script intentionally models component-specific openings as prototype
envelopes. Update them from measured, selected parts before manufacturing.
"""

from pathlib import Path
import math

import FreeCAD as App
import Mesh
import Part


REPO = Path(__file__).resolve().parents[2]
OUTPUT = REPO / "case" / "output"
OUTPUT.mkdir(parents=True, exist_ok=True)

# Master parameters, millimetres/degrees. Keep DESIGN.md in sync when changing
# a user-facing design value.
PCB_W = 108.0
PCB_D = 108.0
PCB_CLEARANCE = 3.0
SHELL_W = PCB_W + 2 * PCB_CLEARANCE
SHELL_D = PCB_D + 2 * PCB_CLEARANCE
CORNER_R = 12.0
WALL = 2.4
FLOOR = 2.4
FRONT_H = 11.0
SLOPE_DEG = 4.0
# The shell itself crosses the circular desk puck at a slight angle. The
# remaining angle is built into the hollow shell so the key plane totals 4°.
SHELL_TO_PUCK_DEG = 2.0
INTERNAL_SLOPE_DEG = SLOPE_DEG - SHELL_TO_PUCK_DEG
LOCAL_REAR_H = FRONT_H + SHELL_D * math.tan(math.radians(INTERNAL_SLOPE_DEG))
REAR_H = FRONT_H + SHELL_D * math.tan(math.radians(SLOPE_DEG))
PLATE_T = 1.6
PUCK_RADIUS = 43.0
PUCK_VISIBLE_H = 6.0
PUCK_EMBED_H = 5.0
GROMMET_EDGE_INSET = 7.0
GROMMET_RECESS = 1.2
GROMMET_T = 2.0
GROMMET_PROUD = GROMMET_T - GROMMET_RECESS
FIT_CLEARANCE = 0.30

# Board datum from KiCad Edge.Cuts: x=-24..84, y=-64..44. The front key row
# is the front. These offsets convert KiCad XY into enclosure-local XY.
KICAD_MIN_X = -24.0
KICAD_MIN_Y = -64.0


def rounded_prism(width, depth, radius, height, z=0.0, x=0.0, y=0.0):
    """Axis-aligned rounded rectangle extruded in +Z."""
    radius = min(radius, width / 2, depth / 2)
    shape = Part.makeBox(width - 2 * radius, depth, height,
                         App.Vector(x + radius, y, z))
    shape = shape.fuse(Part.makeBox(width, depth - 2 * radius, height,
                                    App.Vector(x, y + radius, z)))
    for cx in (x + radius, x + width - radius):
        for cy in (y + radius, y + depth - radius):
            shape = shape.fuse(Part.makeCylinder(radius, height,
                                                 App.Vector(cx, cy, z)))
    return shape.removeSplitter()


def wedge(width, depth, front_height, rear_height, x=0.0, y=0.0, z=0.0):
    """Linear front-to-rear wedge extruded along X."""
    profile = Part.makePolygon([
        App.Vector(x, y, z),
        App.Vector(x, y + depth, z),
        App.Vector(x, y + depth, z + rear_height),
        App.Vector(x, y, z + front_height),
        App.Vector(x, y, z),
    ])
    return Part.Face(profile).extrude(App.Vector(width, 0, 0))


def local_to_shell(kicad_x, kicad_y):
    return (
        kicad_x - KICAD_MIN_X + PCB_CLEARANCE,
        kicad_y - KICAD_MIN_Y + PCB_CLEARANCE,
    )


def plate_transform(shape):
    transformed = shape.copy()
    transformed.rotate(App.Vector(0, 0, 0), App.Vector(1, 0, 0), SLOPE_DEG)
    transformed.translate(App.Vector(0, 0, FRONT_H))
    return transformed


def set_view(obj, color, transparency=0):
    """Apply GUI presentation metadata when a GUI view provider exists."""
    if obj.ViewObject is not None:
        obj.ViewObject.ShapeColor = color
        obj.ViewObject.Transparency = transparency


doc = App.newDocument("FocalPoint_RevA_Enclosure")

# A spreadsheet makes dimensions visible and editable when the FCStd is opened.
sheet = doc.addObject("Spreadsheet::Sheet", "Parameters")
parameters = [
    ("PCB width", PCB_W, "mm"),
    ("PCB depth", PCB_D, "mm"),
    ("PCB clearance", PCB_CLEARANCE, "mm"),
    ("Shell width", SHELL_W, "mm"),
    ("Shell depth", SHELL_D, "mm"),
    ("Corner radius", CORNER_R, "mm"),
    ("Wall", WALL, "mm"),
    ("Floor", FLOOR, "mm"),
    ("Front height", FRONT_H, "mm"),
    ("Rear height", REAR_H, "mm"),
    ("Forward slope", SLOPE_DEG, "deg"),
    ("Plate thickness", PLATE_T, "mm"),
    ("Shell-to-puck angle", SHELL_TO_PUCK_DEG, "deg"),
    ("Circular puck radius", PUCK_RADIUS, "mm"),
    ("Grommet edge inset", GROMMET_EDGE_INSET, "mm"),
    ("Grommet recess", GROMMET_RECESS, "mm"),
    ("Fit clearance", FIT_CLEARANCE, "mm"),
]
sheet.set("A1", "Parameter")
sheet.set("B1", "Value")
sheet.set("C1", "Unit")
for row, (label, value, unit) in enumerate(parameters, start=2):
    sheet.set(f"A{row}", label)
    sheet.set(f"B{row}", f"{value:.3f}")
    sheet.set(f"C{row}", unit)
sheet.setColumnWidth("A", 190)
sheet.setColumnWidth("B", 90)
sheet.setColumnWidth("C", 55)

# Lower shell: rounded external wedge, hollowed from above, with a retained
# floor. The inner cut follows the same slope so wall height stays consistent.
outer_round = rounded_prism(SHELL_W, SHELL_D, CORNER_R, LOCAL_REAR_H)
outer = outer_round.common(wedge(SHELL_W, SHELL_D, FRONT_H, LOCAL_REAR_H))
inner_w = SHELL_W - 2 * WALL
inner_d = SHELL_D - 2 * WALL
inner_round = rounded_prism(inner_w, inner_d, CORNER_R - WALL,
                            LOCAL_REAR_H + 4, FLOOR, WALL, WALL)
inner_cut = inner_round.common(
    wedge(inner_w, inner_d, FRONT_H + 4, LOCAL_REAR_H + 4,
          WALL, WALL, FLOOR)
)
bottom_shape = outer.cut(inner_cut)

# Four heat-set-insert bosses. Their height follows the sloped plate datum.
boss_xy = [(12, 12), (SHELL_W - 12, 12),
           (12, SHELL_D - 12), (SHELL_W - 12, SHELL_D - 12)]
for bx, by in boss_xy:
    top_z = FRONT_H + by * math.tan(math.radians(INTERNAL_SLOPE_DEG))
    boss = Part.makeCylinder(4.5, top_z - FLOOR, App.Vector(bx, by, FLOOR))
    pilot = Part.makeCylinder(1.7, top_z + 2, App.Vector(bx, by, FLOOR))
    bottom_shape = bottom_shape.fuse(boss.cut(pilot))

# Rotate the complete rectangular shell across the circular pedestal. Rotation
# about the front top datum keeps the front seam registered with the top plate.
bottom_shape.rotate(App.Vector(0, 0, FRONT_H), App.Vector(1, 0, 0),
                    SHELL_TO_PUCK_DEG)

# Circular base/puck: its bottom remains flat on the desk while its upper half
# passes through the angled bottom-shell plane. The overlap makes the union
# structural rather than a tangent contact.
puck_center_x = SHELL_W / 2
puck_center_y = SHELL_D / 2
puck_z = -PUCK_VISIBLE_H
puck = Part.makeCylinder(
    PUCK_RADIUS,
    PUCK_VISIBLE_H + PUCK_EMBED_H,
    App.Vector(puck_center_x, puck_center_y, puck_z),
)
bottom_shape = bottom_shape.fuse(puck)

# A circular replaceable elastomer pad is recessed into the puck's flat face.
grommet_radius = PUCK_RADIUS - GROMMET_EDGE_INSET
grommet_recess = Part.makeCylinder(
    grommet_radius,
    GROMMET_RECESS,
    App.Vector(puck_center_x, puck_center_y, puck_z),
)
bottom_shape = bottom_shape.cut(grommet_recess)
grommet_shape = Part.makeCylinder(
    grommet_radius,
    GROMMET_T,
    App.Vector(puck_center_x, puck_center_y, puck_z - GROMMET_PROUD),
)

# Top/plate shell, modeled in its local plane and then tilted as one part.
plate_local = rounded_prism(SHELL_W, SHELL_D, CORNER_R, PLATE_T)

# MX cutouts use actual Ergogen centers. The three reserved cells are encoder
# top-left, joystick top-right, and touch bottom-right.
key_centers = [
    local_to_shell(x, y)
    for y in (20.0, 0.0, -20.0, -40.0)
    for x in (0.0, 20.0, 40.0, 60.0)
    if (x, y) not in {(0.0, 20.0), (60.0, 20.0), (60.0, -40.0)}
]

cutout = 14.0 + 2 * FIT_CLEARANCE
for cx, cy in key_centers:
    cutter = Part.makeBox(cutout, cutout, PLATE_T + 4,
                          App.Vector(cx - cutout / 2, cy - cutout / 2, -2))
    plate_local = plate_local.cut(cutter)

# Prototype control openings. Replace these values from the selected parts.
encoder_x, encoder_y = local_to_shell(0.0, 20.0)
touch_x, touch_y = local_to_shell(60.0, -40.0)
joystick_x, joystick_y = local_to_shell(60.0, 20.0)
joystick_cut = Part.makeCylinder(10.0, PLATE_T + 4,
                                 App.Vector(joystick_x, joystick_y, -2))
encoder_cut = Part.makeCylinder(4.0, PLATE_T + 4,
                                App.Vector(encoder_x, encoder_y, -2))
plate_local = plate_local.cut(joystick_cut.fuse(encoder_cut))

# A shallow circular witness mark identifies the capacitive touch cell without
# cutting through the plate or placing metal above the PCB electrode.
touch_mark = Part.makeCylinder(
    6.0, 0.30, App.Vector(touch_x, touch_y, PLATE_T - 0.20)
)
plate_local = plate_local.cut(touch_mark)

# M3-class lid clearance holes align with the four lower bosses.
for bx, by in boss_xy:
    screw = Part.makeCylinder(1.7, PLATE_T + 4, App.Vector(bx, by, -2))
    plate_local = plate_local.cut(screw)

top_shape = plate_transform(plate_local).removeSplitter()
bottom_shape = bottom_shape.removeSplitter()
grommet_shape = grommet_shape.removeSplitter()


def validate_shape(name, shape):
    if shape.isNull() or not shape.isValid():
        raise RuntimeError(f"{name} is not a valid B-rep")
    if len(shape.Solids) != 1:
        raise RuntimeError(f"{name} must be one printable solid; got {len(shape.Solids)}")
    if shape.Volume <= 0:
        raise RuntimeError(f"{name} has no positive volume")


validate_shape("bottom shell", bottom_shape)
validate_shape("top shell", top_shape)
validate_shape("top shell print orientation", plate_local)
validate_shape("bottom grommet", grommet_shape)

bottom = doc.addObject("PartDesign::Feature", "BottomShell")
bottom.Label = "Bottom shell — dark structural base"
bottom.Shape = bottom_shape
bottom.addProperty("App::PropertyString", "PrintOrientation", "Manufacturing")
bottom.PrintOrientation = "Circular puck face on build plate; supports off"
set_view(bottom, (0.12, 0.13, 0.14))

top = doc.addObject("PartDesign::Feature", "TopPlateShell")
top.Label = "Tilted top shell — frosted/translucent"
top.Shape = top_shape
top.addProperty("App::PropertyString", "PrototypeWarning", "Design")
top.PrototypeWarning = "Joystick and encoder apertures require selected-part measurements"
set_view(top, (0.72, 0.82, 0.84), 45)

top_print = doc.addObject("PartDesign::Feature", "TopPlateShell_PRINT")
top_print.Label = "Top shell — flat print orientation (export helper)"
top_print.Shape = plate_local
top_print.addProperty("App::PropertyString", "Purpose", "Manufacturing")
top_print.Purpose = "Flat, support-free STL export; use TopPlateShell for assembly"
if top_print.ViewObject is not None:
    top_print.ViewObject.Visibility = False

grommet = doc.addObject("PartDesign::Feature", "BottomGrommet")
grommet.Label = "Replaceable circular silicone/EPDM bottom grommet"
grommet.Shape = grommet_shape
grommet.addProperty("App::PropertyString", "MaterialTarget", "Manufacturing")
grommet.MaterialTarget = "1.5–2.0 mm silicone/EPDM, 50–70 Shore A"
set_view(grommet, (0.04, 0.04, 0.04))

# Reference envelopes are visible in FreeCAD but excluded from manufacturing
# exports. They make the unresolved component decisions obvious.
battery = doc.addObject("PartDesign::Feature", "BatteryEnvelope_PLACEHOLDER")
battery.Label = "1,000 mAh battery envelope placeholder — 50 × 32 × 9 mm"
battery.Shape = Part.makeBox(
    50, 32, 9, App.Vector((SHELL_W - 50) / 2, (SHELL_D - 32) / 2, FLOOR)
)
set_view(battery, (0.95, 0.65, 0.15), 70)

antenna = doc.addObject("PartDesign::Feature", "AntennaKeepout_PLACEHOLDER")
antenna.Label = "Radio antenna keep-out placeholder — replace from module datasheet"
antenna.Shape = Part.makeBox(25, 20, 12,
                             App.Vector(SHELL_W - WALL - 25,
                                        SHELL_D - WALL - 20, FLOOR))
set_view(antenna, (0.9, 0.15, 0.15), 75)

doc.recompute()
doc.saveAs(str(OUTPUT / "focalpoint-rev-a.FCStd"))

# Neutral CAD and print exports. The assembly STEP contains the three physical
# parts; reference envelopes remain only in the editable FCStd.
Part.export([bottom], str(OUTPUT / "focalpoint-bottom.step"))
Part.export([top], str(OUTPUT / "focalpoint-top.step"))
Part.export([grommet], str(OUTPUT / "focalpoint-grommet.step"))
Part.export([bottom, top, grommet], str(OUTPUT / "focalpoint-assembly.step"))
Mesh.export([bottom], str(OUTPUT / "focalpoint-bottom.stl"))
Mesh.export([top_print], str(OUTPUT / "focalpoint-top.stl"))
Mesh.export([grommet], str(OUTPUT / "focalpoint-grommet.stl"))

print("Generated FocalPoint Rev A enclosure:")
print(f"  shell: {SHELL_W:.1f} × {SHELL_D:.1f} mm")
print(f"  height: {FRONT_H:.1f} mm front / {REAR_H:.1f} mm rear")
print(f"  slope: {SLOPE_DEG:.1f} degrees")
print(f"  bottom volume: {bottom_shape.Volume / 1000:.1f} cm^3")
print(f"  top volume: {top_shape.Volume / 1000:.1f} cm^3")
print(f"  grommet volume: {grommet_shape.Volume / 1000:.1f} cm^3")
print(f"  output: {OUTPUT}")
