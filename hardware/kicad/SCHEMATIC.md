# Rev A schematic capture — connectivity specification

Status: **design capture + eeschema transcription complete; ERC passes 0/0
(errors and warnings, `focalpoint.kicad_sch`); independent human review + DRC
still required** (release blocker 1, `BOM.md`). Transcription judgment calls and
the items a reviewer must check are in `TRANSCRIPTION_NOTES.md`; the resolved
capture-checks and new gaps (C26=IN bypass, FG_ALRT pull-up, R20 conflict,
joystick filter values) are in `../CAPTURE_GAP_RESOLUTIONS.md`.

This document is the electrical source of truth for the Rev A schematic: every
net and every pin-to-pin connection, grounded in the frozen `bom.csv`
designators and the recorded decisions in `DECISIONS.md`. It exists so the
eeschema drawing is transcription rather than design, and so the design can be
reviewed by a person before any symbol is placed. It does **not** replace ERC —
it is the input to it.

Why a spec and not a `.kicad_sch` yet: hand/script-authored KiCad schematic
files whose wires must land exactly on pins are error-prone and expensive to
get ERC-clean, and blocker 1 requires human review in eeschema regardless. The
engineering (topology, pin assignment, support networks) is here; drawing it is
the mechanical step that follows.

Reference designators below are exactly those frozen in `bom.csv` (verified by
`finalize_bom.py`). Where this capture implies a BOM change, it is called out as
a **pending BOM revision** — the BOM is not edited here.

---

## 1. Power tree

```
USB-C VBUS ──[D14 TVS]──┬─────────────────────────► U3 BQ24074 IN
                        │
                      (5V1 domain, transient-clamped)

U3 BQ24074:  IN ─► [power path] ─► SYS ──┬─► U4 TPS63031 ──► +3V3 (always-on)
                                          ├─► U5 TPS61023 ──► +5V (RGB boost)
             BAT ◄────────────────────────┴─ J2 ─ BT1 (LiPo, JST-SH)

+5V ──► U7 AHCT VCC (always-on, upstream of switch)
+5V ──► U6 TPS22918 IN ──(gated)──► +5V_LED ─► LED1..LED13 VDD
```

- **+3V3** is always-on: powers U1 (MDBT50Q), U8 (touch), U9 (fuel gauge), all
  logic pull-ups, and the SWD header. Buck-boost (U4 TPS63031, fixed-3.3 V DSKT
  variant — **no external FB divider**) holds 3.3 V across the full 3.0–4.2 V
  cell range.
- **+5V** (U5 TPS61023 boost) is kept always-on while the system is awake so
  U7's VCC never collapses under a driven input (AHCT has no partial-power-down
  guarantee — `DECISIONS.md`). The **LED chain** alone is gated by U6
  (TPS22918, default-off), producing **+5V_LED**.
- **SYS** is the BQ24074 power-path output (load-sharing: runs from USB when
  present, from BAT otherwise).

### Net: +3V3 loads and decoupling
| Consumer | Pin | Bypass (from C1–C22 100 nF set) | Bulk |
|---|---|---|---|
| U1 MDBT50Q VDD | module VDD | 1× 100 nF at pin | C23 4.7 µF |
| U8 AT42QT1010 VDD | pin 1 | 1× 100 nF | — |
| U9 MAX17048 (VDD = cell, see §4) | — | 1× 100 nF | — |
| U4 TPS63031 output | VOUT | (see §1.2) | C27–C29 10 µF |

### 1.1 U3 BQ24074 (charger / power-path) — designator U3, C54313
| Pin (function) | Net / part |
|---|---|
| IN | VBUS (post-D14) |
| SYS | SYS rail; **C25** 4.7 µF to GND |
| BAT | J2.1 (LiPo +), **C24** 4.7 µF to GND |
| ISET | **R5** 2.21 kΩ to GND → 403 mA fast charge |
| ILIM | **R6** 3.09 kΩ to GND → ~521 mA input limit (needs EN2=1/EN1=0) |
| ITERM | **R7** 2.94 kΩ to GND → ~40 mA (10 %) termination (pin 15, BQ24074 only) |
| TMR | **R8** 46.4 kΩ to GND → ~6.2 h safety timer |
| TS | **R14** 10 kΩ to GND (JEITA disabled — fixed-TS decision, `DECISIONS.md`) |
| /CHG | open-drain → U1 `CHG_STAT` (P0.12), pull-up **R15** 10 kΩ to +3V3 |
| /PGOOD | open-drain → U1 `PGOOD` (P0.14), pull-up **R16** 10 kΩ to +3V3 |
| EN1, EN2 | strap EN2=1/EN1=0 for resistor-programmed ILIM (verify against SLUS810N Table; document strap) |
| VSS/thermal pad | GND (thermal vias — QFN thermal test, blocker 10) |
| VDPM / decouple | **C26** 1 µF (confirm exact pin vs datasheet) |

