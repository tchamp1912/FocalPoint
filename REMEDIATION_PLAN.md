# Rev A remediation plan

Source: three-way design review (protocol/plan coherence, electrical/BOM,
mechanical/enclosure) of 2026-07-28. Items are grouped into work packages with
**disjoint file ownership** so they can be fixed in parallel. Severity is from
the review: blocker > major > minor > nit.

Status legend: `[ ]` todo · `[x]` fixed · `[H]` needs human/physical action —
cannot be closed by editing files (sampling, purchasing, lab work, or a
judgment call the owner must sign off).

Overall verdict from the review: the software half (daemon/adapters, PROTOCOL
§3–§5) is coherent and shipped. The hardware side re-baselined itself to a
13-key + capacitive-touch layout (matching the real Codex Micro) without
back-propagating to PLAN.md §3 or forward-propagating into PROTOCOL.md, and the
"frozen" BOM sits on top of a design with no schematic. **No parts or print
order until WP2/WP3 blockers close.**

---

## WP1 — Protocol and plan documents

Owns: `PROTOCOL.md`, `PLAN.md`, `hardware/CONTROL_MAPPING.md`,
`daemon/README.md`, `adapters/README.md`,
`firmware/keychron-v1-max/focalpoint.h` (comment text only).

1. `[x]` **BLOCKER — PROTOCOL.md covers neither the frozen hardware nor BLE.**
   *Fixed: new PROTOCOL.md §6 v0.3 DRAFT — control IDs 17/18 (`key_13`/
   `touch_01`), GET_CAPS/CAPS + PONG extension, mapping-profile messages,
   BLE transport (GATT layout w/ TBD UUIDs, MTU/fragmentation, link-loss,
   LESC pairing, USB-wins arbitration). Draft numbers need owner sign-off.*
   Draft a versioned **v0.3 (draft)** section that is purely additive over
   v0.2: control IDs for `key_13` and `touch_01`; a capability descriptor
   (extends `PONG`'s bare key count); dynamic mapping-profile messages per
   `CONTROL_MAPPING.md`; and a BLE transport section — GATT service/
   characteristic UUID scheme, MTU rule (fixed 32-byte reports vs 20-byte
   default ATT payload → negotiation/fragmentation), link-loss vs USB-suspend
   semantics for `SET_HOST_MODE`, pairing/bonding + authentication policy
   (this channel can synthesize keystrokes on the host — treat as a security
   surface), and USB/BLE simultaneous-connection arbitration. Mark the whole
   section DRAFT; do not alter v0.2 semantics the shipped daemon/firmware
   implement.
2. `[x]` **BLOCKER — PLAN.md §3 describes a product that no longer exists**
   (12 selector + 4 ceramic action keys, 16 switch positions). Rewrite to the
   frozen layout: 13 RGB MX keys (12 frosted selector + 1 ceramic) + encoder +
   analog joystick + capacitive touch = 16 logical inputs via dynamic mapping
   profiles (`hardware/CONTROL_MAPPING.md`). Delete the false rationale that
   "the protocol reserves controls 0–3 … so the physical product needs 16
   switch positions". Also fix §1 reference spec (real Codex Micro has a touch
   sensor) and §3's "4×3 grid" claim (the 12 selector keys sit in a 1+4+4+3
   scatter around the corner controls, per the CONTROL_MAPPING lattice —
   also fix CONTROL_MAPPING.md:8 which itself says "4×3").
3. `[x]` **MAJOR — Licensing split.** *(CERN-OHL-S v2 now written as decided —
   sign off explicitly.)* PLAN §6: firmware GPLv2 "required — QMK
   derivative" only holds for the Phase 0 Keychron keymap. State: QMK keymap
   GPLv2 (forced); Zephyr/nRF-Connect application Apache-2.0 (ecosystem norm;
   avoids the GPLv2-vs-Nordic-SoftDevice-Controller linking conflict).
   Decide hardware license now: **CERN-OHL-S v2** (the plan's own stated
   preference; files are already published).
