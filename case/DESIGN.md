# FocalPoint Rev A enclosure design language

Reference: [OpenAI Supply Co. × Work Louder Codex Micro](https://openai.com/supply/co-lab/work-louder/).
This is an industrial-design reference only. FocalPoint does not copy its
dimensions, internal construction, proprietary surfaces, or exact part forms.

## Character to carry forward

- A compact, softly rounded command-center silhouette rather than a flat PCB
  tray.
- A slight forward presentation angle: taller at the rear/control edge and
  lower at the user/action edge.
- A translucent or frosted upper/plate volume over a visually denser, darker
  structural base.
- Sixteen controls on a uniform visual 4×4 lattice: encoder top-left, analog
  joystick top-right, capacitive touch bottom-right, and 13 RGB MX keys in all
  remaining cells. Their functions remain dynamically assignable rather than fixed.
- A clean underside dominated by a circular base/puck and recessed circular
  elastomer grommet. The rectangular shell bisects the puck on a shallow angle.
- Generous corner radii and restrained seams. USB-C, reset, and service openings
  should look intentionally integrated rather than cut into a generic box.

## Parameters

This table is **emitted by `case/freecad/enclosure.py`** (rerun the script
after changing a constant; do not hand-edit between the markers). These are
prototype values, not production dimensions.

<!-- BEGIN GENERATED PARAMETERS (case/freecad/enclosure.py) -->
| Parameter | Value | Unit |
|---|---:|---|
| PCB width | 108 | mm |
| PCB depth | 108 | mm |
| PCB thickness | 1.6 | mm |
| PCB clearance | 3 | mm |
| Shell width | 114 | mm |
| Shell depth | 114 | mm |
| Corner radius | 6 | mm |
| Wall | 2.4 | mm |
| Floor | 2.4 | mm |
| Front height | 11 | mm |
| Rear height | 18.97 | mm |
| Forward slope | 4 | deg |
| Plate thickness | 1.5 | mm |
| MX plate cutout | 14.05 | mm |
| Shell-to-puck angle | 2 | deg |
| Circular puck radius | 43 | mm |
| Grommet edge inset | 7 | mm |
| Grommet stock thickness | 1.59 | mm |
| Grommet recess | 0.8 | mm |
| Grommet projection | 0.79 | mm |
| Fit clearance (non-latching) | 0.3 | mm |
| Insert boss OD | 9 | mm |
| Insert pilot diameter | 4 | mm |
| Insert pilot depth | 5.5 | mm |
| Plate screw clearance | 2.9 | mm |
| Battery pocket | 43.0 x 40.0 | mm |
| Battery pocket floor Z | -2 | mm |
| Battery cavity depth | 8.64 | mm |
| USB opening width | 10.14 | mm |
| Reset pinhole | 2 | mm |
<!-- END GENERATED PARAMETERS -->

Fit-test ranges for the print iterations: shell clearance per PCB side
1.0–3.0 mm, wall 2.0–3.0 mm, corner radius 6–15 mm, forward slope 3–6°,
circular base diameter 80–94 mm, printed-part clearance per printer.
Heights are component-driven; the grommet recess matches the selected sheet
stock.

The action-key edge is **front**; the joystick/encoder rail is **rear**. The
keycap plate slopes downward toward the front. Prefer a continuous internal
wedge or stepped internal bosses while keeping the exterior side wall smooth.

## Recorded mechanical decisions (Rev A)

- **PCB retention: switch-hung, not boss-supported.** The four Ø9 heat-set
  insert bosses pass through Ø10.5 corner relief cutouts in the PCB
  (`hardware/ergogen/config.yaml`, outline `pcb_reliefs`) with 0.75 mm radial
  clearance. The bosses carry only the M2.5 plate screws; the PCB hangs from
  the switches clipped into the plate. Rationale: one screw path per corner
  (a boss cannot take a plate screw and a PCB screw), and no standoff-height
  tolerance chain against a sloped datum. Consequence: the PCB must never be
  pressed against while unsupported — see `hardware/ASSEMBLY.md`.
- **Inserts:** McMaster `94180A321` (M2.5 × 0.45 × 3.4 mm) in blind Ø4.0 ×
  5.5 mm pilots (recommended pilot ~Ø4.0, ≥4.5 mm deep). Print coupons before
  ordering.
- **Plate thickness 1.5 mm** (MX clip nominal) with **14.05 mm** cutouts for
  MJF PA12. The generic 0.30 mm fit clearance is only for non-latching
  features; both numbers are coupon-validated before a full print.
- **Battery:** TinyCircuits ASR00012 (42 × 39 × 5.5 mm) sits in a flat
  43 × 40 mm pocket sunk into the Ø86 puck (pocket floor at world z = −2.0),
  giving ≥8 mm of cavity depth below the hot-swap sockets and a ≥2 mm solid
  web above the grommet recess. A 12 mm-wide JST-SH pigtail bay opens off the
  pocket's +X wall (provisional side until the connector is placed in KiCad).
- **USB-C:** opening derived from the GCT `USB4105-GF-A-060` shell
  (8.94 × 3.26 mm) + 0.6 mm clearance per side; it is an open-top notch in
  the rear wall closed from above by the plate, because the connector top
  clears the plate underside by only ~0.24 mm. X position provisional until
  KiCad edge placement exists.
- **Reset:** Ø2.0 pinhole through the floor (outside the puck), assuming the
  B3U-1000P is placed on the PCB bottom side over the hole. Provisional.
- **Antenna vs. metal fastener:** the rear-right insert boss stays at its
  corner; the antenna keep-out is positioned inboard so the metal M2.5 insert
  stays ≥8 mm from the keep-out volume. The keep-out box is still a
  placeholder to be replaced from the Raytac MDBT50Q datasheet at placement.
- **Touch coupling:** a conductive-foam pillar (~Ø12, ~5 mm free height)
  compresses between the PCB electrode and a Ø13 × 0.4 mm underside recess in
  the plate, so the AT42QT1010 senses through ~1.1 mm of PA12 instead of
  ~5 mm of plate + air. The top-face witness mark stays 0.2 mm deep.
  Alternative (plate-bonded electrode + pogo) rejected for Rev A as harder to
  service.

## Bottom grommet / foot

Rev A should use a replaceable laser-cut or die-cut circular silicone/EPDM pad
seated in the shallow pocket of an 86 mm circular structural puck, not an
overmold. The puck stays flat on the desk while the rectangular shell intersects
its upper portion at 2°, producing the subtle angled-base expression.

- Selected stock: 1/16 in (1.59 mm) silicone disc (BOM: McMaster `8525T575`),
  50–70 Shore A, in a 0.8 mm recess → ~0.8 mm proud, inside the 0.6–1.0 mm
  projection target. (2.0 mm stock with a 1.2 mm recess is an equivalent
  alternative.)
- Add shallow retention nibs only after testing adhesive-backed sheet stock.
- Do not let the foot trap the battery door, obscure regulatory markings, or
  cover enclosure screws needed for safe LiPo service.

## Material plan

- First fit prototypes: opaque PLA/PETG for both shells.
- Visual prototype: translucent/frosted PETG upper shell and dark lower shell.
- Target process for real units: MJF PA12 (no supports). FDM prints of the
  bottom shell need supports under the ~35 mm corner overhangs beyond the
  puck.
- Production option: CNC polycarbonate upper plus anodized aluminum lower, but
  only with a polymer RF window around the certified module antenna.

## CAD construction order

1. Import the populated KiCad STEP board into FreeCAD as the master reference.
2. Create a parameter spreadsheet and link every shell dimension to it.
3. Model the tilted PCB/plate datum and component keep-out envelopes.
4. Build the lower shell, battery pocket, bosses, USB-C opening, and antenna
   exclusion volume.
5. Build the upper shell/plate around measured switches, caps, encoder, and
   joystick.
6. Cut the bottom grommet recess and service openings last.
7. Export separate top, bottom, and fit-gauge STLs; print the fit gauge before
   committing to a full enclosure print.

## First-print acceptance gates

- All four corner fasteners engage without forcing or bowing the PCB, and
  every boss passes freely through its PCB corner relief.
- Switches latch into the plate and hot-swap sockets remain unloaded.
- Ceramic caps clear adjacent caps and the sloped shell throughout travel.
- Encoder and joystick can reach their full motion without touching the shell.
- USB-C inserts straight without using the connector as a structural stop.
- Battery drops into its pocket, cannot contact switch pins, screws, or the
  antenna keep-out, and its pigtail folds into the relief bay unpinched.
- A pin reaches the reset switch through the floor pinhole with the case
  closed.
- The unit does not rock, and the grommet remains loaded across a flat desk.
