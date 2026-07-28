# Rev A engineering BOM

Status: **complete two-device procurement BOM; product release validation is
still pending**. Design basis: 108 x 108 mm PCB, 114 x 114 mm enclosure, thirteen
RGB MX keys plus encoder, analog joystick, and capacitive touch = sixteen
logical inputs.

`bom.csv` is the machine-readable procurement list for **two finished devices**.
It does not include discretionary spares. Supplier pack minimums and assembler
attrition may leave unavoidable excess, but no third PCBA is to be populated.
The `Designators` column freezes the intended per-board reference map and
`finalize_bom.py` verifies coverage and two-device quantities.

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
| BLE/USB MCU | Raytac `MDBT50Q-1MV2` | 1 | JLC SMT | V1-V2; exact land pattern and antenna keep-out required; JLC availability unconfirmed. |
| USB-C | GCT `USB4105-GF-A-060` | 1 | JLC hybrid | V1-V2; case opening/edge placement pending. LCSC `C3025063`. |
| USB ESD | TI `TPD2EUSB30DRTR` | 1 | JLC SMT | V1-V2; genuine TI `C97502`. Never substitute `C3011197`. |
| VBUS TVS | Nexperia `PESD5V0S1UL` | 1 | JLC SMT | V1-V2; live stock pending. |
| Charger/power path | TI `BQ24074RGTR` | 1 | JLC SMT | V1-V2; 400 mA charge/500 mA USB input; QFN thermal validation pending. `C54313`. |
| 3.3 V regulator | TI `TPS63031DSKT` | 1 | JLC SMT | V1-V2; buck-boost. |
| 5 V RGB boost | TI `TPS61023DRLR` | 1 | JLC SMT | V1-V2; exact high-current layout required. |
| RGB load switch | TI `TPS22918DBVR` | 1 | JLC SMT | V1-V2; defaults off. `C131941`. |
| RGB buffer | TI `SN74AHCT1G125DBVR` | 1 | JLC SMT | V1-V2; AHCT is intentional, AHC is not equivalent here. |
| Key RGB | OPSCO `SK6812MINI-E`, exact 12 mA variant | 13 | JLC bottom SMT | V1-V2; reverse mount/MSL5a; exact footprint, rotation, and assembly fixture pending. `C5149201`. |
| Touch IC | Microchip `AT42QT1010-TSHR` | 1 | JLC SMT | V1-V2; electrode must be tested through final shell. |
| Fuel gauge | ADI `MAX17048G+T10` | 1 | JLC SMT | V1-V2; calibrate against final battery. |
| Battery | TinyCircuits `ASR00012` / Hondark `803040PL-1000mAh` | 1 | User | V1-V2; protected, 1 A max, 42 x 39 x 5.5 mm, JST-SH. Pocket redesign required. |
| Battery header | JST `SM02B-SRSS-TB(LF)(SN)` | 1 | JLC SMT | V1-V2; verify pack polarity. |
| Joystick | Alps `RKJX21224001` | 1 | User | V1/body clearance only; tail, cap sweep, STEP, footprint, and opening are blockers. `C2886732`. |
| Encoder | Alps `EC11E15244G1` | 1 | User THT | V1-V2; exact lug holes/height need CAD validation. `C370970`. |
| Knob | Mentor `505.6131` | 1 | User | V1-V2; 12 mm diameter, 6 mm shaft. |
| Hot-swap socket | Kailh `CPG151101S11` | 13 | JLC bottom SMT | V1; replace legacy footprint with official land pattern; JLC acceptance pending. `C2803348`. |
| Matrix diode | Diodes Inc. `1N4148W-13-F` | 13 | JLC SMT | V1-V2; SOD-123. `C112342`. |
| Tactile MX switch | Kailh Polia `CPG151101D280` | 13 | User | V1; physical sample/supply gate remains. |
| Frosted 1u cap | Adafruit `5068`, clear DSA 12-pack | 12 | User | V1-V2; 18.6 mm square leaves 1.4 mm between caps at 20 mm pitch. Buy two packs. |
| Ceramic 1u cap | Cerakey `F SET-RX1U` four-pack | 1 used | User | V1; physically gauge before release. |
| Reset/boot | Omron `B3U-1000P` | 2 | JLC SMT | V1; access depends on final case. |
| SWD | Tag-Connect `TC2030-IDC-NL` footprint | 1 | None | V1; external `TC2030-ARM2010-NL` cable and nRF52840-DK/CMSIS-DAP probe required. |

