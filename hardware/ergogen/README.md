# FocalPoint Ergogen layout

`config.yaml` is the source of truth for the Rev A input geometry and the first
plate/case perimeter. It uses the supplied reference’s compact rounded-square
composition: a complete visual 4×4 lattice. The encoder is top-left, joystick
top-right, and touch sensor bottom-right; 13 RGB MX keys fill every other cell.
It is deliberately an **MX** layout:

- 12 keys use clear/translucent caps and one top-row key uses a ceramic cap;
- all 13 keys and the three non-key controls are dynamically assignable. The
  names describe physical placement, not fixed firmware behavior.

The generated PCB is only the mechanical/matrix starting point. Finish the
nRF52840 module, USB-C/charger/power path, battery connector, addressable LEDs,
joystick, antenna keep-out, test pads, mounting hardware, and traces in KiCad.
Do not use it to order a board until those items and electrical review are
complete.

## Generate

Requires Node.js 20+ and Ergogen 4.1+:

```sh
npx --yes ergogen@4.1.0 hardware/ergogen -o hardware/ergogen/output
```

Useful generated artifacts:

- `output/pcbs/focalpoint_matrix.kicad_pcb` — generated KiCad 8 matrix and EC11
  placement foundation. Refresh the tracked working board with
  `hardware/kicad/refresh-from-ergogen.sh` before schematic/PCB placement work.
- `output/outlines/pcb.dxf` — board/plate edge reference.
- `output/outlines/case_outer.dxf` — printed-case outer envelope.
- `output/outlines/switch_cutouts.dxf` — plate cutouts.
- `output/outlines/plate.dxf` — the switch-field plate perimeter.

Generated `output/` is ignored because it is reproducible.

## Mechanical and RF gates

Before beginning the KiCad schematic:

1. Print the `case_outer` and `switch_cutouts` plate at 1:1. Test the selected
   MX sockets, transparent selector caps, ceramic action caps, encoder, and
   joystick for interference. The EC11 is generated at
   `encoder_x`/`control_y`; place the selected joystick footprint at
   `joystick_x`/`control_y` after checking its datasheet and a real sample.
2. Reserve the nRF52840 module’s documented antenna keep-out: no copper,
   battery, screws, or aluminum directly under/above the antenna.
3. Put the battery in its own pocket, away from the radio end of the board.
4. The first printed enclosure must include a polymer RF window. A later
   aluminum enclosure must retain that window or move the antenna to a
   non-metal end-cap.
5. Budget RGB brightness in firmware for battery operation; the LED rail,
   charger, protection, and connectors still need electrical review for the
   worst-case load.
