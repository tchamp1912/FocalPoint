# Attention orchestrator: a semi-context-aware supervisor for your attention

**Status: DESIGN DRAFT — nothing implemented yet.** This file is a scoping
spec, written so a fresh agent (or a future you) can pick it up cold and build
it. All paths are repo-root-relative (this file lives at the repo root
alongside `PLAN.md` / `PROTOCOL.md`; the completed session-identity design is
documented in `docs/session-identity-persistence.md`).
If you're that agent: read `CLAUDE.md` first for repo conventions and
`PROTOCOL.md` §3–§5 for the socket API this is built on, then this file in
full. The Context/Why notes explain decisions that were reached by rejecting a
simpler first idea — don't re-litigate them without reading why.

## What it is

An **attention orchestrator**: an opt-in supervisor whose only job is to manage
*your* attention across multiple simultaneous agent sessions. It is
context-aware in a semantic (not purely rule-based) way — it understands your
high-level priorities for the day and ranks what deserves your attention
accordingly. It does only **low-risk, reversible** things by default, and every
action that could reach an agent is gated behind an explicit opt-in.

It is **just another socket client** — like `app/` or any adapter. It speaks no
HID, reimplements no state logic, and adds no new authoritative surface. Per
`CLAUDE.md`'s architecture rule, everything it does goes through the
`focalpoint` CLI / Unix-socket JSON API (`PROTOCOL.md` §3–§5). This is the
non-negotiable framing: the wire is already done, the orchestrator only adds
*judgment* on top of it.

## Core invariants (do not violate)

1. **Slots stay put; attention is a separate ordering.** Session numbered-key
   slots are sticky-for-life by design (`PROTOCOL.md` §3) so "my backend agent
   is key 3" stays true for muscle memory and any slot-bound hotkey. The
   orchestrator **never calls `swap-slots`.** Attention priority is its own
   orthogonal ranking that drives only *the order in which you're told about
   things* (notification order, focus order when several sessions want you at
   once, an optional "who needs me" sorted view). Key N stays key N.
2. **A nudge is a proposal.** Input reaches an agent only after either an
   explicit confirming press (default) or an explicitly-enabled, clearly-flagged
   auto-dispatch mode (below). The orchestrator never silently types into a
   session under the default configuration.
3. **Answering an agent's own approval is permanently off — not a setting.**
   The orchestrator will never `inject accept` / `inject reject` to resolve a
   session's `waiting`-on-approval prompt. That human-in-the-loop is the entire
   reason the device exists. (Distinct from auto-*dispatching a nudge*, which
   is a togglable danger-zone setting — see the ladder.)
4. **Off by default.** `[orchestrator] enabled = false`. Every action class is
   individually toggleable. Graceful degradation everywhere: if the LLM tier is
   asleep or unavailable, the reflex tier keeps running the last policy.

## Architecture: two tiers

Mirrors the daemon's own `session.rs` (pure logic) / `daemon.rs` (effects)
split — semantic judgment is isolated from fast, deterministic reflexes.

### Tier 1 — Reflex layer (no LLM, always on, cheap)

A small, long-running socket client. Subscribes to `focalpoint watch`, keeps
per-session timers, and executes the **current policy** handed down by Tier 2.
Deterministic and instant. Responsibilities:

- Notify / focus on state edges and time thresholds, in **attention-rank
  order** (from Tier 2), per-state configurable (e.g. auto-focus on `error`,
  notify on `waiting`).
- **Stall detection:** flag a session that has sat in `running`/`thinking` past
  a threshold with no meta movement (`turns`/`tool_calls`/`tokens_*`/
  `context_tokens` unchanged), or is `waiting` unusually long. Flagging goes to
  Tier 2; Tier 1 does not itself decide to nudge.
- Drive the notification + nudge-confirm UX (below).

Runs as a launchd companion (like `focalpointd`), or folded into the daemon
behind a config flag. Keeps working on the last policy if Tier 2 is unavailable.

### Tier 2 — Orchestrator layer (LLM, periodic + event-triggered)

