# Rev A engineering BOM

Status: **prototype candidate, not order-ready.** The schematic is captured and
passes ERC; the fully routed six-layer PCB has zero unconnected pads. The
remaining electrical release gates are disposition of the saved DRC warnings,
independent review, and JLCPCB's live component/rotation check. Design basis:
116 x 116 mm PCB, 122 x 122 mm enclosure, thirteen RGB MX keys plus encoder,
analog joystick, and capacitive touch = sixteen logical inputs.

`bom.csv` is the machine-readable procurement list for **two finished devices**.
It does not include discretionary spares. Supplier pack minimums and assembler
attrition may leave unavoidable excess, but no third PCBA is to be populated.
The designator freeze lives in `finalize_bom.py`'s reference map; the csv
`Designators` column is derived output that the script rewrites on every run.
The script also cross-checks the frozen-parts table below (MPN, qty, assembly
side, LCSC citation) against `bom.csv` so the two cannot drift silently.
Passive lines carry validation `V1-V2 prov` in `bom.csv` to mark the
provisional status above.

## Validation levels

- **V1** manufacturer, exact MPN, datasheet, package, and lifecycle checked.
- **V2** electrical role and first-pass power/mechanical math checked.
- **V3** schematic, exact footprint, routing, and populated CAD checked.
- **V4** live assembler match, placement side, and rotation checked.
- **V5** physical fit, thermal, RF, charge, and functional tests passed.

No line is production-approved until V1-V5 pass.

## Frozen parts

| Function | Exact selection | Qty | Assembly | Current status |
|---|---|---:|---|---|
| BLE/USB MCU | Raytac `MDBT50Q-1MV2` | 1 | JLC SMT | V1-V2; exact land pattern and antenna keep-out required; JLC lists `C5118826` — live stock/matcher check pending. |
| USB-C | GCT `USB4105-GF-A-060` | 1 | JLC hybrid | V1-V2; case opening/edge placement pending. LCSC `C3025063`. |
| USB ESD | TI `TPD2EUSB30DRTR` | 1 | JLC SMT | V1-V2; genuine TI `C97502`. Never substitute `C3011197`. |
| VBUS TVS | Nexperia `PESD5V0S1UL` | 1 | JLC SMT | V1-V2; LCSC `C85402` (",315" packing suffix); live stock pending. |
| Charger/power path | TI `BQ24074RGTR` | 1 | JLC SMT | V1-V2; 400 mA charge, ~520 mA resistor-programmed input limit; programming network re-verified against TI SLUS810N 2026-07-28 (see passives section); QFN thermal validation pending. `C54313`. |
| 3.3 V regulator | TI `TPS63031DSKT` | 1 | JLC SMT | V1-V2; buck-boost. LCSC stocks the reel suffix `TPS63031DSKR` as `C15516` (same device). |
| 5 V RGB boost | TI `TPS61023DRLR` | 1 | JLC SMT | V1-V2; exact high-current layout required. `C919459`. |
| RGB load switch | TI `TPS22918DBVR` | 1 | JLC SMT | V1-V2; defaults off; retention rationale recorded in `kicad/DECISIONS.md`. `C131941`. |
| RGB buffer | TI `SN74AHCT1G125DBVR` | 1 | JLC SMT | V1-V2; AHCT is intentional, AHC is not equivalent here; power from the always-on boost output upstream of TPS22918 (see `kicad/DECISIONS.md`). `C7484`. |
| Key RGB | OPSCO `SK6812MINI-E`, exact 12 mA variant | 13 | JLC bottom SMT | V1-V2; reverse mount/MSL5a; exact footprint, rotation, and assembly fixture pending. "12 mA variant" is not a verifiable orderable MPN — confirm per-channel current from the `C5149201` datasheet before ordering. |
| Touch IC | Microchip `AT42QT1010-TSHR` | 1 | JLC SMT | V1-V2; electrode must be tested through final shell. `C74512`. |
| Fuel gauge | ADI `MAX17048G+T10` | 1 | JLC SMT | V1-V2; calibrate against final battery. `C2682616`. |
| Battery | TinyCircuits `ASR00012` | 1 | User | V1-V2; protected, 1 A max, 42 x 39 x 5.5 mm, JST-SH pigtail. Verify pigtail polarity against the header before first plug-in (2-pin LiPo polarity is unstandardized); silkscreen polarity marks required. Pocket redesign required. |
| Battery header | JST `SM02B-SRSS-TB(LF)(SN)` | 1 | JLC SMT | V1-V2; verify pack polarity; SH contacts are rated ~1 A — zero margin over the pack's 1 A limit. `C160402`. |
| Joystick | Alps `RKJXV122400R` | 1 | User THT | Rev A prototype baseline; direct PCB terminals and center push, 10 kΩ, 18.2 × 21.7 × 11.2 mm. Project-local footprint is transcribed from Alps Drawing No. 1 (catalog update 2510); Ø20 enclosure aperture is parameterized. LCSC `C918854`; Mouser `688-RKJXV122400R`. The low-profile RKJX21224001 remains a future option only. |
| Encoder | Alps `EC11E15244G1` | 1 | User THT | V1-V2; exact lug holes/height need CAD validation. `C370970`. |
| Knob | Mentor `505.6131` | 1 | User | V1-V2; 12 mm diameter, 6 mm shaft. |
| Hot-swap socket | Kailh `CPG151101S11` | 13 | JLC bottom SMT | V1-V3 footprint; project-local land pattern transcribed from Kailh KHA-PG1511-094EN Rev B / KH-PS-1607-10 Rev B; placement/rotation and JLC acceptance pending. `C2803348`. |
| Tactile MX switch | Kailh Polia `CPG151101D280` | 13 | User | V1; physical sample/supply gate remains. |
| Frosted 1u cap | Adafruit `5068`, clear DSA 12-pack | 12 | User | V1-V2; 18.6 mm square leaves 1.4 mm between caps at 20 mm pitch. Buy two packs. |
| Ceramic 1u cap | Cerakey `F SET-RX1U` four-pack | 1 used | User | V1; physically gauge before release. |
| Reset/boot | Omron `B3U-1000P` | 2 | JLC SMT | V1; access depends on final case. `C231329`. |
| SWD | Tag-Connect `TC2030-IDC-NL` footprint | 1 | None | V1; external `TC2030-ARM2010-NL` cable and nRF52840-DK/CMSIS-DAP probe required. |

