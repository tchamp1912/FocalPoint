# Rev A schematic capture — connectivity specification

Status: **design capture + datasheet-controlled schematic/footprint repair
complete; hierarchical ERC passes 0/0 (`focalpoint.kicad_sch`); the corrected
four-layer Rev B PCB has zero schematic/PCB pin-net mismatches, zero unrouted
connections, and a zero-violation native KiCad DRC report. Independent review,
JLCPCB upload review, and physical prototype validation remain required**
(release blocker 1, `BOM.md`). Transcription judgment calls and
the items a reviewer must check are in `TRANSCRIPTION_NOTES.md`; resolved
capture questions are recorded in `../CAPTURE_GAP_RESOLUTIONS.md`.

This document is the electrical source of truth for the Rev A schematic: every
net and every pin-to-pin connection, grounded in the frozen `bom.csv`
designators and the recorded decisions in `DECISIONS.md`. It exists so the
eeschema drawing is transcription rather than design, and so the design can be
reviewed by a person before any symbol is placed. It does **not** replace ERC —
it is the input to it.

The checked-in `.kicad_sch` is now the electrical source consumed by KiCad.
This document explains the intended topology and remains a human-review aid;
the exported netlist and ERC report govern connectivity.

## Hierarchical capture

`focalpoint.kicad_sch` is the root sheet. It links to
`focalpoint_power.kicad_sch`, `focalpoint_signals.kicad_sch`, and
`focalpoint_peripherals.kicad_sch`. Cross-sheet connections intentionally use
the already-reviewed global net names, so the hierarchy changes organization
only. An exact comparison against `focalpoint_flat_reference.kicad_sch` reports
107 components, 80 nets, and zero component or net-node mismatches; PCB parity
also remains at zero mismatches. See `hierarchical_schematic_equivalence.txt`.
The generated child sheets use conventional passive, protection, switch,
battery, and power-flag notation; device-specific ICs and modules retain their
pin-accurate functional block symbols. Fixed A2 placement cells distribute the
design across each printable page and are checked for containment and overlap
by `hierarchize_schematic.py`; see
`hierarchical_schematic_layout_validation.txt`.

Reference designators below are exactly those frozen in `bom.csv` (verified by
`finalize_bom.py`). Where this capture implies a BOM change, it is called out as
an applied BOM revision documented in `bom.csv`.

---

## 1. Power tree

