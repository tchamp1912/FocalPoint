"""Generate the parametric FocalPoint Rev A enclosure with FreeCAD.

Run from the repository root:
  /Applications/FreeCAD.app/Contents/Resources/bin/freecadcmd case/freecad/enclosure.py

The script intentionally models component-specific openings as prototype
envelopes. Update them from measured, selected parts before manufacturing.
Anything marked PROVISIONAL is placed from layout assumptions, not from a
routed KiCad board; re-derive it once footprint placement exists.

Frames of reference
- "local" = the bottom shell before it is rotated across the puck: a plain,
  unwedged rectangular prism, uniform height FRONT_H everywhere. No slope is
  modeled into the shell's own geometry (redesign note, WP4-1: the keyboard
  portion itself must not be angled — only the cylinder it bisects is).
- "world" = after rotating that flat prism by the full SLOPE_DEG about the
  front-bottom-wall datum (0, 0, FRONT_H). The entire forward tilt comes from
  this one rigid rotation cutting the flat shell across the level, untilted
  circular puck at an angle, matching how the top plate is already built
  (`plate_transform`: a flat plate, rotated once by the full slope). The
  plate underside plane is exactly z = FRONT_H + y*tan(SLOPE_DEG) in both
  frames — the rotation reproduces this plane exactly, not approximately,
  since both shells now share the identical single-rotation construction;
  the desk is z ~ 0 (grommet below it).
"""

from pathlib import Path
import math
import re

import FreeCAD as App
import Mesh
import MeshPart
import Part


REPO = Path(__file__).resolve().parents[2]
OUTPUT = REPO / "case" / "output"
OUTPUT.mkdir(parents=True, exist_ok=True)
KICAD_BOARD = REPO / "hardware" / "kicad" / "focalpoint_rev_a_release_candidate.kicad_pcb"
DESIGN_MD = REPO / "case" / "DESIGN.md"

# Master parameters, millimetres/degrees. DESIGN.md's parameter table is
# emitted by this script between generated-content markers — rerun the script
# after changing a value instead of editing both files by hand.
PCB_W = 116.0
PCB_D = 116.0
PCB_T = 1.6
PCB_CLEARANCE = 4.5
SHELL_W = PCB_W + 2 * PCB_CLEARANCE
SHELL_D = PCB_D + 2 * PCB_CLEARANCE
CORNER_R = 6.0
WALL = 2.4
FLOOR = 2.4
FRONT_H = 11.0
SLOPE_DEG = 4.0
# WP4-1 redesign: the rectangular shell carries no internal wedge at all —
# it's built flat (uniform height FRONT_H) and rotated once, rigidly, by the
# *full* SLOPE_DEG. The entire forward tilt is expressed as the flat shell
# bisecting the level, untilted circular puck at an angle, not as a shape
# baked into the shell itself. (Previously this was split into a 2°
# internal wedge plus a 2° rigid rotation — replaced because it modeled the
# keyboard portion itself as angled, which is exactly what this redesign
# removes.)
REAR_H = FRONT_H + SHELL_D * math.tan(math.radians(SLOPE_DEG))
# Plate 1.5 mm: Cherry-style MX plate clips are specified for a 1.5 mm plate;
# the earlier 1.6 mm exceeded the clip nominal (WP3-6 decision; coupon-verify
# in MJF PA12 before committing).
PLATE_T = 1.5
# MX plate-mount stack (Cherry MX spec): plate TOP surface to PCB TOP is
# 5.0 mm regardless of plate thickness (the flange seats on the plate top).
MX_PLATE_TOP_TO_PCB_TOP = 5.0
PCB_TOP_DROP = MX_PLATE_TOP_TO_PCB_TOP - PLATE_T   # PCB top below plate underside
# Kailh MX hot-swap socket housing height below the PCB underside — the
# lowest obstruction hanging under the board.
SOCKET_BELOW_PCB = 1.85
# MX plate cutout: 14.05 mm nominal for MJF PA12 so the switch clips can
# latch. Do NOT add FIT_CLEARANCE here — a 14.6 mm opening kills MX clip
# retention. The 0.30 mm fit clearance is only for non-latching mating
# features (WP3-6; coupon print validates the exact MJF number).
MX_CUTOUT = 14.05
PUCK_RADIUS = 43.0
PUCK_VISIBLE_H = 6.0
# WP4-1: with the shell's full 4 deg tilt now carried entirely as a rigid
# rotation (no internal wedge — see shell_rotate), the shell's own floor
# rises enough toward the rear that a shallow puck no longer reaches it
# across the puck's whole footprint (the old 2 deg-only floor rotation, half
# the current amount, never had this problem). 5.0 mm left a ~2 mm gap at
# the puck's rear edge; 9.0 mm clears the worst point (rear edge of the
# puck's own circular footprint) with margin — asserted below, not just
# assumed.
PUCK_EMBED_H = 9.0
GROMMET_EDGE_INSET = 7.0
# Grommet stock is 1/16 in (1.59 mm) silicone (BOM: McMaster 8525T575 disc).
# A 0.8 mm recess leaves ~0.79 mm proud — inside DESIGN.md's 0.6-1.0 mm
# projection target (the old 1.2 mm recess left only 0.39 mm). Alternative:
# 2.0 mm stock with a 1.2 mm recess also lands at 0.8 mm proud.
GROMMET_T = 1.59
GROMMET_RECESS = 0.8
GROMMET_PROUD = GROMMET_T - GROMMET_RECESS
FIT_CLEARANCE = 0.30   # printed mating features that do NOT latch

# Heat-set inserts: McMaster 94180A321 (M2.5 x 0.45, 3.4 mm long). Governing
# constraint: 94180A321 recommended pilot ~Ø4.0, and >=4.5 mm deep so the
# insert plus protruding screw tip never bottom out. The pilot is blind from
# the boss top (the old model was a Ø3.4 through-hole — wrong on both
# counts). Print insert coupons before ordering (Phase 1 criterion).
BOSS_OD = 9.0
BOSS_AXIS_EDGE = 3.0         # screw axis; clears PCB edge by 0.05 mm
BOSS_Y_FRACTION = 0.30       # two fastener stations along each side wall
INSERT_PILOT_D = 4.0
INSERT_PILOT_DEPTH = 5.5
# M2.5 plate screws: Ø2.9 normal-fit clearance holes (previously Ø3.4 and
# mislabelled "M3-class").
PLATE_SCREW_CLEAR_D = 2.9

