# Schematic-capture open-gap resolutions (Rev A)

Resolves the "Additional Rev A gaps that must close at schematic capture"
(`BOM.md`) and the `⚠` capture-checks in `kicad/SCHEMATIC.md`, so the schematic
revision and the independent human review (blocker 1) have concrete answers
instead of open questions.

Written 2026-07-28 while the eeschema transcription runs. **These fold into
`kicad/DECISIONS.md` and the pending BOM revision once `kicad/` is free — kept
standalone here to avoid colliding with the running transcription.** Datasheet-
verified items are marked ✔ VERIFIED; engineering-judgment items that still need
owner sign-off are marked ⚠ SIGN-OFF.

---

## 1. BQ24074 EN1/EN2 strap — ✔ VERIFIED (SLUS810N Table 7-2)
`(EN2, EN1)` truth table, quoted:

| EN2 | EN1 | Max input current into IN |
|---|---|---|
| 0 | 0 | 100 mA (USB100) |
| 0 | 1 | 500 mA (USB500) |
| **1** | **0** | **Set by external resistor from ILIM to VSS** |
| 1 | 1 | Standby (USB-suspend) |

So **EN2 = 1, EN1 = 0** is correct for the resistor-programmed input limit
(R6 3.09 kΩ on ILIM). EN1/EN2 have internal ≈285 kΩ pulldowns and the datasheet
says *do not leave unconnected*. **Wiring:** EN1 → GND (hard). EN2 → logic high.
Recommend EN2 to an nRF52840 GPIO (default-high via pull-up) rather than hard
+3V3, so firmware can drop to USB100 / suspend if a source can't supply 500 mA;
hard +3V3 is acceptable if a GPIO is scarce. Document the strap on the sheet.

## 2. C26 (1 µF) node — ✔ VERIFIED (was the only "unconfirmed" node)
C26 is the **IN-pin bypass**: datasheet IN pin — "Connect bypass capacitor 1 µF
to 10 µF to VSS." So **C26: IN ↔ GND**. Also confirmed in range: C24 (BAT) and
C25 (SYS/OUT) at 4.7 µF each sit inside the datasheet's 4.7–47 µF window.

## 3. SK6812MINI-E per-channel current — ✔ (figure) / `[H]` (full table)
LCSC C5149201 listing + datasheet header: **5 V @ 12 mA**, with the maker's note
to use **~70 % grayscale when driving tri-color (RGB)**. The 12 mA figure is
confirmed; the per-channel R/G/B breakdown table is image-locked in the PDF and
should be eyeballed by a human. Consequence: the ~13 × 37 ≈ **480 mA all-white**
worst case is a *datasheet-discouraged* condition (the 70 % note), which
reinforces the existing decision — firmware default-off + 156 mA aggregate cap
(`DECISIONS.md`, LED single-fault entry). No change to that decision.

## 4. Joystick SAADC RC filter — ✔ VALUES (was flagged missing in bom.csv)
nRF52840 SAADC max source resistance vs acquisition time (product spec):
3 µs→10 kΩ, 5 µs→40 kΩ, 10 µs→100 kΩ, 15 µs→200 kΩ, 20 µs→400 kΩ, 40 µs→800 kΩ.
Joystick element ≈10 kΩ; wiper source resistance varies with position.

**Per axis:** series **R = 1 kΩ** (JOY_X/JOY_Y → SAADC) + shunt **C = 10 nF** to
GND at the pin → f_c = 1/(2π·1k·10n) ≈ **15.9 kHz** anti-alias/debounce, and the
cap is a charge reservoir for the SAADC sampling capacitor. Worst-case source
(10 kΩ pot + 1 kΩ series ≈ 11 kΩ) → set **acquisition time ≥ 10 µs** (100 kΩ
margin); oversample in firmware for extra noise rejection.

**BOM revision adds:** R20 (existing 1 kΩ) → JOY_X series; **+1× 1 kΩ** for
JOY_Y; **+2× 10 nF** shunt caps. (Fold into the same revision that drops D1–D13.)

## 5. USB CC-pin ESD — ⚠ RECOMMEND (BOM add)
U2 TPD2EUSB30 protects D± only; CC1/CC2 are exposed at J1. Add **low-capacitance
ESD on CC1/CC2** — ≤3 pF so it does not disturb the 5.1 kΩ Rd sink detection
(R1/R2). Two options:
- Minimal: 2× single-line low-cap TVS (PESD5V0-class) CC1/CC2 → GND.
- **Preferred:** swap to a combined USB-C ESD array covering CC + D± (e.g. TI
  TPD6E004 / TPD4E05U06, Nexperia IP4234) — fewer parts, one footprint.
SBU1/SBU2 stay no-connect (no protection needed unless later exposed). New line
in the BOM revision.

## 6. Test points — ✔ SPEC (copper only, no BOM cost)
Add 1 mm test pads: **rails** SYS, +3V3, +5V, +5V_LED, +BAT; **GND** ×2;
**signals** RGB_DATA, FG_SDA, FG_SCL, nRESET, CHG_STAT, PGOOD, JOY_X, JOY_Y.
SWDIO/SWDCLK already reachable at J3. Directly supports `BRINGUP_TEST_PLAN.md`
§2/§5.