4. `[x]` **MAJOR — Add a compliance/safety section to PLAN.md** *(added as new
   §7; later PLAN sections renumbered +1 — references below to PLAN §7/§10
   mean the pre-fix numbering)*: modular-cert
   strategy (pre-certified Raytac module; FCC 15B unintentional-radiator
   testing still applies to the finished device; aluminum case or integrated
   radio in Rev B forfeits the modular grant — record as a Rev B cost);
   user-supplied-battery policy as an explicit decision (sidesteps UN38.3/IATA
   shipping for kits; requires polarity/connector warnings in docs); kit
   safety-documentation plan (charging inside a closed case); BLE pairing
   threat model pointer to the v0.3 draft; note "FocalPoint" needs a trademark
   check before Phase 4.
5. `[x]` **MAJOR — PLAN §7 roadmap no longer describes reality** (Phase 2
   artifacts exist while Phase 1 exit criteria are open). Re-sequence honestly:
   acknowledge design-ahead-of-validation and name `hardware/BOM.md`'s release
   blockers as the true gate for spending money; keep coupons/cap-samples/
   transport-spec as the Phase 1 criteria that remain open.
6. `[x]` **MINOR — Version/state drift sweep** *(focalpoint.h fixed as comment
   only; bumping the PONG version constant is a separately-tracked firmware
   code change)*: daemon/README.md says
   "implements v0.1" yet documents `compacting` (v0.2); firmware
   `focalpoint.h` comment says v0.1; aggregate-order lists in daemon/README and
   adapters/README omit `compacting`; PROTOCOL.md §2 says "six styles" while
   §get-styles says seven. Align all to v0.2 (+ v0.3 draft where relevant).
7. `[x]` **MINOR — PLAN §10 open decisions**: mark closed — module (Raytac
   MDBT50Q-1MV2, superseding the "nice!nano-compatible replaceable module"
   rationale; record why), daemon language (Rust, shipped), stick (analog Alps,
   single footprint — "footprint both" is contradicted by the frozen BOM),
   name (FocalPoint). Keep open: wireless transport/pairing (→ item 1), cap/
   switch samples. Also PLAN §5/§7/§8 staleness: "Rust or Go", Adafruit
   MacroPad Phase 0 (actual rig: Keychron V1 Max), missing cursor/mac-virtual
   adapters, missing `app/`/`packaging/`/`install.sh` in repo layout.

## WP2 — Electrical BOM and procurement documents

Owns: `hardware/BOM.md`, `hardware/bom.csv`, `hardware/finalize_bom.py`,
`hardware/kicad/DECISIONS.md`.

1. `[x]` **BLOCKER — Demote "frozen" passives to provisional.** *Fixed: BOM.md
   opens "NOT order-ready"; passive lines carry `V1-V2 prov` pending schematic
   capture + ERC.* There is no
   schematic (`hardware/kicad/` has no `.kicad_sch`; the `.kicad_pro` is
   empty). Only ICs/mechanicals/long-lead parts keep frozen status; passive
   counts/designators become "provisional pending schematic capture + ERC".
   Update BOM.md status line — it must stop reading as order-ready.
   `[H]` The schematic capture itself is engineering work outside this plan.
2. `[x]` **BLOCKER — Verify the BQ24074 programming network against the
   datasheet.** *Resolved — the review's premise was WRONG: TI SLUS810N
   confirms the BQ24074 does have an ITERM pin (pin 15; TD/SYSOFF sit there on
   siblings). Network re-derived and confirmed correct (ITERM 2.94 kΩ ≈ 40 mA
   ≈ 10% ICHG; ILIM wording corrected to ~521 mA typ; resistor mode needs
   EN2=1/EN1=0). Full derivation now recorded in BOM.md; no downgrade.* The 2.94 kΩ "ITERM" resistor likely programs a pin that does
   not exist on this part (the BQ2407x family terminates at ~10% of ISET;
   the sibling pin is a digital function). Confirm from the TI datasheet
   (WebFetch), correct BOM.md:56 and bom.csv, and re-derive every constant in
   that network; downgrade the charger's validation level if the network was
   wrong. Verified-good for reference: ISET 2.21 kΩ ≈ 403 mA, ILIM 3.09 kΩ ≈
   502 mA, TPS61023 732k/100k ≈ 4.99 V.
