# FocalPoint Rev B PCB fabrication constraints

The authoritative PCB is `focalpoint_rev_b_4layer_release_candidate.kicad_pcb`.
It is a routed 116 x 116 mm, nominal 1.6 mm, four-layer prototype release
candidate. Order it only with JLCPCB stack **JLC04161H-7628**; do not substitute
a generic four-layer construction if controlled USB impedance is required.

| Layer | Intended use | JLC04161H-7628 construction |
| --- | --- | --- |
| F.Cu | Signals, power, USB differential pair | 1 oz, 0.035 mm |
| dielectric 1 | USB-to-reference spacing | 7628 prepreg, 0.2104 mm, Dk 4.4 |
| In1.Cu | Continuous GND reference plane | 0.5 oz, 0.0152 mm |
| dielectric 2 | Core | NP-155F, 1.065 mm, Dk 4.43 |
| In2.Cu | GND pour plus slow signals | 0.5 oz, 0.0152 mm |
| dielectric 3 | Bottom dielectric | 7628 prepreg, 0.2104 mm, Dk 4.4 |
| B.Cu | Signals and local power | 1 oz, 0.035 mm |

The layer policy intentionally has no separate 3.3 V or 5 V plane. In1 is the
primary continuous return plane. In2 may carry slow signals but retains a GND
pour. Power is routed locally with wider traces. Refill zones and rerun DRC
after any copper, footprint, outline, or keepout change.

## USB decision record

| Item | Recorded choice |
| --- | --- |
| Electrical target | USB 2.0, 90 ohm differential |
| Structure | F.Cu edge-coupled differential microstrip over continuous In1 GND |
| KiCad netclass | `USB2_FS_JLC04161H_7628_90R` |
| Pair geometry | 0.2332 mm trace width, 0.15 mm edge-to-edge gap |
| Stack | JLC04161H-7628, 1.6 mm order class, 1 oz outer / 0.5 oz inner |
| Geometry provenance | JLC04161H-7628 90-ohm values published in the JITX JLC stack library; stack dimensions and materials cross-checked against JLCPCB's current impedance documentation and calculator guide on 2026-07-31 |
| Release condition | Select the named JLC stack and impedance control in the order form; verify USB on both physical prototypes |

The design evidence is in `focalpoint_rev_b_4layer_usb_report.txt`. This
calculated geometry improves the design, but a CAD rule cannot prove the
manufactured impedance or USB behavior; prototype measurement remains a gate.

## Routing and manufacturing evidence

- Native KiCad DRC: `focalpoint_rev_b_4layer_release_DRC.rpt` reports zero
  violations, zero unconnected pads, and zero footprint errors.
- Schematic/PCB parity:
  `focalpoint_rev_b_4layer_schematic_pcb_net_compare.txt` reports zero
  numbered-pin net mismatches.
- Independent copper audit: `focalpoint_rev_b_4layer_static_audit.txt` reports
  zero clearance and fabrication-minimum violations.
- Footprint audit: `focalpoint_rev_b_4layer_footprint_audit.txt` reports zero
  project-local geometry mismatches.
- Route audit: `focalpoint_rev_b_4layer_route_audit.txt` records 1,033 track
  segments and 227 vias. It checks tracks and via annular rings separately.
  No track or via is within the enforced 1.00 mm external-edge target. The
  closest bottom via is KEY12 at 2.200 mm, and the KEY12 bottom track is
  2.400 mm from the edge. The closest bottom track overall is +3V3 at
  1.690 mm. The criticized
  left-edge track clearance is 2.850 mm.

## Release generation

Generate all manufacturing outputs from the exact authoritative board:

```sh
python3 hardware/kicad/build_release_candidate.py \
  --drc-report hardware/kicad/focalpoint_rev_b_4layer_release_DRC.rpt
```

The builder produces four-layer Gerbers, separate PTH/NPTH drills, a JLC BOM,
placement data, source/evidence files, hashes, and ZIP archives under the Rev B
names. It refuses a supplied DRC report that does not explicitly report zero
violations.

## Order and physical-validation boundary

Before payment, use JLCPCB's live Gerber/DFM, component matching, placement,
and rotation previews. Select JLC04161H-7628, 1.6 mm, ENIG, impedance control,
and the required via-in-pad treatment. Populate exactly two boards; the bare
PCB fabrication minimum may be higher.

CAD, ERC, DRC, parity, and fabrication-file checks do not guarantee first-spin
hardware success. An electrical peer review, enclosure/purchased-part fit
review, and two-board bring-up using `hardware/BRINGUP_TEST_PLAN.md` remain
mandatory. Battery polarity, charging temperature, USB, RF range, and every
input/RGB channel must be tested before any larger build.
