# Rev A two-unit bring-up test plan (release blocker 10)

Status: **plan only — execution requires assembled hardware.** This document
satisfies the *plan* half of BOM.md release blocker 10; the pass/fail columns
are filled in by a human running the sequence on real units. It must not be
marked complete until two Rev A units have been through it.

Scope: verify every rail, interface, input, and the closed-case charge/thermal
behavior on **two** assembled Rev A units before any larger PCBA/enclosure run
is justified. Order is dependency-first: nothing downstream is tested until the
rail(s) it depends on are proven. **Stop at the first hard failure in the
power/charge stages** (§2–§4) — those can damage the board or the cell.

Net names, IC designators, and GPIO assignments below are exactly those in
`kicad/SCHEMATIC.md`. Where a step depends on an item the schematic still flags
open (C26 net, joystick SAADC filter, SW15 DFU pin), it is called out inline.

---

## 0. Units, equipment, firmware

**Units under test:** 2× Rev A PCBA in enclosure (per `hardware/BOM.md`
"populate exactly two"). Record serial/board-rev on each.

**Reusable lab tools (from BOM.md):**
- Tag-Connect `TC2030-ARM2010-NL` cable (SWD via J3).
- Nordic `nRF52840-DK` as SWD programmer/debugger for the MDBT50Q.
- Bench DC supply with **adjustable current limit** and readout.
- USB-C source/sink meter (inline VBUS current + orientation flip).
- DMM; thermocouple or IR camera for the closed-case thermal step.
- BLE test host (phone/laptop with nRF Connect) at measured distances.

**Firmware:** flash the Rev A bring-up build (Zephyr/nRF Connect application;
the Phase 0 QMK/Keychron rig does not run on this board). If the bring-up
build isn't ready, a minimal Zephyr "rail + GPIO + RGB walking-one + raw HID"
test image is sufficient for §5–§7 and should be produced first.

**Software counterpart:** run `focalpointd` (real device, not `--mock-device`)
against the unit over USB raw HID; use `focalpoint inject`/event logs to confirm
each input arrives as the correct control ID (PROTOCOL.md §2/§6). RGB and state
mirroring are checked via `focalpoint set-state` / `set-key-state`.

---

## 1. Bare-board / unpowered checks (before any power)

| # | Check | Method | Pass criteria | U1 | U2 |
|---|---|---|---|---|---|
| 1.1 | No rail-to-GND short | DMM Ω, power off | +3V3–GND, +5V–GND, +5V_LED–GND, SYS–GND, VBUS–GND all not near 0 Ω | | |
| 1.2 | Battery connector polarity | DMM against J2 pinout + silkscreen mark | Pigtail + matches J2.1 (the 2-pin LiPo polarity is unstandardized — **verify before first connection**, DECISIONS.md) | | |
| 1.3 | No solder bridges on fine-pitch parts | Visual/scope: U1 module, U3 BQ24074 QFN, U9 MAX17048 | none | | |
| 1.4 | Antenna keep-out clear | Visual: no copper/metal/screw/battery intrudes on module keep-out | clear (cross-check blocker 3) | | |

Do **not** attach the battery yet.

---

## 2. Power rails on bench supply (USB path, current-limited)

Feed VBUS from the bench supply set to **5.0 V, limit 250 mA** through the
USB-C connector (or a VBUS injection point). Battery still disconnected.

| # | Check | Pass criteria | U1 | U2 |
|---|---|---|---|---|
| 2.1 | Inrush | current settles < ~150 mA idle, no limit-latch | | |
| 2.2 | SYS rail | BQ24074 SYS present, ~VBUS-side (power-path from IN) | | |
| 2.3 | +3V3 (U4 TPS63031) | 3.30 V ±3 % under MCU idle load | | |
| 2.4 | +5V (U5 TPS61023) | 4.99 V ±3 % (732k/100k divider) — present when boost enabled | | |
| 2.5 | +5V_LED gated off by default | ~0 V at rest (U6 TPS22918 `ON`/RGB_PWR_EN low, R12 pull-down) | | |
| 2.6 | U7 AHCT VCC | sits on always-on +5V, **upstream** of U6 (not on +5V_LED) — probe confirms | | |