A Claude agent (Claude Agent SDK / `claude -p` on a launchd timer or `/loop`),
talking to the daemon over the socket like any other client. Wakes on a cadence
and when Tier 1 flags something ambiguous. Each pass:

1. Reads the world: `sessions` (with `cwd`, `label`, `name`, `model`,
   `cost_usd`, `tokens_*`, `context_tokens`, time-in-state), `usage`, and your
   **daily priorities** (see below). Optionally reads a stalled session's
   Claude Code transcript JSONL (it has the `cwd`/`session_id`) to judge
   "stalled for no reason" vs. legitimately working — this is the reach that
   makes it context-aware.
2. Emits a **policy**: an attention ranking + per-session attention mode
   (notify / focus / ignore) + any **nudge proposals** for stalled sessions.
3. Applies it: hands the ranking + modes to Tier 1; arms nudges (below).
   Optionally `rename-session` to auto-label by priority (cosmetic, low risk).

**Where the attention ranking lives (decided):** internal to the orchestrator
for MVP — it drives notify/focus sequencing only, zero protocol writes, zero
side effects. Rejected for MVP: writing it back as session `meta`
(`attention_rank=…`) so all front-ends could sort by it — because `set-meta`
counts as session activity and would keep idle sessions from ever hitting
`session_ttl_minutes`, turning the orchestrator into an accidental keep-alive.
If the app should later *show* attention order, add a dedicated lightweight
signal (an `attention` event / a sorted-view toggle), don't piggyback on
`set-meta`.

### Daily priorities input

A `~/.config/focalpoint/priorities.md` you jot each morning (or set via a
one-line chat), read verbatim by Tier 2. Simple, transparent, editable. Phase 2
(optional): the Gmail / Calendar MCP connectors could feed "what's on my
calendar / what did I say I'd ship" into the same priority context — flagged as
later scope, not MVP.

### Reading another agent's context (privacy & injection surface)

Tier 2 can locate a session's full transcript deterministically — it holds the
`session` id and `cwd`, which name the file: Claude Code
`~/.claude/projects/<encoded-cwd>/<session_id>.jsonl`, Codex
`~/.codex/sessions/**/*.jsonl` (Cursor has no accessible transcript — the
degraded case). It reads **files**, not the agent's live memory, so it sees the
*full on-disk transcript*, a superset of the live context window (occupancy
itself comes from the `context_tokens`/`context_window` meta). Two consequences
that shape the design:

- **It's a real data egress.** Reading a transcript ships its contents — code,
  prompts, secrets that scrolled through tool output — to whatever model powers
  Tier 2. So `read_transcripts` stays opt-in, and Tier 2 reads only the **tail**
  (last N messages) needed to judge a stall or extract a pending question, never
  the whole file.
- **It's a prompt-injection → action chain.** A transcript can contain
  untrusted content (a fetched web page, a hostile repo file) that tries to
  steer the orchestrator — which can synthesize keystrokes. Mitigations, load-
  bearing: nudge content is **bounded/templated** (resume, or a human-chosen
  answer), never free text lifted from a transcript; the action allowlist is
  narrow; auto-dispatch is off by default. This is the sharpest reason the
  allowlist stays small.

## Managed sessions & the nudge transport

"Managed" is the vocabulary for the whole feature, chosen over "tmux session"
so it names the *capability* (FocalPoint can drive this session) rather than the
mechanism (which could change: tmux today, screen/zellij, or a tool-native
channel someday). Every session is one of:

- **Managed** — running inside a pty multiplexer FocalPoint controls (today:
  tmux). It has a precise input channel, so nudges (`tmux send-keys -t <pane>`)
  and focus (`tmux select-window`) are exact, work in the **background**, need
  **no Accessibility permission**, and never fight the window server.
- **Unmanaged** — a bare terminal. No controllable input channel → the
  orchestrator degrades to the CGEvent fallback (below) or notify-only.

The app should show a small **managed** badge on the row so the state is
visible, and it explains in plain user terms *why* some sessions can be nudged
and others can only be surfaced to you.

### Why the transport matters ("through the tty" is a myth)

Three candidate ways to get input into an agent; only one is both clean and
tool-agnostic:

- **Writing to `/dev/ttysNNN`** hits the terminal's *output*, not the process's
  *stdin* — it never reaches the agent as input.
- **TIOCSTI** (push bytes into another tty's input queue) is the only real
  "inject into a tty" primitive and is **disabled/removed on macOS** (a known
  local-privilege-escalation hole). Linux's `reptyr` pty re-parenting has **no
  macOS equivalent** (SIP/ptrace). So there is no retrofit path on macOS.
- **Synthesized OS keystrokes to the focused window** (CGEvent / osascript —
  what `PROTOCOL.md` §5 `paste`/`keystroke` already do) is the only
  tool-agnostic path, and it is inherently **best-effort and racy**: it lands
  wherever keyboard focus is, needs Accessibility, steals focus, and interleaves
  with your own typing.

So the transport tiers, best first:

1. **Multiplexer write (`tmux send-keys`)** — managed sessions. Precise,
   background, permission-free. Session→pane resolves deterministically: a
   managed session carries `mux_pane` (`%7`) in meta (see hook detection below),
   and a tmux pane has a tty for cross-checking.
2. **Synthesized keystrokes + focus-first (CGEvent)** — the fallback for
   unmanaged sessions. `focus-session <id>` to raise the window, then post
   keystrokes. Kept only so unmanaged sessions degrade rather than fail.
3. **Tool-native IPC** — cleanest semantically, rarely exists for a live
   interactive session; don't count on it.

Both mux config and transcript paths are **private, tool-specific formats** —
best-effort, may change under us (same caveat as the existing Codex `jq`
transcript scan), and degrade to "state + meta only" when unavailable.

### Becoming managed

You can't move an already-running process into a multiplexer on macOS (it's
bound to its terminal's pty; nothing can adopt it after the fact). So a session
becomes managed one of two ways:

- **Launch-time wrapper (the only place mux can be *created*).** A shell
  function / `focalpoint run <cmd>` that `exec`s into tmux *before* the agent
  starts, under an invisible FocalPoint tmux config (`status off`, `mouse on`,
  truecolor passthrough) so it looks and feels close to a plain terminal:

  ```sh
  claude() {
    if [ -z "$TMUX" ]; then
      exec tmux -f ~/.config/focalpoint/tmux.conf new-session -A -s "cc-$$" command claude "$@"
    else
      command claude "$@"
    fi
  }
  ```

- **Right-click "Reopen as Managed Session"** (see below) — promotes an
  unmanaged session in place via quit-and-resume.

**SessionStart hook: detect & register, never create.** The hook fires *after*
the agent is up and in a child process, so it cannot mux the current session.
Its job is only to report managed-ness so the orchestrator picks the right
transport per session. A trivial addition to `adapters/claude-code/hooks.sh`:

```sh
if [ -n "$TMUX" ]; then
  MUX_PANE=$(tmux display-message -p '#{pane_id}' 2>/dev/null)   # e.g. %7
  # → focalpoint set-state … --meta managed=true --meta mux_pane="$MUX_PANE"
fi
```

`managed=true` is the boolean the UI and orchestrator reason about; `mux_pane`
is how. The hook can also *bootstrap* the launch wrapper for next time (a
one-time opt-in hint, or `install.sh` offering to add the shell function) — it
just can't fix the session it's currently in.

**A `managed` behavioral interaction with `PROTOCOL.md` §3:** under tmux the
agent's controlling tty is the persistent tmux pane pty, so **closing the
terminal window no longer kills the agent or triggers the dead-tty sweep** — the
session keeps running detached until the pid sweep or TTL catches it. Arguably
more correct (the agent really is alive, and you can reattach), but it changes
*when* sessions leave the pad, so it's a real behavioral shift, not cosmetic.

### What focus *looks like* for a managed session

Two organizational models, and it's a real UX choice (make it a preference):

- **Shared session, one terminal (the "cockpit" model — most pad-native).** All
  managed agents are *windows in a single tmux session* shown in one terminal.
  Focusing a session is `tmux select-window` / `switch-client` — the one
  terminal's content **flips to that agent in place** (like the pad changing
  channels on one screen). Focus is rock-solid and instant: no window-server
  raise, no AppleScript, just an internal tmux switch (plus raising the terminal
  app to the front if it's behind another app). Trade-off: **one agent visible
  at a time** — focusing another hides the current (unless you split into
  panes). This is the tightest fit for "the pad bounces me between sessions."
- **Session per agent, separate windows.** Each managed agent is its own tmux
  session in its own terminal window. Focus looks like today (raise a distinct
  window) but is more reliable, and you can see multiple agents at once via
  normal macOS window management. Trade-off: more windows to manage.

So the honest answer to "is it one window that just changes the tmux session?":
that's the *cockpit* model, and it's the cleanest — one window, refocus =
`select-window`. But it's a preference, because it costs you the side-by-side
view the per-window model keeps. This choice also shapes the reopen script: the
cockpit model does `tmux new-window -t fp:` in a shared session; the per-agent
model does `tmux new-session -s fp-<id>`. Either way, `focus-session.sh` gains a
**managed branch**: if the session has `mux_pane`, resolve pane → window/session
→ raise the hosting terminal and `select-window`/`switch-client` to it, instead
of the AppleScript tty-matching used for unmanaged sessions (which gets *more*
reliable as a result).

### Right-click: "Reopen as Managed Session"

A new item in the app's existing per-session `.contextMenu`
(`app/Sources/MenuContentView.swift`, alongside rename / Move to Slot / End
Session). Because a live process can't be adopted into a mux, this is a
**quit-and-resume**, not a move:

1. `quit-session` the old process (graceful SIGINT — existing protocol command),
   wait for its pid to clear.
2. `tmux new-session -d -s fp-<id> -c <cwd>` running the tool's **resume**
   command under the invisible FocalPoint tmux config.
3. Open a terminal attached (`tmux attach -t fp-<id>`), or leave detached.
4. The resumed agent's SessionStart hook fires → registers `managed=true` +
   `mux_pane` → now nudge-able.

**The handoff is already solved by machinery you built.** If the resume keeps
the same `session_id` (Claude Code `--resume`), it's a clean reconnect. If it
forks a new id, the **rekey/recovery** logic (`label`+`cwd` ≥2-signal match,
`PROTOCOL.md` §3 — the exact machinery written for compaction continuations)
reunites them, carrying slot, name, and cumulative stats forward. So "reopen"
inherits slot-stickiness and stat-continuity for free — a strong reason it
belongs in *this* app, not a generic tmux tool.

Keep the logic out of Swift: a `reopen-session.sh` adapter script dispatched by
`kind` (like `focus-session.sh` → `focus-cursor.sh`), invoked via `focalpoint
reopen-session <id>`. The menu item just fires it; the tool-specific resume
knowledge lives in one script. Resume commands are per-tool: Claude Code
`claude --resume <session_id>`, Codex `codex resume` (thread-id), **Cursor:
unsupported** (IDE, no headless resume — grey the item out).

UI gating and honest caveats (surface in the menu):

- **Only offer it for unmanaged sessions of a resumable `kind`.** Grey out for
  already-managed rows and for Cursor.
- **It interrupts in-flight work** — `--resume` restores the *transcript*, not a
  mid-turn tool execution. Gate on state: offer only when `idle`/`waiting`/
  `done`, not actively `running` (otherwise you kill a running command).
- **Visible churn** — a new terminal window appears; the old one is left with an
  exited agent at a shell prompt. Acceptable for an explicit action.
- **Terminal choice** — the script picks which terminal to spawn/attach (iTerm
  vs Terminal vs a pref), the same ambiguity `focus-session.sh` navigates.

## The nudge-confirm flow

A nudge always targets a *specific, probably-unfocused* session, and — per the
transport above — reaches it via `tmux send-keys` for managed sessions or the
racy `focus-session` + CGEvent fallback for unmanaged ones. Nothing reaches an
agent until the flow below says so.

**Nudge content is minimal by design — never model-authored free text.** A
free-text paste is the biggest injection surface and the least necessary; most
real "stalled for no reason" cases reduce to one of two bounded actions:

- **Resume** — the session is idle at a prompt / a returned turn; the fix is a
  single `Enter` or a templated `"continue"`. ~90% of nudges, near-zero
  injection risk.
- **Answer a specific pending question** — Tier 2 reads the transcript tail,
  sees the agent asked a *bounded* question, and **surfaces that question to
  you**; you answer with a pad accept/reject. The orchestrator delivers your
  bounded choice, never text it composed from (possibly-untrusted) transcript
  content.

So the orchestrator's job is **detect + rank + surface the real question**; the
delivered keystroke is templated or human-chosen, never a mystery paste.

1. Tier 1 flags a stall → Tier 2 decides a nudge is warranted and picks a
   *bounded* nudge (resume, or a surfaced question).
2. Orchestrator **arms** the nudge: fires a notification ("Backend stalled 9m —
   accept to nudge, reject to dismiss") and puts the pad into a transient
   **nudge-pending** cue on *that session's key* — a distinct color/strobe so
   it is unmistakably "confirm a nudge," not normal agent state.
3. **Accept** → deliver via the session's transport (managed: `send-keys`;
   unmanaged: `focus-session` + CGEvent). **Reject** → dismiss and snooze nudges
   for that session a while. **Timeout** → auto-dismiss, back to normal.

### Confirm mechanism (decided: daemon-side modal capture; app-owned fallback)

The catch: `accept`/`reject` already mean "send Enter/Escape to the focused
terminal," and the daemon fires that `[actions]` keystroke **and** broadcasts
the key event to subscribers simultaneously — so merely watching the stream for
an accept press would *also* send Enter to whatever's focused.

**Recommended — daemon-side modal capture (additive, v0.3-flavored).** A small
new command: the orchestrator `arm-nudge {session, prompt}` puts the daemon into
a transient nudge-pending mode; while armed, the next `accept`/`reject` is
**captured** — its normal keystroke action **suppressed** — and instead resolves
the nudge, emitting a `nudge-resolved` event; the mode times out on its own and
shows a distinct LED cue. This makes the pad's own accept/reject keys the
confirm gate (the device's whole reason to exist). Cost: a transient daemon mode
+ action suppression + LED cue. Keep it strictly additive — no v0.2 message
changes meaning.

**Fallback — app-owned hotkey (no daemon change).** The app already registers
global hotkeys via Carbon and speaks the socket. The orchestrator emits a
`nudge` event; the app shows a notification (with Accept/Reject action buttons)
and arms a temporary hotkey pair, reporting the result back over the socket. The
pad's accept/reject stay untouched. This is the path for the no-hardware /
`mac-virtual` rig.

## The nudge safety ladder (three modes + two permanent never-automatics)

Per-session-class configurable. The dangerous rung is allowed but off and
clearly marked.

1. **Notify-only** (default) — orchestrator tells you; you act.
2. **Confirm-with-press** — armed nudge resolved by a pad accept/reject (modal
   capture above).
3. **Auto-dispatch** — delivers the (bounded) nudge via the session's transport
   *without* confirmation. **Default off.** Settings must present it in a "danger
   zone" with plain-language warning that it types into a running session on your
   behalf. **Built-in guardrail even when on: never fires on a `waiting`
   session** (one blocked on an approval) — delivering into a live approval
   prompt is where auto-injection gets genuinely risky, so that class always
   requires a press regardless of the toggle. Note it is *less* dangerous for a
   managed session (deterministic pane + bounded content) than for an unmanaged
   one (racy CGEvent), but it is still typing into a live session either way.

**Permanently never automatic (not settings):**

- Answering an agent's own approval (`inject accept`/`reject` to resolve a
  `waiting` prompt). Invariant 3.
- `quit-session` (SIGINT the real process) and `end-session`. The sharpest
  edges — the orchestrator may *suggest* these via notification, never execute
  them autonomously.

## Action allowlist summary

| Action | Primitive | Auto by default? |
|--------|-----------|------------------|
| Read state | `sessions`, `get-state`, `usage`, `watch` | yes |
| Read transcript (context) | tool JSONL tail by `cwd`/`session_id` | yes (opt-in flag) |
| Attention ranking | internal → notify/focus order | yes |
| Notify | notification | yes |
| Focus | managed: `tmux select-window`; unmanaged: `focus-session <id>` | configurable (per-state) |
| Auto-label | `rename-session` | configurable (cosmetic) |
| Promote to managed | `reopen-session <id>` (quit-and-resume) | **no — explicit right-click only** |
| Nudge (propose) | arm-nudge → notify + pad cue | configurable |
| Nudge (dispatch) | managed: `send-keys`; unmanaged: `focus-session` + CGEvent | **no — danger-zone opt-in, bounded content, excludes `waiting`** |
| Answer approval | `inject accept`/`reject` | **never (not a setting)** |
| Quit / end session | `quit-session` / `end-session` | **never (suggest only; `reopen-session` uses `quit-session` only on explicit click)** |

## Config sketch (`~/.config/focalpoint/config.toml`)

```toml
[orchestrator]
enabled = false                 # master switch (invariant 4)
priorities_file = "~/.config/focalpoint/priorities.md"
tier2_interval_secs = 180       # LLM priority-pass cadence
read_transcripts = false        # opt-in context reach (tool JSONL tail only)
transcript_tail = 40            # max messages read per stall check

[orchestrator.attention]
# per-state: "notify" | "focus" | "both" | "ignore"
waiting = "notify"
error   = "both"

[orchestrator.stall]
running_stall_secs  = 300       # running/thinking + no meta movement past this → flag
waiting_stall_secs  = 600

[orchestrator.nudge]
mode = "confirm"                # "notify" | "confirm" | "auto"  (auto = danger zone)
content = "resume"              # "resume" (templated) | "question" (surface bounded Q)
snooze_secs = 900
# auto mode NEVER fires on a `waiting` session regardless of this block

[orchestrator.managed]
# tmux transport for managed sessions.
layout = "cockpit"              # "cockpit" (one terminal, select-window) | "per-agent" (window each)
tmux_conf = "~/.config/focalpoint/tmux.conf"   # invisible config: status off, mouse on, truecolor
```

## MVP cut (build order)

1. **Tier 1 reflex watcher** — subscribe to `watch`; notify + configurable
   auto-focus on `waiting`/`error`; stall detection/flagging. Delivers
   attention routing immediately, no LLM.
2. **Tier 2 v1** — periodic pass: read `sessions` + `usage` + `priorities.md`,
   compute attention ranking, hand it to Tier 1, send ranked "needs attention"
   notifications. **Read + rank + notify only — no injection.**
3. **Managed sessions** — invisible `tmux.conf` + launch wrapper /
   `focalpoint run`; `hooks.sh` detection of `managed`/`mux_pane`; managed
   branch in `focus-session.sh`; app "managed" badge. This unlocks the clean
   nudge/focus transport before any nudging ships.
4. **Reopen as Managed Session** — `reopen-session.sh` (kind-dispatched
   quit-and-resume) + the state-gated `.contextMenu` item.
5. **Nudge ladder rung 1–2** — notify-only, then confirm-with-press (choose
   daemon modal capture vs app-owned hotkey per hardware availability); bounded
   content only.
6. **Transcript-tail reading** and **auto-dispatch danger-zone** (behind the
   guardrails above).
7. **Calendar/Gmail priority context** (optional, last).

## Open questions to resolve before coding

- Confirm mechanism: commit to daemon modal capture, or ship app-owned hotkey
  first and add modal capture with the Rev A firmware? (Leaning: app-owned for
  the current `mac-virtual` rig, modal capture as the hardware lands.)
- Managed layout default: `cockpit` (one terminal, `select-window` — most
  pad-native but one agent visible at a time) vs `per-agent` (a window each,
  side-by-side but more windows). Ship one default, expose both.
- Multiplexer: tmux (has `send-keys`, the reason to pick it) vs a
  lower-chrome option like `dtach` (zero UI but no clean `send-keys`). Leaning
  tmux-with-`status off`.
- Tier 2 host: Claude Agent SDK script vs. a `/loop` Claude Code session vs. a
  scheduled cloud agent — which fits your daily workflow best.
- Does auto-labeling (`rename-session` by priority) help or add noise? Cheap to
  try, easy to gate.
