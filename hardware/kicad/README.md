# FocalPoint KiCad Rev A

This directory is the persistent KiCad 8 workspace. The PCB begins as a
snapshot of the reproducible Ergogen matrix, while the schematic, electrical
parts, routing, zones, and manufacturing setup are owned here.

## Refresh the mechanical foundation

```sh
npx --yes ergogen@4.1.0 hardware/ergogen -o hardware/ergogen/output
hardware/kicad/refresh-from-ergogen.sh
```

The refresh script refuses to overwrite a board that has already gained
KiCad-owned electrical work. Once schematic capture or manual placement starts,
move Ergogen changes across deliberately instead of replacing the board.

Open `focalpoint_matrix.kicad_pro` in KiCad 8. The initial board contains 16 MX
hot-swap sockets, 16 diodes, the EC11 encoder, and the rounded board edge. It is
not ready to manufacture.

## Rev A sheets to capture

1. `matrix`: 4 columns × 4 rows, 16 switches and diodes.
2. `controls`: EC11 A/B/push and the selected joystick X/Y/push.
3. `mcu`: certified nRF52840 module, SWD, reset, and boot/recovery.
4. `usb`: USB-C USB 2.0 device, CC resistors, ESD, and data protection.
5. `power`: protected 1-cell LiPo, charger with power-path management, battery
   measurement, 3.3 V regulation, and switched/current-budgeted LED rail.
6. `rgb`: 13 SK6812 MINI-E LEDs, local bypassing, data conditioning, and test
   pads.

Do not assign footprints for the radio, joystick, charger, battery connector,
or USB-C receptacle from a generic name. Pin them to an orderable manufacturer
part and verify the land pattern against its current datasheet first.
