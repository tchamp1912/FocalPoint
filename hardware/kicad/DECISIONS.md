# Rev A electrical decisions and gates

## Fixed for the first schematic

- 4×4-capable matrix: `C0..C3`, `R0..R3`, with 13 populated switch positions
  and diode direction switch → row.
- 13 south-facing MX hot-swap positions and 13 SK6812 MINI-E LEDs.
- EC11 encoder with direct GPIO signals `ENC_A`, `ENC_B`, and `ENC_SW`.
- True analog joystick (X/Y/push) and one capacitive touch input.
- USB 2.0 device plus BLE HID/custom GATT on an nRF52840 module.
- One-cell protected LiPo; charging must include power-path/load sharing.
- Target 1,000–1,100 mAh protected LiPo; freeze the pocket only after measuring
  the purchased pack and verifying JST-PH polarity.
- Every mechanical key gets independently addressable RGB with a switched 5 V
  rail and a hard firmware current ceiling.
- Tactile MX switches are the Rev A feel target; samples still gate spring and
  ceramic-key return-force selection.

## Must be selected before footprints are committed

- Exact certified nRF52840 module and its antenna/courtyard/keep-out drawing.
- Exact analog joystick and cap/retention method.
- Exact USB-C receptacle, LiPo connector/polarity, charger/power-path IC,
  regulator/load switch, and ESD array.
- Exact battery pack, connector polarity, maximum charge current, and enclosure
  location.
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
