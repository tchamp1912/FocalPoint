# Rev A electrical decisions and gates

## Fixed for the first schematic

- 4×4-capable matrix: `C0..C3`, `R0..R3`, with 13 populated switch positions
  and diode direction switch → row. Retention is now conditional — see the
  matrix-vs-direct-GPIO decision below.
- 13 south-facing MX hot-swap positions and 13 SK6812 MINI-E LEDs.
- EC11 encoder with direct GPIO signals `ENC_A`, `ENC_B`, and `ENC_SW`.
- True analog joystick (X/Y/push) and one capacitive touch input.
- USB 2.0 device plus BLE HID/custom GATT on an nRF52840 module.
- One-cell protected LiPo; charging must include power-path/load sharing.
- Target 1,000–1,100 mAh protected LiPo; one pack, one connector: TinyCircuits
  ASR00012 with a JST-SH header (`SM02B-SRSS-TB(LF)(SN)`) — **not JST-PH**
  (earlier text here was wrong; the BOM freeze is SH). Freeze the pocket only
  after measuring the purchased pack. 2-pin LiPo pigtail polarity is
  unstandardized: verify the actual pigtail against the header pinout before
  first connection, and add silkscreen polarity marks at the header. SH
  contacts are rated ~1 A — zero margin over the pack's 1 A protection limit.
- Every mechanical key gets independently addressable RGB with a switched 5 V
  rail and a hard firmware current ceiling.
- Tactile MX switches are the Rev A feel target; samples still gate spring and
  ceramic-key return-force selection.

## Must be selected before footprints are committed

- Exact certified nRF52840 module and its antenna/courtyard/keep-out drawing.
- Exact analog joystick and cap/retention method.
- Exact USB-C receptacle, LiPo connector/polarity, charger/power-path IC,
  regulator/load switch, and ESD array.
- Exact battery pack, connector polarity, maximum charge current, and enclosure
  location.
- Mounting screw/inserts and the location of every board hole.

## Recorded decisions — 2026-07-28 remediation review

- **BQ24074 programming network: verified, kept.** The design review suspected
  the ITERM resistor programmed a nonexistent pin. TI SLUS810N (Rev N)
  refutes this: the BQ24074 variant specifically has a real ITERM pin
  (pin 15) — the BQ24072/73 carry the digital TD function there and the
  BQ24075/79 carry SYSOFF. Network as frozen: ISET 2.21 kΩ → 403 mA fast
  charge; ILIM 3.09 kΩ → ~521 mA typ input limit (EN2=1/EN1=0); ITERM
  2.94 kΩ → ~40 mA ≈ 10 % termination; TMR 46.4 kΩ → ~6.2 h fast-charge
  timeout. Full derivation in `hardware/BOM.md`.
- **Charger TS pin: fixed 10 kΩ for Rev A (JEITA disabled).** The ASR00012 is
  a two-wire pack with no accessible NTC, so TS gets the datasheet's
  "function unused" fixed 10 kΩ to VSS. Consequence: no battery-temperature
  qualification or JEITA derating while charging 400 mA inside a sealed
  case. Preferred long-term fix: a pack with an integrated NTC brought to TS.
  Rev A mitigations: 0.4 C charge rate, 6.2 h safety timer, pack-internal
  protection, and the mandatory closed-case charge/thermal test (BOM release
  blocker 10). Revisit whenever the pack changes.
- **Unthrottled LED worst case: single-fault risk accepted for Rev A.**
  All-white unthrottled at the claimed 12 mA/channel ≈ 13 × 37 mA ≈ 0.48 A at
  5 V ≈ 0.9–1.0 A from a depleted 3.0 V cell — at the pack's protection
  limit; TPS22918 is a load switch, not a current limiter. Decision: accept
  for Rev A on the basis of firmware default-off + 156 mA aggregate limit +
  default-off load switch + pack protection as the last resort; evaluate a
  current-limiting TPS2553-class switch when the schematic is captured.
- **TPS22918 stays; AHCT buffer is powered upstream of it.** TPS61023 true
  shutdown could disconnect the LED rail on its own, but the SN74AHCT1G125
  level buffer must be powered from the always-on boost output *upstream* of
  the switch: AHCT has no Ioff/partial-power-down guarantee, so its VCC must
  not collapse while the MCU drives its input. Keeping the boost enabled and
  gating only the LED chain with TPS22918 preserves that, and the switch's
  quick-output-discharge (QOD) yields a clean SK6812 power-on reset.
  Re-evaluate at schematic capture.