# Battery: TinyCircuits ASR00012 1S LiPo, 42 x 39 x 5.5 mm, JST-SH pigtail.
# The under-PCB airspace alone (~3.5 mm at the front, ~1.65 mm under the
# hot-swap sockets) cannot take a 5.5 mm pack, so the floor is pocketed down
# into the Ø86 puck, which has ~6 mm of otherwise unused depth (WP3-2).
# The pocket bottom is flat in world coordinates (the pack sits level).
BATTERY_L = 42.0
BATTERY_W = 39.0
BATTERY_T = 5.5
BATTERY_POCKET_CLEAR = 0.5       # per side; the pocket walls retain the pack
BATTERY_POCKET_BOTTOM_Z = -2.0   # world Z of the flat pocket floor
BATTERY_MIN_CAVITY = 8.0         # required pocket-floor -> lowest obstruction
BATTERY_MIN_AIR = 0.5            # required pack-top -> lowest obstruction
POCKET_MIN_WEB = 2.0             # solid puck left under the pocket floor
# JST-SH pigtail relief: a fold-up bay off the pocket's +X side so the cable
# is not pinched between pack and pocket wall. PROVISIONAL until the KiCad
# battery-connector placement exists.
CABLE_RELIEF_L = 12.0            # along +X, beyond the pocket wall
CABLE_RELIEF_W = 12.0            # along Y, centered on the pocket

# USB-C: GCT USB4105-GF-A-060 drawing — overall shell 8.94 wide x 3.26 tall,
# mounted on the PCB top at the board edge. Opening = shell + 0.6 mm
# clearance per side. Because the connector top sits only ~0.24 mm below the
# plate underside, the opening is an open-top notch in the rear wall, closed
# from above by the plate (WP3-5).
USB_SHELL_W = 8.94
USB_SHELL_H = 3.26
USB_CLEAR = 0.6
# Exact routed placement: J1 anchor (146.0, 102.2) maps to shell x=50.5 mm.
USB_X = 50.5
USB_TOP_NOTCH_D = 12.0

# J2 is a top-mounted JST-SH battery connector. A service opening above it
# gives its body and pigtail room while allowing the cable to fold around the
# board edge into the battery pocket below.
JST_KICAD_X = 108.0
JST_KICAD_Y = 120.0
JST_SERVICE_W = 8.0
JST_SERVICE_D = 8.0

# Reset access: Omron B3U-1000P is top-actuated; assume it is placed on the
# PCB *bottom* side so a pin can reach it through a floor pinhole (WP3-5).
# PROVISIONAL position — rear-left floor area outside the puck, clear of the
# battery pocket and bosses; KiCad must place the switch over this hole (or
# this hole moves to the switch).
RESET_PINHOLE_D = 2.0
RESET_X = 20.0
RESET_Y = 95.0

# Antenna keep-out placeholder (replace from the Raytac MDBT50Q datasheet at
# KiCad placement time). Recorded rule (WP3-7): the metal M2.5 insert in the
# rear-right boss must stay >= ANTENNA_INSERT_CLEAR from the keep-out, so the
# placeholder is positioned inboard of the rear-right side boss.
ANTENNA_KEEPOUT_W = 25.0
ANTENNA_KEEPOUT_D = 20.0
ANTENNA_KEEPOUT_H = 12.0
ANTENNA_INSERT_CLEAR = 8.0

# Capacitive-touch coupling (WP3-8 decision, see case/DESIGN.md): a
# conductive-foam pillar (~Ø12, ~5 mm free height) compresses between the PCB
# electrode and a locally thinned plate underside, so the AT42QT1010 senses
# through ~1.1 mm of PA12 instead of ~5 mm of plate + air.
TOUCH_MARK_D = 12.0        # top witness mark
TOUCH_MARK_DEPTH = 0.2
TOUCH_RECESS_D = 13.0      # underside foam-locating recess
TOUCH_RECESS_DEPTH = 0.4

# Same three optical rays as app/Assets/focalpoint-mark.svg (viewBox 0 0 128
# 64): one shared origin, a convex lens transition (approximated with stable
# line segments), and one focal point. Engraved in one neutral line weight;
# color is an app/print presentation detail. LOGO_W/GROMMET_LOGO_W below are
# sized against this mark's own ink bounding box (x:10-82, y:5-59 — NOT the
# full 128x64 SVG canvas, which pads well past the ink on the right and
# unevenly on the left), so "23 mm wide" means the visible mark spans 23 mm.
LOGO_SEGMENTS = [
    (10, 16, 43, 16), (43, 16, 48, 17.778), (48, 17.778, 82, 48),
    (10, 16, 82, 48),
    (10, 16, 43.8, 45.8), (43.8, 45.8, 49, 48), (49, 48, 82, 48),
    # Convex lens outline, approximated with stable engraved line segments.
    (46, 5, 42, 16), (42, 16, 40, 32), (40, 32, 42, 48),
    (42, 48, 46, 59), (46, 59, 50, 48), (50, 48, 52, 32),
    (52, 32, 50, 16), (50, 16, 46, 5),
]
_logo_xs = [x for seg in LOGO_SEGMENTS for x in (seg[0], seg[2])]
_logo_ys = [y for seg in LOGO_SEGMENTS for y in (seg[1], seg[3])]
LOGO_INK_MIN_X, LOGO_INK_MAX_X = min(_logo_xs), max(_logo_xs)
LOGO_INK_MIN_Y, LOGO_INK_MAX_Y = min(_logo_ys), max(_logo_ys)
LOGO_INK_W = LOGO_INK_MAX_X - LOGO_INK_MIN_X
LOGO_INK_H = LOGO_INK_MAX_Y - LOGO_INK_MIN_Y
LOGO_INK_CX = (LOGO_INK_MIN_X + LOGO_INK_MAX_X) / 2
LOGO_INK_CY = (LOGO_INK_MIN_Y + LOGO_INK_MAX_Y) / 2