If any rail is out of spec, **stop** and debug before §3. Ramp the current
limit up only after 2.1–2.4 pass.

---

## 3. USB enumeration, both orientations

| # | Check | Pass criteria | U1 | U2 |
|---|---|---|---|---|
| 3.1 | Enumerate orientation A | host sees the CDC/HID device; no VBUS fault | | |
| 3.2 | Enumerate orientation B (flip) | identical result (CC1/CC2 R1/R2 5.1 k both present) | | |
| 3.3 | Raw HID endpoint | `focalpointd` reports "connected"; PONG/GET_CAPS round-trips (PROTOCOL §6) | | |
| 3.4 | D± integrity | if R3/R4 22 Ω were populated vs DNP, note which; enumeration stable either way | | |

---

## 4. SWD, charging, fuel gauge, closed-case thermal (SAFETY GATE)

This stage is the one with real hazard: **charging 400 mA into a sealed case
with JEITA disabled** (TS fixed 10 k, DECISIONS.md). The fixed-TS choice was
accepted *only on condition this test passes* — treat a thermal failure here as
blocking, not a warning.

**Program first, then charge.**

| # | Check | Pass criteria | U1 | U2 |
|---|---|---|---|---|
| 4.1 | SWD detect | nRF52840-DK + TC2030 reads the MDBT50Q IDCODE via J3 | | |
| 4.2 | Flash bring-up firmware | flashes + runs; RTT/log banner | | |
| 4.3 | Fuel gauge I²C | U9 MAX17048 ACKs on FG_SDA/FG_SCL (P0.26/P0.27); reports plausible SOC/VCELL | | |
| 4.4 | /CHG + /PGOOD | CHG_STAT (P0.12) and PGOOD (P0.14) read correct states on USB-present/charging | | |
| 4.5 | Charge current | with a **partially discharged** pack (verified polarity, §1.2), fast-charge ≈ 400 mA (ISET 2.21 k); tapers to ~40 mA termination (ITERM) | | |
| 4.6 | Safety timer | charge completes / terminates within the 6.2 h TMR window (spot-check, don't force full cycle) | | |
| 4.7 | **Closed-case charge thermal** | case fully assembled, charge 400 mA to full; **peak internal/cell temp within the pack + BQ24074 ratings**, no thermal runaway, case exterior comfortable | | |
| 4.8 | Battery-only run | disconnect USB; unit runs from BAT through SYS power-path; +3V3/+5V hold across a 4.2→3.3 V sweep | | |
| 4.9 | Brown-out / low-cell | at ~3.0 V cell, behavior is graceful (no LED overdraw at the protection limit — see §6.3) | | |

A fail on 4.7 forces the fallback in DECISIONS.md: a pack with an integrated
NTC brought to TS, or a reduced charge rate — record which.

---

## 5. Inputs (all 16 logical, direct-scan)

Drive each input physically; confirm the correct control ID over raw HID
(`focalpointd` event log). Direct GPIO scan — **no matrix diodes** (D1–D13
dropped per the pending BOM revision).

| # | Input | GPIO (SCHEMATIC §3) | Pass criteria | U1 | U2 |
|---|---|---|---|---|---|
| 5.1 | KEY1–KEY13 | P1.00–P1.12 | each key → its own control ID; **N-key rollover** (no ghosting, direct scan) | | |
| 5.2 | Any-key wake | any KEYn | device wakes from PORT/sense-on-low | | |
| 5.3 | Encoder rotate | ENC_A/ENC_B (P0.17/P0.19) | CW/CCW detents, correct direction, no missed steps | | |
| 5.4 | Encoder push | ENC_SW (P0.20) | press registers | | |
| 5.5 | Joystick X/Y | JOY_X P0.02/AIN0, JOY_Y P0.03/AIN1 | full-scale sweep both axes; centered ≈ mid-code; noise acceptable **only if SAADC RC filter is populated** (open item — if unfiltered, record noise floor) | | |
| 5.6 | Joystick push | JOY_SW (P0.16) | press registers | | |
| 5.7 | Capacitive touch | U8 OUT → TOUCH_OUT (P0.15), Cs=C34 10 nF | finger through the shell triggers reliably (validates the case coupling provision, DESIGN.md); no false triggers at rest | | |
| 5.8 | DFU/user button | SW15 → GPIO (spec suggests P0.13 — **confirm the pin the schematic actually assigned**) | enters DFU / registers as configured | | |
| 5.9 | Reset button | SW14 → nRESET (P0.18), R17 10 k pull-up | resets the MCU | | |

---

## 6. RGB chain

| # | Check | Pass criteria | U1 | U2 |
|---|---|---|---|---|
| 6.1 | Enable path | firmware asserts RGB_PWR_EN (P0.08) → U6 on → +5V_LED rises; QOD gives clean SK6812 power-on reset | | |
| 6.2 | Walking-one | light LED1..LED13 one at a time; **all 13 in order, correct positions**, no dropouts (validates U7 AHCT level-shift of 3V3 data to the 5 V-referenced chain) | | |
| 6.3 | Current ceiling | all-white at the firmware 156 mA aggregate cap: measure +5V_LED current ≈ budget, **not** the ~480 mA unthrottled worst case; confirm firmware default-off at boot (single-fault decision, DECISIONS.md) | | |
| 6.4 | Color fidelity | R/G/B per channel correct; no swapped channels; confirm SK6812MINI-E per-channel current vs the C5149201 datasheet (open BOM item) | | |
| 6.5 | State mirroring | `focalpoint set-state` / per-key `set-key-state` render the expected colors (aggregate vs per-key, CLAUDE.md) | | |

---

## 7. BLE

| # | Check | Pass criteria | U1 | U2 |
|---|---|---|---|---|
| 7.1 | Advertise + pair | LESC pairing/bonding per the v0.3 draft; device appears with expected GATT layout | | |
| 7.2 | HID over BLE | key/dial/joy events arrive over GATT; 32-byte report fragmentation over 20-byte ATT default works (PROTOCOL v0.3) | | |
| 7.3 | Range | usable at representative desk distances; record RSSI at 1 m / 3 m / 5 m — this is the **antenna keep-out** validation (blocker 3) | | |
| 7.4 | USB/BLE arbitration | plugging USB while BLE-connected follows the "USB wins" rule; link-loss vs USB-suspend `SET_HOST_MODE` semantics behave per draft | | |
| 7.5 | Simultaneous sessions | multiple agent sessions each claim a distinct numbered key; aggregate vs per-key display correct | | |

---

## 8. Physical / enclosure integration

| # | Check | Pass criteria | U1 | U2 |
|---|---|---|---|---|
| 8.1 | Board seats | PCB seats without flexing over the battery pocket; switch install order per ASSEMBLY.md (plate+switches onto supported PCB) | | |
| 8.2 | Battery fit | 42×39×5.5 pack + JST-SH cable relief fit the pocket; no interference with puck/floor | | |
| 8.3 | Insert bosses | heat-set inserts seat in Ø4.0×5.5 pilots; corner reliefs clear the PCB fillet; no boss through board copper | | |
| 8.4 | USB-C opening | connector mates through the rear-wall notch without stress (GCT USB4105 geometry) | | |
| 8.5 | Reset pinhole | tool reaches SW14 through the floor Ø2.0 pinhole | | |
| 8.6 | Keycaps | frosted selector + ceramic key seat and diffuse acceptably (sample sets, not a gate — order after) | | |
| 8.7 | Grommet | feet project 0.6–1.0 mm proud; unit doesn't rock | | |

---

## 9. Sign-off

- [ ] Unit 1 — all mandatory rows pass; deviations recorded below.
- [ ] Unit 2 — all mandatory rows pass; deviations recorded below.
- [ ] §4.7 closed-case charge thermal explicitly signed off (safety gate).
- [ ] Any open schematic item exercised here (C26 net, joystick SAADC filter,
      SW15 pin, R3/R4 DNP) resolved or ticketed.
- [ ] Results fed back into `BOM.md` (clears blocker 10) and any failing rail/
      value fed back to the schematic before a larger order.

**Deviations / notes:**

_(record per-unit anomalies, measured values, and firmware build hash here)_