## 7. Fiducials — ✔ SPEC (copper/mask only, no BOM parts)
Per JLC SMT: **3 global fiducials**, 1 mm copper / 2 mm solder-mask opening,
placed in an **asymmetric** pattern (not rotationally symmetric) near three
corners of the primary component side. Optional **local fiducials** on the
MDBT50Q module and the BQ24074 QFN for fine-pitch placement.

## 8. Ship-mode / power switch — ⚠ SIGN-OFF (recommend: no switch)
Recommend **no mechanical power switch** for Rev A (sealed case, no good
location). "Off" = nRF52840 **System OFF** (~1.5 µA) with **wake-on-any-key**
(direct-scan PORT event, already the wake design). Always-on cell drains:
MAX17048 (~23 µA active / ~3 µA hibernate — **firmware must hibernate it**),
BQ24074 battery-side quiescent. Total ≈5–30 µA → a 1000 mAh cell lasts well over
a year. Rev A ships with the **battery user-installed** (disconnected in
transit), which also sidesteps deep-discharge and the UN38.3/IATA path already
chosen. Firmware: a key-combo enters ship mode (System OFF + MAX17048 hibernate).
Revisit a true hardware disconnect (load switch / ship-mode-capable charger) only
if measured standby is too high. **Owner: confirm no-switch is acceptable.**

## 9. PCB retention: boss-supported vs switch-hung — ⚠ SIGN-OFF (recommend hybrid)
Pure switch-hung is risky here: the joystick and encoder take side/insertion
loads, and the PCB spans the battery void, so switch-install and actuation flex
the bottom-side hot-swap sockets (see `ASSEMBLY.md` re-order, WP3-9). **Recommend
a hybrid:** switch-hung primary + **2 support standoffs** at board edges, sited
**clear of the battery pocket and the module antenna keep-out**. Interacts with
the enclosure (bosses must not intrude on pocket/keep-out; the rear-right boss
was already moved out of the keep-out, WP3-7) and with `ergogen/config.yaml`
(outline owner). **Owner: pick switch-hung vs hybrid — it changes the outline and
enclosure.**

## 10. USB R3/R4 22 Ω series on D± — ✔ DECISION
nRF52840 USB is **Full-Speed (12 Mbps)**; series D± resistors are a High-Speed /
impedance-tuning practice not needed at FS. **Keep the footprints; populate 0 Ω**
(or strap) rather than 22 Ω. Confirm against the Raytac MDBT50Q USB reference
schematic at footprint capture. (SCHEMATIC.md currently lists R3/R4 22 Ω DNP —
change to 0 Ω populated in the revision.)

---

## 11. FG_ALRT pull-up — ⚠ RECOMMEND (new gap, found during transcription)
The ERC-clean capture modeled U9 MAX17048 `FG_ALRT` as a `passive` pin because
`SCHEMATIC.md` §4.1 claimed it "uses SDA/SCL pull domain" and allocated no
pull-up. That reasoning is wrong: ALRT is a **separate open-drain line** — the
SDA/SCL pull-ups (R18/R19) do not pull it. Rev A therefore needs **either** a
dedicated pull-up on FG_ALRT (≈100 kΩ to +3V3 — interrupt line, no speed
requirement) **or** a firmware decision to poll SOC over I²C and leave ALRT
unused/unconnected. Recommend the 100 kΩ pull-up (keeps the low-battery
interrupt usable). **New BOM-revision line if the pull-up is chosen.**

## 12. R20 double-allocation — reconcile in the BOM revision
The transcription used **R20 (1 kΩ) as the RGB_DATA buffer-input series
resistor** (U1 P0.06 → R20 → U7 IN), which is a defensible reading of
`SCHEMATIC.md` §8 ("R20 RGB input series"). But §4 gap and this memo's §4 also
eyed R20 for the **JOY_X SAADC filter**. It can't be both. The joystick filter
therefore needs **2× new 1 kΩ** (both axes), not the 1× assumed in §4 above —
*unless* the RGB input series R is dropped (RGB_DATA straight to U7 IN, common
and acceptable), freeing R20 for JOY_X. Owner/reviewer picks; the BOM math below
assumes RGB keeps its series R (so +2× 1 kΩ for the joystick).

## Net effect on the pending BOM revision
Folds together with the D1–D13 removal into **one** reviewed BOM change:
- **Remove:** D1–D13 (matrix diodes, direct-scan confirmed).
- **Add:** 2× 1 kΩ (JOY_X + JOY_Y series — see §12), 2× 10 nF (joystick shunt),
  USB-C CC ESD (2× low-cap TVS *or* 1× combined array — §5), and 1× 100 kΩ
  (FG_ALRT pull-up — §11, if the interrupt is kept).
- **Change:** R3/R4 22 Ω → 0 Ω populated; correct C26 to the **IN-pin bypass**
  node (✔ verified §2 — the transcription's tentative "VDPM pin 14" placement is
  a local-symbol artifact to fix at footprint reconciliation).
- **No BOM parts, layout only:** test points (§6), fiducials (§7).
- Re-run `finalize_bom.py` after applying.

## Still open (not resolvable from a datasheet)
- §8 ship-mode and §9 retention need **owner sign-off**.
- SK6812 full per-channel table — human eyeball of the image-based PDF (§3).
- Joystick FPC-tail interconnect (connector vs solder pads vs THT RKJXV
  fallback) — mechanical/footprint decision, tracked in `BOM.md` blocker 6.