# FocalPoint ray mark engraved into the clear front apron of the top plate,
# viewed from above (outward normal +Z, looking down). Mirrored in X to read
# correctly from that viewing direction. A shallow recess keeps the mark
# legible without becoming a through-feature in the 1.5 mm plate.
LOGO_W = 23.0
LOGO_H = LOGO_W * LOGO_INK_H / LOGO_INK_W
LOGO_CENTER_X = SHELL_W / 2
LOGO_CENTER_Y = 13.0
LOGO_STROKE = 0.4
LOGO_DEPTH = 0.25

# Same mark, molded large into the replaceable puck grommet's exposed desk-
# facing face (the true "bottom of the cylinder" — the plastic puck itself is
# almost entirely covered by the grommet, radius PUCK_RADIUS - GROMMET_EDGE_
# INSET = 36, so that's what's actually visible), viewed from below (outward
# normal -Z, looking up) — mirrored in X *and* Y relative to the top mark, to
# read correctly from that opposite viewing direction. 52 mm wide keeps the
# mark's bounding-box half-diagonal (~32.5 mm) inside that Ø72 grommet face
# with a small (~3.5 mm) safety margin.
GROMMET_LOGO_W = 52.0
GROMMET_LOGO_H = GROMMET_LOGO_W * LOGO_INK_H / LOGO_INK_W
GROMMET_LOGO_DEPTH = 0.25

# Alps RKJXV122400R prototype joystick (official Drawing No. 1, update 2510).
# It is PCB-mounted: the 18.2 x 21.7 mm lower body sits below the top shell,
# while the 12.45 x 10.8 mm top frame and tilting Ø4 mm shaft pass through it.
# A Ø20 opening clears that frame and the shaft through its full 23° motion.
# The body is 11.2 mm above PCB top; terminals/lugs project 2.5 mm below PCB.
JOYSTICK_BODY_W = 18.2
JOYSTICK_BODY_D = 21.7
JOYSTICK_ABOVE_PCB = 11.2
JOYSTICK_BELOW_PCB = 2.5
JOYSTICK_TOP_FRAME_W = 12.45
JOYSTICK_TOP_FRAME_D = 10.8
JOYSTICK_OPENING_D = 20.0

# Board datum from KiCad Edge.Cuts: x = -24..84, y = -65..+43 (the ergogen
# outline is shifted [10, -9], so it is NOT symmetric about the key field —
# the old hand-copied y = -64..44 was off by 1 mm, WP3-1). The values are
# asserted against the generated board below instead of being trusted.
KICAD_MIN_X = 100.0
KICAD_MIN_Y = 100.0


def kicad_edge_cuts_extents(path):
    """Parse the Edge.Cuts bounding box out of the generated KiCad board."""
    xs, ys = [], []
    text = path.read_text()
    # KiCad 10 writes the rectangular production outline across two lines,
    # with the layer token following the start/end coordinates.
    for match in re.finditer(
            r"\(gr_rect\s+\(start\s+(-?\d+\.?\d*)\s+(-?\d+\.?\d*)\)"
            r"\s+\(end\s+(-?\d+\.?\d*)\s+(-?\d+\.?\d*)\).*?"
            r"\(layer\s+\"Edge\.Cuts\"\)", text, re.DOTALL):
        xs.extend((float(match.group(1)), float(match.group(3))))
        ys.extend((float(match.group(2)), float(match.group(4))))
    for line in text.splitlines():
        if "Edge.Cuts" not in line:
            continue
        if not any(tok in line for tok in ("gr_line", "gr_arc", "gr_circle", "gr_rect")):
            continue
        if "gr_circle" in line:
            # Interior relief cutouts: never the outline extremes, and their
            # (center)/(end) encoding would need radius math — skip.
            continue
        for m in re.finditer(
                r"\((?:start|mid|end)\s+(-?\d+\.?\d*)\s+(-?\d+\.?\d*)\)", line):
            xs.append(float(m.group(1)))
            ys.append(float(m.group(2)))
    if not xs:
        raise RuntimeError(f"no Edge.Cuts geometry found in {path}")
    return min(xs), max(xs), min(ys), max(ys)


# WP3-1: the board datum is asserted, not hand-copied.
if not KICAD_BOARD.exists():
    raise RuntimeError(f"KiCad board not found: {KICAD_BOARD}")
_min_x, _max_x, _min_y, _max_y = kicad_edge_cuts_extents(KICAD_BOARD)
for got, want, name in (
    (_min_x, KICAD_MIN_X, "Edge.Cuts min X"),
    (_max_x, KICAD_MIN_X + PCB_W, "Edge.Cuts max X"),
    (_min_y, KICAD_MIN_Y, "Edge.Cuts min Y"),
    (_max_y, KICAD_MIN_Y + PCB_D, "Edge.Cuts max Y"),
):
    if abs(got - want) > 0.01:
        raise RuntimeError(
            f"{name} mismatch: board has {got:.3f}, enclosure assumes {want:.3f};"
            " update KICAD_MIN_X/KICAD_MIN_Y/PCB_W/PCB_D from the board")


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


def board_to_shell(kicad_x, kicad_y):
    """Map production KiCad coordinates into the enclosure's front-left datum."""
    return (
        kicad_x - KICAD_MIN_X + PCB_CLEARANCE,
        KICAD_MIN_Y + PCB_D - kicad_y + PCB_CLEARANCE,
    )


def local_to_shell(layout_x, layout_y):
    """Map the established 4x4 layout coordinates through the production PCB."""
    return board_to_shell(
        KICAD_MIN_X + 28.0 + layout_x,
        KICAD_MIN_Y + 47.0 - layout_y,
    )


