# FocalPoint

An open-source agent macropad — an open-hardware take on the OpenAI × Work
Louder **Codex Micro**, but agent-agnostic. RGB keys mirror your coding agent's
live status (thinking / running / waiting / done / error); physical keys, a
rotary dial, and a joystick drive the agent loop: accept, reject, new task,
push-to-talk, reasoning level, canned workflows.

Works with **Claude Code**, **Codex CLI**, or anything that can run a shell
command on lifecycle events.

<p align="center">
  <img src="docs/assets/focalpoint-live-sessions.png" width="535" alt="FocalPoint showing live Claude Code, Codex, and Cursor sessions with status, model, context, token, tool, turn, subagent, cost, and account-usage telemetry">
</p>

<p align="center"><em>One glance for every agent: live state, session telemetry, context pressure, and provider quota.</em></p>

## What it does

- **One live dashboard for every agent.** Track Claude Code, Codex CLI, and
  Cursor sessions together, with stable numbered slots for keyboard and
  macropad navigation.
- **Rich session telemetry.** See model, input/output tokens, tool calls,
  turns, subagents, cost, and a context-window gauge whenever the provider
  exposes them.
- **Attention you can feel.** Waiting and error states light the hardware,
  badge the menu-bar icon, and surface in the optional desktop overlay.
- **Provider usage at a glance.** Monitor Claude, Codex, and Cursor quota
  periods and their reset times without leaving the agent loop.
- **Fast session control.** Focus, rename, reorder, or end sessions from the
  native macOS UI; bind the same workflow to global hotkeys or physical
  controls.
- **A UI that fits your desk.** Use the compact menu, a movable translucent
  desktop widget, per-state colors and animation patterns, configurable stat
  badges, budget alerts, quick actions, and local session history.

## Repo layout

| Directory | Contents | License |
|---|---|---|
| [`daemon/`](daemon/) | `focalpointd` host daemon + `focalpoint` CLI (Rust) | MIT |
| [`firmware/`](firmware/) | QMK/Vial firmware for the RP2040 board | GPLv2 |
| [`adapters/`](adapters/) | Claude Code, Codex CLI, and generic integrations | MIT |
| [`hardware/`](hardware/) | KiCad PCB (rev A: KB2040 module, Choc hot-swap) | CERN-OHL-S |
| [`case/`](case/) | 3D-printable case | CERN-OHL-S |
| [`docs/`](docs/) | Build guide | CC-BY-SA |

Key documents:

- [`PLAN.md`](PLAN.md) — project plan, hardware spec, roadmap
- [`PROTOCOL.md`](PROTOCOL.md) — the v0.1 contract between firmware, daemon,
  and adapters (HID reports, socket API, CLI)

## Architecture

```
Claude Code / Codex CLI / any tool
        │ hooks → `focalpoint set-state …`
        ▼
focalpointd ──(config.toml actions)── keystrokes/scripts back to the agent
        │ USB Raw HID
        ▼
the macropad: LEDs ← agent state · keys/dial/joystick → events
```

## Quick start

```sh
git clone <this repo> && cd focalpoint
./install.sh
```

One command builds the daemon, wires up the Claude Code adapter, builds the
macOS menu bar app and backlight helper (if present in your checkout), and
installs a launchd agent so `focalpointd` runs automatically. It's safe to
re-run any time — every step checks what's already there before touching it.
No FocalPoint hardware yet? Pass `--mock` to run the daemon in
`--mock-device` mode instead. See `./install.sh --help` and
`./uninstall.sh --help` for options (including `uninstall.sh --dry-run`).

## Status

Early development. The daemon has a `--mock-device` mode so the full software
stack is testable without any hardware (Phase 0); rev A PCB is next.
