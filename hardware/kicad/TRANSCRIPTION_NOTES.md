# Rev A schematic transcription notes

## Datasheet-controlled repair — 2026-07-29

The five findings from the first independent review have now been applied to
`focalpoint.kicad_sch`:

- U1 uses the real Raytac MDBT50Q-1MV2 module pad numbers for every connected
  GPIO, USB, SWD, reset, VDD, and GND signal. All chosen GPIOs were confirmed
  exposed in Raytac specification Ver. L. The assigned footprint is KiCad 10's
  `RF_Module:Raytac_MDBT50Q`, which contains all 61 pads and the vendor antenna
  geometry.
- U2 is now the real three-pad TPD2EUSB30 DRT shunt topology: pad 1 D+, pad 2
  D-, pad 3 GND. The fictional flow-through outputs and VBUS pin were removed.
- U3 is now the BQ24074 RGT physical pin map, including both BAT pads, both OUT
  pads, CE, and the exposed ground pad. CE and EN1 are grounded, EN2 is high,
  and C26 is connected from IN/VBUS to GND.
- D15, R23-R25, and C35-C36 were inserted and connected to the BOM-revision
  nets. The exported netlist confirms D15 on CC1/CC2, joystick RC filtering,
  and the dedicated FG_ALRT pull-up.
- Every on-board schematic instance has a non-empty footprint assignment.
  Off-board BT1 and ERC-only power flags are explicitly excluded from board
  placement.

KiCad 10.0.5 error-level ERC and netlist export both pass. Project-local
footprint links for the Kailh sockets and Alps joystick remain named
`FocalPoint:*`; the project library is registered in `fp-lib-table`. The exact
Kailh CPG151101S11 and Rev A Alps RKJXV122400R footprints now exist. The
RKJXV footprint is transcribed from official Drawing No. 1 (catalog update
2510) and includes every electrical hole, solder lug and locating boss. The
older RKJX21224001 entry remains mechanical-only and is not used for Rev A.
update. This is no longer an empty-assignment problem, but remains a physical
land-pattern release gate.

Mechanical transcription of `SCHEMATIC.md` (net-level spec) into KiCad 10
files. **Not a redesign** — every net/connection below is taken directly from
`SCHEMATIC.md`; where the spec left a node ambiguous or open, that ambiguity
is carried through and flagged, not resolved by invention.

## How this was built

- Generated programmatically (`gen.py`, not committed — a throwaway build
  script) rather than hand-drawn, because the design has ~104 discrete
  placements and ~330 pin-to-net assignments. The script encodes the net
  table from `SCHEMATIC.md` §1–8 directly (see its `NET`/`NC` maps) and emits
  KiCad 10 s-expression files. This is the only way I could keep the
  transcription verifiably 1:1 with the spec at this scale.
- **All symbols are local**, defined from scratch in `focalpoint.kicad_sym`
  (22 rectangular part types, correct pin numbers/names/electrical types per
  the datasheet function named in `SCHEMATIC.md`). No official KiCad library
  is referenced anywhere — not in the schematic, not in a `sym-lib-table`
  (intentionally not created; see below).
- Connectivity is by **global label**, not routed wire: every pin gets a
  short stub wire + a global label carrying the exact net name from
  `SCHEMATIC.md` (`+3V3`, `GND`, `KEY1`…`KEY13`, `JOY_X`, etc.). Same label
  text = same net, verbatim, no aliasing.
- Components are placed on a 50.8 mm grid (a multiple of KiCad's 1.27 mm
  connection grid, chosen after the first ERC pass flagged 426
  `endpoint_off_grid` warnings from an initial non-aligned 50 mm grid).

## ERC result

```
kicad-cli sch erc --output erc.rpt --severity-error --exit-code-violations focalpoint.kicad_sch
```

**0 errors, 0 warnings** (severity-error report, `erc.rpt`, committed).

