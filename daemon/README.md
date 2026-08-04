# focalpointd — FocalPoint host daemon + CLI

The host-side bridge for [FocalPoint](../PLAN.md): it pushes a coding agent's live
state to the macropad's RGB keys and turns key/dial/joystick events into agent
actions. It implements [`PROTOCOL.md`](../PROTOCOL.md) v0.3 (the wire contract;
the v0.3 material in PROTOCOL.md §6 is a draft and not implemented here).

Two binaries, one crate:

- **`focalpointd`** — the daemon. Talks USB Raw HID to the device and serves a
  Unix-socket API.
- **`focalpoint`** — a thin CLI client over that socket (adapters and scripts call
  it). `focalpoint daemon` runs the daemon too.

## Build

```sh
cargo build            # debug binaries in target/debug/
cargo build --release  # optimized (LTO + stripped) in target/release/
```

Requires a Rust 2021 toolchain. Dependencies: `hidapi`, `serde`/`serde_json`,
`toml`, `clap`, `dirs`, `tokio`.

## Run

```sh
# With hardware attached:
focalpointd

# No hardware — simulate a device (logs LED writes, reads injected events on
# stdin). Great for developing adapters:
focalpointd --mock-device
# or: focalpoint daemon --mock-device
```

The daemon keeps serving the socket API even with no device attached; it
remembers the last state and pushes it (plus `SET_HOST_MODE 1`) whenever a
device appears, and reconnects automatically on hot-plug.

### CLI

```sh
focalpoint set-state <idle|thinking|running|waiting|approval|done|error|compacting>
        [--session ID] [--kind KIND] [--label LABEL] [--cwd PATH]
focalpoint get-state        # aggregate state (worst across live sessions)
focalpoint sessions [--json]   # live sessions in slot order
focalpoint rename-session <ID> [NAME]   # omit NAME (or pass "") to clear
focalpoint end-session <ID>
focalpoint set-led <index|all> <r> <g> <b>
focalpoint watch            # NDJSON events (incl. state/session/session-ended)
focalpoint ping             # exits 0 iff the daemon AND a device are up
focalpoint inject key <control> <press|release|tap>   # synthetic device input
focalpoint inject dial <delta>                        # e.g. 2 or -1
focalpoint inject joy <north|east|south|west|press>
focalpoint styles [--json]
focalpoint set-style <state> <r> <g> <b> <solid|breathe|blink|strobe|off> [period_ms]
```

Example driving the LEDs from an agent hook:

```sh
focalpoint set-state thinking   # model is reasoning  -> purple pulse
focalpoint set-state waiting    # waiting for user input -> blue slow blink
focalpoint set-state approval   # permission approval needed -> orange fast blink
focalpoint set-state done       # turn finished       -> green
```

### Multi-session tracking

Several agents can drive the pad at once. A `set-state` carrying a `--session`
id implicitly registers that session (PROTOCOL.md §3):

- Each session claims the **lowest free numbered key** (1–12) and keeps that
  slot for its lifetime; slots never shift. Sessions past 12 get `slot: null`.
  The device shows each session's state on its own key via `SET_KEY_STATE`.
- The **aggregate state** — worst across all live sessions,
  `error > approval > waiting > running > thinking > done > compacting > idle` — is what
  `get-state`, the `state` event, and the device's `SET_STATE` (ambient zone)
  report.
- `kind`/`label`/`--cwd` (→ `meta.cwd`) merge into the record on later updates.
- A session ends via `end-session` or after `[session] ttl_minutes` of no
  updates; its slot is then freed (`SET_KEY_STATE <slot> EMPTY`).
- A `set-state` with **no** `--session` is the back-compat *sessionless
  default*: it holds no slot but still counts toward the aggregate.

```sh
focalpoint set-state thinking --session claude-1 --kind claude --cwd ~/proj
focalpoint set-state running  --session codex-1  --kind codex
focalpoint sessions            # table of live sessions (slot order)
focalpoint end-session codex-1
```

**Renaming:** `rename-session` gives a session a user-assigned `name` that
front-ends show instead of the adapter's `label` (precedence: `name` →
`label` → `kind`).

