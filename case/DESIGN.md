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

## Starting parameters for the first print

These values are prototypes, not production dimensions:

| Parameter | Initial value | Fit-test range |
|---|---:|---:|
| PCB envelope | 108 × 108 mm | Ergogen-owned |
| Shell clearance per side | 1.5 mm | 1.0–2.0 mm |
| Outer wall | 2.4 mm | 2.0–3.0 mm |
| Corner radius | 12 mm | 9–15 mm |
| Plate thickness | 1.5 mm | 1.5–2.0 mm |
| Forward slope | 4° | 3–6° |
| Front base height | 11 mm | component-driven |
| Rear base height | 20 mm | component-driven |
| Circular base diameter | 86 mm | 80–94 mm |
| Shell-to-base angle | 2° | 1–3° |
| Circular grommet diameter | 72 mm | part/material-driven |
| Grommet recess | 1.2 mm | match selected sheet/part |
| Printed-part clearance | 0.30 mm per mating side | printer-specific |

The action-key edge is **front**; the joystick/encoder rail is **rear**. The
keycap plate slopes downward toward the front. Prefer a continuous internal
wedge or stepped internal bosses while keeping the exterior side wall smooth.

## Bottom grommet / foot

Rev A should use a replaceable laser-cut or die-cut circular silicone/EPDM pad
seated in the shallow pocket of an 86 mm circular structural puck, not an
overmold. The puck stays flat on the desk while the rectangular shell intersects
its upper portion at 2°, producing the subtle angled-base expression.

- Target 1.5–2.0 mm pad thickness and roughly 50–70 Shore A.
- Keep the installed rubber proud of the base by about 0.6–1.0 mm.
- Add shallow retention nibs only after testing adhesive-backed sheet stock.
- Do not let the foot trap the battery door, obscure regulatory markings, or
  cover enclosure screws needed for safe LiPo service.

## Material plan

- First fit prototypes: opaque PLA/PETG for both shells.
- Visual prototype: translucent/frosted PETG upper shell and dark lower shell.
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

- All four corner fasteners engage without forcing or bowing the PCB.
- Switches latch into the plate and hot-swap sockets remain unloaded.
- Ceramic caps clear adjacent caps and the sloped shell throughout travel.
- Encoder and joystick can reach their full motion without touching the shell.
- USB-C inserts straight without using the connector as a structural stop.
- Battery cannot contact switch pins, screws, or the antenna keep-out.
- The unit does not rock, and the grommet remains loaded across a flat desk.