```
USB-C VBUS ──[D14 TVS]──┬─────────────────────────► U3 BQ24074 IN
                        │
                      (5V1 domain, transient-clamped)

U3 BQ24074:  IN ─► [power path] ─► SYS ──┬─► U4 TPS63031 ──► +3V3 (always-on)
                                          ├─► U5 TPS61023 ──► +5V (RGB boost)
             BAT ◄────────────────────────┴─ J2 ─ off-board BT1 (LiPo, JST-SH)

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
| U8 AT42QT1010 VDD | pin 5 | 1× 100 nF | — |
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
| IN bypass | **C26** 1 µF from VBUS to GND |

The exported netlist confirms C26 from VBUS to GND. Confirm EN1/EN2 strap
behavior against SLUS810N before release.

### 1.2 U4 TPS63031 (3.3 V buck-boost) — U4, C15516 (DSKT fixed 3.3 V)
| Physical pin | Function / net |
|---|---|
| 1 | VOUT → +3V3 |
| 2 / 4 | L2 / L1 → opposite ends of **L1** (Sunlord SWPA3015 1.5 µH) |
| 3 / 9 / 11 | PGND / GND / exposed pad → GND |
| 5 / 8 | VIN / VINA → SYS |
| 6 | EN → +3V3 (always on) |
| 7 | PS/SYNC → GND (power-save enabled) |
| 10 | FB, fixed-output connection per TPS63031 datasheet |

**C27–C29** provide the datasheet input/output capacitance split. The WSON
footprint, exposed pad, and pin numbering are captured explicitly in both
schematic and PCB.

### 1.3 U5 TPS61023 (5 V boost) — U5, C919459
| Physical pin | Function / net |
|---|---|
| 1 | FB: **R9** 732 kΩ to +5V / **R10** 100 kΩ to GND → ≈4.99 V |
| 2 | EN → U1 `BOOST_EN` (P1.13 / module pad 6), pull-down **R11** 100 kΩ |
| 3 | VIN → SYS; **C30** 10 µF |
| 4 | GND |
| 5 | SW; **L2** is connected between SYS and SW |
| 6 | VOUT → +5V; **C31–C32** 22 µF |

The inductor topology is `SYS → L2 → SW`; it is not connected between SW and
+5V.

### 1.4 U6 TPS22918 (LED load switch) — U6, C131941
| Physical pin | Function / net |
|---|---|
| 1 | VIN → +5V |
| 2 | GND |
| 3 | ON → U1 `RGB_PWR_EN` (P0.08 / module pad 24), **R12** 100 kΩ pull-down |
| 4 | CT → **C33** 220 pF to GND |
| 5 | QOD per datasheet discharge connection |
| 6 | VOUT → +5V_LED |

---

## 2. USB (data + VBUS)

- USB-C **J1** (GCT USB4105, 16-pin):
  - VBUS (both) → net VBUS → **D14** PESD5V0S1UL TVS to GND → U3 IN.
  - CC1 → **R1** 5.1 kΩ to GND; CC2 → **R2** 5.1 kΩ to GND (UFP/sink).
  - D+ pair tied, D− pair tied → **R3/R4** 22 Ω series (DNP by default) →
    **U2 TPD2EUSB30** ESD shunt → U1 MDBT50Q USB `D+`/`D−` (dedicated module pins).
  - SBU1/SBU2 → no-connect.
  - Shield → chassis/GND per EMC (single-point).
- **U2 TPD2EUSB30** (C97502 — never substitute C3011197) is captured as the
  3-pin DRT shunt array: pin 1 USB D+, pin 2 USB D−, pin 3 GND. It is not a
  powered or flow-through device.

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
| BOOST_EN | **P1.13** (module pad 6) | → U5 EN; remapped for a manufacturable module escape |
| CHG_STAT | **P0.12** | ← U3 /CHG (open-drain, pulled up) |
| PGOOD | **P0.14** | ← U3 /PGOOD (open-drain, pulled up) |
| FG_SDA | **P1.15** (module pad 8) | I²C to U9 |
| FG_SCL | **P0.30** (module pad 14) | I²C to U9 |
| FG_ALRT | **P0.24** (module pad 48) | ← U9 /ALRT (open-drain) |
| USB D+/D− | dedicated | to U2 |
| SWDIO/SWDCLK | dedicated | to J3 |
| nRESET | **P0.18** | to J3 + **SW14**, pull-up **R17** 10 kΩ |

Signal count: 28 (13 keys + 2 analog + 13 control/sense/comms) — well within the
module's exposed GPIO budget. Every assigned GPIO and the physical module pad
mapping were checked against Raytac MDBT50Q-1MV2 specification Ver. L.

- U1 supply: pad 28 VDD → +3V3 with 100 nF + **C23** 4.7 µF bulk.
  Pads 1, 2, 15, 33, and 55 → GND; pad 32 → USB VBUS detect/input.
- DEC/DCC pins (internal regulator decoupling) and the RF/antenna are handled
  inside the certified module — **module antenna keep-out** governs placement
  (blocker 3).

### Applied BOM revision — direct scan, no matrix diodes
The direct-scan pin budget fits (28 ≤ 48), so the matrix is not needed
(`DECISIONS.md` set this as the trigger). **D1–D13 were removed** from `bom.csv`
and the schematic. The 13 keys are direct GPIO inputs with internal pull-ups.

---

## 4. Sensing

### 4.1 U9 MAX17048 (fuel gauge) — U9, C2682616
| Physical pin | Function / net |
|---|---|
| 2 / 3 | CELL / VDD → J2.1 (+BAT); 100 nF bypass |
| 1 / 4 / 6 / 9 | CTG / GND / QSTRT / exposed pad → GND for Rev A |
| 8 | SDA → FG_SDA (P1.15); **R18** 4.7 kΩ pull-up |
| 7 | SCL → FG_SCL (P0.30); **R19** 4.7 kΩ pull-up |
| 5 | /ALRT → FG_ALRT (P0.24); **R25** 100 kΩ pull-up |

### 4.2 U8 AT42QT1010 (capacitive touch) — U8, C74512
| Physical pin | Function / net |
|---|---|
| 1 | OUT → TOUCH_RAW / **R21** / TOUCH_OUT |
| 2 | VSS → GND |
| 3 / 4 | SNSK / SNS → **C34** 10 nF sample capacitor and electrode |
| 5 | VDD → +3V3, 100 nF bypass |
| 6 | SYNC/mode → GND for the captured free-running mode |

---

## 5. Controls

- **Keys SW1–SW13** via hot-swap **HS1–HS13**: one side → its KEYn GPIO
  (P1.00–P1.12), other side → GND. Internal pull-ups; **no diodes** (direct scan).
- **Encoder ENC1** (EC11): A/B → ENC_A/ENC_B (P0.17/P0.19) with pull-ups; common
  → GND; switch → ENC_SW (P0.20)/GND.
- **Joystick JS1** (Alps RKJXV122400R prototype baseline): X-wiper → JOY_X
  (P0.02), Y-wiper →
  JOY_Y (P0.03), pot ends → +3V3 / GND (ratiometric to SAADC VDD reference);
  push → JOY_SW (P0.16)/GND.
  The project-local `Alps_RKJXV122400R` footprint captures the manufacturer
  Drawing No. 1 mounting-hole pattern, including duplicate pot/switch contacts,
  four soldered metal lugs, and two locating bosses. The enclosure carries a
  parameterized Ø20 aperture for the 18.2 × 21.7 × 11.2 mm body assembly.
  The future low-profile RKJX21224001 option has a seven-conductor **FPC signal
  tail**. Alps' public outline identifies the conductors (two dummy, SW out,
  VR2 out, GND, VDD, VR1 out) but does not dimension contact pitch, contact
  side, insertion depth, or the metal mounting-lug land pattern. The local
  `Alps_RKJX21224001` footprint therefore contains authoritative envelope/FPC
  sweep geometry only and deliberately has no pads. Obtain Alps' formal
  delivery drawing before choosing a connector; do not substitute a guessed
  direct-solder pattern.
  **R23–R24 (1 kΩ) and C35–C36 (10 nF)** provide per-axis SAADC filtering.

The `Kailh_CPG151101S11_Hotswap` local footprint is captured from Kailh
KHA-PG1511-094EN Rev B / KH-PS-1607-10 Rev B, including the 3.05 mm switch-pin
openings, 2.55 x 2.50 mm contact lands, MX center/locating holes, and the
manufacturer socket envelope. It is intended to be flipped to the PCB bottom.

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
- **SW15** (B3U-1000P) → P0.13/GND for DFU/user.

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
| C26 | 1 µF | BQ IN/VBUS bypass | captured |
| C27–C29 | 10 µF ×3 | TPS63031 in/out | ok |
| C30 | 10 µF | TPS61023 in | ok |
| C31–C32 | 22 µF ×2 | TPS61023 out | ⚠ MPN obsolete — substitute |
| C33 | 220 pF | TPS22918 CT | ok |
| C34 | 10 nF | touch Cs | ok |

### Remaining passive procurement checks
Any alternate passive selected during JLC's live component review must match
the voltage, dielectric, tolerance, package, and effective-capacitance
requirements recorded in `BOM.md`/`bom.csv`.

---

## 9. Remaining steps to close blocker 1

1. Preserve the zero-violation native KiCad DRC result on
   `focalpoint_rev_b_4layer_release_candidate.kicad_pcb` after any edit.
2. Regenerate and verify Gerbers, PTH/NPTH drill files, BOM, and component
   placement from that exact PCB revision.
3. Complete the JLC upload/rotation review and independent human schematic/PCB
   review before manufacturing two prototypes.
