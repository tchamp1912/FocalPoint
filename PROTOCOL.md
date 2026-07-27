# FocalPoint Protocol v0.2

The contract between the **host daemon** (`focalpointd`), the **keyboard firmware**,
and **agent adapters**. Implementations MUST NOT change wire formats below
without bumping the protocol version. Details not specified here are
implementation-defined.

---

## 1. Agent states

Canonical state names and numeric IDs, used across all layers:

| ID | Name | Meaning | Default LED effect |
|----|------|---------|--------------------|
| 0 | `idle` | No agent session active | dim white breathing |
| 1 | `thinking` | Model is reasoning | purple pulse |
| 2 | `running` | Executing a tool/command | amber chase |
| 3 | `waiting` | Blocked on user input/approval | blue slow blink |
| 4 | `done` | Turn/task finished | green solid (fades to idle after 30 s) |
| 5 | `error` | Failure needing attention | red blink |

## 2. Device transport: USB Raw HID

- QMK Raw HID interface: usage page `0xFF60`, usage `0x61`, **32-byte** reports.
- Byte 0 of every report is the command ID. Unused trailing bytes are `0x00`.
- Device identifies as VID `0xFEED`, PID `0x5642` ("VB"), usage per above.
  (Phase 0 off-the-shelf boards may differ; the daemon matches on usage page.)

### Host → device

| Cmd | Name | Payload |
|-----|------|---------|
| `0x00` | `PING` | byte 1: protocol major, byte 2: minor |
| `0x01` | `SET_STATE` | byte 1: state ID (table above). The AGGREGATE state; firmware renders it on the ambient zone (status bar / dedicated keys), NOT on numbered keys that have a `SET_KEY_STATE`. |
| `0x02` | `SET_LED` | byte 1: LED index (0xFF = all), bytes 2–4: R,G,B. Overrides effect until next `SET_STATE`. |
| `0x03` | `SET_HOST_MODE` | byte 1: 1 = daemon attached (keys report via HID events), 0 = detached (keys send their fallback keycodes) |
| `0x04` | `SET_KEY_STATE` | byte 1: user-key number 1–12, byte 2: state ID, or `0xFF` = slot empty (key returns to ambient/off). Firmware renders that state's effect on that key's LED only. |
| `0x05` | `SET_STATE_STYLE` | byte 1: state ID, bytes 2–4: R,G,B, byte 5: pattern (0 solid, 1 breathe, 2 blink, 3 strobe, 4 off), bytes 6–7: period in ms (little-endian u16). Overrides that state's default effect everywhere it renders (aggregate and per-key). Stored in RAM; defaults restored on power cycle. The daemon pushes all six styles on device connect. |

### Device → host

| Cmd | Name | Payload |
|-----|------|---------|
| `0x80` | `PONG` | byte 1: protocol major, byte 2: minor, byte 3: firmware key count |
| `0x81` | `KEY_EVENT` | byte 1: control ID (below), byte 2: 1 = pressed, 0 = released |
| `0x82` | `DIAL` | byte 1: signed int8 delta (clockwise positive) |
| `0x83` | `JOY` | byte 1: gesture — 0 N, 1 E, 2 S, 3 W, 4 press |

### Control IDs (byte 1 of `KEY_EVENT`)

| ID | Control |
|----|---------|
| 0 | accept |
| 1 | reject |
| 2 | new-task |
| 3 | push-to-talk (sends press AND release) |
| 4–15 | user keys 1–12 |
| 16 | dial press |

Firmware MUST keep working as a plain Vial macropad when no daemon has sent
`SET_HOST_MODE 1` (and revert on USB disconnect/suspend).

## 3. Daemon API (adapters → `focalpointd`)

- Unix domain socket: `$XDG_RUNTIME_DIR/focalpoint.sock`, falling back to
  `~/.local/state/focalpoint/focalpoint.sock`. (Windows: named pipe `\\.\pipe\focalpoint`.)
- Newline-delimited JSON, one object per line.

Requests:

```json
{"cmd": "set-state", "state": "thinking", "session": "optional-id",
 "kind": "claude", "label": "focalpoint", "meta": {"cwd": "/path"}}
{"cmd": "get-state"}
{"cmd": "list-sessions"}
{"cmd": "rename-session", "session": "id", "name": "Backend"}
{"cmd": "end-session", "session": "id"}
{"cmd": "set-led", "index": 3, "rgb": [255, 0, 128]}
{"cmd": "get-styles"}
{"cmd": "set-style", "state": "waiting", "rgb": [30, 144, 255],
 "pattern": "blink", "period_ms": 800}
{"cmd": "set-usage", "provider": "claude",
 "usage": {"five_hour_used": 42.5, "five_hour_resets_at": 1738425600,
           "seven_day_used": 18.0, "seven_day_resets_at": 1738600000}}
{"cmd": "get-usage"}
{"cmd": "subscribe"}            // stream of event objects follows
{"cmd": "inject", "kind": "key", "control": "accept", "action": "tap"}
{"cmd": "inject", "kind": "dial", "delta": 1}
{"cmd": "inject", "kind": "joy", "gesture": "north"}
```

