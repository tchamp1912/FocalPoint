# Rev A prototype assembly strategy

## Recommended split

Outsource the PCB fabrication and **all SMT assembly**. This includes the nRF52840
module, QFN charger, USB ESD device, regulator, RGB power circuit, SK6812 LEDs,
matrix diodes, passives, and hot-swap sockets. Request automated optical
inspection and X-ray inspection for exposed-pad/QFN parts where offered.

The owner is comfortable with through-hole soldering and wiring, but should not
need hot-plate, hot-air, or reflow work. The owner should only need to:

1. inspect and electrically test the assembled PCBA;
2. flash firmware through the Tag-Connect/debug pads (before the board goes
   into the enclosure, while the pads are reachable);
3. solder the through-hole encoder (and joystick, if the THT variant is
   chosen — see the sourcing note below);
4. seat all MX switches into the **plate** first, then mate the loaded
   plate+switches onto the PCB (switch-installation order below);
5. place the battery in its enclosure pocket, verify connector polarity, and
   connect it;
6. install keycaps, encoder knob, joystick cap, and close the enclosure; and
7. run the functional and charging test plan.

**Switch-installation order (do not press switches into a mounted board).**
The PCB is switch-hung: it has no boss support and spans the battery pocket
void (see `case/DESIGN.md`), so pressing switches into a PCB that is already
in the case flexes the board and loads the bottom-side hot-swap sockets —
the classic way to tear a socket's pads off. Instead: clip every switch into
the bare plate; support the PCB flat on the bench (component-free zones on
foam, never over the open case); align and press the plate+switch assembly
down so all pins enter their sockets together while the board is fully
backed; then drop the joined plate/PCB sandwich into the enclosure and drive
the four plate screws.

Leave the through-hole encoder and any through-hole joystick/header unpopulated
for local installation. JLCPCB must populate every SMD part, including hot-swap
sockets; do not substitute an SMD joystick that requires local reflow.

> **Joystick assembly:** Rev A uses the Alps `RKJXV122400R` through-hole
> joystick. Leave JS1 unpopulated at the assembler; insert it from the PCB top
> and hand-solder every electrical terminal and all four metal mounting lugs
> from the PCB bottom. Use at most 350°C for 3 seconds per joint, once, per
> Alps' published hand-soldering conditions. The earlier low-profile FPC-tail
> RKJX21224001 is not used in Rev A.

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