The Hondark "803040PL-1000mAh" alternate previously listed alongside the
battery is removed from the table: "803040" nomenclature denotes an
8.0 x 30 x 40 mm cell, contradicting the 42 x 39 x 5.5 mm / JST-SH description
it carried here. Treat it as an unverified alternate at most; do not order it
without measuring a physical sample and verifying its connector and polarity.

## Passives and power values (provisional)

All passive values, counts, and designator ranges are **provisional pending
schematic capture and ERC**. Only the derivations below have been checked
against datasheets; schematic capture must confirm them or deliberately revise
and revalidate the BOM.

**Inductors (LCSC-stocked provisional equivalents).** The originally selected
Coilcraft `LPS3015-152MLB` and `XEL4030-102ME` are effectively never
JLC-stocked, so `bom.csv` now carries verified-in-catalog equivalents, both
marked "provisional equivalent — verify L/Isat/DCR against the TI datasheet
before layout":

- 3.3 V rail (TPS63031): Sunlord `SWPA3015S1R5MT`, 1.5 uH, Isat ≥ 2.3 A, DCR
  65 mΩ max (50 mΩ typ), 3.0 x 3.0 x 1.5 mm, LCSC `C83434` (Sunlord SWPA
  series datasheet, 1R5 row; JLCPCB listing confirms the MT tolerance
  variant). Matches or beats LPS3015-152MLB on Isat and DCR at the same body.
- 5 V rail (TPS61023, switch current up to ~3.7 A): Sunlord `MWSA0402S-1R0MT`,
  1 uH, Isat 7 A, rated 6 A, DCR 27 mΩ, 4.4 x 4.2 mm, LCSC `C408332`
  (JLCPCB listing). Comfortably covers the Isat ≥ 4 A requirement.

**BQ24074 programming network (verified against TI SLUS810N Rev N,
2026-07-28).** The 2026-07-28 design review suspected the ITERM resistor
programmed a nonexistent pin; the datasheet refutes this — the BQ24074
variant specifically has a real ITERM pin (pin 15), where the BQ24072/73 carry
the digital TD function and the BQ24075/79 carry SYSOFF. The network stands:

- ISET (pin 16) 2.21 kΩ → ICHG = KISET/RISET = 890 AΩ / 2.21 kΩ ≈ **403 mA**
  (valid range 590 Ω–8.9 kΩ).
- ILIM (pin 12) 3.09 kΩ → IIN(max) = KILIM/RILIM = 1610 AΩ / 3.09 kΩ ≈
  **521 mA typ** (485–557 mA over KILIM spread; valid range 1.1–8 kΩ). Active
  only with EN2=1/EN1=0 strapped; USB100/USB500 modes remain available via the
  EN pins.
- ITERM (pin 15) 2.94 kΩ → ITERM = 0.03 × RITERM/RISET ≈ **40 mA ≈ 10 %** of
  fast charge (falls to ~13 mA in USB100 mode; RITERM must be < 15 kΩ).
  Floating ITERM would give the same 10 % default; the explicit resistor keeps
  the threshold programmable.
