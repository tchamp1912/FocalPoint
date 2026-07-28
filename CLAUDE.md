# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## What this is

FocalPoint is an open-source, agent-agnostic clone of the OpenAI × Work Louder
"Codex Micro" macropad: a device (real or virtual) whose RGB keys mirror a
coding agent's live status (thinking/running/waiting/done/error) and whose
keys/dial/joystick drive the agent loop (accept/reject/new-task/push-to-talk).
It works with Claude Code, Codex CLI, or any tool that can shell out on
lifecycle events, and supports multiple simultaneous agent sessions, each
claiming its own numbered key.

**`PROTOCOL.md` is the source of truth.** It's the wire/API contract between
every component (HID report layout, the daemon's Unix-socket JSON API, the
CLI, the config schema). Read it before touching daemon, firmware, or app
code — the components don't share a language or process, only this spec.
`PLAN.md` has the original project rationale/roadmap.

## Repo layout and how the pieces connect

```
agent adapter ──focalpoint CLI──▶ ┌─────────────── focalpointd ───────────────┐
                                │  Unix socket API (PROTOCOL.md §3/§4)   │
                                │    ▼                                    │
                                │  device thread (blocking)   ── HID §2 ─▶│──▶ macropad / firmware
                                │    - reconnect / hot-plug loop          │    (or app/ mac-virtual UI)
config.toml ── actions §5 ────▶│    - decode events → actions + broadcast│
                                └─────────────────────────────────────────┘
```

- **`daemon/`** — `focalpointd` (daemon) + `focalpoint` (CLI), Rust. The hub: everything
  else talks to it, never directly to each other. See `daemon/README.md` for
  the full CLI/config/architecture reference — it's kept current and detailed;
  don't duplicate it here.
- **`adapters/`** — shell scripts wiring specific tools to `focalpoint set-state`/
  `end-session`: `claude-code/` (hooks-based, richest integration), `cursor/`
  (Cursor's user-level hooks; no `waiting` state and no token stats, and its
  hooks must never exit 2 or write to stdout), `codex-cli/`
  (native Codex lifecycle hooks; legacy `notify` fallback), `generic/` (wrap any
  command), `mac-virtual/` (the pre-hardware validation rig: a keyboard-backlight
  renderer using the private CoreBrightness API).
- **`app/`** — native SwiftUI menu-bar app (`FocalPoint.app`), swiftc-only build
  (no Xcode project/SPM). Menu-bar dropdown, settings (per-state style editor),
  a draggable desktop widget, and global hotkeys via Carbon — all driven purely
  over the daemon's Unix socket, same as any adapter. See `app/README.md`.
- **`firmware/keychron-v1-max/`** — QMK keymap turning a real Keychron V1 Max
  into FocalPoint hardware over USB Raw HID, implementing PROTOCOL.md §1-§2
  device-side. Lives out-of-tree from a QMK/Keychron fork checkout; see its
  README for the fork URL, build, and flash/unflash procedure.
- **`hardware/`, `case/`, `docs/`** — reserved for the from-scratch open PCB
  (KiCad) and 3D-printable case described in `PLAN.md`; not yet populated.
- **`install.sh` / `uninstall.sh` / `packaging/`** — one-command setup: builds
  the daemon, installs the Claude Code hook (merging into
  `~/.claude/settings.json`, never clobbering), installs a launchd user agent
  (`packaging/dev.focalpoint.daemon.plist`) so `focalpointd` runs at login, builds
  `app/` and the backlight helper if present. Idempotent — safe to re-run.

## Commands

### Daemon (Rust) — `daemon/`

```sh
cargo build --release   # daemon/target/release/{focalpointd,focalpoint}
cargo test               # unit tests: protocol codec, session registry, styles, config
cargo test <name>        # run a single test by name (substring match)
cargo clippy              # requires `rustup component add clippy`
```

No hardware needed for development: `focalpointd --mock-device` simulates the
device (logs LED writes, accepts injected key/dial/joy events on stdin), and
`focalpoint inject ...` drives the same dispatch path over the socket against any
running daemon. `daemon/README.md` has a full copy-pasteable smoke-test
sequence.

### macOS app — `app/`

