# FocalPoint enclosure path

## Rev A: printed first

Use a two-piece, support-free FDM enclosure:

- a plate/top shell that locates MX switches and provides a 1.5–2.0 mm plate;
- a bottom shell with heat-set inserts, USB-C opening, reset/boot access,
  battery pocket, and a removable service path;
- a dedicated non-metal radio zone around the nRF52840 module antenna;
- 0.5–1.0 mm clearance around the tallest ceramic action caps and the encoder
  knob, verified with the actual parts;
- optional foam/gasket volume so acoustics can be tuned without changing the
  PCB.

Start from `hardware/ergogen/output/outlines/case_outer.dxf`, then model the
shell in a parametric CAD tool. Keep the source model in this directory and
export STL/STEP only after a physical fit check.

## Production option: aluminum after validation

Aluminum is a follow-on manufacturing finish, not a Rev A substitute. Its
conductivity detunes/shields a nearby Bluetooth antenna. The aluminum design
must retain either:

1. a polymer antenna window directly above/around the approved module antenna,
   or
2. a non-metal end-cap with the antenna relocated behind it.

Carry forward the printed case’s plate plane, screw pattern, USB datum,
battery-service path, and antenna exclusion zone. Validate RF range again
after every enclosure material or finish change.
