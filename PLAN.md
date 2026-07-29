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

- 13 mechanical keys + capacitive touch sensor + rotary dial + planar
  joystick, based on the Work Louder Creator Micro 2 platform; 32 swappable
  keycaps included
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

**Layout (frozen for Rev A — see `hardware/CONTROL_MAPPING.md` and
`hardware/BOM.md`):**

- **13 RGB MX keys**: 12 frosted **agent selector** keys (clear/frosted PC
  caps so per-key LEDs stay legible) plus **one ceramic key**. The 12
  selector keys are not a contiguous grid — they scatter 1+4+4+3 around the
  corner controls on a uniform 4×4 visual lattice (encoder, joystick, and
  touch region occupy three corners; see the CONTROL_MAPPING lattice).
- EC11 rotary encoder with push (reasoning dial)
- Alps 2-axis analog thumbstick with press (workflow joystick)
- Capacitive touch region (AT42QT1010)
- That's **16 logical inputs** total (13 keys + encoder + joystick + touch).
  There are no dedicated accept/reject/new-task/push-to-talk switch
  positions: those roles — and everything else — are assigned through
  **dynamic mapping profiles** (`hardware/CONTROL_MAPPING.md`; protocol
  support drafted in `PROTOCOL.md` §6). The v0.2 control codes 0–3 are
  logical actions a profile maps onto physical controls, not physical keys.
- Per-key RGB + a light-guide status bar along the top edge (optional).
  The ceramic cap is opaque, so its LED is intentionally underglow/accent
  light rather than a shine-through status indicator.

**Electronics:**

| Part | Choice | Why |
|---|---|---|
| MCU/radio | nRF52840 module — Raytac `MDBT50Q-1MV2` (frozen in `hardware/BOM.md`) | Native Bluetooth LE, USB, battery-friendly sleep; pre-certified modular radio grant and documented antenna keep-out (supersedes the earlier "nice!nano-compatible replaceable module" idea — see §11) |
| Wireless firmware | Zephyr/nRF Connect SDK application | Supports BLE HID plus a custom authenticated FocalPoint GATT service for state/style updates; ZMK is valuable reference code but does not eliminate the custom daemon control-channel work |
| Switches | MX hot-swap, 5-pin compatible | Necessary for readily available clear selector caps and the ceramic `key_13` cap; much broader switch and acoustic choice than Choc |
| RGB | SK6812 MINI-E per key | Reverse-mount legs, hand-solderable, and supported by standard addressable-LED drivers; use south-facing switch/LED geometry to avoid ceramic Cherry-profile interference |
| Encoder | EC11 with push switch | Standard, well supported |
| Joystick | Alps RKJX2-series analog thumbstick on nRF52840 ADC pins (frozen) | True analog like the original; the earlier 5-way-switch fallback is dropped — see §11 |
| Touch | Microchip AT42QT1010 capacitive touch IC + PCB electrode | Matches the original's touch sensor; electrode coupling through the case is an open mechanical question (WP3) |
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

**Keycaps:** clear/frosted PC MX selector caps for slots 1–12; **one** ceramic
MX cap for `key_13` (Cerakey; the frozen BOM buys a four-pack but populates
one). The cap selection must be validated for switch stem fit, keycap mass,
south-facing LED clearance, and plate height before locking the case. Ceramic
caps are deliberately not used where RGB needs to shine through.

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
  when wireless, without changing session or style semantics. The versioned
  BLE transport section now exists as `PROTOCOL.md` §6 (v0.3, DRAFT); its
  TBDs must be closed before firmware work starts.
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
  focalpointd (Rust, single static binary; macOS/Linux, Windows stubbed)
        │  Raw HID (hidapi)
        ▼
  keyboard: LEDs ← state, keys/dial/joystick → actions