⚠ **Capture check:** confirm EN1/EN2 strap levels and the C26 net against
SLUS810N — the 1 µF placement is the one node this spec marks *unconfirmed*.

### 1.2 U4 TPS63031 (3.3 V buck-boost) — U4, C15516 (DSKT fixed 3.3 V)
| Pin | Net |
|---|---|
| VINA / VIN | SYS |
| L1, L2 | **L1** Sunlord SWPA3015 1.5 µH |
| VOUT | +3V3; **C27–C29** 10 µF (input + output split per datasheet) |
| FB | tied per fixed-output DSKT rule (no divider) |
| EN | +3V3 (always-on) or U1 GPIO if soft-start desired — **default tie high** |
| PS/SYNC | GND (power-save enabled) or per datasheet |
| GND / PGND | GND |

### 1.3 U5 TPS61023 (5 V boost) — U5, C919459
| Pin | Net |
|---|---|
| VIN | SYS; **C30** 10 µF |
| SW | **L2** Sunlord MWSA0402 1.0 µH |
| VOUT | +5V; **C31–C32** 22 µF (⚠ MPN obsolete — substitute at capture) |
| FB | divider node: **R9** 732 kΩ (top, to VOUT) / **R10** 100 kΩ (bottom, to GND) → 0.6 V×(1+732/100) ≈ 4.99 V |
| EN | U1 `BOOST_EN` (P0.11), pull-down **R11** 100 kΩ |
| GND | GND |

### 1.4 U6 TPS22918 (LED load switch) — U6, C131941
| Pin | Net |
|---|---|
| VIN | +5V |
| VOUT | +5V_LED → LED1 VDD |
| ON | U1 `RGB_PWR_EN` (P0.08), pull-down **R12** 100 kΩ (default off) |
| QOD | to VOUT or per datasheet (quick-output-discharge for clean LED reset) |
| CT | **C33** 220 pF to GND (slew-rate) |
| GND | GND |

---

## 2. USB (data + VBUS)

- USB-C **J1** (GCT USB4105, 16-pin):
  - VBUS (both) → net VBUS → **D14** PESD5V0S1UL TVS to GND → U3 IN.
  - CC1 → **R1** 5.1 kΩ to GND; CC2 → **R2** 5.1 kΩ to GND (UFP/sink).
  - D+ pair tied, D− pair tied → **R3/R4** 22 Ω series (DNP by default) →
    **U2 TPD2EUSB30** ESD → U1 MDBT50Q USB `D+`/`D−` (dedicated module pins).
  - SBU1/SBU2 → no-connect.
  - Shield → chassis/GND per EMC (single-point).
- **U2 TPD2EUSB30** (C97502 — never substitute C3011197): I/O on the connector
  side, protected I/O to the MCU side, VCC/GND per datasheet (it is a flow-through
  ESD array).

⚠ **Capture check:** R3/R4 22 Ω are DNP placeholders pending the Raytac USB
review — populate only if signal integrity requires.

---

## 3. MCU / radio — U1 MDBT50Q-1MV2

GPIO assignment (nRF52840 net names; **physical module pin numbers assigned from
the Raytac MDBT50Q-1MV2 pin table at footprint capture**). Constraints honored:
the two analog joystick axes on SAADC AIN pins; NFC pins P0.09/P0.10 avoided;
P0.18 reserved as nRESET; P0.00/P0.01 left free for an optional 32.768 kHz LFXO.

