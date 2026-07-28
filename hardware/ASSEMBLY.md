# Rev A prototype assembly strategy

## Recommended split

Outsource the PCB fabrication and **all SMT assembly**. This includes the nRF52840
module, QFN charger, USB ESD device, regulator, RGB power circuit, SK6812 LEDs,
matrix diodes, passives, and hot-swap sockets. Request automated optical
inspection and X-ray inspection for exposed-pad/QFN parts where offered.

The owner is comfortable with through-hole soldering and wiring, but should not
need hot-plate, hot-air, or reflow work. The owner should only need to:

1. inspect and electrically test the assembled PCBA;
2. connect the protected battery after verifying connector polarity;
3. install the MX switches, keycaps, encoder knob, joystick cap, and enclosure;
4. flash firmware through the Tag-Connect/debug pads; and
5. run the functional and charging test plan.

Leave the through-hole encoder and any through-hole joystick/header unpopulated
for local installation. JLCPCB must populate every SMD part, including hot-swap
sockets; do not substitute an SMD joystick that requires local reflow.

## Supplier path

- First quote: JLCPCB standard PCBA, because it supports SMT, manually placed
  parts, through-hole/wave soldering, and customer-consigned components.
- Comparison quote: PCBWay turnkey assembly, particularly if the joystick or
  radio-module sourcing is awkward.
- US-support comparison: MacroFab. It accepts KiCad/Gerber/BOM inputs and has no
  minimum quantity, but is normally the premium-cost option for a tiny run.

## Planning cost—not a manufacturing quote

For five fully assembled Rev A boards, reserve approximately:

- **$150–300 landed** when the design can use the assembler's stocked parts;
- **$250–500 landed** if several components must be globally sourced,
  consigned, or manually installed;
- **$500–1,500** for a low-volume US-managed service.

The board's component cost, extended-part feeder charges, shipping, tax,
inspection, and rework dominate more than placement labor. Generate Gerbers,
BOM, and centroid files and upload them to at least two assemblers for a real
quote before buying inventory.

## Skills worth learning anyway

Basic through-hole soldering, connector inspection, continuity testing, and
safe LiPo handling remain useful for debug and repair. Practise on an inexpensive
kit; do not make the custom nRF/QFN power board your first reflow exercise.
