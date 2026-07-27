# FocalPoint

An open-source agent macropad — an open-hardware take on the OpenAI × Work
Louder **Codex Micro**, but agent-agnostic. RGB keys mirror your coding agent's
live status (thinking / running / waiting / done / error); physical keys, a
rotary dial, and a joystick drive the agent loop: accept, reject, new task,
push-to-talk, reasoning level, canned workflows.

Works with **Claude Code**, **Codex CLI**, or anything that can run a shell
command on lifecycle events.

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