def plate_underside_world(y):
    """World-frame z of the plate underside above shell-local y."""
    return FRONT_H + y * math.tan(math.radians(SLOPE_DEG))


def shell_floor_world_z(y):
    """World-frame z of the bottom shell's own floor-bottom (its exterior
    underside, local z=0) above shell-local y, after shell_rotate's full-angle
    rotation about (0, 0, FRONT_H). Derived the same way as
    plate_underside_world, but from local z=0 instead of local z=FRONT_H:
    z = FRONT_H*(1 - cos(SLOPE_DEG)) + y*sin(SLOPE_DEG). Used to guarantee the
    puck stays tall enough to reach this floor everywhere inside its own
    footprint (WP4-1) — see the puck-height check below."""
    rad = math.radians(SLOPE_DEG)
    return FRONT_H * (1 - math.cos(rad)) + y * math.sin(rad)


def shell_rotate(shape):
    """Rotate the flat, unwedged bottom shell across the puck by the full
    forward slope (WP4-1) — the shell's entire tilt comes from this single
    rigid rotation, not from any internal wedge geometry."""
    shape.rotate(App.Vector(0, 0, FRONT_H), App.Vector(1, 0, 0), SLOPE_DEG)
    return shape


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


def make_logo_cutter(center_x, center_y, width, depth, surface_z, material_above,
                     mirror_x=False, mirror_y=False):
    """Build the FocalPoint ray-mark cutter (app/Assets/focalpoint-mark.svg
    proportions) as a shallow engraving recessed `depth` into a flat face at
    z = surface_z, centered on the mark's own ink bounding box (not the wider,
    unevenly-padded SVG canvas) so `width` truly is the visible mark's width
    and (center_x, center_y) is where it visually centers. `material_above`
    selects which side of that face the solid material sits on (True: bottom
    shell's underside, material at z > surface_z; False: top plate's topside,
    material at z < surface_z) so the cutter overshoots the face on the empty
    side and stops `depth` into the material side, rather than needing a
    per-caller z-offset worked out by hand. `mirror_x`/`mirror_y` flip the
    mark about its own center — needed because a mark viewed from -Z (above)
    and the same mark viewed from +Z (below) are mirror images of each other
    when drawn from the same (x, y) data."""
    scale = width / LOGO_INK_W
    sx = -scale if mirror_x else scale
    sy = -scale if mirror_y else scale
    z0 = surface_z - 0.1 if material_above else surface_z - depth
    cut_h = depth + 0.1

    def point(x, y):
        return (center_x + (x - LOGO_INK_CX) * sx,
                center_y + (y - LOGO_INK_CY) * sy)

    def engraved_segment(x1, y1, x2, y2):
        ax, ay = point(x1, y1)
        bx, by = point(x2, y2)
        length = math.hypot(bx - ax, by - ay)
        stroke = Part.makeBox(
            length, LOGO_STROKE, cut_h,
            App.Vector(ax, ay - LOGO_STROKE / 2, z0),
        )
        stroke.rotate(App.Vector(ax, ay, 0), App.Vector(0, 0, 1),
                      math.degrees(math.atan2(by - ay, bx - ax)))
        # Round caps also prevent tiny acute corners in the physical recess.
        for px, py in ((ax, ay), (bx, by)):
            stroke = stroke.fuse(Part.makeCylinder(LOGO_STROKE / 2, cut_h,
                                                    App.Vector(px, py, z0)))
        return stroke

    cutter = None
    for segment in LOGO_SEGMENTS:
        segment_shape = engraved_segment(*segment)
        cutter = segment_shape if cutter is None else cutter.fuse(segment_shape)
    fx, fy = point(82, 48)
    focus = Part.makeCylinder(1.25 * scale, cut_h, App.Vector(fx, fy, z0))
    return cutter.fuse(focus)


# ---------------------------------------------------------------------------
# Derived stack + battery geometry, with runtime sanity checks (WP3-2).
# World frame: PCB top = plate underside - PCB_TOP_DROP (3.5 mm);
# PCB bottom = top - PCB_T; sockets hang SOCKET_BELOW_PCB below that.
# ---------------------------------------------------------------------------
pocket_w = BATTERY_L + 2 * BATTERY_POCKET_CLEAR
pocket_d = BATTERY_W + 2 * BATTERY_POCKET_CLEAR
pocket_x0 = SHELL_W / 2 - pocket_w / 2
pocket_y0 = SHELL_D / 2 - pocket_d / 2

# Lowest obstruction over the pocket footprint = socket bottoms at the
# pocket's front edge (plate/PCB rise toward the rear).
_lowest_socket = (plate_underside_world(pocket_y0)
                  - PCB_TOP_DROP - PCB_T - SOCKET_BELOW_PCB)
_cavity_depth = _lowest_socket - BATTERY_POCKET_BOTTOM_Z
_battery_air = _lowest_socket - (BATTERY_POCKET_BOTTOM_Z + BATTERY_T)
_pocket_web = BATTERY_POCKET_BOTTOM_Z - (-PUCK_VISIBLE_H + GROMMET_RECESS)
# The puck (flat top at world z = PUCK_EMBED_H, never rotated) must stay in
# contact with the tilted shell floor across the puck's ENTIRE circular
# footprint, or the two read as structurally disconnected where the floor
# has risen above the puck (WP4-1 regression: a shallow puck can satisfy
# every other check here and still leave a visible gap at the puck's rear
# edge). The floor's rotated plane only depends on y, so its worst point
# within the puck's footprint is the single rearmost y on the puck's circle.
_puck_top_z = PUCK_EMBED_H
_floor_z_at_puck_rear = shell_floor_world_z(SHELL_D / 2 + PUCK_RADIUS)
if _floor_z_at_puck_rear >= _puck_top_z:
    raise RuntimeError(
        f"puck too shallow: shell floor reaches {_floor_z_at_puck_rear:.2f} mm "
        f"at the puck's rear edge, >= puck top {_puck_top_z:.2f} mm "
        f"(PUCK_EMBED_H={PUCK_EMBED_H}); increase PUCK_EMBED_H")