| Signal | nRF52840 GPIO | Notes |
|---|---|---|
| KEY1…KEY13 | **P1.00…P1.12** | direct scan, input pull-up, sense-on-low → any-key PORT wake |
| JOY_X | **P0.02 (AIN0)** | analog to SAADC |
| JOY_Y | **P0.03 (AIN1)** | analog to SAADC |
| JOY_SW | **P0.16** | digital, pull-up |
| ENC_A | **P0.17** | pull-up |
| ENC_B | **P0.19** | pull-up |
| ENC_SW | **P0.20** | pull-up |
| TOUCH_OUT | **P0.15** | from U8 OUT (active per QT1010) |
| RGB_DATA | **P0.06** | → U7 buffer input (3V3 logic) |
| RGB_PWR_EN | **P0.08** | → U6 ON |
| BOOST_EN | **P0.11** | → U5 EN |
| CHG_STAT | **P0.12** | ← U3 /CHG (open-drain, pulled up) |
| PGOOD | **P0.14** | ← U3 /PGOOD (open-drain, pulled up) |
| FG_SDA | **P0.26** | I²C to U9 |
| FG_SCL | **P0.27** | I²C to U9 |
| FG_ALRT | **P0.07** | ← U9 /ALRT (open-drain) |
| USB D+/D− | dedicated | to U2 |
| SWDIO/SWDCLK | dedicated | to J3 |
| nRESET | **P0.18** | to J3 + **SW14**, pull-up **R17** 10 kΩ |

Signal count: 28 (13 keys + 2 analog + 13 control/sense/comms) — well within the
module's ~48 exposed GPIO. **Confirm each assigned pin is broken out on the
MDBT50Q-1MV2** (a few nRF pins are not, depending on module variant); reshuffle
within the same constraint classes if any is absent.

- U1 supply: VDD → +3V3 with 100 nF at pin + **C23** 4.7 µF bulk. VSS/pad → GND.
- DEC/DCC pins (internal regulator decoupling) and the RF/antenna are handled
  inside the certified module — **module antenna keep-out** governs placement
  (blocker 3).

### Pending BOM revision — direct scan confirms; drop the matrix
The direct-scan pin budget fits (28 ≤ 48), so the matrix is not needed
(`DECISIONS.md` set this as the trigger). **Pending BOM action:** remove
**D1–D13** (1N4148W, 26-qty line) and the 4×4 matrix wiring; revalidate
`bom.csv`/`finalize_bom.py` and the presentation deck as one reviewed change.
Not done in this document to keep the BOM edit deliberate. Net effect: 13 fewer
bottom-side parts, simpler wake.

---

## 4. Sensing

### 4.1 U9 MAX17048 (fuel gauge) — U9, C2682616
| Pin | Net |
|---|---|
| CELL / VDD | J2.1 (LiPo +) — measures cell directly; 100 nF bypass |
| GND | GND |
| SDA | FG_SDA (P0.26); pull-up **R18** 4.7 kΩ to +3V3 |
| SCL | FG_SCL (P0.27); pull-up **R19** 4.7 kΩ to +3V3 |
| /ALRT | FG_ALRT (P0.07); open-drain (uses SDA/SCL pull domain) |

### 4.2 U8 AT42QT1010 (capacitive touch) — U8, C74512
| Pin | Net |
|---|---|
| VDD | +3V3, 100 nF bypass |
| VSS | GND |
| SNS1/SNS2 | **C34** 10 nF (Cs sample cap) + electrode pad (through the shell — coupling provision in `case/DESIGN.md`) |
| OUT | TOUCH_OUT (P0.15) |
| (mode pins) | per datasheet defaults |

---

## 5. Controls

- **Keys SW1–SW13** via hot-swap **HS1–HS13**: one side → its KEYn GPIO
  (P1.00–P1.12), other side → GND. Internal pull-ups; **no diodes** (direct scan).
- **Encoder ENC1** (EC11): A/B → ENC_A/ENC_B (P0.17/P0.19) with pull-ups; common
  → GND; switch → ENC_SW (P0.20)/GND.
- **Joystick JS1** (Alps RKJX21224001): X-wiper → JOY_X (P0.02), Y-wiper →
  JOY_Y (P0.03), pot ends → +3V3 / GND (ratiometric to SAADC VDD reference);
  push → JOY_SW (P0.16)/GND.
  ⚠ **Open capture item:** the RKJX21224001 has an **FPC signal tail** — select
  an FPC connector or hand-solder land pattern (fallback: THT RKJXV122400R).
  Add **series + RC filtering on JOY_X/JOY_Y** to the SAADC (flagged gap — add
  as new passives in the BOM revision, not invented here).

---

## 6. RGB chain

```
U1 P0.06 (RGB_DATA, 3V3) ─► U7 AHCT1G125 IN
U7 VCC = +5V (always-on)   U7 /OE = GND (enabled), pull-down R13 100k
U7 OUT ─► R22 33Ω ─► LED1 DIN
LED1 DOUT ─► LED2 DIN ─► … ─► LED13 DIN     (SK6812MINI-E, +5V_LED / GND)
each LED: 100nF local bypass (from C1–C22 set), VDD=+5V_LED, VSS=GND
```

