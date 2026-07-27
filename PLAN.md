# FocalPoint — an open-source agent macropad

An open-hardware, open-firmware take on the OpenAI × Work Louder **Codex Micro**
($230, closed): a small desk device that shows your coding agent's live status on
RGB keys and gives you physical controls for the agent loop — accept, reject,
new task, push-to-talk, a dial for reasoning effort, and a joystick for
launching workflows.

Unlike the original, FocalPoint is **agent-agnostic**: it should work with Claude
Code, Codex CLI, or anything else that can run a hook or speak a simple protocol.

---

## 1. What we're cloning (reference spec)

The Codex Micro, from public coverage:

- ~13 mechanical keys + rotary dial + planar joystick, based on the Work Louder
  Creator Micro 2 platform; 32 swappable keycaps included
- Per-key RGB that reflects agent state: thinking / running / waiting / done
- Dial adjusts the model's reasoning level on the fly
- Joystick launches canned workflows (review PR, debug error, refactor)
- Dedicated keys: accept, reject, push-to-talk, new task
- CNC aluminum frame, USB-C + Bluetooth, $230

The keys and RGB are commodity macropad territory. The differentiating piece is
the **host-side bridge**: software on the computer that pushes agent state to the
LEDs and turns key/dial/joystick events into agent actions. That's where most of
the design effort goes.

## 2. Goals and non-goals

**Goals**

- Total DIY cost well under $100; no single-vendor lock-in on parts
- Fully open: hardware (KiCad), firmware, host software, protocol spec
- **Wireless is a P0 capability of the assembled FocalPoint:** Bluetooth HID for
  input plus a bidirectional BLE control channel for daemon-driven status LEDs;
  USB-C remains a fully functional wired and charging path.
- Works out of the box with Claude Code and Codex CLI; trivially extensible to
  other agents via a documented protocol
- Buildable by a hobbyist: hot-swap switches, 3D-printable case, through-hole
  or JLCPCB-assembled SMD

**Non-goals (first assembled revision)**

- Aluminum case as the default. A 3D-printable case is the first enclosure;
  CNC aluminum follows only after the printed case proves the ergonomics,
  acoustics, antenna clearance, and fastener geometry.

## 3. Hardware design

**Layout (informed by the original, but sized for the actual protocol):**

- 4×3 grid = 12 numbered **agent selector** keys. These use clear MX keycaps
  so their per-key LEDs remain legible.
- Four distinct **action** keys — accept, reject, new task, and push-to-talk —
  use ceramic MX keycaps. This corrects the earlier 13-key count: the protocol
  already reserves controls 0–3 in addition to user keys 1–12, so the physical
  product needs 16 switch positions.
- EC11 rotary encoder with push (reasoning dial)
- 2-axis analog thumbstick with press (workflow joystick)
- Per-key RGB + a light-guide status bar along the top edge (optional).
  Selector caps are clear/frosted PC for direct RGB visibility; ceramic action
  caps are opaque, so their LEDs are intentionally underglow/accent light rather
  than shine-through status indicators.

**Electronics:**

| Part | Choice | Why |
|---|---|---|
| MCU/radio | nRF52840 module (nice!nano-compatible pinout for Rev A) | Native Bluetooth LE, USB, battery-friendly sleep, and a replaceable module while the RF/power design matures |
| Wireless firmware | Zephyr/nRF Connect SDK application | Supports BLE HID plus a custom authenticated FocalPoint GATT service for state/style updates; ZMK is valuable reference code but does not eliminate the custom daemon control-channel work |
| Switches | MX hot-swap, 5-pin compatible | Necessary for readily available clear selector caps and ceramic action caps; much broader switch and acoustic choice than Choc |
| RGB | SK6812 MINI-E per key | Reverse-mount legs, hand-solderable, and supported by standard addressable-LED drivers; use south-facing switch/LED geometry to avoid ceramic Cherry-profile interference |
| Encoder | EC11 with push switch | Standard, well supported |
| Joystick | PSP/Switch-style analog thumbstick on nRF52840 ADC pins | True analog like the original; fallback: 5-way tactile nav switch (cheaper, no ADC) |
| Power | Protected LiPo, USB-C charger with power-path management, 3.3 V regulator, LED power switch/current limit | Wireless requires a safe charging path and a controlled RGB battery budget |
| Connector | USB-C, ESD protection, CC resistors | Wired data, charging, recovery, and firmware update |