3. `[x]` **MAJOR — Battery: one pack, one connector.** *Fixed: DECISIONS.md
   corrected to JST-SH; Hondark demoted out of the frozen table; polarity/
   silkscreen/1 A-contact warnings recorded. `[H]` pack measurement remains.* DECISIONS.md says
   JST-PH; BOM.md/bom.csv freeze JST-SH (`SM02B-SRSS-TB`). Fix DECISIONS.md to
   SH. Keep TinyCircuits ASR00012 as the single primary pack; the Hondark
   "803040" alternate cannot be 42×39×5.5 mm (nomenclature = 8.0×30×40 mm) —
   remove it or relabel "unverified alternate, dimensions/connector wrong as
   listed". Add: polarity must be verified against the actual pigtail (2-pin
   LiPo polarity is unstandardized), silkscreen polarity marking required, and
   note SH contacts are rated ~1 A — zero margin over the pack limit. `[H]`
   Physical pack measurement.
4. `[x]` **MAJOR — State the unthrottled LED worst case.** *Documented; recorded
   decision: Rev A accepts single-fault risk, evaluate TPS2553-class at
   schematic capture. `[H]` C5149201 datasheet/sample check remains.* BOM.md's 169/313 mA
   figures are the firmware-limited budget; all-white unthrottled is ~13×37 ≈
   480 mA @5 V ≈ 1 A from a 3.0 V cell — at the pack's protection limit, and
   TPS22918 is a load switch, not a current limiter. Document the worst case
   and add an explicit recorded decision: accept single-fault risk, or add a
   current-limited switch (TPS2553-class) at schematic time. Also flag that
   "SK6812MINI-E 12 mA variant" is not a verifiable orderable MPN — C5149201's
   datasheet must confirm per-channel current. `[H]` Datasheet/sample check.
5. `[x]` **MAJOR — Charger TS pin.** *Fixed-10k decision recorded with JEITA
   implications and mitigations (0.4 C, 6.2 h timer, closed-case test).* bom.csv buries a fixed 10 k on TS
   (defeats battery temperature sensing) while charging 400 mA in a sealed
   case. Record an explicit decision in BOM.md/DECISIONS.md: prefer a pack
   with integrated NTC brought to TS, else document the fixed-TS choice and
   its JEITA implications.
6. `[x]` **MAJOR — Joystick mounting technology.** *Confirmed worse than
   suspected: Alps page shows SMD lugs + an FPC signal tail not covered by any
   BOM interconnect. Moved to JLC SMT; FPC-connector-or-pads is a new open
   schematic item; THT RKJXV fallback recorded.* Alps RKJX2 series is SMT
   (THT is RKJXV) but bom.csv assigns it "User" assembly and ASSEMBLY.md
   forbids user-reflowed SMD sticks. Verify the Alps drawing; either move to
   JLC-side assembly or substitute a THT stick (RKJXV122400R-class). Update
   BOM.md:42 blockers accordingly.
7. `[x]` **MAJOR — LCSC coverage.** *Sunlord inductor equivalents selected with
   real C-codes (SWPA3015S1R5MT C83434, MWSA0402S-1R0MT C408332, marked
   provisional); ~10 more cells filled from verified listings; the rest marked
   `consign`. `[H]` live JLC matcher pass remains.* ~20 JLC-SMT lines have empty LCSC fields
   and both Coilcraft inductors are effectively never JLC-stocked. For each
   empty cell: fill a real LCSC code, or mark `consign` explicitly. Pre-select
   LCSC-stocked inductor equivalents (matching L/Isat/DCR from the TI
   datasheets) now, since inductor choice affects layout. `[H]` Live JLC
   matcher pass stays a release blocker.
8. `[x]` **MINOR — Record the matrix-vs-direct-GPIO decision.** *Full ~29-signal
   direct-GPIO map recorded in DECISIONS.md; direct preferred, diodes retained
   until schematic capture assigns real pins.* 13 direct
   GPIOs likely fit the MDBT50Q pin budget (~28 pins total need), removing 13
   diodes from a crowded bottom side and enabling any-key PORT wake. Add a
   decision entry with the full pin map to DECISIONS.md; do not rip the matrix
   out of the BOM unilaterally.