```sh
focalpoint rename-session claude-1 "Backend API"
focalpoint rename-session claude-1        # clear it; the label shows again
```

`name` is a *separate field* from `label` on purpose. Adapters re-send
`--label` on every state change (`adapters/claude-code/hooks.sh` does), so a
rename written into `label` would be wiped the next time the agent changed
state. Nothing but `rename-session` writes `name`. Renaming broadcasts a
`session` event but doesn't count as session activity, so it never extends
`ttl_minutes`. Names are in-memory only: they don't survive the session
ending or a daemon restart.

**Focus:** pressing a numbered key whose slot holds a live session runs the
`[session] focus` action (not that key's `[actions]` entry), with the session
exposed via `FOCALPOINT_SESSION_ID/KIND/LABEL/NAME/DISPLAY/CWD` and
`FOCALPOINT_SLOT` env vars (empty string for missing values; `DISPLAY` is the
resolved `name`/`label`/`kind`). Empty slots fall back to `[actions]`. This
also applies to injected key events.

### Render styles

Every state has a render **style** — `rgb` + `pattern`
(`solid|breathe|blink|strobe|off`) + `period_ms` (clamped 100–5000). Defaults
come from the PROTOCOL.md §1 table; `[styles.<state>]` config entries override
them at startup.

```sh
focalpoint styles                                  # table of all eight styles
focalpoint set-style waiting 30 144 255 blink 800  # change one (persists)
```

`set-style` updates the runtime style, pushes `SET_STATE_STYLE` to the device,
broadcasts a `style` event to subscribers, and **persists** by rewriting only
the `[styles.<state>]` table in `~/.config/focalpoint/config.toml` in place — the
rest of your config (comments, formatting, other sections) is preserved
verbatim (via `toml_edit`). All eight styles are (re)pushed to the device on
connect. Period defaults to the state default when omitted.

### Subscribing to events

`focalpoint watch` (a `subscribe` request) receives, as NDJSON:

- an immediate snapshot on connect: an aggregate `{"event":"state",...}` event
  plus one `{"event":"session",...}` event per live session,
- every subsequent aggregate change and session change (registration included),
  `{"event":"session-ended",...}` when a session ends, and
  `{"event":"session-rekeyed","old_session":...,"new_session":...}` when a
  `compacting` session (PROTOCOL.md §1/§3) is reunited with its
  post-compaction continuation under a new session_id — front-ends should
  relabel their existing record in place rather than treat it as an end,
- one `{"event":"style",...}` per state (all eight) after the state/session
  snapshot events, plus a `style` event on every later `set-style`,
- every device event, real or injected
  (`key` / `dial` / `joy`, per PROTOCOL.md §3).

### Injecting synthetic events

`focalpoint inject` feeds a synthetic event through the **same dispatch path** as
real hardware: configured actions fire and subscribers see the event. Useful
for testing and for virtual-device front-ends (e.g. global hotkeys standing in
for physical keys before hardware exists).

```sh
focalpoint inject key accept tap    # press then release (actions fire on press)
focalpoint inject key reject press  # press only
focalpoint inject dial 2            # dial delta (signed; -1 works directly)
focalpoint inject joy north
```

This is distinct from `--mock-device` stdin injection: `inject` works against
**any** running daemon (real device attached or not), over the socket.

### Mock event injection

With `--mock-device`, type these on the daemon's stdin to simulate the hardware:

```
key <control> [1|0]   # e.g. `key accept 1` (press), `key accept 0` (release)
dial <delta>          # e.g. `dial 2`, `dial -1`  (signed, CW positive)
joy <gesture>         # north | east | south | west | press
```

Control names: `accept`, `reject`, `new-task`, `push-to-talk`, `dial-press`,
and `key1`..`key12` (the 12 user keys).

## Config

`~/.config/focalpoint/config.toml` (or `$XDG_CONFIG_HOME/focalpoint/config.toml`).
Copy [`config.example.toml`](config.example.toml) to get started. A missing file
means every action defaults to `none` — events are still reported over the
socket, but nothing is synthesized.

Actions bind device events to: `keystroke`, `paste`, `shell`, or `none`
(PROTOCOL.md §5). On macOS, `keystroke`/`paste` are synthesized via `osascript`
(System Events); `shell` runs via `sh -c` on every platform. On non-macOS
platforms `keystroke`/`paste` log a warning and are skipped (the socket event is
still delivered). Key actions fire on **press**; the dial runs `cw`/`ccw`
depending on tick direction.

The `[session]` block configures the `focus` action (see Multi-session tracking
above) and `ttl_minutes` (session idle timeout; absent → 60, `0` → never).
`[styles.<state>]` blocks override the default render styles (see Render styles
above); the daemon rewrites them in place on `set-style`.

## Test

```sh
cargo test        # unit tests: protocol encode/decode, config parsing
cargo clippy      # if installed (rustup component add clippy)
```

End-to-end smoke test without hardware (short socket dir avoids the macOS
`SUN_LEN` path limit):

```sh
export XDG_RUNTIME_DIR=/tmp/vk; mkdir -p /tmp/vk
mkfifo /tmp/vk/in; exec 3<>/tmp/vk/in
focalpointd --mock-device < /tmp/vk/in &
focalpoint ping                    # -> "ok: daemon up, device present", exit 0
focalpoint set-state thinking      # -> ok  (daemon logs: LED <- SET_STATE 1)
focalpoint get-state               # -> thinking
focalpoint watch &                 # stream events
printf 'key accept 1\ndial 2\njoy north\n' >&3   # inject -> events appear in watch
```

## Architecture

```
agent adapter ──focalpoint CLI──▶ ┌─────────────── focalpointd ───────────────┐
                                │  tokio UnixListener  (socket API §3)    │
   subscribe ◀───broadcast──────┤    │ set-state/set-led → host mpsc      │
                                │    ▼                                    │
                                │  device thread (blocking)   ── HID §2 ─▶│──▶ macropad
                                │    - reconnect / hot-plug loop          │    LEDs ◀ state
   config.toml ── actions §5 ──▶│    - decode events → actions + broadcast│    keys/dial/joy ▶
                                └─────────────────────────────────────────┘
```

- **`protocol.rs`** — pure codec: state IDs + aggregation priority, 32-byte Raw
  HID report encode/decode (incl. `SET_KEY_STATE`), control/gesture name maps.
- **`session.rs`** — the session registry: slot assignment/reuse, aggregate
  computation, TTL expiry (mockable clock). Pure logic returning `Effect`s the
  daemon translates into device commands + events. Fully unit-tested.
- **`styles.rs`** — per-state render styles: the `Style` model, defaults, period
  clamping, and the `StyleTable`. Fully unit-tested.
- **`config.rs`** — TOML config model and loading (missing file = all `none`),
  plus format-preserving `set-style` persistence via `toml_edit`.
- **`actions.rs`** — action execution (osascript / `sh -c`).
- **`daemon.rs`** — the device thread (real HID or `--mock-device`), the async
  socket server, and event→action dispatch. The device thread does blocking
  HID I/O and talks to the async server via an mpsc (host→device) and a
  broadcast channel (device→subscribers). Current state lives in shared state
  so it survives device disconnects.
- **`paths.rs`** — socket path resolution (`$XDG_RUNTIME_DIR/focalpoint.sock` →
  `~/.local/state/focalpoint/focalpoint.sock`).
- **`client.rs`** — the CLI's synchronous socket client.

### Device matching (PROTOCOL.md §2)

Matches on usage page `0xFF60` / usage `0x61`, preferring VID `0xFEED` /
PID `0x5642` and falling back to any device with that usage page (for Phase 0
off-the-shelf boards). Writes prepend the platform report-ID byte (`0x00`) that
hidapi expects for QMK Raw HID.

## Platform support

macOS and Linux (Unix domain socket). **Windows is stubbed**: the daemon and
client return a clear "named pipe `\\.\pipe\focalpoint` not yet implemented" error
rather than misbehaving.

## License

MIT.