- U7 **SN74AHCT1G125** single buffer level-shifts 3.3 V data to a 5 V-referenced
  swing (SK6812 V_IH ≈ 0.7·VDD = 3.5 V, so AHCT — not AHC — is required). VCC
  from **+5V always-on, upstream of U6** (`DECISIONS.md`).
- **+5V_LED** (U6 output) supplies only the LED VDD rail; firmware defaults it
  off and enforces the 156 mA aggregate cap.

---

## 7. Programming / reset

- **J3** Tag-Connect TC2030 (footprint only): SWDIO, SWDCLK → U1 dedicated SWD
  pins; nRESET → net RESET; +3V3; GND; (optional) SWO.
- **SW14** (B3U-1000P) → RESET/GND (reset button); **RESET** pull-up **R17**
  10 kΩ to +3V3.
- **SW15** (B3U-1000P) → a GPIO/GND for DFU/user (assign to a free pin, e.g.
  P0.13, at capture) — currently the one input this spec leaves to eeschema.

---

## 8. Passive reconciliation vs frozen `bom.csv`

| Ref | Value | Use in this spec | Note |
|---|---|---|---|
| R1–R2 | 5.1 kΩ | USB CC1/CC2 | ok |
| R3–R4 | 22 Ω | USB D± series | DNP default |
| R5–R8 | 2.21k/3.09k/2.94k/46.4k | BQ24074 network | ok, verified |
| R9 | 732 kΩ | boost FB top | ok |
| R10–R13 | 100 kΩ ×4 | boost FB bottom (R10), BOOST_EN pd (R11), RGB_PWR_EN pd (R12), /OE pd (R13) | **fully allocated** |
| R14–R17 | 10 kΩ ×4 | TS (R14), /CHG pull (R15), /PGOOD pull (R16), RESET pull (R17) | **fully allocated** |
| R18–R19 | 4.7 kΩ | I²C pull-ups | ok |
| R20–R21 | 1 kΩ | RGB input series / touch series | **R20 spare or joystick-filter candidate; R21 touch** — see gap below |
| R22 | 33 Ω | RGB data series | ok |
| C1–C22 | 100 nF ×22 | 13 LED + U1/U3/U4/U5/U6/U7/U8/U9 bypass (8) = 21; **1 spare** | ok |
| C23 | 4.7 µF | U1 bulk | ok |
| C24–C25 | 4.7 µF | BQ BAT/SYS | ok |
| C26 | 1 µF | BQ (pin ⚠ unconfirmed) | verify |
| C27–C29 | 10 µF ×3 | TPS63031 in/out | ok |
| C30 | 10 µF | TPS61023 in | ok |
| C31–C32 | 22 µF ×2 | TPS61023 out | ⚠ MPN obsolete — substitute |
| C33 | 220 pF | TPS22918 CT | ok |
| C34 | 10 nF | touch Cs | ok |

### Passive gaps this capture surfaces (for the BOM revision)
1. **Joystick SAADC filtering** (JOY_X/JOY_Y series R + cap) is not in the frozen
   set — R20 could serve one axis but there is no second series R and no filter
   caps. Add 2×series R + 2×filter C in the BOM revision.
2. **C26 (BQ 1 µF)** net is the single unconfirmed placement — resolve against
   SLUS810N.
3. **C31–C32** (obsolete 22 µF) and **C27–C29** (NRND 10 µF) need LCSC-stocked
   substitutes at the matcher pass (already flagged in `bom.csv`).
4. SW15's GPIO (DFU/user) needs a pin + optional pull assigned in eeschema.

---

## 9. Remaining steps to close blocker 1

1. Resolve the four items in §8 and the ⚠ capture checks (BQ straps/C26, USB
   R3/R4, joystick FPC + filtering).
2. Apply the **pending BOM revision** (drop D1–D13; add joystick filters) as one
   reviewed change; re-run `finalize_bom.py`.
3. Draw this net list in eeschema (custom symbols needed: TPS61023, TPS22918,
   MAX17048, the Alps joystick + FPC tail; the rest are in the official libs).
4. Run KiCad **ERC** to zero errors; export netlist; sync to the PCB and route
   (4-layer) → **DRC**.
5. **Independent human review** of schematic + PCB (blocker 1's second half).