A full `--severity-all` pass (not committed — outside the file-ownership
list for this task) additionally reports **104 warnings, all
`lib_symbol_issues`**: *"The current configuration does not include the
symbol library 'focalpoint'"*, one per placed instance. This is the direct,
expected consequence of Rule 1 (no `sym-lib-table` may be created) — KiCad
still fully resolves and ERCs every symbol because the schematic caches a
complete copy of each symbol definition in its own `lib_symbols` block (the
same mechanism KiCad itself uses for any schematic), it just can't cross-
reference an external, catalogued library table. **A human opening this in
the KiCad GUI should either add `focalpoint.kicad_sym` to their symbol
library table, or treat this warning as cosmetic** — it does not affect
netlist correctness (confirmed separately: `kicad-cli sch export netlist`
succeeds and produces a complete netlist with all 104 components).

Two non-obvious bugs fixed en route to 0 errors, noted here since they'd bite
anyone hand-generating KiCad 10 s-expressions:
1. A lib symbol's inner unit must be named `"<SymbolName>_1_1"`, **not**
   `"<LibNickname>:<SymbolName>_1_1"` — including the nickname on the
   sub-unit silently breaks the schematic loader (`Failed to load
   schematic`, no further diagnostic).
2. Symbol-library space is Y-up; sheet space is Y-down. At `(at x y 0)`
   placement (rotation 0, no mirror), a pin's local `(at px py angle)`
   maps to world `(x+px, y-py)` — the Y sign flips. Missing this produced
   328 `pin_not_connected` / `label_dangling` errors (labels landed at the
   coordinates I *thought* were the pins; the real pins were elsewhere).

## Judgment calls / places I filled a gap without a spec-given answer

- **7 → 3 PWR_FLAGs.** The task brief said to add a `PWR_FLAG` on all seven
  supply nets (GND, +3V3, +5V, +5V_LED, SYS, VBUS, +BAT). Doing that
  literally makes KiCad ERC error (`pin_to_pin`: two Power-output pins on
  one net), because +3V3, +5V, +5V_LED and SYS already have a natural
  `power_out` driver from the spec's own topology (U4 VOUT, U5 VOUT, U6
  VOUT, U3 SYS respectively). Kept flags only on GND, VBUS, +BAT — the three
  nets with no natural output-type driver — which satisfies the brief's
  actual goal (every `power_in` pin has a driver) without the conflict.
- **U9 FG_ALRT modeled as `passive`, not `open_collector`.** `SCHEMATIC.md`
  §4.1 explicitly says ALRT is open-drain and "uses SDA/SCL pull domain" —
  i.e. no dedicated pull-up resistor, and none is allocated in `bom.csv`.
  KiCad's ERC won't accept a lone `open_collector`+`input` net as "driven."
  Rather than invent a pull-up resistor (forbidden — frozen BOM), I typed
  the pin `passive`, which is honest to "no explicit external driver exists
  here per the spec" and clears ERC. **A human should verify against the
  MAX17048 datasheet whether Rev A actually needs a discrete ALRT pull-up**;
  if so, that's a real BOM gap to add to the pending revision, same bucket
  as the joystick SAADC filtering gap already flagged in `SCHEMATIC.md` §8.
- **R20/R21 node interpretation.** §8 of `SCHEMATIC.md` reconciles R20/R21 as
  "RGB input series / touch series" but doesn't spell out the exact two
  endpoints. I placed R20 in series between U1 P0.06 (net `RGB_DATA`) and
  U7 pin 2 IN (net `RGB_DATA_BUF`) — i.e. protecting the buffer's input —
  and R21 in series between U8 OUT (net `TOUCH_RAW`) and U1 P0.15 (net
  `TOUCH_OUT`, the verbatim spec name). This is the primary allocation in
  §8's table; the §8 aside that "R20 could serve one axis" of joystick
  filtering is a *secondary, explicitly unresolved* candidate use the spec
  itself doesn't commit to, so I didn't route R20 there.
- **HS1–HS13 carry the KEY/GND connection, not a separate SW1–SW13 symbol.**
  `bom.csv` marks SW1–SW13 (Kailh CPG151101D280) as user-assembled/
  removable — they clip into the HS1–HS13 hot-swap sockets and are not
  soldered to the board. Since HS*n* is what actually lands the KEY*n*/GND
  net on the PCB, I placed HS1–HS13 (2-pin, `KEYn` ↔ `GND`) as the schematic
  symbols and did not add a redundant SW1–SW13 symbol on the same two
  nodes. `SW1–SW13` designators from `bom.csv` are intentionally absent
  from the schematic for this reason — flagging in case a reviewer expects
  to see them.
