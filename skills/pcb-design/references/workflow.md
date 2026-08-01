# PCB workflow

## Contents

- Requirements and authority
- Schematic capture
- Footprints and placement
- Routing stages
- Change control
- Progress reporting

## Requirements and authority

Translate product intent into explicit electrical and mechanical requirements:
input count/type, scan topology, analog behavior, USB/BLE, RGB load, battery and
charging, programming, tactile parts, assembly boundary, board dimensions,
connector openings, moving-part envelopes, antenna clearance, and prototype
quantity. Record unresolved choices before layout.

Maintain one authoritative path for each artifact. Use descriptive revision
names and promote candidates only after validation. Archive intermediates into
one recoverable ZIP after the release source is accepted.

## Schematic capture

Partition by function rather than arbitrary page count. A practical hierarchy:

- power entry, charging, battery monitoring, conversion, and load switching;
- controller, USB, ESD, RF, programming, reset, and signal conditioning;
- keys, LEDs, encoder, joystick, touch, and other peripherals.

Use conventional symbols and left-to-right flow. Keep labels and wires on grid,
fill the printable page, avoid overlaps, and include test points and power flags.
Run ERC and export a KiCad XML netlist. Lock a flat reference before a large
hierarchy refactor, then compare component and net-node equivalence.

## Footprints and placement

Verify every critical footprint from its current manufacturer drawing:
connector shell and board edge, module pad numbering, exposed pads, switch and
socket orientation, joystick lugs and travel, encoder body, battery polarity,
and programming connector pin 1. Use project-local footprints for intentional
modifications and project-local 3D models where available.

Place in this order:

1. outline, holes, bosses, connector and panel datums;
2. user controls and display-visible elements;
3. antenna/module keepout and RF-sensitive items;
4. switching power loops and input/output capacitors;
5. controller decoupling, crystal/sensitive analog, USB ESD;
6. remaining parts and test points.

Check component bodies, not just courtyard rectangles, against the enclosure.

## Routing stages

Route and validate in bounded stages:

1. local power loops and decoupling;
2. USB/RF/clock/analog critical signals;
3. high-current trunks and rail distribution;
4. ordinary controls and buses;
5. local escapes, ground stitching, and zones;
6. cleanup of detours, stair-steps, acute bends, redundant segments, and edge
   proximity.

Save a named checkpoint after each clean stage. When importing an autorouter
session, preserve the pre-import PCB and rules file, validate connectivity, and
promote into a new PCB filename.

## Change control

After any footprint, track, via, zone, outline, keepout, or stack change:

1. refill zones;
2. save the PCB;
3. rerun DRC and unrouted checks;
4. rerun net parity if connectivity or pin mapping changed;
5. rerun edge, footprint, and fabrication audits;
6. regenerate all fabrication outputs and hashes;
7. update the task/release record.

Do not reuse an older clean report for a newer board.

## Progress reporting

Report percentage by deliverable rather than optimism. Separate PCB CAD,
manufacturing package, human review, and physical validation. Example:

- PCB CAD 100%: routed and automated checks clean;
- local release package 100%: outputs rebuilt and hashes verified;
- order readiness incomplete: live DFM/placement and peer review pending;
- product validation incomplete: prototypes not assembled or tested.
