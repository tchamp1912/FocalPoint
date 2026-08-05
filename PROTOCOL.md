# FocalPoint Protocol v0.3

The contract between the **host daemon** (`focalpointd`), the **keyboard firmware**,
and **agent adapters**. Implementations MUST NOT change wire formats below
without bumping the protocol version. Details not specified here are
implementation-defined.

Sections 1–5 are **v0.3** — the operative contract implemented by the shipped
daemon and firmware. Section 6 is a purely additive **v0.4 DRAFT** covering the
Rev A custom hardware (13th key, capacitive touch, capability descriptor,
mapping profiles) and the BLE transport; nothing in §6 is implemented yet.

---

## 1. Agent states

Canonical state names and numeric IDs, used across all layers:

| ID | Name | Meaning | Default LED effect |
|----|------|---------|--------------------|
| 0 | `idle` | No agent session active | dim white breathing |
| 1 | `thinking` | Model is reasoning | purple pulse |
| 2 | `running` | Executing a tool/command | amber chase |
| 3 | `waiting` | Blocked on ordinary user input | blue slow blink |
| 4 | `done` | Turn/task finished | green solid (fades to idle after 30 s) |
| 5 | `error` | Failure needing attention | red blink |
| 6 | `compacting` | Transient: session is between identities across a Claude Code compaction (§3 Sessions) | slate-grey breathe, dimmed like idle |
| 7 | `approval` | Claude Code permission approval needed (not ordinary user input) | orange fast blink |