## Passives and power values

Use Coilcraft `LPS3015-152MLB` 1.5 uH for 3.3 V and `XEL4030-102ME`
1 uH for 5 V. The BQ24074 programming network is 3.09 kΩ ILIM,
2.21 kΩ ISET, 2.94 kΩ ITERM, and 46.4 kΩ TMR. USB CC1/CC2 each use
5.1 kΩ. TPS61023 feedback is 732 kΩ/100 kΩ. Every LED gets 100 nF local
bypass. Exact capacitor MPNs and preliminary quantities are in `bom.csv`; all
counts and designator ranges are frozen in `bom.csv`; schematic capture must
match them or deliberately revise and revalidate the BOM.

## Mechanical parts

| Item | Selection | Qty | Validation required |
|---|---|---:|---|
| Inserts | McMaster `94180A321`, M2.5 x 0.45 x 3.4 mm | 4 | Current 1.7 mm CAD pilots are wrong; redraw and print test coupons. |
| Screws | ISO 7380-1 A2 M2.5 x 8 | 4 + spares | Verify engagement, recess, and PCB clearance. |
| Circular pad | 72 mm disc cut from McMaster `8525T575` 60A silicone, bonded with 3M `467MP` | 1 | Selected stock is 1/16 in (1.59 mm), giving about 0.39 mm projection from the present 1.2 mm recess. Cut two discs. |

The 20 mm control lattice is regular. Typical 19 mm 1u caps leave about 1 mm
between neighbors. Exact cap geometry—not center placement—must be sampled.

## Power limits

- Thirteen selected LEDs require about 169 mA at 5 V including static current,
  or roughly 313 mA from a depleted 3.0 V cell at 90% efficiency.
- Firmware must default RGB off and enforce an aggregate 156 mA channel limit.
  Generic 60 mA-per-pixel substitutes are prohibited.
- Keep total battery draw below 0.45 A. The selected pack permits 1 A maximum.
- Charging is limited to about 0.4 A. The charger can dissipate about 0.8 W at
  low cell voltage, so thermal copper/vias and a closed-case test are mandatory.
- No USB-PD controller is present; do not claim USB-PD charging.

## Assembly boundary

JLCPCB reflows all SMT, especially QFN power parts, radio, LEDs, sockets, and
passives. The user installs joystick, encoder, MX switches, keycaps, battery,
inserts, screws, and circular pad. Quote USB-C as hybrid assembly.

## Release blockers

1. Complete and independently review the KiCad schematic; pass ERC.
2. Use exact manufacturer footprints, complete a four-layer route, and pass DRC.
3. Check antenna exclusion on every copper layer and against battery/base/screws.
4. Import populated STEP models and pass enclosure interference review.
5. Redesign the battery pocket to at least 42 x 39 x 8 mm plus cable relief.
6. Model the joystick tail/cap sweep and replace its 20 mm placeholder opening.
7. Derive the USB opening from GCT's drawing.
8. Freeze/sample frosted caps, ceramic cap, inserts, and circular pad.
9. Manually validate every exact MPN, side, and rotation in JLC's live matcher.
10. Build at least two Rev A units and test rails, USB both ways, charging and
    temperature, every input, RGB walking-one, BLE range, touch, and physical fit.

Until these close, individual development parts may be sampled, but the full
PCBA/enclosure order is not justified.

## Fabricated items and reusable tooling

- JLCPCB: five 108 x 108 mm, four-layer, 1.6 mm FR-4, ENIG bare boards; populate
  exactly two. Five is treated as an unavoidable fabrication minimum, not a
  third device.
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
- [Alps RKJX21224001](https://tech.alpsalpine.com/e/products/detail/RKJX21224001/)
- [Microchip AT42QT1010](https://ww1.microchip.com/downloads/en/DeviceDoc/40001946A.pdf)
- [ASR00012 battery datasheet](https://www.mouser.com/datasheet/2/855/ASR00012_1000mAh-3078650.pdf)
- [JLC component matching guidance](https://jlcpcb.com/help/article/component-matching-guidelines-for-pcba-orders)
