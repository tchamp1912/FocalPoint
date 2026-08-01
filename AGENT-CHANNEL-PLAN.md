# Inter-agent channels: orchestrator ⇄ worker messaging

**Status: DESIGN DRAFT — co-authored, not yet implemented.** Scoping spec for a
daemon-owned message channel that lets a FocalPoint orchestrator and the workers
it launches exchange structured messages, with an optional wake path for idle
*managed* sessions. All paths are repo-root-relative. Read `CLAUDE.md` for repo
conventions, `PROTOCOL.md` §3–§5 for the socket API this builds on, and
`ORCHESTRATOR-PLAN.md` — this feature reuses that plan's *managed-session
transport* and *nudge safety* analysis rather than re-deriving them.

## What it is

A **channel** is a daemon-owned, persisted mailbox that a set of sessions can
post to and read from. An orchestrator creates a channel, passes its id when it
`launch`es a worker (auto-joining that worker), and the two exchange bounded,
structured messages through the daemon — the same hub every other client already
talks to. It adds coordination *without* adding a new authoritative surface: a
channel is just another daemon object alongside sessions, tombstones, and the
attention order.

Delivery is **pull-first**: agents read their mailbox at natural turn boundaries.
An optional **wake** path can rouse an *idle, managed* member when a message
arrives — but the wake is a fixed, templated ping that only tells the agent
"you have mail," never the message body typed in as free text. The agent then
pulls the body itself. That single choice is what keeps this on the safe side of
the project's "never type model-authored free text into another session"
guardrail.

## Core invariants (do not violate)

1. **The injected keystroke is always a constant.** A wake ping is a fixed
   template (e.g. `run: fpctl-agent channel read ...`). Message *content* is
   never synthesized into another session's input — it travels through the pull
   channel the agent reads on its own. This is the whole reason the design is
   acceptable.
2. **Channel content is untrusted data, never instructions.** An agent treats
   messages as data to consider, exactly like a transcript tail. A message that
   says "delete the repo" is a string, not a command.
3. **Never wake a `waiting`-on-approval session.** Same carve-out as the nudge
   ladder — delivering into a live approval prompt is the riskiest injection.
4. **Ownership-gated, like `stop`/`transcript`.** Only channel members can
   post/read; only the creating orchestrator can close it. `launch --channel`
   is the only way a worker joins.
5. **Off the critical path.** If the daemon has no channel, or the tier is down,
   nothing breaks — agents run exactly as today. Graceful degradation, per
   `CLAUDE.md`.

## Topology: star, not mesh (decided)

Messages flow **orchestrator ⇄ worker only**, not worker ⇄ worker. The
orchestrator is the hub of its channel. Rationale: it matches the actual
supervision relationship, keeps the trust model simple (a worker only trusts its
orchestrator, not sibling workers), and avoids a general message bus. Worker
coordination, if ever needed, routes *through* the orchestrator.

## API surface (`fpctl-agent channel ...`)

```sh
fpctl-agent channel create                      # → { channel_id }
fpctl-agent channel post   --channel <id> --body <text> [--to <session>]
fpctl-agent channel read   --channel <id> [--since <cursor>] [--tail N]   # → messages + next cursor
fpctl-agent channel members --channel <id>
fpctl-agent channel close  --channel <id>
fpctl-agent launch ... --channel <id>           # auto-joins the launched worker
```