```sh
cd app && ./build.sh     # swiftc -O, arm64, assembles + ad-hoc codesigns FocalPoint.app
open FocalPoint.app         # or: ./FocalPoint.app/Contents/MacOS/FocalPoint  (logs to stderr)
FOCALPOINT_DEBUG=1 ./FocalPoint.app/Contents/MacOS/FocalPoint   # also logs every socket event
```

No automated tests (SwiftUI/AppKit UI) — verify by running it against a live
`focalpointd` and checking stderr for `connected to focalpointd` / hotkey
registration counts, plus manual visual/interactive checks the agent doing the
work can't perform itself.

### Adapters — `adapters/`

Shell scripts; verify with `bash -n <script>`. They talk to the daemon only
through the `focalpoint` CLI (never assume daemon internals), and every hook
script must silently no-op (exit 0 fast) if `focalpoint`/the daemon is unavailable
— they run inline in an agent's hook lifecycle and must never block or break
the host tool.

### Firmware — `firmware/keychron-v1-max/`

Requires the QMK CLI + ARM toolchain and a clone of Keychron's QMK fork (the
V1 Max isn't in upstream QMK, it's in their `wireless_playground` branch); not
installed in every dev environment. Compiles clean today
(`qmk compile -kb keychron/v1_max/ansi_encoder -km focalpoint`); a prebuilt
`.bin`/`.hex`/`.elf` + `SHA256SUMS` is committed in `build/`. See that
directory's README for the fork branch, flash/bootloader-entry procedure, and
a non-obvious `rules.mk` fix this fork requires (Keychron's own
`raw_hid_receive()` must be excluded via a lazily-expanded `SRC` filter, not
the usual `SRC := $(filter-out …)`, or the build silently drops the ChibiOS
startup code).

### Full install

```sh
./install.sh --yes --mock   # --mock: run focalpointd --mock-device (no hardware attached)
./install.sh --help
./uninstall.sh --dry-run    # preview only; never run the destructive path without checking first
```

## Architecture notes that span files

- **The daemon is the only thing that speaks the wire protocol.** Adapters,
  the app, and hotkey handlers all go through the `focalpoint` CLI or the
  Unix-socket JSON API — never construct HID reports or reimplement
  state logic outside `daemon/src/`. If you're adding a new front-end
  (another platform's menu bar, another agent integration), it should look
  like `adapters/mac-virtual/` or `app/`: a client of the socket API, nothing
  more.
- **Sessions vs. aggregate.** Multiple agents can drive the pad at once; each
  gets a sticky numbered key slot (assigned lowest-free, kept for life,
  PROTOCOL.md §3). Anything that can only show one signal at a time (the
  daemon's own `SET_STATE`, a menu-bar dot, the keyboard backlight) shows the
  **aggregate** — worst state across all live sessions
  (`error > waiting > running > thinking > done > idle`) — not any single
  session's state. Only per-key displays (numbered keys on real/virtual
  hardware) show individual session state via `SET_KEY_STATE`.
  `session.rs` is pure logic (mockable clock, no I/O) returning `Effect`s
  that `daemon.rs` translates into device commands and socket broadcasts —
  keep that separation when extending it.
- **Styles are runtime-configurable and persisted.** `set-style` rewrites only
  the touched `[styles.<state>]` table in the user's `config.toml` via
  `toml_edit`, preserving the rest of the file byte-for-byte (comments,
  formatting, other sections). Don't switch this to a full serialize/rewrite
  round-trip — that was a deliberate choice to keep hand-edited configs intact.
- **Graceful degradation is load-bearing, not optional, throughout:** the
  daemon serves the socket API with no device attached and replays state on
  reconnect; firmware only emits FocalPoint HID events after `SET_HOST_MODE 1`
  and reverts to a plain keyboard otherwise; the app degrades to
  aggregate-only display against an older daemon that lacks session/style
  events; adapters no-op silently if the daemon is down. When changing any of
  these components, preserve the corresponding fallback path.
- **macOS keyboard backlight is a single PWM channel** (`adapters/mac-virtual`,
  private CoreBrightness API) — there is no per-key control on Mac laptop
  keyboards, so that renderer can only ever show the aggregate, never
  per-session state. That's a hardware ceiling, not a bug to fix.
