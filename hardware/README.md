# FocalPoint hardware

The first assembled FocalPoint is a square wireless MX macropad, not a wired RP2040
derivative. The Keychron V1 Max firmware remains the Phase 0 test platform for
the host loop while this hardware is developed.

## Rev A definition of done

- A visual 4×4 input lattice with the encoder top-left, analog joystick
  top-right, capacitive touch bottom-right, and 13 RGB MX keys filling every
  other cell. Twelve caps are clear/frosted PC and one is ceramic. All controls are
  dynamically assignable in firmware/host configuration. Use south-facing LED
  geometry: Cerakey-style Cherry-profile caps can collide with north-facing
  switch LEDs, and ceramic itself will not transmit the status light.
- nRF52840-module-based board that pairs as BLE HID and accepts daemon status
  updates through a versioned FocalPoint BLE GATT transport.
- USB-C supports charging, USB HID/Raw HID, recovery, and firmware updates.
- Protected LiPo, charger with power-path management, battery connector, and
  firmware RGB current limit.
- Printed two-piece case with a protected battery pocket, a radio antenna
  keep-out/RF window, no-support FDM orientation, and accessible reset/boot
  control.
- One real agent session works end-to-end while unplugged: daemon state updates
  reach LEDs and input events reach the daemon.

## Work order

1. Generate and physically validate the Ergogen plate in `ergogen/`.
2. Buy a small cap/switch sample set before finalizing plate height and case
   clearance.
3. Choose the certified nRF52840 module and place its official antenna
   keep-out on the KiCad board before placing the battery or screws.
4. Design the charger/power path and verify thermal/current margins before
   routing the RGB rail.
5. Add the logical BLE transport to `PROTOCOL.md`, then implement firmware and
   daemon transport selection together.
6. Print and test the enclosure before ordering five Rev A boards.

The PCB project, manufacturing files, and BOM belong here once schematic
capture starts. Do not treat generated Ergogen output as a production-ready
electrical design.