- TMR (pin 14) 46.4 kΩ → tPRECHG = 48 s/kΩ × 46.4 kΩ ≈ **37 min**, tMAXCHG =
  10 × that ≈ **6.2 h** — adequate margin over the ~3.5 h expected full charge
  at 0.4 C (valid range 18–72 kΩ).
- TS (pin 1) uses a fixed 10 kΩ to VSS, the datasheet's documented
  "TS function unused" connection — an explicit decision with JEITA
  implications, recorded in `kicad/DECISIONS.md`.

USB CC1/CC2 each use 5.1 kΩ. TPS61023 feedback is 732 kΩ/100 kΩ ≈ 4.99 V.
Every LED gets 100 nF local bypass. Exact capacitor MPNs and preliminary
quantities are in `bom.csv`.

**LCSC column semantics.** In `bom.csv`, a value of `consign` means no LCSC
code was verified for that exact MPN during the 2026-07-28 sourcing pass; the
line must either be consigned or substituted with a stocked equivalent during
the live-matcher pass (release blocker 9). Every code present was individually
verified against an LCSC/JLCPCB listing; none are guesses. Known flags:
The earlier `GRM31CR61A226KE19L` (22 uF, 1206) and
`GRM188R60J106ME84D` (10 uF, 0603 NRND) choices were replaced in the release
BOM with package-compatible, live-listed 0603 parts. `C45000` and `C71631`
remain exact listed matches but are flagged obsolete/NRND by some
distributors, so reconfirm them in JLC's live matcher.

## Mechanical parts

| Item | Selection | Qty | Validation required |
|---|---|---:|---|
| Inserts | McMaster `94180A321`, M2.5 x 0.45 x 3.4 mm | 4 | Current 1.7 mm CAD pilots are wrong; redraw and print test coupons. |
| Screws | ISO 7380-1 A2 M2.5 x 8 | 4 + spares | Verify engagement, recess, and PCB clearance. |
| Circular pad | 72 mm disc cut from McMaster `8525T575` 60A silicone, bonded with 3M `467MP` | 1 | Selected stock is 1/16 in (1.59 mm), giving about 0.79 mm projection from the current 0.8 mm recess (meets the 0.6-1.0 mm DESIGN.md target). Cut two discs. |

The 20 mm control lattice is regular. Typical 19 mm 1u caps leave about 1 mm
between neighbors. Exact cap geometry—not center placement—must be sampled.

## Power limits

- Thirteen selected LEDs require about 169 mA at 5 V including static current,
  or roughly 313 mA from a depleted 3.0 V cell at 90% efficiency. **Those are
  firmware-limited figures.** The unthrottled worst case — all-white at the
  claimed 12 mA/channel — is ~13 × 37 mA ≈ 0.48 A at 5 V, i.e. ~0.9–1.0 A
  from a depleted 3.0 V cell: at the pack's 1 A protection limit, and a
  generic 60 mA/pixel part would be ~3x that. TPS22918 is a load switch, not
  a current limiter. Recorded decision (see `kicad/DECISIONS.md`): Rev A
  accepts this single-fault exposure; evaluate a current-limiting
  TPS2553-class switch at schematic capture.
- Firmware must default RGB off and enforce an aggregate 156 mA channel limit.
  Generic 60 mA-per-pixel substitutes are prohibited.
- Keep total battery draw below 0.45 A. The selected pack permits 1 A maximum.
- Charging is limited to about 0.4 A. The charger can dissipate about 0.8 W at
  low cell voltage, so thermal copper/vias and a closed-case test are mandatory.
- No USB-PD controller is present; do not claim USB-PD charging.

## Assembly boundary

JLCPCB reflows all SMT, especially QFN power parts, radio, LEDs, sockets, and
passives. The user
installs encoder, MX switches, keycaps, battery, inserts, screws, and circular
pad. Quote USB-C as hybrid assembly.

## Release blockers

1. Complete and independently review the KiCad schematic; pass ERC.
   *Progress 2026-07-28: schematic transcribed (`kicad/focalpoint.kicad_sch`,
   106 footprints / 80 nets, all-local symbols) and **ERC passes 0/0** (errors +
   warnings); netlist exports clean; no dangling nets (verified). **Independent
   human review still owed** — see `kicad/TRANSCRIPTION_NOTES.md` for the
   reviewer checklist and `CAPTURE_GAP_RESOLUTIONS.md` for resolved/new gaps.*
2. Use exact manufacturer footprints, complete the six-layer route, and pass
   native KiCad DRC on
   `kicad/focalpoint_rev_a_release_candidate.kicad_pcb`.
