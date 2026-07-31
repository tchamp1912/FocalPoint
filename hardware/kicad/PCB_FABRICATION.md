# FocalPoint Rev A PCB fabrication constraints

`focalpoint_rev_a_release_final_pinoutfix_drcfix2.kicad_pcb` is the corrected, fully
routed 116 x 116 mm, 1.6 mm, six-layer Rev A release candidate. Its order stack
is JLCPCB's controlled-impedance option **JLC06161H-3313**. Do not substitute
a generic six-layer construction.

| Layer | Intended use | JLC06161H-3313 material / thickness |
| --- | --- | --- |
| F.Cu | Signals and local power | 1 oz outer copper, 0.035 mm |
| dielectric 1 | F.Cu return spacing | 3313 RC57% prepreg, 0.0994 mm, Dk 4.10 |
| In1.Cu | Continuous GND reference plane | 0.5 oz inner copper, 0.0152 mm |
| dielectric 2 | Core | NP-155F core, 0.55 mm, Dk 4.41 |
| In2.Cu | Internal signals | 0.5 oz inner copper, 0.0152 mm |
| dielectric 3 | Center bond | 2116 RC54% prepreg, 0.1088 mm, Dk 4.16 |
| In3.Cu | Internal signals | 0.5 oz inner copper, 0.0152 mm |
| dielectric 4 | Core | NP-155F core, 0.55 mm, Dk 4.41 |
| In4.Cu | +3V3 power plane | 0.5 oz inner copper, 0.0152 mm |
| dielectric 5 | B.Cu return spacing | 3313 RC57% prepreg, 0.0994 mm, Dk 4.10 |
| B.Cu | Signals and local power | 1 oz outer copper, 0.035 mm |

JLCPCB currently labels this free construction as a nominal 1.54 mm finished
board within the selected 1.6 mm ±10% order class. The KiCad board thickness
remains 1.6 mm for enclosure/mechanical modeling.

## Plane policy

The generator creates two refillable zones inset 0.5 mm from the edge:

- In1.Cu is a GND zone. It is the primary return plane and must remain
  uninterrupted under all ordinary signals.
- In4.Cu is a +3V3 zone. It is a power plane, not a general-purpose signal
  layer. Do not run USB, switching-node, or other signals through it.
- In2.Cu and In3.Cu are the two internal signal layers.

The Raytac module footprint's all-layer antenna keep-out takes precedence.
Before manufacturing, visually confirm the zone refill leaves its required
antenna clearance and that no split plane interrupts a signal return path.

The checked-in candidate contains saved zone fills. If placement, routing, or a
keep-out is changed in PCB Editor, press **B** to refill all zones, rerun DRC,
and save before plotting.

Export the refilled copper layers as a quick release check:
the In1 and In4 Gerbers should contain filled regions, not only pads.

```sh
/Applications/KiCad/KiCad.app/Contents/MacOS/kicad-cli pcb export gerbers \
  --layers In1.Cu,In4.Cu --output hardware/kicad/gerbers \
  hardware/kicad/focalpoint_rev_a_release_final_pinoutfix_drcfix2.kicad_pcb
```

## Routing classes

The generator writes these KiCad project classes into
`focalpoint_production.kicad_pro`:

| Class | Track / clearance | Via | Nets |
| --- | --- | --- | --- |
| Default | 0.20 / 0.15 mm | 0.60 / 0.30 mm | ordinary signals |
| PWR_3V3_PLANE | 0.50 / 0.15 mm | 0.80 / 0.40 mm | +3V3 |
| PWR_HIGH_CURRENT | 1.00 / 0.15 mm | 1.00 / 0.50 mm | +BAT, VBUS, SYS, +5V, +5V_LED |
| USB2_FS_JLC06161H_90R_TARGET | 0.142 mm trace / 0.1524 mm pair gap | 0.60 / 0.30 mm | USB data segments |

