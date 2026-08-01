# Vibekey/FocalPoint case study

Use this reference only for this repository or as a concrete example. Do not
copy its values into unrelated designs without recalculation.

## Product and layout

- 116 mm square PCB in a square tilted enclosure.
- Sixteen logical inputs in a 4x4 visual arrangement: thirteen RGB MX hot-swap
  keys, top-left encoder, top-right true analog joystick, and bottom-right
  capacitive touch input.
- nRF52840 module, USB-C, one-cell LiPo charging/power path, fuel gauge, 3.3 V
  conversion, 5 V RGB boost/switching, SWD, reset, and BLE.
- SMT assembly is outsourced; the user installs through-hole/mechanical parts,
  switches, caps, battery, fasteners, and enclosure pieces.

## Electrical source organization

The authoritative schematic is hierarchical:

- `hardware/kicad/focalpoint_power.kicad_sch`
- `hardware/kicad/focalpoint_signals.kicad_sch`
- `hardware/kicad/focalpoint_peripherals.kicad_sch`

The root is `hardware/kicad/focalpoint.kicad_sch`. The authoritative board is
`hardware/kicad/focalpoint_rev_b_4layer_release_candidate.kicad_pcb` with its
same-name project file.

## Four-layer decision

Rev A used six layers and accumulated long, stair-stepped autorouter routes.
Rev B returned to four layers after placement and routing cleanup:

1. F.Cu signals/local power/USB;
2. In1 continuous GND;
3. In2 GND pour plus slow routing;
4. B.Cu signals/local power.

3.3 V and 5 V do not have separate planes. The selected prototype stack is
JLCPCB JLC04161H-7628, nominal 1.6 mm, 1 oz outer and 0.5 oz inner copper. The
recorded USB 2.0 outer-layer differential geometry is 0.2332 mm width and
0.15 mm edge gap over In1 for a 90-ohm target. Reconfirm these time-sensitive
fabricator values before another order.

## Routing lessons

- Moving the radio into open lower-right space reduced congestion; short-range
  keyboard use still requires the module antenna keepout.
- The accepted board uses 1,033 track segments and 227 vias, roughly half the
  legacy six-layer route length.
- A first edge audit examined tracks but missed a KEY12 via annular ring only
  about 0.74 mm from the bottom edge. DRC passed because the project rule was
  the 0.20 mm fabrication limit.
- The corrected KEY12 track is 2.4 mm from the bottom edge and its via ring is
  2.2 mm away. The reusable audit now checks track width and via diameter and
  fails below the internal 1.0 mm target.
- Other sub-2 mm copper is either comfortably above fab minimums or intentional:
  +3V3 bottom routing at 1.69 mm, a USB route/via at 1.70–1.88 mm, 1 mm GND
  pours, and USB-C shield pads at the board edge.

## Release evidence

The accepted revision records:

- ERC: zero violations;
- DRC: zero violations, zero unconnected pads, zero footprint errors;
- schematic/PCB numbered-pad mismatches: zero;
- independent copper/fabrication violations: zero;
- vendored footprint geometry mismatches: zero;
- JLC placement cross-check: 101 placed references and no unmatched BOM lines;
- verified full-source and Gerber ZIP archives.

These results make it a DRC-clean prototype release candidate, not guaranteed
working hardware. Live JLC DFM/placement review, independent electrical review,
enclosure/purchased-part fit, assembly, and two-unit bring-up remain required.
