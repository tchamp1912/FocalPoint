# Rev A schematic transcription notes

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
- **U1 module: 36 sequential pins, GPIO net names as pin names, no real
  Raytac pin numbers** — exactly as the task brief specified ("physical
  module pin numbers deferred... connect by GPIO net name").
- **U2 TPD2EUSB30 modeled with 6 pins** (GND, IO1/IO2 connector-side,
  OUT1/OUT2 protected-side, VBUS) representing it as the "flow-through ESD
  array" `SCHEMATIC.md` describes. I did not have exact datasheet pin
  numbers on hand; numbering is sequential 1–6, not the real SOT-23-6
  pinout. **A human must map this to the real TPD2EUSB30 pinout at
  footprint assignment.**

## Carried-through open items (from `SCHEMATIC.md`, not resolved here)

- **C26 (BQ24074 1 µF)**: placed on a pin I named `VDPM` (U3 pin 14), tied
  to GND — matching the spec's *tentative* placement. `SCHEMATIC.md` itself
  flags this net as the one unconfirmed node pending an SLUS810N pin check.
  Still unconfirmed; not resolved by this transcription.
- **Joystick (JS1) SAADC filtering**: not placed. `SCHEMATIC.md` §5 and §8
  are explicit that series-R + filter-cap per axis is a gap not yet in
  `bom.csv`; I did not invent passives for it. JS1's X/Y wipers go straight
  to U1 P0.02/P0.03 (nets `JOY_X`/`JOY_Y`) with no series/filter component,
  same as the spec.
- **Joystick FPC tail / interconnect**: not modeled. JS1 is a single 5-pin
  symbol (VCC, GND, X, Y, SW); the spec's open item about an FPC connector
  vs. hand-solder pad vs. THT fallback part is a footprint/BOM decision, out
  of scope for net-level capture.
- **D1–D13 (matrix diodes): omitted, as directed.** `bom.csv` still lists
  them (pending BOM revision — not edited here per instructions), but the
  schematic reflects the confirmed direct-scan design: KEY1–KEY13 go
  straight from each HS*n* socket to U1 P1.00–P1.12, no diodes, matching
  `SCHEMATIC.md` §3's "Pending BOM revision" note.
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

## What a human reviewer must check before this goes further

1. **Footprint assignment for all 104 placed symbols** — none have a
   footprint yet (this task was net-level capture only); the `Footprint`
   property is present but empty on every symbol.
2. **U1 module physical pin numbers** — sequential 1–36 here; must be
   remapped to the real Raytac MDBT50Q-1MV2 pin table, and every assigned
   GPIO must be confirmed as actually broken out on that module variant
   (`SCHEMATIC.md` §3 flags this directly).
3. **U2 TPD2EUSB30 real pinout** vs. the placeholder 6-pin sequential
   numbering here.
4. **C26 net** (BQ24074 pin 14, "VDPM") against SLUS810N — still
   unconfirmed, carried through as-is.
5. **FG_ALRT pull** — confirm whether MAX17048 ALRT needs a discrete
   external pull-up for Rev A; I modeled the pin `passive` (no driver
   claimed) rather than inventing a resistor.
6. **HS vs. SW1–13 decision above** — confirm the "HS carries the net,
   SW is mechanically-only" reading of `bom.csv`/`SCHEMATIC.md` §5 is what
   was intended; add SW1–13 as separate schematic symbols if not.
7. **Joystick SAADC filtering and FPC interconnect** — both explicitly
   unresolved gaps per `SCHEMATIC.md` §8, not addressed here.
8. **Add `focalpoint.kicad_sym` to a symbol library table** (project- or
   global-level) before opening this in the KiCad GUI, to clear the 104
   cosmetic `lib_symbol_issues` ERC warnings — not required for ERC/netlist
   correctness, but needed for normal symbol-editor workflows (edit pin,
   re-annotate, etc.) going forward.
9. **DRC / PCB sync** has not been attempted — this deliverable is schematic
   + ERC only, per the task scope.