3. Check antenna exclusion on every copper layer and against battery/base/screws.
4. Import populated STEP models and pass enclosure interference review.
5. Redesign the battery pocket to at least 42 x 39 x 8 mm plus cable relief.
6. Place the RKJXV122400R footprint, verify its body/cap sweep against the
   neighboring key and enclosure, and keep all four solder lugs accessible.
7. Derive the USB opening from GCT's drawing.
8. Freeze/sample frosted caps, ceramic cap, inserts, and circular pad.
9. Manually validate every exact MPN, side, and rotation in JLC's live matcher.
10. Build at least two Rev A units and test rails, USB both ways, charging and
    temperature, every input, RGB walking-one, BLE range, touch, and physical fit.
    The step-by-step procedure is written in `BRINGUP_TEST_PLAN.md` (execution
    needs assembled hardware; the closed-case charge/thermal step §4.7 is the
    safety gate for the fixed-TS decision).

Additional Rev A gaps that must close at schematic capture (from the
2026-07-28 review). Most were resolved at capture — see
`CAPTURE_GAP_RESOLUTIONS.md` for the full derivations:

- Ship-mode/power-switch: **decided — no switch** (nRF52840 System OFF + wake-
  on-any-key; MAX17048 firmware-hibernated; kits ship with battery
  disconnected). Owner-confirmed 2026-07-28.
- Test points and fiducials: **specified** (copper/mask only — 1 mm rail/signal
  test pads; 3 asymmetric global fiducials). Layout task, no BOM cost.
- USB CC ESD: **added** — D15 (dual low-cap TVS on CC1/CC2).
- Joystick ADC RC filter: **added** — R23-R24 (1 kΩ series) + C35-C36 (10 nF
  shunt), f_c ≈ 16 kHz, SAADC acquisition ≥10 µs.
- MAX17048 FG_ALRT pull-up: **added** — R25 (100 kΩ); the earlier "shares
  SDA/SCL pull" assumption was wrong (ALRT is a separate open-drain line).
- PCB retention: **decided — switch-hung + 2 support standoffs** (clear of the
  battery pocket and antenna keep-out). Owner-confirmed 2026-07-28; feeds the
  WP3 enclosure/ergogen outline (2 standoffs to add).
- Every `consign` LCSC cell must be resolved (real code or explicit
  consignment) in the live-matcher pass.
- SK6812MINI-E per-channel current must be confirmed from the `C5149201`
  datasheet — the "12 mA variant" wording is not an orderable MPN.
- SN74AHCT1G125 must be powered from the always-on boost output upstream of
  TPS22918; TPS22918 retention rationale is recorded in `kicad/DECISIONS.md`.

Until these close, individual development parts may be sampled, but the full
PCBA/enclosure order is not justified.

## Fabricated items and reusable tooling

- JLCPCB: five 116 x 116 mm, six-layer, 1.6 mm order-class FR-4, ENIG bare
  boards using JLC06161H-3313; populate exactly two. Select impedance control
  and epoxy-filled/capped via-in-pad. Five is treated as an unavoidable
  fabrication minimum, not a third device.
- JLC3DP: two each of the top, bottom, and circular-base STEP files in black MJF
  PA12 nylon.
- One Tag-Connect `TC2030-ARM2010-NL` cable and one Nordic `nRF52840-DK` are
  reusable lab tools for programming both units.

## Primary references

- [Raytac MDBT50Q](https://www.raytac.com/product/ins.php?index_id=24)
- [TI BQ24074](https://www.ti.com/lit/ds/symlink/bq24074.pdf)
- [TI TPS63031](https://www.ti.com/lit/ds/symlink/tps63030.pdf)
- [TI TPS61023](https://www.ti.com/lit/ds/symlink/tps61023.pdf)
- [GCT USB4105](https://gct.co/files/specs/usb4105-spec.pdf)
- [Alps RKJXV122400R](https://tech.alpsalpine.com/e/products/detail/RKJXV122400R/)
- [Sunlord SWPA series datasheet](https://ferrite.ru/upload/docs/pdf/products/sunlord/SWPA%20series%20of%20SMD%20Power%20Inductor.pdf)
- [Sunlord MWSA0402S-1R0MT at JLCPCB](https://jlcpcb.com/partdetail/Sunlord-MWSA0402S1R0MT/C408332)
- [Microchip AT42QT1010](https://ww1.microchip.com/downloads/en/DeviceDoc/40001946A.pdf)
- [ASR00012 battery datasheet](https://www.mouser.com/datasheet/2/855/ASR00012_1000mAh-3078650.pdf)
- [JLC component matching guidance](https://jlcpcb.com/help/article/component-matching-guidelines-for-pcba-orders)
