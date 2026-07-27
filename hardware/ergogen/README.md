# FocalPoint Ergogen layout

`config.yaml` is the source of truth for the Rev A switch matrix and the first
plate/case perimeter. It uses the supplied reference’s compact rounded-square
composition: top control rail (joystick + encoder), selector field, then action
row. It is deliberately an **MX** layout:

- selector keys `selectors_slot_{1..4}_row_{1..3}` are 12 clear/translucent
  agent-selector caps and map to protocol slots 1–12, left-to-right then
  top-to-bottom;
- `actions_accept_action`, `actions_reject_action`,
  `actions_new_task_action`, and `actions_push_to_talk_action` are ceramic
  action keys and map to protocol controls 0–3.

The generated PCB is only the matrix starting point. Finish the nRF52840
module, USB-C/charger/power path, battery connector, addressable LEDs, encoder,
joystick, antenna keep-out, test pads, mounting hardware, and traces in KiCad.
Do not use it to order a board until those items and electrical review are
complete.

## Generate

Requires Node.js 20+ and Ergogen 4.1+:

```sh
npx --yes ergogen@4.1.0 hardware/ergogen -o hardware/ergogen/output
```

Useful generated artifacts:

- `output/pcbs/focalpoint_matrix.kicad_pcb` — import into KiCad 8 as the matrix
  placement foundation.
- `output/outlines/pcb.dxf` — board/plate edge reference.
- `output/outlines/case_outer.dxf` — printed-case outer envelope.
- `output/outlines/switch_cutouts.dxf` — plate cutouts.
- `output/outlines/plate.dxf` — the switch-field plate perimeter.

Generated `output/` is ignored because it is reproducible.

## Mechanical and RF gates

Before beginning the KiCad schematic:

1. Print the `case_outer` and `switch_cutouts` plate at 1:1. Test the selected
   MX sockets, transparent selector caps, ceramic action caps, encoder, and
   joystick for interference.
   Place the joystick and encoder centers at the `joystick_x`/`control_y` and
   `encoder_x`/`control_y` values in `config.yaml`; they are intentionally
   reserved geometry, not generated footprints.
2. Reserve the nRF52840 module’s documented antenna keep-out: no copper,
   battery, screws, or aluminum directly under/above the antenna.
3. Put the battery in its own pocket, away from the radio end of the board.
4. The first printed enclosure must include a polymer RF window. A later
   aluminum enclosure must retain that window or move the antenna to a
   non-metal end-cap.
5. Budget RGB brightness in firmware for battery operation; the LED rail,
   charger, protection, and connectors still need electrical review for the
   worst-case load.