9. `[x]` **MINOR — finalize_bom.py** *(now cross-checks BOM.md's frozen table
   against bom.csv — negative-tested; passes: "Cross-checked 24 frozen-table
   rows")*: add a BOM.md-table-vs-csv consistency
   check (drift found: MDBT50Q LCSC `C5118826` in csv but "unconfirmed" in
   BOM.md; Hondark pack absent from csv); state in BOM.md that the designator
   freeze lives in the script (csv column is derived output).
10. `[x]` **NIT — Rev A gaps to add to BOM.md release blockers/notes**: no
    ship-mode/power switch decision; no test points or fiducials; no ESD on
    CC pins; no RC filter on joystick ADC lines; PCB retention strategy
    unspecified (see WP3-3); AHCT1G125 must be powered from the always-on
    boost output upstream of TPS22918 (record); TPS22918 arguably redundant
    given TPS61023 true-shutdown — record why it stays (QOD) or goes.

## WP3 — Enclosure, ergogen, and assembly

Owns: `case/freecad/enclosure.py`, `case/DESIGN.md`, `hardware/ASSEMBLY.md`,
`hardware/ergogen/config.yaml` (+ regenerated outputs if tooling available).

1. `[x]` **BLOCKER — Y-datum off by 1 mm.** *Fixed; enclosure.py now parses
   Edge.Cuts extents from the .kicad_pcb at runtime and asserts.* `enclosure.py` assumes Edge.Cuts
   y = −64..44; the generated board is y = −65..+43 (ergogen
   `shift: [10, -9]` makes the outline asymmetric). Set `KICAD_MIN_Y = -65.0`
   and add an assertion that parses the generated board/DXF instead of a
   hand-copied datum.
2. `[x]` **BLOCKER — Battery cannot fit.** *Fixed: 43×40 pocket sunk into the
   puck (floor z=−2), JST-SH cable bay, runtime assertions (cavity 8.64 mm ≥ 8,
   pack air gap 3.14 mm, puck web 3.20 mm). Also fixed a latent puck-through-
   floor interference found during the work.* Under-PCB clearance is ~2.7–4.8 mm
   vs a 5.5 mm pack; the reference box is the wrong size (50×32×9 vs required
   ≥42×39×8 + cable relief). Pocket the floor into the Ø86 puck (≈6 mm unused
   depth) and/or raise FRONT_H; model the real 42×39×5.5 pack with retention
   walls and JST-SH cable relief.
3. `[x]` **BLOCKER — Insert bosses pass through PCB corner material.** *Fixed:
   four Ø10.5 corner reliefs added in ergogen and regenerated into the KiCad
   board via the repo's refresh script (0.75 mm/side around Ø9 bosses).
   Decision recorded: switch-hung PCB — needs owner sign-off.* Bosses
   Ø9 at (12,12)/(102,12)/(12,102)/(102,102) intersect the board (10 mm corner
   fillet, arc center (13,13)). Add corner reliefs or mounting holes to
   `ergogen/config.yaml` (owns the outline) sized ≥Ø9.5 for the bosses, and
   decide boss-supported vs switch-hung PCB; regenerate the KiCad board if
   ergogen is available, else record that regeneration is required.
4. `[x]` **BLOCKER — Insert pilots undersized.** *Fixed: blind Ø4.0 × 5.5 mm.* `makeCylinder(1.7, …)` is a
   radius → Ø3.4; McMaster 94180A321 needs ~Ø4.0 × ≥4.5 mm deep. Fix, keep
   Ø9 boss OD. `[H]` Print coupons before ordering (Phase 1 criterion).
5. `[x]` **BLOCKER — No USB-C opening and no reset access.** *Fixed: open-top
   rear-wall USB notch (10.14 mm wide, closed by the plate) and Ø2.0 floor
   reset pinhole — both positions PROVISIONAL until KiCad placement.* Add a USB-C wall
   opening derived from GCT USB4105-GF-A-060 drawing dimensions (mark position
   provisional until KiCad edge placement exists) and a reset pinhole for the
   B3U-1000P. Without these the closed-case charge test is impossible.
6. `[x]` **MAJOR — Switch cutouts 14.6 mm kill MX clip retention**
   *Fixed: 14.05 mm cutouts, plate 1.6 → 1.5 mm (clip nominal).* (and plate
   1.6 mm exceeds the 1.5 mm clip nominal). Change key cutouts to 14.05 mm
   nominal for MJF PA12 (keep 0.3 mm clearance only for non-latching
   features); note plate-thickness decision. `[H]` Coupon print validates.
7. `[x]` **MAJOR — Rear-right boss (102,102) sits inside the antenna keep-out
   placeholder box.** Move/shorten that boss or shift the keep-out with a
   recorded note; metal fastener in keep-out fails BOM blocker 3 as drawn.
8. `[x]` **MAJOR — Touch coupling.** *Fixed: conductive-foam pillar provision
   with thinned plate web at the touch cell; decision recorded in DESIGN.md.* ~5 mm plate+air between the PCB electrode
   and finger; AT42QT1010 will not sense reliably through that. Add a modeled
   provision (spring/conductive-foam pillar cavity, or plate-bonded electrode
   with pogo/wire) or an explicit TODO geometry + decision note in DESIGN.md.
9. `[x]` **MAJOR — ASSEMBLY.md switch installation flexes an unsupported
   PCB** over the battery void, loading the bottom-side sockets. Re-order:
   seat switches into the plate and mate plate+switches onto the
   bench-supported PCB before fastening; or add support pillars (respecting
   the battery pocket). Also note the joystick SMT question (WP2-6) affects
   the "user installs joystick" step.
10. `[x]` **MAJOR — DESIGN.md has drifted from enclosure.py** *(table is now
    emitted by enclosure.py between markers — can no longer drift)* (111 vs 114 mm
    shell, corner radius 12 vs 6, plate 1.5 vs 1.6, rear height 20 vs 18.97).
    Code+BOM agree at 114×114 — regenerate DESIGN.md's table from the script's
    parameters (ideally emit it from the script).
11. `[x]` **MINOR — Grommet projection 0.39 mm vs DESIGN's 0.6–1.0 mm
    target.** *Fixed: recess 0.8 mm → 0.79 mm proud. BOM.md's projection note
    still needs the matching one-line edit (WP2 file).* Cut the recess to ~0.8 mm (or note 2 mm stock as alternative);
    keep BOM.md's stock selection unchanged (WP2 owns that file — flag if the
    projection note there needs a matching edit).