- **Prototype joystick baseline: Alps RKJXV122400R through-hole.** The earlier
  RKJX21224001 public outline
  shows metal mounting lugs that Alps requires soldering to the substrate and
  a separate seven-conductor FPC signal tail. It does not publish the lug land
  pattern or enough FPC dimensions to select a connector. The project-local
  CAD entry is therefore mechanical-only. Obtain the formal Alps delivery
  drawing before choosing JLC assembly, a connector, or a direct-solder
  process. Rev A prototypes therefore use the exact THT `RKJXV122400R`, which
  is hand-solderable and exposes its electrical terminals directly. Capture
  its manufacturer mounting-hole pattern and update the larger top opening and
  11.2 mm body-height clearance before PCB/enclosure release. Keep
  RKJX21224001 as a future low-profile option only.
- **Matrix vs direct GPIO: direct preferred, matrix retained until schematic
  capture.** Full direct-scan signal budget (~29 GPIO): KEY1–KEY13 (13,
  enables any-key PORT wake), ENC_A/ENC_B/ENC_SW (3), JOY_X/JOY_Y (2, must
  land on AIN-capable pins P0.02–P0.05/P0.28–P0.31), JOY_SW (1), TOUCH_OUT
  (1), RGB_DATA (1), RGB_PWR_EN (1), CHG_STAT + PGOOD (2), fuel-gauge
  SDA/SCL/ALRT (3), optional BOOST_EN (1); USB D± and RESET are dedicated
  module pins. The MDBT50Q-1MV2 exposes up to 48 GPIO, so direct scan fits,
  would delete D1–D13 from a crowded bottom side, and simplifies wake. The
  4+4 matrix saves only ~5 pins at the cost of 13 diodes and messier wake.
  Decision: keep the matrix and diodes in the BOM until schematic capture
  assigns concrete pins from the Raytac pin table (avoid P0.09/P0.10 NFC and
  the low-frequency-crystal pins unless reconfigured); if the direct map
  confirms, remove D1–D13 and revalidate the BOM.

## Schematic capture — 2026-07-28

Net-level design capture is recorded in `kicad/SCHEMATIC.md` (every net + every
pin-to-pin connection, grounded in the frozen `bom.csv`). Key outcomes:

- **Direct GPIO scan confirmed; matrix retired.** Assigning concrete nRF52840
  pins yields a 28-signal budget (KEY1–KEY13 on P1.00–P1.12, two analog axes on
  AIN0/AIN1, the rest on P0) — well inside the module's ~48 GPIO. This is the
  confirmation the matrix-vs-direct decision above was waiting on. The BOM
  revision removing D1–D13 and the 4×4 matrix has been applied and validated.
- **Passive set fully allocated** against the frozen R1–R22 / C1–C34 designators;
  R10–R13 (100 k) and R14–R17 (10 k) networks are now assigned per-pin. The only
  unconfirmed node is C26 (BQ 1 µF) pending an SLUS810N pin check.
- **New passive gaps surfaced for the BOM revision:** joystick SAADC filtering
  (series R + cap per axis) was added as R23/R24 and C35/C36; the retired Alps FPC tail
  needs an interconnect selected; C31–C32 (obsolete) / C27–C29 (NRND) need
  stocked substitutes at the matcher pass.
- **Status:** schematic capture and custom symbols are complete; ERC passes
  0/0. The corrected six-layer PCB is fully routed and its schematic/PCB
  pin-net comparison passes with zero mismatches. Native DRC records zero
  errors and zero unconnected pads with warnings still requiring disposition;
  regenerated manufacturing outputs and independent human review remain open.

## Post-capture decisions — 2026-07-28 (owner-confirmed)

Recorded after the ERC-clean transcription (`focalpoint.kicad_sch`, ERC 0/0).
Full engineering derivations for all capture gaps are in
`../CAPTURE_GAP_RESOLUTIONS.md`; the two product/mechanical calls below were
explicitly confirmed by the owner.

- **Ship-mode: no mechanical power switch.** "Off" = nRF52840 System OFF
  (~1.5 µA) with wake-on-any-key (direct-scan PORT event); MAX17048 must be
  firmware-hibernated (~3 µA). Total standby ≈5–30 µA → a 1000 mAh cell lasts
  >1 year. Kits ship with the battery user-installed (disconnected in transit),
  which also keeps the UN38.3/IATA sidestep. Firmware provides a key-combo ship
  mode. Revisit a hardware disconnect only if measured standby is too high.