**PCB:** KiCad 8, single board. Rev A uses an nRF52840 module footprint and
module-level antenna keep-out (no RF layout gamble); Rev B integrates the radio
only after RF, sleep current, charging, and enclosure validation. The matrix,
switch and case geometry start in `hardware/ergogen/` and are exported to
KiCad/DXF rather than hand-positioned.

**Case:** two-part FDM-printable case first, with a plate/switch module, a
separate battery compartment, and a non-conductive radio window above the
module antenna. It must print without supports in normal orientation. Once
the printed revision is stable, produce a CNC aluminum shell while retaining a
polymer antenna window or relocating the antenna to a non-metal end-cap.

**Keycaps:** clear/frosted PC MX selector caps for slots 1–12; ceramic MX action
caps for accept/reject/new-task/push-to-talk. The cap selection must be
validated for switch stem fit, keycap mass, south-facing LED clearance, and
plate height before locking the case. Ceramic caps are deliberately not used
where RGB needs to shine through.

**Estimated BOM (qty 1, DIY):** wireless module + charger/power ~$20–30,
PCB ~$10–15, switches+sockets ~$20–35, LEDs ~$4, encoder+stick ~$4, protected
LiPo ~$8–12, case print ~$8–15, and misc ~$15 → **~$90–125**. The original
`<$100` target remains aspirational, but claiming it as a hard constraint would
undercut safe wireless power design and the requested premium keycaps.

## 4. Firmware

- The existing **QMK/Vial Keychron V1 Max keymap remains the wired Phase 0
  integration rig**. It proves the daemon, protocol, RGB semantics, and
  interaction design while custom hardware is designed.
- The assembled wireless FocalPoint uses a **Zephyr/nRF Connect SDK firmware**:
  BLE HID carries fallback keyboard input; a FocalPoint BLE GATT service carries
  the same logical command/event model as USB Raw HID. USB exposes normal HID
  plus the existing Raw HID transport for wired development and recovery.
- The daemon owns transport selection: it talks USB when plugged in and BLE
  when wireless, without changing session or style semantics. `PROTOCOL.md`
  will gain a versioned BLE transport section before firmware work starts.
- LED current is firmware-limited in battery mode; animations use a low average
  brightness budget and state is retained/replayed across reconnects.
- Firmware behaves as a normal Bluetooth macropad when no daemon is attached,
  preserving the existing graceful-degradation contract.

## 5. Host software — the core of the project

A small daemon, working name **`focalpointd`**, running on the computer:

```
agent (Claude Code / Codex CLI / other)
        │  hooks / notify events / adapter
        ▼
  focalpointd (Rust or Go, single static binary; macOS/Linux/Windows)
        │  Raw HID (hidapi)
        ▼
  keyboard: LEDs ← state, keys/dial/joystick → actions
```

**Agent → LEDs:** a tiny local API (unix socket + `focalpoint set-state <state>`
CLI) that adapters call. States: `idle`, `thinking`, `running-tool`,
`waiting-for-input`, `done`, `error` — each mapped to a color/animation.

**Controls → agent:**

- Accept / reject / new-task keys: injected as the agent's own keybindings in
  the focused terminal, or via agent-specific IPC where available
- Push-to-talk: keydown starts OS dictation or a local whisper pipe, keyup stops
- Dial: adjusts a per-agent setting (e.g. Claude Code effort/model, Codex
  reasoning level) via the adapter
- Joystick flicks: user-defined workflow prompts from a TOML config
  (`north = "review this PR"`, …)