if _cavity_depth < BATTERY_MIN_CAVITY:
    raise RuntimeError(
        f"battery cavity {_cavity_depth:.2f} mm < {BATTERY_MIN_CAVITY} mm")
if _battery_air < BATTERY_MIN_AIR:
    raise RuntimeError(
        f"battery-to-socket air gap {_battery_air:.2f} mm < {BATTERY_MIN_AIR} mm")
if _pocket_web < POCKET_MIN_WEB:
    raise RuntimeError(
        f"puck web under battery pocket {_pocket_web:.2f} mm < {POCKET_MIN_WEB} mm")
_pocket_diag = math.hypot(pocket_w / 2 + CABLE_RELIEF_L, CABLE_RELIEF_W / 2)
if _pocket_diag > PUCK_RADIUS or math.hypot(pocket_w / 2, pocket_d / 2) > PUCK_RADIUS:
    raise RuntimeError("battery pocket/cable relief exceeds the puck footprint")

doc = App.newDocument("FocalPoint_RevA_Enclosure")

# A spreadsheet makes dimensions visible and editable when the FCStd is opened.
sheet = doc.addObject("Spreadsheet::Sheet", "Parameters")
parameters = [
    ("PCB width", PCB_W, "mm"),
    ("PCB depth", PCB_D, "mm"),
    ("PCB thickness", PCB_T, "mm"),
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
    ("MX plate cutout", MX_CUTOUT, "mm"),
    ("Joystick body", f"{JOYSTICK_BODY_W:.1f} x {JOYSTICK_BODY_D:.1f}", "mm"),
    ("Joystick height above PCB", JOYSTICK_ABOVE_PCB, "mm"),
    ("Joystick projection below PCB", JOYSTICK_BELOW_PCB, "mm"),
    ("Joystick top opening", JOYSTICK_OPENING_D, "mm"),
    ("Circular puck radius", PUCK_RADIUS, "mm"),
    ("Grommet edge inset", GROMMET_EDGE_INSET, "mm"),
    ("Grommet stock thickness", GROMMET_T, "mm"),
    ("Grommet recess", GROMMET_RECESS, "mm"),
    ("Grommet projection", GROMMET_PROUD, "mm"),
    ("Fit clearance (non-latching)", FIT_CLEARANCE, "mm"),
    ("Insert boss OD", BOSS_OD, "mm"),
    ("Insert screw-axis edge inset", BOSS_AXIS_EDGE, "mm"),
    ("Insert pilot diameter", INSERT_PILOT_D, "mm"),
    ("Insert pilot depth", INSERT_PILOT_DEPTH, "mm"),
    ("Plate screw clearance", PLATE_SCREW_CLEAR_D, "mm"),
    ("Battery pocket", f"{pocket_w:.1f} x {pocket_d:.1f}", "mm"),
    ("Battery pocket floor Z", BATTERY_POCKET_BOTTOM_Z, "mm"),
    ("Battery cavity depth", _cavity_depth, "mm"),
    ("USB opening width", USB_SHELL_W + 2 * USB_CLEAR, "mm"),
    ("Reset pinhole", RESET_PINHOLE_D, "mm"),
    ("FocalPoint mark", f"{LOGO_W:.1f} x {LOGO_H:.1f}", "mm"),
    ("FocalPoint engraving depth", LOGO_DEPTH, "mm"),
]
sheet.set("A1", "Parameter")
sheet.set("B1", "Value")
sheet.set("C1", "Unit")
for row, (label, value, unit) in enumerate(parameters, start=2):
    sheet.set(f"A{row}", label)
    if isinstance(value, str):
        sheet.set(f"B{row}", value)
    else:
        sheet.set(f"B{row}", f"{value:.3f}")
    sheet.set(f"C{row}", unit)
sheet.setColumnWidth("A", 190)
sheet.setColumnWidth("B", 90)
sheet.setColumnWidth("C", 55)

# Lower shell (WP4-1): a plain, unwedged rounded prism, uniform height
# FRONT_H, hollowed from above with a retained floor. No slope is modeled
# here at all — the shell's forward tilt comes entirely from shell_rotate()
# below, applied to this flat shape as a single rigid rotation.
outer = rounded_prism(SHELL_W, SHELL_D, CORNER_R, FRONT_H)
inner_w = SHELL_W - 2 * WALL
inner_d = SHELL_D - 2 * WALL
inner_cut = rounded_prism(inner_w, inner_d, CORNER_R - WALL,
                          FRONT_H + 4 - FLOOR, FLOOR, WALL, WALL)
bottom_shape = outer.cut(inner_cut)

# USB-C wall opening (WP3-5). Derived from the GCT USB4105-GF-A-060 shell
# (8.94 x 3.26 above the PCB top) + 0.6 mm clearance per side. The connector
# top clears the plate underside by only PCB_TOP_DROP - USB_SHELL_H
# (~0.24 mm), so the opening runs out of the top of the wall as a notch; the
# tilted plate closes it from above. Cut in the local (flat, pre-rotation)
# frame so it stays registered with the PCB once shell_rotate is applied —
# with no internal wedge (WP4-1), the local-frame reference height is just
# the constant FRONT_H everywhere, not a y-dependent slope. X position
# PROVISIONAL.
usb_open_w = USB_SHELL_W + 2 * USB_CLEAR
pcb_top_local = FRONT_H - PCB_TOP_DROP
usb_bottom_z = pcb_top_local - USB_CLEAR
usb_cut = Part.makeBox(
    usb_open_w, WALL + 4, FRONT_H + 4 - usb_bottom_z,
    App.Vector(USB_X - usb_open_w / 2, SHELL_D - WALL - 1, usb_bottom_z))
bottom_shape = bottom_shape.cut(usb_cut)