- **PCB retention: switch-hung + 2 support standoffs.** Plate-mounted switches
  carry the board, plus two edge standoffs (clear of the battery pocket and the
  module antenna keep-out) to take joystick/encoder side-loads and switch-
  insertion force without flexing the bottom-side hot-swap sockets. **Feeds
  WP3:** add the two standoffs to `ergogen/config.yaml`/`enclosure.py`.
- **BQ24074 EN strap + C26 (verified, SLUS810N):** EN1→GND, EN2→logic-high
  (GPIO or +3V3) for the resistor-programmed ILIM mode (Table 7-2: EN2=1/EN1=0).
  C26 1 µF is the **IN-pin bypass** — resolves the spec's one unconfirmed node.
- **Pending BOM revision applied (`bom.csv`, `finalize_bom.py`, `BOM.md`):**
  removed D1–D13 (matrix retired, direct-scan confirmed); added R23–R24 (joystick
  SAADC 1 kΩ series), C35–C36 (10 nF shunt), R25 (100 kΩ FG_ALRT pull-up), D15
  (CC1/CC2 low-cap TVS). `finalize_bom.py` re-validated (60 lines / 23 frozen
  rows). The Rev A joystick FPC issue is closed by selecting the through-hole
  RKJXV122400R; other manufacturer-specific footprint and symbol audits remain.

## Review gates before ordering

- Print the switch plate and control datums at 1:1 with actual caps and parts.
- Calculate peak/limited RGB load, battery runtime, charge current, thermal
  rise, regulator headroom, and USB current behavior.
- Enforce the module vendor's full antenna keep-out on every copper and
  mechanical layer; keep battery, screws, and metal case parts outside it.
- Run KiCad ERC and DRC, inspect every footprint against its datasheet, and
  review schematic/PCB with another person.
- Order unassembled PCBs or a small prototype quantity before an assembly run.

## PCB routing decisions — 2026-07-30

- **Six-layer prototype stack fixed:** JLCPCB `JLC06161H-3313`, selected as a
  1.6 mm order. Copper order is F.Signal / In1.GND / In2.Signal / In3.Signal /
  In4.+3V3 / B.Signal. The exact NP-155F 3313/0.55 mm core/2116/0.55 mm
  core/3313 construction is embedded in
  `focalpoint_rev_a_release_candidate.kicad_pcb`.
- **Routing connectivity complete:** the corrected release candidate
  `focalpoint_rev_a_release_candidate.kicad_pcb` reports zero
  unconnected items after zone refill. FreeRouting was not used for the final
  eleven connections; finite, clearance-conservative scripts completed them.
- **Filled/capped via-in-pad accepted for the six-layer prototype:** trapped
  module, USB-C, LED, resistor, and fuel-gauge pads use reviewed 0.25/0.15,
  0.35/0.15, or 0.45/0.25 mm through-vias. The JLCPCB order must select
  `Epoxy Filled & Capped`; these are not ordinary open vias under SMT pads.
- **USB target recalculated from JLCPCB's live calculator:** 90.0093 ohm at
  0.1420 mm design width and 0.1524 mm gap for coated outer-layer microstrip on
  JLC06161H-3313. The current full-speed route is length-matched but changes
  layers, so successful USB enumeration/data transfer on both prototypes is a
  mandatory physical release gate before any larger quantity.
- **Package pinouts revalidated after routing:** Raytac MDBT50Q Ver. L and the
  U4–U9 vendor datasheets were used to repair physical pad numbering and power
  topology. Routing-driven GPIO remaps are BOOST_EN=P1.13/pad 6,
  FG_SDA=P1.15/pad 8, FG_SCL=P0.30/pad 14, and FG_ALRT=P0.24/pad 48.
  `release_candidate_schematic_pcb_net_compare.txt` records zero mismatches and
  `release_candidate_static_audit.txt` records zero clearance/fabrication-minimum
  violations for the corrected candidate.
- **Native KiCad DRC checkpoint:** the application-bundle CLI wrapper completed
  DRC for `focalpoint_rev_a_release_candidate.kicad_pcb`.
  `DRC_release_candidate_native.rpt` records zero errors and zero unconnected
  pads and zero violations. All hole-to-hole, narrow-connection, dangling-via,
  dangling-track, and silkscreen warnings were repaired without creating
  clearance violations. Thirty-seven intentionally modified footprints are
  vendored into `FocalPoint.pretty`; `release_candidate_footprint_audit.txt`
  reports zero geometry mismatches while ignoring only regenerated property
  UUID metadata. KiCad's library-mismatch category is ignored for this locked
  release library because J3 and U1 otherwise remain false positives.