```

**Agent → LEDs:** a tiny local API (unix socket + `focalpoint set-state <state>`
CLI) that adapters call. States (canonical names, `PROTOCOL.md` §1): `idle`,
`thinking`, `running`, `waiting`, `done`, `error`, `compacting` — each mapped
to a color/animation.

**Controls → agent:**

- Accept / reject / new-task keys: injected as the agent's own keybindings in
  the focused terminal, or via agent-specific IPC where available
- Push-to-talk: keydown starts OS dictation or a local whisper pipe, keyup stops
- Dial: adjusts a per-agent setting (e.g. Claude Code effort/model, Codex
  reasoning level) via the adapter
- Joystick flicks: user-defined workflow prompts from a TOML config
  (`north = "review this PR"`, …)

**Adapters shipped (all exist in `adapters/`):**

1. **Claude Code** — hooks (`Notification`, `Stop`, `PreToolUse`/`PostToolUse`)
   call `focalpoint set-state`; statusline integration as a bonus. This is the
   easiest and most complete integration.
2. **Cursor** — user-level hooks in `~/.cursor/hooks.json`; no `waiting`
   state or token stats (Cursor doesn't expose them).
3. **Codex CLI** — native lifecycle hooks (legacy `notify` fallback).
4. **Generic** — the CLI itself / `wrap.sh`; any script can drive the LEDs.
5. **mac-virtual** — the pre-hardware validation rig: renders the aggregate
   on the Mac's keyboard backlight (private CoreBrightness API).

**Protocol spec:** a short markdown doc (`PROTOCOL.md`) defining the HID report
format and the daemon's state API, versioned, so other keyboards or agents can
implement it. If this project catches on, the protocol is the durable artifact.

## 6. Licensing

- Hardware: **CERN-OHL-S v2** — *decided*, not tentative: the design files are
  already published, and strongly-reciprocal was this plan's stated preference
  from the start (keeps derivatives open). OHL-P is off the table.
- Firmware — split by codebase, because "GPLv2, required" only ever applied to
  the QMK work:
  - Phase 0 Keychron V1 Max **QMK keymap**: **GPLv2** (forced — QMK
    derivative).
  - Rev A **Zephyr/nRF-Connect application**: **Apache-2.0** (the
    Zephyr/nRF-Connect ecosystem norm, and it avoids the linking conflict a
    GPLv2 application would have with Nordic's proprietary SoftDevice
    Controller / nRF-Connect SDK components).
- Host daemon + adapters: **MIT** (maximize adapter adoption)
- Docs/art: CC-BY-SA 4.0

## 7. Compliance and safety

Decisions and obligations that shape the hardware program; recorded here so
they are budgeted, not discovered at ship time.

- **Radio certification — modular strategy.** Rev A rides the Raytac
  MDBT50Q-1MV2's pre-certified modular grants (FCC/ISED/CE/TELEC), which is
  the main reason a module beat an integrated radio. That grant does **not**
  make the finished device exempt: FCC Part 15B unintentional-radiator
  testing (SDoC) still applies to the assembled product. Two futures forfeit
  the modular grant entirely and require full intentional-radiator testing —
  an **aluminum case** (the §2 stretch goal) and a **Rev B integrated radio**.
  Record both as a real certification cost against those options before
  choosing them.
- **User-supplied battery — explicit policy decision.** Kits ship **without**
  a battery; the builder buys the specified protected pack themselves. This
  deliberately sidesteps UN38.3 testing and IATA dangerous-goods shipping for
  every kit sold. The cost of that choice: 2-pin LiPo pigtail polarity is
  unstandardized, so the build docs MUST carry prominent polarity and
  connector (JST-SH) warnings, and the PCB carries silkscreen polarity
  marking (see `hardware/BOM.md`).
- **Kit safety documentation.** The build guide must cover charging a LiPo
  inside a closed, unventilated printed case: charge-current rationale
  (400 mA vs pack capacity), temperature expectations, the TS-pin/JEITA
  decision recorded in the BOM docs, first-charge supervision, and what a
  swollen pack looks like.
- **BLE threat model.** The wireless control channel can synthesize
  keystrokes on the host. Pairing/bonding/authentication policy lives in
  `PROTOCOL.md` §6.4 (v0.3 DRAFT) and must be closed before wireless
  firmware ships.
- **Trademark.** "FocalPoint" has had no trademark search. Run one before the
  Phase 4 public launch; renaming after announce is far more expensive than
  before.

## 8. Roadmap

**Phase 0 — Prove the loop on off-the-shelf hardware — DONE**
Done, on a **Keychron V1 Max** running a QMK/Vial keymap
(`firmware/keychron-v1-max/`), not the Adafruit MacroPad originally sketched
here. `focalpointd`, the CLI, the Claude Code / Cursor / Codex / generic /
mac-virtual adapters, and the macOS menu-bar app all exist and run daily; LEDs
track real coding sessions and accept/reject/dial work end-to-end. *This
de-risked the software half completely.*

**Phase 1 — Industrial + electrical design lock — IN PROGRESS (exit criteria
open)**
Validate the Ergogen MX layout with printed plate coupons; sample the frosted
selector caps (diffusion) and the Cerakey ceramic cap (mass/stem fit);
finalize the wireless transport spec (drafted as `PROTOCOL.md` §6, still
DRAFT); define battery envelope, radio antenna keep-out, LED brightness
budget, and a charging safety test plan. Exit criterion: an approved
mechanical envelope, validated coupons/cap samples, and the transport spec
out of DRAFT. **None of these have closed yet.**

**Phase 2 — Wireless Rev A PCB + printed case (design started early —
honestly: ahead of Phase 1 validation)**
Design artifacts exist before Phase 1's exit criteria are met: the ergogen
layout, an enclosure script, and a "frozen" two-device BOM
(`hardware/BOM.md`) were produced ahead of coupons, cap samples, and a
schematic. That order is acknowledged, not hidden — paper design is cheap,
hardware isn't. The true gate for spending money is therefore **the release
blockers listed in `hardware/BOM.md`** (schematic capture + ERC, routed
board, charger-network verification, battery fit, joystick assembly question,
LCSC coverage) *plus* the open Phase 1 criteria above. **No parts order, no
PCBA, no print order until those close.** Then: assemble two boards,
implement the Zephyr BLE/USB transport per the finalized `PROTOCOL.md` §6,
and iterate the printed case. Exit criterion: one untethered device runs a
real agent session with the daemon driving LEDs over BLE.

**Phase 3 — Polish, docs, and aluminum readiness**
Rev B with integrated radio only if justified (note: it forfeits the modular
radio grant — §7); build guide with photos; BOM with LCSC part numbers;
`PROTOCOL.md` §6 out of DRAFT and stable; print-ready case STLs plus a CNC
drawing/STEP package that preserves RF performance (aluminum also forfeits
the modular grant — §7).

**Phase 4 — Community launch**
GitHub repo(s) public from day one, but this is the announce point: interactive
BOM, flashing guide, demo video of a live Claude Code session lighting it up.
Trademark search for "FocalPoint" (§7) happens before this point. Stretch:
group-buy or kit via a vendor and a production aluminum option.

## 9. Repo layout

```
focalpoint/
  hardware/        # ergogen + KiCad sources, BOM.md/bom.csv, CONTROL_MAPPING.md
  case/            # FreeCAD (Python) enclosure source + DESIGN.md
  firmware/        # keychron-v1-max/ QMK keymap (Phase 0 rig), Vial JSON
  daemon/          # focalpointd + focalpoint CLI source (Rust)
  adapters/        # claude-code/, cursor/, codex-cli/, generic/, mac-virtual/
  app/             # macOS menu-bar app (SwiftUI, swiftc-only build)
  packaging/       # launchd plist for focalpointd
  install.sh       # one-command setup (daemon + hooks + launchd + app)
  uninstall.sh
  PROTOCOL.md
  docs/            # build guide, assembly photos