### Sessions

A `set-state` carrying a `session` id implicitly registers that session on
first sight. `kind` is a free-form tool identifier (`claude`, `codex`,
`openrouter`, …); `label` and `meta` (arbitrary object; `cwd` is the
well-known key) are optional and merge into the session record on any
subsequent `set-state`.

- Each session claims the **lowest free numbered key** (1–12) at registration
  and keeps that slot for its lifetime; slots never shift. Sessions beyond 12
  are tracked with `slot: null`.
- A session ends via `end-session`, after `session_ttl_minutes` (config,
  default 60, 0 = never) without an update, or — for a session carrying a
  `tty` in `meta` (the well-known key set via `--meta tty=$(tty)`, e.g. by
  the Claude Code adapter) — the moment that pty device stops existing on
  disk. The daemon sweeps for this every 30s, independent of
  `session_ttl_minutes`; it's a hard OS fact (closing the terminal destroys
  its pty) rather than a guess, so it reaps a dead session far sooner than
  the TTL fallback without the false-positive risk of inferring death from a
  failed window-focus attempt. Sessions with no `tty` are unaffected. Any
  end reason frees the session's slot (`SET_KEY_STATE slot 0xFF` on the
  device).
- A `set-state` with **no** `session` sets the sessionless default session:
  it occupies no slot but participates in the aggregate (back-compat).
- `rename-session` sets a session's user-assigned `name`, which front-ends
  display **in preference to `label`** (falling back `name` → `label` →
  `kind`). `name` is a distinct field from `label` because adapters re-send
  `label` on every `set-state`, which would otherwise overwrite a rename on
  the session's next state change; nothing but `rename-session` writes
  `name`. The value is trimmed, and an empty or omitted `name` clears the
  rename. Renaming broadcasts a `session` event but does **not** count as
  session activity, so it never extends `session_ttl_minutes`. Renaming an
  unknown session is an error. Names live only as long as the session: they
  are not persisted across `end-session`, TTL expiry, or a daemon restart.
- The **aggregate state** is the worst state across all live sessions:
  `error > waiting > running > thinking > done > idle`. `get-state`, the
  `state` event, and device `SET_STATE` all carry the aggregate.
- Device mapping: the daemon sends `SET_KEY_STATE <slot> <state>` on every
  session change, and `SET_STATE <aggregate>` when the aggregate changes.

### Focus (bouncing between sessions)

When a numbered key whose slot has a live session is pressed, the daemon runs
the `[session] focus` action (config §5) instead of that key's `[actions]`
entry, with the session exposed in env vars: `FOCALPOINT_SESSION_ID`,
`FOCALPOINT_SESSION_KIND`, `FOCALPOINT_SESSION_LABEL`, `FOCALPOINT_SESSION_NAME`,
`FOCALPOINT_SESSION_DISPLAY`, `FOCALPOINT_SESSION_CWD`, `FOCALPOINT_SLOT`.
(`FOCALPOINT_SESSION_DISPLAY` is the resolved `name` → `label` → `kind` a UI
would show; `FOCALPOINT_SESSION_NAME` is empty unless the user renamed it.)
Keys with empty slots fall back to their normal `[actions]` mapping.

`inject` feeds a synthetic device event through the same dispatch path as real
hardware input (actions fire, subscribers see the event). It exists for
testing and for virtual-device front-ends (e.g. hotkeys standing in for
physical keys before hardware exists). `action` is `press`, `release`, or
`tap` (press immediately followed by release).

Responses / events:

```json
{"ok": true}
{"ok": true, "state": "thinking"}
{"ok": true, "sessions": [{"session": "id", "kind": "claude", "label": "focalpoint",
                           "name": "Backend", "slot": 1, "state": "waiting",
                           "meta": {"cwd": "/path"}}]}
{"event": "state", "state": "thinking"}
{"event": "session", "session": "id", "kind": "claude", "label": "focalpoint",
 "name": "Backend", "slot": 1, "state": "waiting", "meta": {"cwd": "/path"}}
{"event": "session-ended", "session": "id", "slot": 1}
{"event": "key", "control": "accept", "pressed": true}
{"event": "dial", "delta": 2}
{"event": "joy", "gesture": "north"}
```

`list-sessions` returns live sessions in slot order (slotless ones last).

### Account usage