- **Message shape:** `{ id, channel, from_session, to (channel|session), ts,
  kind, body }`. `kind ∈ { note, question, progress, blocker, directive }`
  (minimal, extensible). `body` length-capped (e.g. 4096, mirroring
  `fpctl-agent`'s existing sanitization caps).
- **Cursor-based read** so an agent pulls only what it hasn't seen; no
  re-delivery.
- **Late joiners start at the tail (decided).** A session joining a channel
  (via `launch --channel`) has its read cursor initialized to the *current* end
  of the log — it never sees messages posted before it joined. No historical
  backfill on join.
- **Retention:** bounded per channel by **message count** (decided — a rolling
  cap, oldest dropped past the limit; no TTL), persisted in the existing daemon
  `state.json` snapshot alongside sessions/tombstones.

## Delivery tiers (best → worst)

1. **Pull at turn boundary (default, zero injection).** An adapter hook
   (`SessionStart`, and end-of-turn `Stop`) runs `fpctl-agent channel read
   --since <cursor>` and surfaces any backlog into the agent's context. Works
   for any agent that is *already* taking a turn. No wake, no keystrokes.
2. **Wake an idle *managed* member (auto-fires — decided).** When a message
   arrives for a member that is idle + managed, the daemon posts a **fixed
   templated ping** via `tmux send-keys` into that pane. The agent, now
   prompted, pulls the body. Reuses the transport that just landed on
   `worktree-attention-orchestrator`. Because the payload is a constant (not
   message content), this **auto-fires** on managed idle rather than requiring a
   confirm press — it still **excludes `waiting`-on-approval members**, is
   **debounced** per member, and is disableable via a single config flag
   (graceful-degradation default: on for managed sessions).
3. **Unmanaged / Cursor (degraded).** No reliable wake and (Cursor) no
   stdout-writing hook → the message waits for the agent's next turn, and/or a
   human notification surfaces it. Honest second-class behavior, same ceiling as
   the nudge transport.

## Pros and cons

### Pros
- **Fits the architecture with no new authority.** A channel is one more daemon
  object; every client still speaks only the socket API. Nothing reimplements
  state logic or the wire protocol.
- **Pull-first is near-zero risk.** The default path injects nothing — it's the
  agent reading its own mailbox when it chooses. Most coordination
  (worker asks a bounded question, reports a blocker; orchestrator answers or
  redirects) needs nothing more.
- **Keeps the injection guardrail intact.** Because the wake payload is a
  constant and the body is pulled, the sharpest rule ("never type model-authored
  free text into a session") is never bent, even in the wake tier.
- **Real supervisory value.** Removes the human as the mandatory relay between an
  orchestrator and its workers — a worker can flag "blocked, need a decision"
  and the orchestrator can respond or re-prioritize without you in the loop for
  every hop.
- **Async + persisted.** Messages survive restarts (reusing `state.json`) and
  are read when the recipient is ready; no synchronous coupling.
- **Ownership + star topology bound the blast radius.** A worker only ever hears
  from its orchestrator, and only members can read — small, auditable surface.

### Cons / risks
- **New stateful subsystem in the daemon.** Channels bring membership lifecycle,
  retention/TTL, and cursors — more persistence and more code to keep correct
  than the stateless commands `fpctl-agent` has today.
- **The wake tier still injects keystrokes** (even if constant) into a live
  session: it can steal focus / interleave for *unmanaged* fallbacks, and works
  cleanly only for managed sessions — so behavior is visibly uneven (managed vs
  unmanaged), and only the managed case is actually good.
- **Prompt-injection risk is reduced, not eliminated.** If an orchestrator is
  itself steered by untrusted transcript content, its messages carry that
  downstream. Invariant 2 ("treat as data") is a discipline an LLM can violate;
  it can't be hard-enforced the way an allowlist can.
- **Pull reliability depends on cooperation.** Backlog only lands if the adapter
  hook is wired and the agent actually runs the read (or gets woken). A truly
  idle, unmanaged agent parked at a human prompt won't see anything until its
  next turn.
- **Token cost.** Injecting backlog into context each turn spends tokens, and a
  chatty channel could bloat context — needs the `--tail`/cursor discipline.
- **Second-class citizens.** Cursor (no stdout hook) and unmanaged sessions get
  a degraded experience, which has to be surfaced honestly in the UI.
- **Scope-creep magnet.** "A message bus between agents" invites features
  (broadcast, threads, priorities) that would balloon the daemon. Star topology
  + tiny kind-set is a deliberate fence against that.

## MVP cut (build order — all four ship in v1)

Decided: v1 includes the managed-wake tier (the transport already exists), so
the full loop works end to end. Build in this order for safe incremental
landing, but all four are in scope for v1:

1. **Daemon channel primitive** — create/post/read(cursor)/members/close,
   persisted in `state.json`, bounded retention. `fpctl-agent channel *`
   subcommands + `launch --channel` auto-join. Ownership-gated like `stop`.
   Messages carry the full kind set `{ note, question, progress, blocker,
   directive }`.
2. **Pull delivery** — adapter hook (`SessionStart` backlog + `Stop`
   new-message check) for Claude Code first, then Codex; Cursor = notify-only.
   Lands the zero-injection path first so it can be exercised before wake.
3. **Managed wake (auto-fire)** — daemon posts the fixed templated ping via
   `send-keys` to idle managed members; auto-fires (constant payload), excludes
   `waiting`, debounced, single config flag to disable.
4. **Human-notify fallback** for unmanaged/idle recipients.

## Decided

- **MVP delivery:** all four tiers ship in v1, including managed wake.
- **Wake gating:** auto-fires on managed idle (constant payload); excludes
  `waiting`; debounced; one config flag to disable.
- **Message kinds:** full set `{ note, question, progress, blocker, directive }`.
- **Topology:** star (orchestrator ⇄ worker only).
- **Late joiners:** cursor starts at the tail — no pre-join backlog, ever.
- **Retention:** rolling **count** cap per channel, no TTL.
- **Threading:** flat per-channel log (no reply-to).
- **Wake debounce:** coalesce a burst into one ping per member within a short
  window (default ~3s).

## Open questions still to resolve before coding

- **Defaults to confirm in code review:** the exact retention count cap, the
  `--tail` default on pull reads, and the precise debounce window.