- **SW14/SW15 and HS1–13 modeled as generic 2-pin switches**, not their
  real 4-pin footprints (Omron B3U-1000P / Kailh CPG151101S11). Per the
  task brief, appearance/pin-count fidelity doesn't matter for ERC/netlist
  purposes — only the electrical nodes matter, and each of these parts has
  exactly two independent electrical nodes in this design. **A human must
  reconcile the 2-pin symbol against the real 4-pin footprint's pin-pairing
  before layout** (which physical pins are internally bridged).
- **U1 module physical pins are no longer deferred.** Every connected GPIO,
  all five GND pads, VDD, VBUS, USB, SWD, and reset are numbered from Raytac
  MDBT50Q specification Ver. L. Routing-required remaps are recorded in
  `SCHEMATIC.md` and `DECISIONS.md`.
- **U2 TPD2EUSB30 corrected to the 3-pin DRT shunt array:** pin 1 USB D+,
  pin 2 USB D−, pin 3 GND. The obsolete fictional flow-through/VBUS model
  has been removed from the schematic and documentation.

## Carried-through open items (from `SCHEMATIC.md`, not resolved here)

- **C26 (BQ24074 1 µF)** is resolved and captured from VBUS to GND as the IN
  bypass required by SLUS810N.
- **Joystick (JS1) SAADC filtering** is captured as R23/R24 (1 kΩ series)
  and C35/C36 (10 nF shunt), one RC per axis.
- **Retired joystick FPC option**: JS1 is a single 5-pin logical symbol
  (VCC, GND, X, Y, SW). The RKJXV122400R footprint maps its duplicate physical
  pot and switch terminals onto those five logical pads. The old FPC connector
  vs. hand-solder pad vs. THT fallback part is a footprint/BOM decision, out
  of scope for net-level capture.
- **D1–D13 (matrix diodes): omitted, as directed.** They are also removed
  from `bom.csv`; KEY1–KEY13 connect directly from each HS*n* socket to U1
  P1.00–P1.12.
- **SW15 (DFU/user button)**: assigned P0.13 (net `DFU`) as the spec
  suggested ("assign to a free pin, e.g. P0.13, at capture") — this was the
  one input `SCHEMATIC.md` explicitly left to schematic capture.
- **C22 (the 22nd 100 nF cap): intentionally not placed.**
  `SCHEMATIC.md` §8 states the 100 nF pool covers "13 LED + 8 IC bypass
  (U1,U3,U4,U5,U6,U7,U8,U9) = 21; 1 spare." I placed C1–C13 as LED-local
  bypass and C14–C21 as the 8 IC-bypass caps (one per named IC, at its
  primary supply pin — SYS for U3/U4/U5 since none of those has a single
  "VDD" pin, +5V for U6/U7, +3V3 for U1/U8, +BAT for U9 matching its cell-
  sensing VDD). C22 is the documented spare; not wired into any net.
- **R3/R4 (USB D± series, DNP by default)**: placed and wired in series
  (connector → R3/R4 → U2 TPD2EUSB30), per the explicit ERC-section
  instruction that DNP parts are "still placed." DNP is a BOM/assembly
  attribute, not a schematic-capture omission.

## Current human-review gates

The historical placeholder issues above have been resolved in the checked-in
schematic and corrected PCB. Human review now focuses on:

1. Native KiCad DRC on
   `focalpoint_rev_a_release_final_pinoutfix_drcfix2.kicad_pcb`.
2. JLC BOM/placement upload review, including every MPN, side, and rotation.
3. Antenna keepout, USB-C edge alignment, LED/socket orientation, joystick and
   encoder clearances, and the complete enclosure/PCB fit.
4. Correct JST-SH battery polarity on the purchased pack before connection.
5. Bring-up testing of both prototypes before any production quantity.
