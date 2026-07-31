# FocalPoint hardware release tasks

Last updated: 2026-07-31

Authoritative electrical sources:

- Schematic root: `kicad/focalpoint.kicad_sch`
- Schematic children: `kicad/focalpoint_power.kicad_sch`,
  `kicad/focalpoint_signals.kicad_sch`, and
  `kicad/focalpoint_peripherals.kicad_sch`
- PCB: `kicad/focalpoint_rev_a_release_candidate.kicad_pcb`
- Project: `kicad/focalpoint_rev_a_release_candidate.kicad_pro`
- Native DRC evidence: `kicad/DRC_release_candidate_native.rpt`

The board is a routed prototype candidate, not yet an orderable production
release. Keep this file current as checks are completed or reopened.

## Release checklist

- [x] Capture the Rev A schematic.
  - Evidence: `kicad/erc_release_candidate.rpt` reports 0 violations.
- [x] Refactor the flat capture into functional hierarchical sheets.
  - Evidence: `kicad/hierarchical_schematic_equivalence.txt` reports 107
    components, 80 nets, and zero component, net-node, or PCB pin/net
    mismatches.
  - Layout evidence: `kicad/hierarchical_schematic_layout_validation.txt`
    reports zero overlapping pairs, full printable-area containment, and
    preserved connection-grid alignment.
- [x] Route the six-layer PCB with no ratsnest.
  - Evidence: native DRC reports 0 unconnected pads.
- [x] Compare numbered schematic pins with PCB pad nets.
  - Evidence: `kicad/release_candidate_schematic_pcb_net_compare.txt` reports 0
    mismatches.
- [x] Run the independent copper/fabrication-minimum audit.
  - Evidence: `kicad/release_candidate_static_audit.txt` reports 0
    violations.
- [x] Dispose of every native DRC warning.
  - Final checkpoint: 0 violations, 0 unconnected pads, and 0 footprint
    errors in `kicad/DRC_release_candidate_native.rpt`.
  - Resolved locally: all 18 hole-to-hole, all 9 connection-width, all 6
    dangling-via, all 14 original dangling-track, and all 114 silkscreen
    warnings.
  - Thirty-seven intentionally modified footprints are locked in
    `kicad/FocalPoint.pretty`; `kicad/release_candidate_footprint_audit.txt`
    reports 0 geometry mismatches. KiCad's global library-mismatch category is
    ignored only because J3/U1 regenerate property UUID metadata when exported.
- [ ] Obtain an independent schematic/PCB review.
  - Review power topology, package pin numbering, USB, charging, RF keepout,
    via-in-pad, assembly sides, and component rotations.
- [ ] Complete PCB/enclosure interference review.
  - Validate board outline, fastener bosses, USB opening, encoder,
    joystick motion/body/lugs, touch pillar, reset access, battery/cable
    pocket, sockets, and antenna/metal clearance.
  - Deterministic B-rep validation now reports zero PCB/shell intersection:
    0.866 mm minimum to the lower shell and 0.600 mm minimum to the top shell.
    Battery-to-PCB clearance is 6.134 mm.
  - Resolution: the 125 mm square shell uses side-wall screw channels and Ø9
    bosses that stop 0.300 mm below the PCB; J1 and J2 have exact top service
    openings. The PCB remains a plain rectangle and the 4x4 controls stay
    centered.
  - U3 and U9 now use dimensionally matched package-envelope models; provenance
    is recorded in `kicad/COMPONENT_MODEL_SOURCING.md`. ENC1 and JS1 still
    require printed/purchased-part fit because their manufacturer CAD is
    account-gated and their moving/through-panel geometry is the relevant risk.
- [x] Build a fresh manufacturing package from the accepted PCB.
  - Required: Gerbers, PTH/NPTH drills, BOM, centroid/positions, source files,
    validation reports, and hashes.
  - Output: `kicad/release_candidate/`,
    `kicad/focalpoint_rev_a_release_candidate.zip`, and
    `kicad/focalpoint_rev_a_release_candidate_gerbers.zip`.
- [ ] Complete JLCPCB live upload review.
  - Confirm JLC06161H-3313, 1.6 mm order class, ENIG, impedance control, and
    epoxy-filled/capped via-in-pad.
  - Confirm every exact MPN, stock/substitution choice, side, and rotation.
  - Populate exactly two boards; five bare boards may be the fabrication
    minimum.
- [ ] Prepare Rev A bring-up firmware.
  - Minimum: SWD flash, rail controls, all 16 inputs, RGB walking-one/current
    cap, USB raw HID, fuel-gauge I2C, charger status, and BLE test logging.
- [ ] Assemble and test two physical prototypes.
  - Follow `ASSEMBLY.md` and `BRINGUP_TEST_PLAN.md`.
  - Battery polarity and closed-case charging thermal tests are hard safety
    gates.

## Work that can be completed locally now

- [x] Classify the DRC warnings into repair, intentional geometry, and
  documentation-only groups.
- [x] Repair the manufacturing-risk warning classes that could be changed
  without altering the approved
  schematic pinout, board outline, or component placement.
- [x] Rerun ERC, net parity, copper audit, and native DRC after the accepted
  PCB change.
- [x] Audit the release builder against the authoritative PCB and current
  evidence files.
  - It generated placements, Gerbers, drills, hashes, and archives; it passed
    DRC, BOM/position, footprint, net-parity, and copper-audit gates.
- [x] Compare the existing enclosure model with the authoritative PCB and
  record measurable fit results.
  - Evidence: `../case/output/focalpoint-enclosure-validation.txt` and
    `../case/output/focalpoint-assembly-review-final_20260731T141630Z.png`.
  - Result: all modeled solids clear; the battery clears the PCB by 6.134 mm.
    U3/U9 package envelopes are now covered. Purchased ENC1/JS1 fit and full
    joystick travel remain physical/human review gates.
- [x] Produce a human-review packet containing direct links to the exact
  schematic, PCB, reports, manufacturing inputs, and enclosure assembly.
  - This file is the maintained review index; `kicad/README.md` contains the
    electrical workflow and `../case/DESIGN.md` contains the enclosure intent.

## External or physical gates

- [ ] Human electrical peer review.
- [ ] JLCPCB live component matcher, placement preview, quote, and order-form
  selections.
- [ ] Printed enclosure fit coupon/full print.
- [ ] Assembly inspection and bring-up of two populated boards.
- [ ] USB, BLE range, battery, charging, thermal, touch, joystick, encoder,
  switch, and RGB measurements on hardware.