# Reset pinhole through the floor (WP3-5). Ø2.0 for a straightened paperclip;
# position PROVISIONAL (see RESET_X/RESET_Y notes). It sits outside the Ø86
# puck so the hole passes through the 2.4 mm floor only.
if math.hypot(RESET_X - SHELL_W / 2, RESET_Y - SHELL_D / 2) <= PUCK_RADIUS:
    raise RuntimeError("reset pinhole must stay outside the puck footprint")
reset_cut = Part.makeCylinder(RESET_PINHOLE_D / 2, FLOOR + 4,
                              App.Vector(RESET_X, RESET_Y, -2))
bottom_shape = bottom_shape.cut(reset_cut)

# Rotate the complete rectangular shell across the circular pedestal. Rotation
# about the front top datum keeps the front seam registered with the top plate.
shell_rotate(bottom_shape)

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

# Re-clear the interior after fusing the puck: the flat-topped puck otherwise
# protrudes up through the tilted floor into the under-PCB airspace (up to
# ~2.6 mm near its front edge, where the hot-swap sockets pass within
# ~0.05 mm of it). Cutting with the rotated interior cavity keeps the inside
# floor a single plane (WP3-2).
interior_clear = shell_rotate(inner_cut.copy())
bottom_shape = bottom_shape.cut(interior_clear)

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
# FocalPoint ray mark, molded large into the grommet's exposed desk-facing
# face (the world-frame bottom of the puck cylinder, never rotated).
grommet_shape = grommet_shape.cut(make_logo_cutter(
    puck_center_x, puck_center_y, GROMMET_LOGO_W, GROMMET_LOGO_DEPTH,
    puck_z - GROMMET_PROUD, material_above=True,
    mirror_x=True, mirror_y=True))

# Battery pocket (WP3-2): a flat-bottomed pocket sunk through the tilted
# floor into the puck. The cutter extends far above the floor so it also
# clears any floor material inside the footprint; the pocket walls provide
# lateral retention for the pack (add <=1 mm adhesive/foam only — thicker
# padding erodes the pack-to-socket air gap). Cut in the world frame so the
# pack sits level on the desk-parallel pocket floor.
pocket_cut = Part.makeBox(
    pocket_w, pocket_d, 40.0,
    App.Vector(pocket_x0, pocket_y0, BATTERY_POCKET_BOTTOM_Z))
bottom_shape = bottom_shape.cut(pocket_cut)
# JST-SH pigtail fold-up bay off the +X pocket wall (PROVISIONAL side).
relief_cut = Part.makeBox(
    CABLE_RELIEF_L + 1, CABLE_RELIEF_W, 40.0,
    App.Vector(pocket_x0 + pocket_w - 1,
               SHELL_D / 2 - CABLE_RELIEF_W / 2,
               BATTERY_POCKET_BOTTOM_Z))
bottom_shape = bottom_shape.cut(relief_cut)

# Four heat-set-insert bosses at two stations along each side wall. The screw
# shafts pass through the narrow perimeter channel outside the PCB. The Ø9
# bosses may extend under the board in XY, but stop FIT_CLEARANCE below its
# underside, so the routed rectangular PCB needs no corner cutouts. Clipping
# each boss to the shell's local outer prism prevents a side bulge. The blind
# Ø4.0 x 5.5 pilots implement the 94180A321 pilot spec.
boss_y_front = SHELL_D * BOSS_Y_FRACTION
boss_y_rear = SHELL_D * (1.0 - BOSS_Y_FRACTION)
boss_xy = [(BOSS_AXIS_EDGE, boss_y_front),
           (SHELL_W - BOSS_AXIS_EDGE, boss_y_front),
           (BOSS_AXIS_EDGE, boss_y_rear),
           (SHELL_W - BOSS_AXIS_EDGE, boss_y_rear)]
pcb_bottom_local = pcb_top_local - PCB_T
boss_top_local = pcb_bottom_local - FIT_CLEARANCE
if BOSS_AXIS_EDGE + PLATE_SCREW_CLEAR_D / 2 > PCB_CLEARANCE + 0.01:
    raise RuntimeError("lid screw shaft intersects the PCB outline")
if boss_top_local < INSERT_PILOT_DEPTH:
    raise RuntimeError("under-PCB boss is too short for the selected insert pilot")
for bx, by in boss_xy:
    boss = Part.makeCylinder(BOSS_OD / 2, boss_top_local,
                             App.Vector(bx, by, 0))
    boss = boss.common(outer)
    pilot = Part.makeCylinder(INSERT_PILOT_D / 2, INSERT_PILOT_DEPTH + 1,
                              App.Vector(bx, by,
                                         boss_top_local - INSERT_PILOT_DEPTH))
    bottom_shape = bottom_shape.fuse(shell_rotate(boss.cut(pilot)))

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

for cx, cy in key_centers:
    cutter = Part.makeBox(MX_CUTOUT, MX_CUTOUT, PLATE_T + 4,
                          App.Vector(cx - MX_CUTOUT / 2, cy - MX_CUTOUT / 2, -2))
    plate_local = plate_local.cut(cutter)

# Control openings. The joystick aperture is derived from the selected Alps
# RKJXV122400R rather than the former low-profile FPC-tail placeholder.
encoder_x, encoder_y = local_to_shell(0.0, 20.0)
touch_x, touch_y = local_to_shell(60.0, -40.0)
joystick_x, joystick_y = local_to_shell(60.0, 20.0)
joystick_frame_corner = math.hypot(
    JOYSTICK_TOP_FRAME_W / 2, JOYSTICK_TOP_FRAME_D / 2)
if joystick_frame_corner + FIT_CLEARANCE > JOYSTICK_OPENING_D / 2:
    raise RuntimeError("joystick top frame does not clear the top opening")
if joystick_x + JOYSTICK_BODY_W / 2 + FIT_CLEARANCE > SHELL_W - WALL:
    raise RuntimeError("joystick body collides with right enclosure wall")
if joystick_y + JOYSTICK_BODY_D / 2 + FIT_CLEARANCE > SHELL_D - WALL:
    raise RuntimeError("joystick body collides with rear enclosure wall")