12. `[x]` **NIT** — `enclosure.py` print-orientation comment claims FDM
    "supports off" but the corners overhang ~35 mm; order is MJF anyway — fix
    the comment. Plate screw comment says "M3-class" for M2.5 hardware;
    consider Ø2.9 clearance holes.

## Not fixable by editing files (tracking only)

- Schematic capture + ERC, four-layer route + DRC, populated STEP interference
  review (BOM blockers 1–4). *Progress 2026-07-28: net-level design capture done
  in `hardware/kicad/SCHEMATIC.md`; **eeschema transcription complete**
  (`kicad/focalpoint.kicad_sch`, 104 parts / 77 nets, all-local symbols) and
  **ERC passes 0/0** (verified: netlist exports, no dangling nets). Capture-check
  gaps resolved/raised in `hardware/CAPTURE_GAP_RESOLUTIONS.md` (C26=IN bypass ✔,
  BQ EN strap ✔, joystick filter values ✔, FG_ALRT pull-up + R20 conflict new).
  Remaining: **independent human review** (blocker 1b), the pending BOM revision
  (drop D1–D13; add joystick/CC-ESD/FG_ALRT parts), then footprints + 4-layer
  route + DRC + STEP (blockers 2–4).*
- Physical sampling: caps (frosted diffusion, Cerakey mass/fit), switches,
  battery pack measurement, joystick sample, insert/cutout coupons.
  *Decision 2026-07-28: keycaps are NOT a gate — order multiple small-quantity
  sample sets after the fact; only the coupon prints and pack measurement
  remain gating.*
- JLC live-matcher pass over every MPN; JLC3DP order (only after WP3 closes).
- Two-unit bring-up test plan (BOM blocker 10). *Written 2026-07-28:
  `hardware/BRINGUP_TEST_PLAN.md` (rails → USB → SWD/charge/closed-case thermal
  safety gate → all 16 inputs → RGB → BLE → enclosure fit, dependency-ordered).
  Execution still needs two assembled units — remains `[H]`.*
- Trademark search for "FocalPoint". *Decision 2026-07-28: deferred — not
  gating anything until Phase 4 (community launch).*
