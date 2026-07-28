# Rev A electrical decisions and gates

## Fixed for the first schematic

- 4×4 matrix: `C0..C3`, `R0..R3`, diode direction switch → row.
- 16 south-facing MX hot-swap positions and 16 SK6812 MINI-E LEDs.
- EC11 encoder with direct GPIO signals `ENC_A`, `ENC_B`, and `ENC_SW`.
- USB 2.0 device plus BLE HID/custom GATT on an nRF52840 module.
- One-cell protected LiPo; charging must include power-path/load sharing.

## Must be selected before footprints are committed

- Exact certified nRF52840 module and its antenna/courtyard/keep-out drawing.
- Exact analog joystick, or the alternate 5-way switch.
- Exact USB-C receptacle, LiPo connector/polarity, charger/power-path IC,
  regulator/load switch, and ESD array.
- Battery capacity, connector, maximum charge current, and enclosure location.
- Mounting screw/inserts and the location of every board hole.

## Review gates before ordering

- Print the switch plate and control datums at 1:1 with actual caps and parts.
- Calculate peak/limited RGB load, battery runtime, charge current, thermal
  rise, regulator headroom, and USB current behavior.
- Enforce the module vendor's full antenna keep-out on every copper and
  mechanical layer; keep battery, screws, and metal case parts outside it.
- Run KiCad ERC and DRC, inspect every footprint against its datasheet, and
  review schematic/PCB with another person.
- Order unassembled PCBs or a small prototype quantity before an assembly run.