joystick_under_board_air = FRONT_H - PCB_TOP_DROP - PCB_T - FLOOR
if JOYSTICK_BELOW_PCB + FIT_CLEARANCE > joystick_under_board_air:
    raise RuntimeError("joystick terminals/lugs collide with lower shell")
joystick_cut = Part.makeCylinder(JOYSTICK_OPENING_D / 2, PLATE_T + 4,
                                 App.Vector(joystick_x, joystick_y, -2))
encoder_cut = Part.makeCylinder(4.0, PLATE_T + 4,
                                App.Vector(encoder_x, encoder_y, -2))
plate_local = plate_local.cut(joystick_cut.fuse(encoder_cut))

# Exact top-side connector service clearances. The rear USB opening is an
# edge-open notch; the JST-SH opening is a small closed service window above
# J2. Both are intentionally through-features because the component models
# exceed the fixed MX plate-to-PCB air gap.
usb_top_cut = Part.makeBox(
    usb_open_w, USB_TOP_NOTCH_D, PLATE_T + 4,
    App.Vector(USB_X - usb_open_w / 2, SHELL_D - USB_TOP_NOTCH_D, -2),
)
jst_x, jst_y = board_to_shell(JST_KICAD_X, JST_KICAD_Y)
jst_service_cut = Part.makeBox(
    JST_SERVICE_W, JST_SERVICE_D, PLATE_T + 4,
    App.Vector(jst_x - JST_SERVICE_W / 2,
               jst_y - JST_SERVICE_D / 2, -2),
)
plate_local = plate_local.cut(usb_top_cut.fuse(jst_service_cut))

# Capacitive-touch cell (WP3-8): a shallow top witness mark identifies the
# cell, and an underside recess locates a conductive-foam pillar that couples
# the PCB electrode to the thinned plate (~1.1 mm web over the recess). Foam
# span: PCB top -> recess ceiling = PCB_TOP_DROP + TOUCH_RECESS_DEPTH
# (~3.9 mm compressed; spec ~Ø12 x 5 mm free height).
touch_mark = Part.makeCylinder(
    TOUCH_MARK_D / 2, TOUCH_MARK_DEPTH + 0.1,
    App.Vector(touch_x, touch_y, PLATE_T - TOUCH_MARK_DEPTH)
)
plate_local = plate_local.cut(touch_mark)
touch_recess = Part.makeCylinder(
    TOUCH_RECESS_D / 2, TOUCH_RECESS_DEPTH + 0.5,
    App.Vector(touch_x, touch_y, -0.5)
)
plate_local = plate_local.cut(touch_recess)


plate_local = plate_local.cut(make_logo_cutter(
    LOGO_CENTER_X, LOGO_CENTER_Y, LOGO_W, LOGO_DEPTH, PLATE_T,
    material_above=False, mirror_x=True))

# M2.5 lid clearance holes (Ø2.9) align with the four lower bosses.
for bx, by in boss_xy:
    screw = Part.makeCylinder(PLATE_SCREW_CLEAR_D / 2, PLATE_T + 4,
                              App.Vector(bx, by, -2))
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
# MJF is the target process (no supports). The rectangular shell corners
# overhang the puck by ~35 mm, so an FDM print in this orientation would need
# supports — the old "supports off" claim only ever applied to MJF.
bottom.PrintOrientation = ("Circular puck face down; MJF needs no supports. "
                           "FDM would require supports under the corner overhangs")
set_view(bottom, (0.12, 0.13, 0.14))

top = doc.addObject("PartDesign::Feature", "TopPlateShell")
top.Label = "Tilted top shell — frosted/translucent"
top.Shape = top_shape
top.addProperty("App::PropertyString", "PrototypeWarning", "Design")
top.PrototypeWarning = "Joystick and encoder apertures require selected-part measurements"
set_view(top, (0.72, 0.82, 0.84), 45)

grommet = doc.addObject("PartDesign::Feature", "BottomGrommet")
grommet.Label = "Replaceable circular silicone/EPDM bottom grommet"
grommet.Shape = grommet_shape
grommet.addProperty("App::PropertyString", "MaterialTarget", "Manufacturing")
grommet.MaterialTarget = "1/16 in (1.59 mm) silicone (McMaster 8525T575), 50–70 Shore A"
set_view(grommet, (0.04, 0.04, 0.04))

# Reference envelopes are visible in FreeCAD but excluded from manufacturing
# exports. They make the unresolved component decisions obvious.
battery = doc.addObject("PartDesign::Feature", "BatteryEnvelope_PLACEHOLDER")
battery.Label = (f"TinyCircuits ASR00012 battery envelope — "
                 f"{BATTERY_L:.0f} × {BATTERY_W:.0f} × {BATTERY_T:.1f} mm in pocket")
battery.Shape = Part.makeBox(
    BATTERY_L, BATTERY_W, BATTERY_T,
    App.Vector(SHELL_W / 2 - BATTERY_L / 2, SHELL_D / 2 - BATTERY_W / 2,
               BATTERY_POCKET_BOTTOM_Z)
)
set_view(battery, (0.95, 0.65, 0.15), 70)

# Keep-out placeholder positioned inboard of the rear-right boss so the metal
# insert stays >= ANTENNA_INSERT_CLEAR away (WP3-7 recorded note). Replace
# with the real MDBT50Q keep-out at KiCad placement. Built flat in the local
# frame (like the bosses) and rotated with shell_rotate() so it tracks the
# tilted PCB/shell instead of sitting at a fixed world Z — previously this box
# was never rotated, so 74% of its volume fell outside the actual (tilted)
# bottom shell, poking through the floor near the puck.
antenna_x_max = (SHELL_W - BOSS_AXIS_EDGE - BOSS_OD / 2
                 - ANTENNA_INSERT_CLEAR)
antenna_local = Part.makeBox(
    ANTENNA_KEEPOUT_W, ANTENNA_KEEPOUT_D, ANTENNA_KEEPOUT_H,
    App.Vector(antenna_x_max - ANTENNA_KEEPOUT_W,
               SHELL_D - WALL - ANTENNA_KEEPOUT_D, FLOOR))
