# FocalPoint KiCad Rev A

This directory is the persistent KiCad 10 workspace. The verified schematic is
`focalpoint.kicad_sch`; the current PCB is
`focalpoint_rev_a_release_candidate.kicad_pcb`. It is a fully routed six-layer
prototype candidate. Native KiCad DRC reports zero errors and zero unconnected
pads and zero violations. Thirty-seven intentionally modified embedded
footprints are locked to `FocalPoint.pretty` and independently audited. It is
not orderable until the enclosure interference defects are resolved, an
independent review is completed, and the JLCPCB upload is checked.

The production stack-up, internal-plane policy, routing classes, and mandatory
USB impedance confirmation are defined in [PCB_FABRICATION.md](PCB_FABRICATION.md).

## Refresh the mechanical foundation

```sh
npx --yes ergogen@4.1.0 hardware/ergogen -o hardware/ergogen/output
hardware/kicad/refresh-from-ergogen.sh
```

The refresh script refuses to overwrite a board that has already gained
KiCad-owned electrical work. Once schematic capture or manual placement starts,
move Ergogen changes across deliberately instead of replacing the board.

Open `focalpoint_rev_a_release_candidate.kicad_pro` and
`focalpoint_rev_a_release_candidate.kicad_pcb` in KiCad 10. The
active 116 mm square design presents 16 input positions in a 4×4 layout: 13
direct-scan MX hot-swap keys plus the top-left EC11 encoder, top-right analog
joystick, and bottom-right capacitive touch input. Every mechanical key has an
independently addressable RGB LED.

## Rev A functional blocks

1. `keys`: 13 direct GPIO key inputs, hot-swap sockets, and no matrix diodes.
2. `controls`: EC11 A/B/push and the selected joystick X/Y/push.
3. `mcu`: certified nRF52840 module, SWD, reset, and boot/recovery.
4. `usb`: USB-C USB 2.0 device, CC resistors, ESD, and data protection.
5. `power`: protected 1-cell LiPo, charger with power-path management, battery
   measurement, 3.3 V regulation, and switched/current-budgeted LED rail.
6. `rgb`: 13 SK6812 MINI-E LEDs, local bypassing, data conditioning, and test
   pads.

Do not assign unverified footprints for the radio, charger, battery connector,
or USB-C receptacle from a generic name. Pin them to an orderable manufacturer
part and verify the land pattern against its current datasheet first.

## Release-candidate build

After refilling zones, running native DRC, and saving its zero-violation report:

```sh
python3 hardware/kicad/build_release_candidate.py \
  --drc-report hardware/kicad/DRC_release_candidate_native.rpt
```

The output is `release_candidate/` plus candidate ZIP archives. Read
`RELEASE_STATUS.txt`; do not order if it says `NOT YET ORDERABLE`. The
checked-in DRC report is evidence of routing connectivity, not a zero-warning
release report, so the build command intentionally rejects it until the
warnings have been reviewed or corrected.