The release project also permits 0.25/0.15, 0.35/0.15, and 0.45/0.25 mm
through-vias at the explicitly reviewed via-in-pad locations. At order time,
select **Epoxy Filled & Capped**. KiCad's stackup marks vias as filled and
capped. JLCPCB publishes via-in-pad as free for six-layer boards and a minimum
via hole/diameter of 0.15/0.25 mm; 0.15 mm drills and sub-0.45 mm lands may
still affect the quote.

### USB 90-ohm differential pair

JLCPCB's live calculator was queried directly on 2026-07-30 for coated outer-
layer differential microstrip on JLC06161H-3313: H1=3.9134 mil, Er=4.10,
T1=1.6 mil, soldermask C1/C2/C3=1.2/0.6/1.2 mil at Er=3.8, and S1=6 mil.
For a 90-ohm target it returned 90.0093 ohm with W1=5.5917 mil
(0.1420 mm) and etched top width W2=4.8917 mil. The KiCad target therefore
uses 0.142 mm width and 0.1524 mm edge gap.

The present USB full-speed route is length-matched to 0.54 mm on the long
post-ESD pair, but it changes layers and is not represented as a single outer-
layer controlled-impedance pair. The netclass records the correct outer-layer
target for a future pair reroute; Rev A relies on USB Full Speed's lower data
rate and must pass the prototype USB test before any production quantity.

#### USB impedance decision record — 2026-07-30

| Item | Recorded choice |
| --- | --- |
| Fabricator | JLCPCB |
| Stack-up | JLC06161H-3313, 6 layer, 1.6 mm order class, 1 oz outer / 0.5 oz inner copper |
| Structure | Outer-layer edge-coupled differential pair, referenced to continuous In1 GND |
| Electrical target | USB 2.0 90 ohm differential |
| KiCad target geometry | 0.142 mm (5.5917 mil) trace width; 0.1524 mm (6 mil) edge-to-edge pair gap |
| KiCad class | `USB2_FS_JLC06161H_90R_TARGET` |
| Source | JLCPCB live calculator API result, official JLC06161H-3313 template ID `caebedc9f5d84bb4b6eddd81268426df`, accessed 2026-07-30. |
| Release condition | Select JLC06161H-3313 and impedance control in the order. Prototype USB function remains a physical gate because Rev A's existing route changes layers. |

## Regeneration

After any approved PCB change, rerun ERC, schematic/PCB comparison, static
audit, and native DRC. Then regenerate the complete candidate package:

```sh
python3 hardware/kicad/build_release_candidate.py \
  --drc-report hardware/kicad/DRC_pinoutfix_drcfix2_native.rpt
```

The builder regenerates Gerbers, separate PTH/NPTH drill files, placement,
JLC BOM tables, hashes, and ZIP archives from the exact corrected PCB. It
refuses to label the evidence DRC-clean unless the supplied report explicitly
states zero violations. JLC's live component/rotation review and prototype
bring-up remain release gates.

Stack-up figures and dielectric constants come from JLCPCB's
[six-layer capabilities](https://jlcpcb.com/6-layer-pcb),
[manufacturing capabilities](https://jlcpcb.com/capabilities/pcb-capabilities/),
and live calculator template, accessed 2026-07-30. Reconfirm the named stack in
the order form before payment.

## Prototype-release boundary

The KiCad work can be completed to a routed, DRC-clean prototype package,
including Gerbers, drill data, BOM, placement data and assembly notes.  It
cannot by itself prove that a manufactured unit is electrically, thermally or
mechanically successful.  Before ordering, the order owner must select the
actual JLCPCB stack-up and record the calculator's USB differential-pair
geometry.  Before any larger build, two assembled units must pass
`hardware/BRINGUP_TEST_PLAN.md`, including the antenna-range check and the
closed-case charging/thermal safety gate.  These are physical validation steps,
not uncompleted CAD work.