`compacting` was added in v0.2, additively (older firmware/clients that only
know ids 0–5 simply fail to recognize it via `from_id`/`from_name` rather than
misrendering it as another state — see §3 for when it's used).

`approval` was added in v0.3. It is distinct from `waiting`: adapters use
`waiting` for ordinary user input and `approval` only when a permission prompt
requires an explicit user decision. Both need attention, while approval ranks
above waiting in the aggregate and attention fallback.

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
| `0x05` | `SET_STATE_STYLE` | byte 1: state ID, bytes 2–4: R,G,B, byte 5: pattern (0 solid, 1 breathe, 2 blink, 3 strobe, 4 off), bytes 6–7: period in ms (little-endian u16). Overrides that state's default effect everywhere it renders (aggregate and per-key). Stored in RAM; defaults restored on power cycle. The daemon pushes all eight styles on device connect. |
| `0x06` | `SET_NAV_STATE` | byte 1: state ID of the next attention session, or `0xFF` when none. Firmware renders it on its dedicated next-attention indicator (Right Arrow on the Keychron V1 Max). |

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
| 17 | attention next (Right Arrow) |
| 18 | attention previous (Left Arrow) |
| 19 | session next (Down Arrow) |
| 20 | session previous (Up Arrow) |

(Protocol v0.3 — DRAFT, §6 — additively assigns IDs 21–22 to the Rev A
hardware's 13th key and capacitive touch region, and reserves 23–31.)

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
{"cmd": "set-meta", "session": "id", "kind": "claude", "meta": {"cost_usd": 0.42}}
{"cmd": "get-state"}
{"cmd": "list-sessions"}
{"cmd": "rename-session", "session": "id", "name": "Backend"}
{"cmd": "set-session-backlogged", "session": "id", "backlogged": true}
{"cmd": "end-session", "session": "id"}
{"cmd": "swap-slots", "session1": "id-a", "session2": "id-b"}
{"cmd": "set-led", "index": 3, "rgb": [255, 0, 128]}
{"cmd": "get-styles"}
{"cmd": "set-style", "state": "waiting", "rgb": [30, 144, 255],
 "pattern": "blink", "period_ms": 800}
{"cmd": "set-usage", "provider": "claude",
 "usage": {"five_hour_used": 42.5, "five_hour_resets_at": 1738425600,
           "seven_day_used": 18.0, "seven_day_resets_at": 1738600000}}
{"cmd": "get-usage"}
{"cmd": "get-attention-order"}
{"cmd": "set-attention-order", "sessions": ["id-a", "id-b"]}
{"cmd": "focus-next-attention"}
{"cmd": "focus-prev-attention"}
{"cmd": "focus-session", "session": "id"}
{"cmd": "launch-session", "provider": "codex", "model": "gpt-5.6-sol", "cwd": "/prepared/path",
 "task": "Implement and test the assigned task.", "task_id": "stable-task-id",
 "role": "worker", "manager_task_id": "project-orchestrator", "channel_id": "ch-1"}
{"cmd": "launch-session", "provider": "cursor", "cursor_mode": "headless", "cwd": "/prepared/path",
 "task": "Implement and test the assigned task.", "task_id": "cursor-task"}
{"cmd": "channel-create", "task_id": "project-orchestrator"}
{"cmd": "channel-post", "task_id": "worker-task", "channel": "ch-1", "kind": "blocker", "body": "Need a decision.", "to": "channel"}
{"cmd": "channel-read", "task_id": "worker-task", "channel": "ch-1", "since": 12, "tail": 20}
{"cmd": "channel-members", "task_id": "worker-task", "channel": "ch-1"}
{"cmd": "channel-close", "task_id": "project-orchestrator", "channel": "ch-1"}
{"cmd": "read-session-transcript", "session": "id", "task_id": "stable-task-id",
 "tail": 20, "search": null}
{"cmd": "stop-orchestrated-session", "session": "id", "task_id": "stable-task-id"}
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

`set-meta` merges `kind`/`label`/`meta` into an **already-registered**
session without touching its `state` (or the aggregate) — for adapters that
learn a new fact about a session (e.g. running cost) on a rail that has no
opinion about live agent state, so calling `set-state` would either require
guessing a state or clobbering the real one. Unlike `set-state`, `session`
is required and an unknown id is a silent no-op: `set-meta` never registers
a new session (a state-less session has no state to key `SET_KEY_STATE`
off of). Staleness is presentation-only; neither `set-meta` nor `set-state`
drives an age-based session removal.

- Each session claims the **lowest free numbered key** (1–12) at registration
  and keeps that slot for its lifetime; slots never shift automatically (a
  session ending never bumps the others down to close the gap). The one
  exception is `swap-slots`, an explicit user action (drag-to-reorder in the
  app's dropdown) that exchanges two live sessions' slots outright. Sessions
  beyond 12 are tracked with `slot: null` and can't participate in a swap —
  there's no slot to give.
- A session ends via explicit `end-session`, or — for a session carrying a
  `tty` in `meta` (the well-known key, resolved by the daemon — see
  **Identity resolution** below) — the moment that pty device stops existing on
  disk. The daemon sweeps for this every 30s; it's a hard OS fact (closing the
  terminal destroys its pty), not an age-based guess. Sessions with no `tty`
  are unaffected. Or —
  for a session carrying a `pid` in `meta` (the well-known key, also resolved
  by the daemon) — the moment `kill(pid, 0)` reports that process gone. Also
  swept every 30s, same hard-fact tier as the tty check, and independent of
  it: `tty` catches "the terminal closed," `pid` catches "the agent itself
  crashed but the terminal is still open" — neither alone covers both failure
  modes. Sessions with no `pid` are unaffected. Time since the last update
  never ends or disconnects a session; front-ends may show it as stale. Any
  end reason frees the session's slot (`SET_KEY_STATE slot 0xFF` on the
  device).
- **Two removal paths.** An explicit `end-session` (adapter `SessionEnd`, or
  a user running `focalpoint end-session`) removes the session outright and
  **never** leaves a recoverable trace — not a tombstone, not a persisted
  snapshot entry worth matching against later. It emits `session-ended`;
  front-ends drop the row. Every other end reason above (TTL idle timeout,
  dead-tty sweep, dead-pid sweep, or a session stuck in `compacting` past its
  grace period — see below) routes through an internal **reap** instead: the
  session drops out of the aggregate and frees its device slot, and its last
  full record is stashed as a **tombstone** for possible recovery — but it
  **stays visible** as a *disconnected* session rather than vanishing. A reap
  emits `session-disconnected` (below); front-ends keep the row, dimmed and
  marked disconnected, until it's recovered, explicitly ended, dismissed by
  the user (an `end-session` on it, which clears the tombstone), or its
  tombstone expires. `list-sessions` includes tombstoned sessions with
  `"connected": false` (live sessions carry `"connected": true`); a tombstone
  reports the slot it last held but no longer occupies it. Tombstones expire
  after `tombstone_ttl_minutes` (config, default 30, `0` = never — see §5);
  an expiring tombstone emits `session-ended` so front-ends drop the row.
- **Compaction (Claude Code adapter only).** Compaction is always a
  session-lifecycle transition in Claude Code (`SessionStart` fires with
  `source: "compact"` on the continuation), but Claude Code exposes no field
  linking that continuation back to the session it replaces — and the
  `session_id` doesn't even always change: an interactive `/compact` in the
  same process typically keeps it, while a background job forced to
  auto-compact mid-run forks a new `claude` process under a genuinely new
  one. Rather than end the session on `PreCompact` (which would wipe its
  meta — `turns`/`tool_calls`/`tokens_in`/`tokens_out`/`cost_usd` — for no
  reason in the common same-id case), the adapter instead calls `set-state
  compacting` on it: a transient, low-priority state (§1) that keeps the
  session's slot, name, and meta exactly as they were.
  - If the *same* `session_id` sends the next `set-state` (the common case),
    it's an ordinary update: state changes normally, meta merges forward as
    always. Nothing was lost.
  - If a *different* `session_id` registers next while a live `compacting`
    predecessor is still within its **5-minute grace period** (the fast
    compaction-continuation path; a still-visible "compacting" key is almost
    always claimed within seconds), the daemon reunites them from pooled
    signals `{label, cwd, tty, pid}`: **at least 2 must agree**, and `cwd`
    alone is never enough. `label`+`cwd` is valid here because Claude Code's
    `ai-title` survives a compaction fork even when pid/tty do not.
  - Tombstones deliberately use a stricter rule: the same incoming provider
    `session_id` always reclaims its own unexpired tombstone. For a *different*
    id, fuzzy recovery is only for a false reap of the **same process**
    (matching pid plus one other signal, such as cwd or tty). A fresh provider
    process must carry the exact `resume_session_id` stamped by the managed
    resume launcher; shared title and cwd are not conversation identity. A
    reunited id takes over the old session's slot, `name`, and merged `meta` in
    place, and the old id is dropped. Ties are broken by most recent activity.
    On reunification,
    **cumulative** meta keys (`turns`, `tool_calls`,
    `subagents`, `tokens_in`, `tokens_out`, `cost_usd`) are **added** to the
    predecessor's totals rather than overwritten; the `compactions` counter
    increments; instantaneous keys (`context_tokens`, `context_window`, `tty`,
    `pid`, `model`, rate-limit fields) are plain overwrites as always —
    resetting `context_tokens`/`context_window` on compaction is correct, not
    a bug. This emits a `session-rekeyed` event (below) immediately before
    the `session` event carrying the continuation's real state. Front-ends
    should relabel their existing record for `old_session` to `new_session`
    in place (preserving name/history/stats), not treat it as an end
    followed by a fresh registration.
  - A session that remains `compacting` beyond the 5-minute matching grace
    stays live. The grace only bounds fuzzy rekey matching; age alone is not
    evidence that the session ended, and front-ends may render it stale.
- **Identity resolution (daemon-side).** For `claude` and `codex` sessions,
  the `focalpoint` CLI resolves `meta.tty` and `meta.pid` automatically when
  `--kind` is passed — adapters no longer walk process ancestry themselves.
  Resolution walks from the calling process up through parents to the
  outermost ancestor whose process name matches the kind (`claude`/`codex`),
  skipping transient helper processes (e.g. Claude Code's `claude daemon run
  --origin transient` subprocess). `tty` comes from the caller's controlling
  terminal (`/dev/tty`), not stdio fds. Results are cached per session at
  `$XDG_STATE_HOME/focalpoint/sessions/<session_id>.json` (falling back to
  `~/.local/state/focalpoint/sessions/…`); `--refresh-identity` forces a
  fresh walk + cache overwrite (adapters pass this on `SessionStart`). An
  explicit `--meta tty=`/`--meta pid=` from the caller skips auto-resolution
  for that key. The cache is deleted on `end-session`. Cursor/generic/unknown
  kinds skip the walk entirely — same as before.
- **Identity model.** `session` (the id) is the only field any daemon logic
  or front-end may treat as authoritative identity — it's what the adapter
  gets directly from its tool (Claude Code's `session_id`, Codex's
  `thread-id`), never derived. `tty` and `pid` are best-effort hints resolved
  as above, not guarantees. They're trustworthy enough to key the tty/pid
  dead-session sweeps because those only ever act within a single session's
  own reported values. **`cwd` is explicitly not unique** — multiple
  simultaneous sessions commonly share one (several agents working the same
  repo) — so nothing may treat cwd-equality alone as session-equality; it
  only contributes to recovery when paired with at least one other agreeing
  signal (see reunification above). Internal bookkeeping keys `_carry_*` may
  appear in `meta` on `list-sessions`/`session` events — safely ignorable by
  clients; they hold the carried-forward base for cumulative stats across
  rekeys/recoveries and are not part of the adapter contract.
- A `set-state` with **no** `session` sets the sessionless default session:
  it occupies no slot but participates in the aggregate (back-compat).
- `rename-session` sets a session's user-assigned `name`, which front-ends
  display **in preference to `label`** (falling back `name` → `label` →
  `kind`). `name` is a distinct field from `label` because adapters re-send
  `label` on every `set-state`, which would otherwise overwrite a rename on
  the session's next state change; nothing but `rename-session` writes
  `name`. The value is trimmed, and an empty or omitted `name` clears the
  rename. Renaming broadcasts a `session` event but does **not** affect
  lifecycle. Renaming an
  unknown session is an error. Names live only as long as the session is live:
  they are not persisted across `end-session`, TTL/reap expiry, or a daemon
  restart (unlike session records, tombstones, and usage — see **Persisted
  state** below).
- **Backlog.** `set-session-backlogged` moves a live session into or out of
  a daemon-owned backlog without ending or disconnecting it. A backlogged
  session remains registered, retains its state, metadata, and history, and
  stays focusable by id (`focus-session`). It carries `"backlogged": true`
  and `"slot": null`, and is excluded from the aggregate state, attention
  order/cycling, sequential session cycling, and numbered hardware keys.
  Parking releases its old slot (`SET_KEY_STATE slot 0xFF` on the device)
  and compacts the remaining active slots to stay contiguous; clearing the
  flag restores active routing and assigns the lowest free slot (or, when
  none is free, an active slotless overflow session). The command is
  idempotent and rejects unknown or disconnected sessions. The flag is
  daemon-owned routing state exposed as a first-class DTO field on session
  rows and live `session` events — never adapter `meta` — and rides the
  persisted snapshot and compaction reunification. Front-ends render
  backlogged sessions in their own section, not the active list, and mirror
  the daemon's routing by excluding them from attention counts.
- **Persisted state.** The daemon writes a snapshot to
  `$XDG_STATE_HOME/focalpoint/state.json` (falling back to
  `~/.local/state/focalpoint/state.json`) on every session-affecting change
  and on `set-usage`. The file holds live sessions, tombstones, and usage
  snapshots and the optional explicit attention order; on startup the daemon
  loads it instead of starting empty,
  reconstructs internal timestamps from the saved wall-clock anchor, and
  runs a one-shot reconciliation (dead tty/pid → reap/tombstone) before
  serving its first request. Missing or corrupt snapshots are a silent
  no-op (start empty). Session `name` values are **not** in the snapshot.
- The **aggregate state** is the worst state across all live sessions:
  `error > approval > waiting > running > thinking > done > compacting > idle`.
  `compacting` sits just above `idle` — it's bookkeeping, not agent work, so
  it must never make the aggregate (or another session's own key) look
  alarming while a session waits to be reunited with its continuation.
  `get-state`, the `state` event, and device `SET_STATE` all carry the
  aggregate.
- Device mapping: the daemon sends `SET_KEY_STATE <slot> <state>` on every
  session change, and `SET_STATE <aggregate>` when the aggregate changes.

### Focus (bouncing between sessions)

When a numbered key whose slot has a live session is pressed, the daemon runs
the `[session] focus` action (config §5) instead of that key's `[actions]`
entry, with the session exposed in env vars: `FOCALPOINT_SESSION_ID`,
`FOCALPOINT_SESSION_KIND`, `FOCALPOINT_SESSION_LABEL`, `FOCALPOINT_SESSION_NAME`,
`FOCALPOINT_SESSION_DISPLAY`, `FOCALPOINT_SESSION_CWD`, `FOCALPOINT_SESSION_TTY`,
`FOCALPOINT_SLOT`.
(`FOCALPOINT_SESSION_DISPLAY` is the resolved `name` → `label` → `kind` a UI
would show; `FOCALPOINT_SESSION_NAME` is empty unless the user renamed it;
`FOCALPOINT_SESSION_TTY` is the session's `tty` meta if the adapter supplied
one, else empty.)
Keys with empty slots fall back to their normal `[actions]` mapping.

`end-session` (`{"cmd":"end-session","session":"id"}`) removes a session from
the registry **non-destructively** — the underlying agent process is left
running; it just drops out of FocalPoint (and any tombstone is cleared, so it
won't be offered for recovery). `quit-session`
(`{"cmd":"quit-session","session":"id"}`) is the **destructive** counterpart:
it asks the agent process itself to exit (SIGINT, a second SIGINT after a
short grace, then SIGTERM — never SIGKILL) so the tool runs its own teardown
and its `SessionEnd` hook fires (which itself calls `end-session`); the daemon
also removes the session as an idempotent safety net once the process is gone.
For a session with no resolved `pid` (Cursor, or one whose identity never
resolved) `quit-session` degrades to a plain `end-session`.

`relaunch-managed-session`
(`{"cmd":"relaunch-managed-session","session":"id"}`) is the explicit
quit-and-resume promotion used by the app's **Relaunch as Managed Session**
action. The daemon accepts only a connected, unmanaged Claude/Codex session
with a positive provider pid, an existing working directory, and an
`idle`/`waiting`/`done` state. It atomically reserves the session's slot, name,
and metadata; rejects late events from the old process; waits for that process
to exit; then starts the fixed provider resume command in detached tmux. No
command, cwd, environment, or prompt is accepted from the client. The reply
contains an opaque `launch_id`. Progress is broadcast as a
`managed-relaunch` event with status `quitting`, `launched`, `complete`, or
`failed`. Only a replacement hook carrying the matching `meta.relaunch_id`
completes the handoff. A launch or registration failure becomes a recoverable
disconnected session; it never falls back to an unmanaged duplicate.

`focus-session` (`{"cmd":"focus-session","session":"id"}`) runs that same
`[session] focus` action for a session looked up **by id** rather than by a
pressed slot — resolving live sessions *and* tombstoned (disconnected) ones.
Front-ends use it to focus a session with no live slot to press: a
disconnected session (its terminal is usually still open — idle past the TTL,
or an agent crash that left the window), or a slotless overflow session (>12
live). Same env vars as above, from the session's last-known values.
Every successful focus path (a session key, arrow navigation, or
`focus-session`) broadcasts `{"event":"focus","session":"id"}` so every
connected FocalPoint UI highlights the selected session.

The daemon owns a complete attention order separately from numbered slots.
`get-attention-order` returns `{"ok":true,"sessions":[...]}`.
`set-attention-order` replaces it and requires every active (non-backlogged)
live session id exactly once; changes broadcast
`{"event":"attention-order","sessions":[...]}`.
Ended sessions are removed, newly registered sessions are appended
deterministically, restored sessions are appended, rekeys retain position, and
the explicit order persists in the daemon snapshot. Without an explicit order
the fallback is error first, then approval, then waiting, then slot and id.
`focus-next-attention` and `focus-prev-attention` wrap an internal cursor
across only active live waiting/approval/error sessions and reply with
`{"ok":true,"session":"id"}` or `session:null`. ("Active" here and above
means non-backlogged — see **Backlog** in §3 Sessions.)

`launch-session` is the daemon's narrow managed-process primitive. It accepts
`claude`, `codex`, or `cursor`, an optional provider model id/alias, an existing
absolute working directory, a literal
non-empty task of at most 16384 UTF-8 bytes, and a stable task id of 1–64
letters, digits, dots, underscores, or dashes. The daemon rejects duplicate
task ids and starts the provider through the installed managed-session
launcher in the terminal selected by the FocalPoint menu-bar app. The daemon
reads that preference for each launch, so changing terminals requires no
daemon restart; a missing or invalid preference falls back to Terminal. It
does not create worktrees, prepare environments, install
dependencies, decompose work, answer approvals, or accept arbitrary shell
commands.

For Cursor, optional `cursor_mode` is `headless` (the default) or `attachable`.
Headless uses the installed stream wrapper and is registered/tracked normally.
Attachable opens Cursor's interactive terminal UI in managed tmux; Cursor does
not emit an interactive lifecycle feed, so that mode is not a live FocalPoint
session and cannot use channels.

The optional `role` is `worker` (the default) or `orchestrator`. A worker may
name a live managed orchestrator's stable task id in `manager_task_id`; an
orchestrator cannot name a manager. The launcher propagates these as
`meta.orchestration_role` and `meta.manager_task_id`, alongside the launched
session's own `meta.orchestrator_task_id`, so clients can render multiple
independent orchestration groups without inferring them from labels.

`read-session-transcript` and `stop-orchestrated-session` require the session
id and its matching stable orchestrator task id. The daemon also requires the
session to be managed and Claude/Codex-owned. Transcript reads
accept a tail of 1–8000 and an optional bounded case-insensitive search, return
normalized user/assistant/tool messages, omit reasoning blocks and raw tool
inputs, and resolve adapter-reported paths only within the provider's local
transcript directory. Stop requests use the same graceful SIGINT-to-SIGTERM
teardown as `quit-session`; they cannot target unrelated sessions.

### Inter-agent channels

Channels are persisted daemon-owned, pull-first mailboxes for one managed
orchestrator and workers it launches. `channel-create` is allowed only for the
live managed orchestrator identified by `task_id`; `channel-post`,
`channel-read`, and `channel-members` require a member's own managed task id;
only the creator can `channel-close`. Bodies are untrusted strings capped at
4096 characters and kinds are `note`, `question`, `progress`, `blocker`, or
`directive`. A worker post always routes to its owner, never a sibling.

`channel-read` returns `messages` and `next_cursor`; omitted `since` uses and
advances the member cursor. Logs retain the newest 100 messages (count-based,
no TTL). `launch-session.channel_id` auto-joins the worker when its adapter
registers it, initializing its cursor at the then-current tail: no pre-join
message is ever returned. Managed idle members may receive a debounced fixed
tmux ping; it contains no message data, and waiting members are never woken.

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
                           "backlogged": false, "connected": true,
                           "meta": {"cwd": "/path"}}]}
{"event": "state", "state": "thinking"}
{"event": "session", "session": "id", "kind": "claude", "label": "focalpoint",
 "name": "Backend", "slot": 1, "state": "waiting", "backlogged": false,
 "meta": {"cwd": "/path"}}
{"event": "session-ended", "session": "id", "slot": 1}
{"event": "session-disconnected", "session": "id", "slot": 1}
{"event": "session-rekeyed", "old_session": "old-id", "new_session": "new-id"}
{"event": "attention-order", "sessions": ["id-a", "id-b"]}
{"event": "focus", "session": "id"}
{"event": "key", "control": "accept", "pressed": true}
{"event": "dial", "delta": 2}
{"event": "joy", "gesture": "north"}
```

`list-sessions` returns active live sessions (`"connected":true`,
`"backlogged":false`) in compact slot order (slotless overflow sessions last),
then backlogged live sessions (`"connected":true,"backlogged":true`), followed
by any tombstoned sessions (`"connected":false`) — sweep-reaped sessions kept
visible for recovery until ended, dismissed, recovered, or expired.
`backlogged` is present on every session row and live `session` event.
`session-ended` removes a row;
`session-disconnected` marks it disconnected (kept, dimmed) rather than
removing it; a live `session` event on that id reconnects it. A
`session-disconnected` event omits `"connected"` (the event name says it);
only `list-sessions` rows carry the explicit boolean.

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

Usage is retained across daemon restarts (via the persisted snapshot above).
Clients should treat it as last-known data and display the update time when
freshness matters. On `subscribe`, the daemon sends a `usage` event for every
recorded provider after the session snapshot.

`openai-api` is reserved by the macOS app for authorized API billing data. Its
numeric `api_spend_usd`, `api_spend_period_started_at`, and
`api_spend_period_ends_at` fields report the current UTC-day Organization Costs
total. It is deliberately a separate provider from `codex`, whose
`primary_*`/`secondary_*` values are ChatGPT rate-limit windows.

The app additionally uses `claude-api` for Anthropic Admin API usage reports
(`api_input_tokens` and `api_output_tokens` for the current UTC day) and
`cursor-api` for Cursor Admin API current-cycle spend (`api_spend_usd`). These
remain separate from the corresponding subscription/quota provider records.

### Styles

Every state has a render **style**: `rgb` + `pattern`
(`solid|breathe|blink|strobe|off`) + `period_ms`. Defaults are the §1 table.
`set-style` updates one state's style: the daemon persists it to the
`[styles]` config section, broadcasts
`{"event":"style","state":"waiting","rgb":[…],"pattern":"blink","period_ms":800}`
to subscribers, and pushes `SET_STATE_STYLE` to the device. `get-styles`
returns all eight. Renderers (firmware, menu bar, backlight) MUST honor styles
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
focalpoint set-state <idle|thinking|running|waiting|approval|done|error|compacting>
        [--session ID] [--kind KIND] [--label LABEL] [--cwd PATH]
        [--meta KEY=VALUE]... [--refresh-identity]
focalpoint set-meta --session ID [--kind KIND] [--label LABEL]
        [--meta KEY=VALUE]... [--refresh-identity]   # merges meta only; leaves live state untouched
focalpoint get-state        # aggregate
focalpoint sessions         # list live sessions in slot order
focalpoint rename-session <ID> [NAME]   # omit NAME (or pass "") to clear
focalpoint end-session <ID>
focalpoint swap-slots <ID1> <ID2>       # exchange two live sessions' numbered-key slots
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
`tool_calls`, `turns`, `cost_usd`, `compactions`, `plan_compactions`. Any adapter may send some,
all, or none of them — the UI simply omits a badge whose key is absent for a
given session. `compactions` counts how many times a conversation's context
has been compacted (Claude Code: daemon-side on PreCompact/rekey/recovery; Codex:
adapter-side transcript scan — same cumulative key, different source).
`plan_compactions` is the Claude Code subset whose `PreCompact` event reported
`permission_mode=plan`; it is counted immediately, including foreground
compactions that keep the same session id.
`cost_usd` is a real running total in US dollars (not an estimate), rendered
as a `$0.42`-style badge; the Claude Code status-line hook is the only
adapter that reports it today (via `set-meta`, since cost arrives on the
status-line rail independently of state changes — see §3). Well-known
string key `model`: the raw model id driving the session (e.g.
`claude-opus-4-8-...`); the menu bar app shortens it to a small badge like
"Opus" or "Sonnet" next to the row. Claude Code only today. Well-known
numeric key `context_tokens`: current context-window occupancy (the latest
usage snapshot), distinct from the cumulative `tokens_in` stat above;
rendered as a thin always-visible fill bar under the row rather than a
badge. Optional numeric key `context_window` supplies the model's total
context capacity; clients prefer it over a model-name lookup when calculating
`context_tokens / context_window`. Claude Code reports occupancy and Codex
reports both values. Well-known numeric key `pid`: the agent process's own
process id (Claude Code/Codex when `--kind` is passed — resolved by the
daemon, see §3) — not rendered by any client, purely for the daemon's
dead-process sweep (§3). Well-known string key `tty`: the session's
controlling terminal device path — same resolution path as `pid`.

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
tombstone_ttl_minutes = 30   # how long a sweep-reaped session stays recoverable (0 = never)

[channel]
# Optional fixed-ping wake for idle managed members. Pull reads still work when off.
wake_managed = true

# Per-state render styles (§3 Styles). Omitted states use the §1 defaults.
# The daemon rewrites this section when it receives `set-style`.
[styles.waiting]
rgb = [30, 144, 255]
pattern = "blink"        # solid | breathe | blink | strobe | off
period_ms = 800
```

Action types: `keystroke`, `paste`, `shell`, `none`.

## 6. Protocol v0.4 — DRAFT (not yet implemented)

> **Status: DRAFT.** Nothing in this section is implemented by the shipped
> daemon, firmware, adapters, or app. It is the design target for the Rev A
> custom hardware (`hardware/`) and its Zephyr/nRF-Connect firmware, published
> here so the daemon, firmware, and hardware teams converge on one contract
> before code exists. Everything is **purely additive** over v0.3: no v0.3
> message changes meaning, no ID is reused, and a v0.3 host talking to a v0.4
> device (or vice versa) keeps working with the v0.3 feature set. Wire details
> marked **TBD** MUST be finalized before firmware work starts; the rest of the
> section may still change until the version is declared stable and the DRAFT
> marker is removed.

Version signaling: a v0.3 device answers `PONG` with minor = 3. A daemon that
sees minor ≤ 3 MUST assume the v0.3 control set (IDs 0–16, no capability
descriptor, no mapping profiles, USB only).

### 6.1 New controls (Rev A hardware)

Rev A exposes 16 physical controls (`hardware/CONTROL_MAPPING.md`): 13 RGB MX
keys (12 frosted selector + 1 ceramic), an EC11 encoder, an analog joystick,
and a capacitive touch region. Twelve selector keys, the encoder, and the
joystick already have v0.2 IDs; v0.4 adds the remaining two:

| ID | Control | Physical ID | Notes |
|----|---------|-------------|-------|
| 21 | key 13 (ceramic action key) | `key_13` | press/release via `KEY_EVENT`, like any key |
| 22 | touch region | `touch_01` | press/release via `KEY_EVENT`; firmware debounces/thresholds, host sees a clean binary contact |
| 19–31 | *reserved* | — | future controls; hosts MUST ignore unknown IDs |

- `SET_KEY_STATE` is unchanged: session slots remain user keys 1–12. `key_13`
  is not a session slot; its LED renders the ambient/aggregate zone by default
  and remains individually addressable via `SET_LED` (index per the capability
  descriptor's LED map). Per CONTROL_MAPPING.md, a control's input mapping and
  its LED identity are independent.
- **Analog joystick (optional, DRAFT):** `0x84` `JOY_XY`, device → host —
  byte 1: signed int8 X, byte 2: signed int8 Y (calibrated, center = 0).
  Emitted at most every 20 ms while deflected, only when host mode is on and
  the active mapping requests axes. Gesture events (`0x83 JOY`) remain the
  default and are always emitted; `JOY_XY` is additive telemetry.

### 6.2 Capability descriptor

v0.3's `PONG` reports only a bare key count. v0.4 extends `PONG` additively —
bytes 4–5 were previously always `0x00`, so a v0.3 device implicitly reports
"no v0.3 capabilities":

| Byte | Meaning |
|------|---------|
| 4 | capability flags: bit 0 `EXTENDED_CAPS` (`GET_CAPS` supported), bit 1 `KEY_13`, bit 2 `TOUCH`, bit 3 `ANALOG_JOY` (`JOY_XY` available), bit 4 `MAPPING_PROFILES` (§6.3), bit 5 `BLE` (device also exposes the §6.4 transport). Bits 6–7 reserved (0). |
| 5 | LED count (0 = unknown/legacy) |

The full descriptor (CONTROL_MAPPING.md "Required protocol/firmware work"
item 1) is fetched explicitly:

| Cmd | Name | Payload |
|-----|------|---------|
| `0x06` | `GET_CAPS` (host → device) | byte 1: page index |
| `0x85` | `CAPS` (device → host) | byte 1: page index, byte 2: total pages, bytes 3–31: page payload |

Page 0 payload (fixed layout, all further pages **TBD**): firmware version
major/minor/patch (3 bytes), control-ID presence bitmap for IDs 0–31 (4 bytes,
LSB first), per-control gesture-support summary (**TBD** encoding: tap / hold /
double-tap / rotate / directions / axes / press), LED count (1 byte), LED
index of `key_13` (1 byte), mapping-profile slot count (1 byte), mapping
storage bytes (u16 LE).

### 6.3 Mapping profiles

Model per `hardware/CONTROL_MAPPING.md`: firmware reports physical IDs and
gestures and never decides what a position *means*; the daemon owns a library
of named, versioned profiles in `config.toml` and pushes at most one profile
into device NVM as the unplugged/fallback behavior. Unknown actions are
rejected, not silently ignored.

HID messages (host → device unless noted):

| Cmd | Name | Payload |
|-----|------|---------|
| `0x07` | `MAP_BEGIN` | byte 1: profile slot (0 = the single NVM fallback slot), byte 2: fragment count, bytes 3–4: total length u16 LE, byte 5: profile format version |
| `0x08` | `MAP_DATA` | byte 1: fragment sequence number (0-based), bytes 2–31: payload |
| `0x09` | `MAP_COMMIT` | byte 1: profile slot, bytes 2–3: CRC-16/CCITT of the assembled profile, u16 LE |
| `0x0A` | `MAP_ACTIVATE` | byte 1: profile slot, or `0xFF` = raw mode (report events only; daemon dispatches everything) |
| `0x86` | `MAP_ACK` (device → host) | byte 1: command being acknowledged, byte 2: status (0 ok, 1 bad CRC, 2 no space, 3 unsupported entry, 4 bad sequence) |

The serialized profile entry format (control ID, gesture, target type,
argument) is **TBD**; targets follow CONTROL_MAPPING.md (FocalPoint action,
session-slot focus, keyboard shortcut, consumer-control event, profile change,
`disabled`).

Socket API additions (shapes indicative, DRAFT):

```json
{"cmd": "get-mappings"}
{"cmd": "set-mapping", "profile": "default", "map": {"key_13": {"tap": "accept"},
 "touch_01": {"tap": "push-to-talk"}}}
{"cmd": "activate-profile", "profile": "default"}
{"event": "mapping", "profile": "default"}
```

Profiles are validated against the capability descriptor before being accepted
or pushed; `set-mapping` with a control/gesture/target the device or daemon
does not know is an error.

### 6.4 BLE transport

Carries the **same 32-byte reports as §2** — one logical report per GATT
write/notification, identical command IDs and payloads — so §1/§3/§5 semantics
are transport-independent. The daemon owns transport selection (PLAN.md §4);
sessions, styles, and actions do not change between USB and BLE.

**GATT layout.** One primary service, three characteristics. All 128-bit UUIDs
below are **PLACEHOLDERS — TBD before any firmware work**; final values must be
freshly generated random (version-4) UUIDs and recorded here:

| Element | Placeholder UUID | Properties |
|---------|------------------|------------|
| FocalPoint service | `F0CA1000-TBD0-4000-8000-000000000000` | primary |
| Command (host → device) | `F0CA1001-TBD0-4000-8000-000000000000` | write, write-without-response |
| Event (device → host) | `F0CA1002-TBD0-4000-8000-000000000000` | notify |
| Capability (page 0 snapshot) | `F0CA1003-TBD0-4000-8000-000000000000` | read |

The device also exposes standard BLE HID (HOGP) for fallback-keyboard input
and Device Information (DIS); the DIS Serial Number string MUST equal the USB
iSerial so the daemon can recognize the same physical device on both
transports.

**MTU and fragmentation.** Reports are fixed at 32 bytes, but the default ATT
MTU (23) carries only 20 payload bytes. The device requests an ATT MTU of at
least 36 (ideally 247) at connection. If the negotiated payload (MTU − 3) is
≥ 33 — one 32-byte report plus the 1-byte fragment header — each
write/notification carries exactly one report prefixed by a fragment header
with both `first` and `last` set. Otherwise reports are
fragmented: every fragment starts with a 1-byte header — bit 7 `first`, bit 6
`last`, bits 0–5 sequence number within the report — and the receiver
reassembles to exactly 32 bytes, discarding any partial report on sequence
error or reconnection.

**Link loss (replaces USB suspend for `SET_HOST_MODE`).** v0.2 reverts to a
plain keyboard on USB disconnect/suspend; BLE has no suspend, so:

- Host mode is cleared on BLE disconnection or supervision timeout.
- Over BLE the daemon MUST `PING` at least every 30 s; firmware clears host
  mode after 90 s without any valid Command write (keepalive lapse — catches a
  daemon that died while the link stays up).
- On reconnect the device stays a plain keyboard until the daemon re-sends
  `SET_HOST_MODE 1`; the daemon replays state and styles exactly as it does on
  USB hot-plug (graceful-degradation contract unchanged).

**Pairing, bonding, authentication.** This channel is a keystroke-injection
surface: device → host events cause the daemon to synthesize keystrokes and
run shell actions (§5), and the fallback HOGP interface is literally a
keyboard. Treat it accordingly:

- LE Secure Connections pairing with bonding is REQUIRED. Legacy pairing is
  rejected.
- The FocalPoint service characteristics require an encrypted link to a bonded
  peer (Security Mode 1 Level 4; whether Level 3 is an acceptable fallback is
  **TBD**). `SET_HOST_MODE 1` is only accepted over an encrypted, bonded link.
- The device has no display; passkey entry via the 12 numbered keys is
  possible and is the preferred MITM protection. Whether Just Works is
  permitted at all — and only inside an explicit, user-initiated pairing
  window (key chord), advertising the service at no other time — is a **TBD**
  policy decision; Just Works with no pairing window is not acceptable.
- The daemon pins the bonded peer identity (identity address / IRK) and MUST
  ignore FocalPoint events from any other peer, even a bonded one, until the
  user explicitly re-pairs.

**USB/BLE arbitration.** Both transports may be connected simultaneously
(e.g. charging over USB while paired). Exactly one transport is the active
control channel at a time:

- USB wins: `SET_HOST_MODE 1` over USB clears any BLE host mode and moves
  event emission to USB. `SET_HOST_MODE 1` over BLE while USB host mode is
  active is ignored.
- Device → host events are emitted only on the active transport. USB power
  without a host-mode daemon (dumb charger) leaves BLE control unaffected.
- The daemon deduplicates the two appearances of one device via the shared
  serial (DIS = iSerial) and MUST NOT hold both transports active at once.