```

## 10. Future host-software feature ideas

Not scheduled into a phase yet — captured here so they don't get lost.
Ordered roughly by the priority they were proposed at.

1. **Rich attention reasons** *(highest)* — replace the flat `waiting`/`error`/
   `done` states with a reason + urgency, e.g. `waiting: permission_required`,
   `waiting: question`, `error: tests_failed`, `waiting: context_nearly_full`,
   `error: suspected_stuck`. Lets the navigation/routing algorithm rank
   "permission request" above "ordinary idle prompt" instead of treating all
   `waiting` sessions as equal.
2. **Custom attention policies** *(highest)* — user-configurable routing order
   in `config.toml` instead of the hard-coded `error > waiting > done >
   running`, e.g. `priority = ["waiting:permission", "error:*", "done"]`,
   `ignore_done_after_seconds`, `prefer_current_project`. Presets: Interactive,
   Debugging, Review, Current-project, Oldest-first, Round-robin.
3. **Stuck-agent detection** *(very high)* — a new `error: suspected_stall`
   reason inferred from signals like a tool running far past its normal
   duration, no hook/token activity for a configurable window, repeated
   identical tool failures, or a permission-denial loop. Distinct hardware
   treatment (slow pulse) from a hard failure.
4. **Attention-queue preview HUD** *(very high)* — holding the "jump to
   next session" hotkey shows a brief compact list (`1. Claude — permission
   required — focalpoint/daemon`, …) instead of switching apps blind; tap
   jumps immediately, repeated taps cycle, a number key while open selects
   directly.
5. **Queue actions without switching context** *(very high, security-sensitive)*
   — a small keyboard-first approve/reject surface for the common case
   (`Claude wants to run: npm test` → Approve/Reject/Open), plus global
   actions (approve-and-next, snooze, mark reviewed, terminate). Not a full
   remote chat client — just enough to do jump → inspect → approve → next
   without leaving the keyboard.
6. **Session snoozing and deferral** *(high)* — snooze a session for N
   minutes, until another session finishes, or until manually unmuted; pin,
   mute-project, mute-request-type. Turns the queue into an actual
   human-attention scheduler rather than a raw state sort. Snoozed sessions
   stay visibly dimmed on the macropad.
7. **Transcript search / command palette** *(high)* — a Spotlight-style
   (⌥⇧Space) search across repo, session name, initial prompt, recent
   messages, files touched, provider, branch, error text, state, date; results
   support focus/resume/copy-resume-command/open-repo.
8. **Session recovery and handoff** *(high)* — detect "transcript exists but
   no live process" (terminal closed, agent crashed, Mac restarted) versus
   "working tree still has uncommitted agent changes," and offer
   Resume/Open-diff/Archive/Discard while keeping the slot assigned during
   recovery instead of freeing it immediately.
9. **Per-session quota runway** *(medium-high)* — combine existing per-session
   token/cost stats with provider quota to show burn rate and projected
   exhaustion per session (e.g. "24% of 5h window, exhausts in 1h12m"). Used
   for routing warnings (don't assign a big task to a nearly-exhausted
   provider), not as a cost dashboard.
10. **Multi-machine attention routing** *(medium-high)* — normalize sessions
    from other machines (SSH/Tailscale) into one queue grouped by host;
    selecting a remote session opens its SSH/tmux or remote-desktop link.
11. **State-transition automations / webhooks** *(medium)* — a `[[rules]]`
    config (`when = "session.error"`, `run = "..."` / `webhook = "..."`) plus
    Shortcuts.app/AppleScript/CLI-event-stream/Unix-socket-subscribe hooks, so
    FocalPoint is an automation platform, not just a display.
12. **Provider health / incident grouping** *(medium)* — detect that several
    simultaneous errors share a provider-wide cause (API degraded) and
    collapse them into one incident entry instead of flooding the attention
    queue with duplicates.
13. **Git-aware completion state** *(medium-high)* — subdivide `done` into
    `done_unreviewed` / `done_tests_passed` / `done_tests_failed` /
    `done_no_changes` / `done_conflicts` / `done_committed`, with quick actions
    (open diff, run verification command, mark reviewed, commit, open PR).
    Just enough git awareness to make `done` actionable, not a git client.
14. **Subagent aggregation** *(medium-high)* — roll a parent session's
    subagents into a summary (`2 running, 1 done, 1 error`) rather than
    showing/consuming a key per child; a child error elevates the parent's
    displayed state; hold the slot key to expand and select a child.

## 11. Open decisions

Still open:

1. **Wireless transport and pairing** — a versioned draft now exists
   (`PROTOCOL.md` §6: GATT layout with placeholder UUIDs, MTU/fragmentation,
   link-loss semantics, pairing/bonding policy, USB/BLE arbitration), but its
   TBDs (final UUIDs, security level, Just-Works policy, profile entry
   format) must be closed and the DRAFT marker removed before custom
   firmware.
2. **MX switch/cap samples** — confirm the frosted selector diffusion and the
   Cerakey ceramic cap's mass/fit/sound before freezing the plate (Phase 1
   exit criterion, still open).

Closed:

3. **nRF52840 module — CLOSED: Raytac `MDBT50Q-1MV2`** (frozen in
   `hardware/BOM.md`). Supersedes the "nice!nano-compatible replaceable
   module" rationale: the pre-certified modular radio grant (§7), documented
   antenna keep-out, JLC assemblability, and availability outweigh
   socket-level replaceability, which the frozen single-board BOM gave up
   anyway.
4. **Daemon language — CLOSED: Rust.** Shipped (`daemon/`, hidapi, single
   binary).
5. **Joystick — CLOSED: analog Alps (RKJX2 series), single footprint.** The
   "Rev A can footprint both" idea is contradicted by the frozen BOM, which
   carries exactly one stick and no 5-way switch.
6. **Name — CLOSED: FocalPoint** (repo-wide rename done). Trademark search
   still required before Phase 4 (§7).