antenna = doc.addObject("PartDesign::Feature", "AntennaKeepout_PLACEHOLDER")
antenna.Label = ("Radio antenna keep-out placeholder — inboard of the "
                 "rear-right insert boss; replace from module datasheet")
antenna.Shape = shell_rotate(antenna_local)
set_view(antenna, (0.9, 0.15, 0.15), 75)

# Real populated PCB from the routed release candidate (KICAD_BOARD), as a
# reference solid for the assembly view — not a manufacturing export. Built
# via:
#   kicad-cli pcb export step --subst-models --no-dnp --force \
#     --user-origin 100x100mm -o case/output/focalpoint-board-populated.step \
#     hardware/kicad/focalpoint_rev_a_release_candidate.kicad_pcb
# --user-origin 100x100mm moves the STEP's own origin to the Edge.Cuts corner
# (KICAD_MIN_X, KICAD_MIN_Y), so only the board_to_shell offset is left to
# apply here; the exported board's top copper face is STEP z=0, which lines
# up with pcb_top_local before shell_rotate tilts it with everything else.
# Regenerate that STEP (via the command above) whenever the board changes.
PCB_STEP = OUTPUT / "focalpoint-board-populated.step"
pcb = None
if PCB_STEP.exists():
    pcb_shape = Part.Shape()
    pcb_shape.read(str(PCB_STEP))
    pcb_shape.translate(App.Vector(PCB_CLEARANCE, PCB_D + PCB_CLEARANCE, pcb_top_local))
    pcb = doc.addObject("Part::Feature", "PopulatedPCB_REFERENCE")
    pcb.Label = ("Routed Rev A PCB (release candidate) — "
                 "reference only, not a manufacturing export")
    pcb.Shape = shell_rotate(pcb_shape)
    set_view(pcb, (0.05, 0.35, 0.12), 0)
else:
    print(f"note: {PCB_STEP} not found — skipping populated-PCB reference "
          f"(regenerate it via kicad-cli, see comment above)")

doc.recompute()

# Neutral CAD and print exports. The assembly STEP contains the three physical
# parts; reference envelopes remain only in the editable FCStd.
Part.export([bottom], str(OUTPUT / "focalpoint-bottom.step"))
Part.export([top], str(OUTPUT / "focalpoint-top.step"))
Part.export([grommet], str(OUTPUT / "focalpoint-grommet.step"))
Part.export([bottom, top, grommet], str(OUTPUT / "focalpoint-assembly.step"))
if pcb is not None:
    Part.export([bottom, top, grommet, pcb],
                str(OUTPUT / "focalpoint-assembly-with-board.step"))
Mesh.export([bottom], str(OUTPUT / "focalpoint-bottom.stl"))
Mesh.export([grommet], str(OUTPUT / "focalpoint-grommet.stl"))

# The flat (untilted) print-orientation copy of the top plate is an STL-export
# convenience ONLY — it must never linger as a visible object in the saved
# FCStd (previously it did: a PartDesign::Feature added to the document, with
# a `ViewObject.Visibility = False` meant to hide it, but ViewObject is None
# under the documented headless `freecadcmd` workflow this script's own
# docstring instructs, so that hide silently no-op'd and the flat shell stayed
# visible — indistinguishable from the real tilted one — every time the file
# was reopened). Building it straight to a Mesh via MeshPart, with no
# `doc.addObject` at all, means there is nothing to hide because nothing is
# ever added to the document in the first place.
flat_top_mesh = MeshPart.meshFromShape(
    Shape=plate_local, LinearDeflection=0.1, AngularDeflection=0.5
)
flat_top_mesh.write(str(OUTPUT / "focalpoint-top.stl"))

doc.saveAs(str(OUTPUT / "focalpoint-rev-a.FCStd"))


def write_design_table(path):
    """Refresh the generated parameter table inside case/DESIGN.md (WP3-10)."""
    begin = "<!-- BEGIN GENERATED PARAMETERS (case/freecad/enclosure.py) -->"
    end = "<!-- END GENERATED PARAMETERS -->"
    rows = ["| Parameter | Value | Unit |", "|---|---:|---|"]
    for label, value, unit in parameters:
        shown = value if isinstance(value, str) else f"{value:.2f}".rstrip("0").rstrip(".")
        rows.append(f"| {label} | {shown} | {unit} |")
    block = begin + "\n" + "\n".join(rows) + "\n" + end
    text = path.read_text()
    if begin not in text or end not in text:
        print(f"warning: generated-parameter markers not found in {path}")
        return
    pre, rest = text.split(begin, 1)
    _, post = rest.split(end, 1)
    path.write_text(pre + block + post)
    print(f"  refreshed parameter table in {path}")


write_design_table(DESIGN_MD)

print("Generated FocalPoint Rev A enclosure:")
print(f"  shell: {SHELL_W:.1f} × {SHELL_D:.1f} mm")
print(f"  height: {FRONT_H:.1f} mm front / {REAR_H:.1f} mm rear")
print(f"  slope: {SLOPE_DEG:.1f} degrees")
print(f"  under-PCB gap (floor to PCB bottom): "
      f"{plate_underside_world(0) - PCB_TOP_DROP - PCB_T - FLOOR:.2f} mm front / "
      f"{plate_underside_world(SHELL_D) - PCB_TOP_DROP - PCB_T - (FLOOR + SHELL_D * math.tan(math.radians(SLOPE_DEG))):.2f} mm rear")
print(f"  battery cavity: {_cavity_depth:.2f} mm deep "
      f"(pack air gap {_battery_air:.2f} mm, puck web {_pocket_web:.2f} mm)")
print(f"  bottom volume: {bottom_shape.Volume / 1000:.1f} cm^3")
print(f"  top volume: {top_shape.Volume / 1000:.1f} cm^3")
print(f"  grommet volume: {grommet_shape.Volume / 1000:.1f} cm^3")
print(f"  output: {OUTPUT}")