`set-usage` records a provider-wide usage snapshot independently of agent
sessions, so an account-level quota remains visible after an individual session
ends. `provider` is a free-form identifier such as `claude` or `codex`;
`usage` must be an object whose values are numeric. A later snapshot merges
into the provider's record and is immediately broadcast:

```json
{"event":"usage","provider":"claude",
 "usage":{"five_hour_used":42.5,"five_hour_resets_at":1738425600,
          "seven_day_used":18.0,"seven_day_resets_at":1738600000}}
```

`get-usage` returns every recorded provider snapshot:

```json
{"ok":true,"usage":{"claude":{"five_hour_used":42.5}}}
```

Usage is retained for the daemon lifetime. Clients should treat it as
last-known data and display the update time when freshness matters. On
`subscribe`, the daemon sends a `usage` event for every recorded provider
after the session snapshot.

### Styles

Every state has a render **style**: `rgb` + `pattern`
(`solid|breathe|blink|strobe|off`) + `period_ms`. Defaults are the §1 table.
`set-style` updates one state's style: the daemon persists it to the
`[styles]` config section, broadcasts
`{"event":"style","state":"waiting","rgb":[…],"pattern":"blink","period_ms":800}`
to subscribers, and pushes `SET_STATE_STYLE` to the device. `get-styles`
returns all six. Renderers (firmware, menu bar, backlight) MUST honor styles
where physically possible (single-color channels use pattern + brightness and
ignore hue). The `subscribe` snapshot includes one `style` event per state.

On `subscribe`, the daemon immediately sends the current aggregate as a
`state` event plus one `session` event per live session, then streams: every
aggregate change, every session change (registration included), session ends,
and every device event (real or injected).

State names in JSON are the lowercase names from §1 (`running` not
`running-tool`).

## 4. CLI (stable interface for adapters and scripts)

```
focalpoint set-state <idle|thinking|running|waiting|done|error>
        [--session ID] [--kind KIND] [--label LABEL] [--cwd PATH]
        [--meta KEY=VALUE]...
focalpoint get-state        # aggregate
focalpoint sessions         # list live sessions in slot order
focalpoint rename-session <ID> [NAME]   # omit NAME (or pass "") to clear
focalpoint end-session <ID>
focalpoint set-led <index|all> <r> <g> <b>
focalpoint watch            # prints events as NDJSON to stdout (incl. state/session events)
focalpoint ping             # exits 0 if daemon and device are up
focalpoint inject key <control> <press|release|tap>   # synthetic device input
focalpoint inject dial <delta>
focalpoint inject joy <north|east|south|west|press>
focalpoint styles [--json]
focalpoint set-style <state> <r> <g> <b> <solid|breathe|blink|strobe|off> [period_ms]
focalpoint set-usage <provider> [--meta KEY=VALUE]...
focalpoint usage [--json]
```

(`--cwd` populates `meta.cwd`. `--meta` sets an arbitrary extra key, repeatable;
values that parse as a number are stored numerically, everything else as a
string. Well-known numeric keys the menu bar app renders as optional stat
badges next to a session's elapsed time: `tokens_in`, `tokens_out`,
`tool_calls`, `turns`. Any adapter may send some, all, or none of them — the
UI simply omits a badge whose key is absent for a given session.)

`set-usage` accepts numeric `--meta` values only. Well-known Claude Code keys
are `five_hour_used`, `five_hour_resets_at`, `seven_day_used`, and
`seven_day_resets_at`; the status-line reporter forwards them without prompts,
tool input, or transcript content.

`focalpoint` is a thin client over the socket; `focalpointd` is the daemon (also
runnable as `focalpoint daemon`).

## 5. Daemon actions (device events → agent)

Configured in `~/.config/focalpoint/config.toml`. The daemon executes actions on
device events; defaults target the focused terminal via synthesized keystrokes
(macOS: CGEvent / osascript). Example:

```toml
[actions]
accept  = { type = "keystroke", keys = "enter" }
reject  = { type = "keystroke", keys = "escape" }
new-task = { type = "shell", run = "open -a Terminal" }

[joystick]
north = { type = "paste", text = "Review this PR and summarize the risks." }

[dial]
mode = "shell"
cw   = "echo effort-up"
ccw  = "echo effort-down"

[session]
# Runs when a numbered key with a live session is pressed (see §3 Focus).
# The session is exposed via FOCALPOINT_SESSION_* env vars.
focus = { type = "shell", run = "~/.config/focalpoint/adapters/focus-session.sh" }
ttl_minutes = 60   # end sessions with no updates for this long (0 = never)

# Per-state render styles (§3 Styles). Omitted states use the §1 defaults.
# The daemon rewrites this section when it receives `set-style`.
[styles.waiting]
rgb = [30, 144, 255]
pattern = "blink"        # solid | breathe | blink | strobe | off
period_ms = 800
```

Action types: `keystroke`, `paste`, `shell`, `none`.