**Adapters shipped in v1:**

1. **Claude Code** — hooks (`Notification`, `Stop`, `PreToolUse`/`PostToolUse`)
   call `focalpoint set-state`; statusline integration as a bonus. This is the
   easiest and most complete integration.
2. **Codex CLI** — `notify` hook for turn-complete/approval events.
3. **Generic** — the CLI itself; any script can drive the LEDs.

**Protocol spec:** a short markdown doc (`PROTOCOL.md`) defining the HID report
format and the daemon's state API, versioned, so other keyboards or agents can
implement it. If this project catches on, the protocol is the durable artifact.

## 6. Licensing

- Hardware: **CERN-OHL-S v2** (keeps derivatives open) — or OHL-P if we'd
  rather allow closed commercial spins
- Firmware: **GPLv2** (required — QMK derivative)
- Host daemon + adapters: **MIT** (maximize adapter adoption)
- Docs/art: CC-BY-SA 4.0

## 7. Roadmap

**Phase 0 — Prove the loop on off-the-shelf hardware (1–2 weekends)**
Buy an Adafruit MacroPad RP2040 (~$50: 12 keys, encoder, OLED, per-key
NeoPixels) or any Vial macropad. Write `focalpointd` + the Claude Code adapter
against it. Exit criteria: LEDs track a real coding session; accept/reject/dial
work end-to-end. *This de-risks the whole project before any PCB is made.*

**Phase 1 — Industrial + electrical design lock (1–2 weeks)**
Validate the Ergogen MX layout with printed plate coupons; select clear selector
and ceramic action cap samples; define battery envelope, radio antenna keep-out,
BLE pairing/reconnect behavior, LED brightness budget, and a charging safety
test plan. Exit criterion: an approved mechanical envelope and a written
transport extension proposal.

**Phase 2 — Wireless Rev A PCB + printed case (3–6 weeks elapsed)**
KiCad board with nRF52840 module, MX hot-swap sockets, SK6812, encoder,
thumbstick, charger/power path, and battery connector. Order five boards,
hand-assemble, implement the Zephyr BLE/USB transport, and iterate the
3D-printed case. Exit criterion: one untethered device runs a real agent
session with the daemon driving LEDs over BLE.

**Phase 3 — Polish, docs, and aluminum readiness**
Rev B with integrated radio only if justified; build guide with photos; BOM
with LCSC part numbers; `PROTOCOL.md` BLE section finalized; print-ready case
STLs plus a CNC drawing/STEP package that preserves RF performance.

**Phase 4 — Community launch**
GitHub repo(s) public from day one, but this is the announce point: interactive
BOM, flashing guide, demo video of a live Claude Code session lighting it up.
Stretch: group-buy or kit via a vendor and a production aluminum option.

## 8. Repo layout

```
focalpoint/
  hardware/        # KiCad project, gerbers, BOM, ibom.html
  case/            # STEP + STL + FreeCAD/OnShape source
  firmware/        # QMK userspace/fork keymap, Vial JSON
  daemon/          # focalpointd source
  adapters/        # claude-code/, codex-cli/, generic/
  PROTOCOL.md
  docs/            # build guide, assembly photos
```

## 9. Open decisions

1. **Wireless transport and pairing** — choose BLE GATT service UUID,
   authentication/pairing policy, reconnect behavior, and whether USB/BLE may
   be active simultaneously. This must be specified before custom firmware.
2. **nRF52840 module** — compare nice!nano-compatible and other certified
   modules for availability, antenna location, and battery support.
3. **MX switch/cap samples** — confirm the clear selector diffusion and ceramic
   cap/switch sound before freezing the plate.
4. **Daemon language** — Rust (hidapi crate, single binary) vs Go vs Node.
   Recommendation: Rust.
5. **Analog stick vs 5-way switch** — analog is truer to the original;
   5-way is cheaper and simpler. Rev A can footprint both.
6. **Name** — "FocalPoint" assumed from the repo folder.
