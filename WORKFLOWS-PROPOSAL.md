# Workflows in FocalPoint

**Status: design proposal, revision 4. Not implemented. Seeking review.**

Revision 1 was rejected by an independent Codex review (`REVIEW.md`); r2 adopted
that review's split; r3 rewrote it against the attachment/health refactor. This
revision folds in agent types and phased handoffs and reorganizes the whole
document to be reviewable in one pass.

## How to review this

The claims worth attacking are marked. Specifically:

- **Appendix C** lists every factual claim about the current codebase that this
  design rests on, with a symbol or path to check it against. If one of those
  is wrong, the section depending on it is probably wrong too.
- **§10 Open questions** are the things I could not resolve from the code and
  did not want to guess at.
- **Appendix A** records designs already rejected and why. Re-proposing one of
  them is fine, but please engage with the stated reason.
- The riskiest sections, in my own estimation: **§4.2** (advisory vs. enforced
  constraints), **§5.3** (the fan-out authorization gate), and **§6.2** (the
  handoff carrier). These are where a plausible-looking design could be
  quietly unsafe rather than merely wrong.

> **Moving target.** The identity model in §2 was read from the attachment/
> health refactor while it was still uncommitted in the main working tree
> (~1,100 lines across `session.rs`, `daemon.rs`, `identity.rs`, `app/`). The
> health-handling details are most likely to have drifted. Re-verify before
> implementing.

Grounded in: `CLAUDE.md`, `PROTOCOL.md` §3, `orchestrator/README.md`,
`ORCHESTRATOR-PLAN.md`, `AGENT-CHANNEL-PLAN.md`, `daemon/src/{daemon,session,
channel,protocol}.rs`, `daemon/src/bin/fpctl-agent.rs`, `app/Sources/`, and the
uncommitted refactor.

---

## 1. Goal

Pre-packaged agents and crews that can be spawned and managed in one gesture,
native to FocalPoint's role as an orchestration layer between Claude, Codex,
and Cursor — not a generic multi-agent framework bolted onto the side.

Three things are being proposed, in dependency order:

| | What | Where it lives |
| --- | --- | --- |
| **Agent types** | reusable persona + provider affinity + constraints | `~/.config/focalpoint/agents/` |
| **Formations** | a crew of typed roles, wired by channel | `~/.config/focalpoint/workflows/` |
| **Grouping view** | seeing a crew as a crew in the widget | `app/` |

None of them requires a protocol change. All expansion happens in the
supervising orchestrator; the daemon only ever sees individual validated
`launch` / `channel` / `stop` calls.

### 1.1 The primitive: a formation, not a step graph

Other frameworks define a workflow as a step graph. That is the wrong primitive
here: a step graph wants to auto-answer approvals and auto-retry launches, both
permanently prohibited (`ORCHESTRATOR-PLAN.md` invariants 2-3).

FocalPoint's substrate is different — a fixed physical address space (sticky
slots 1-12), a provider-plural launcher, pull-first channels, and a human who
is a required node rather than an exception handler.

**A workflow is a formation: a crew, materialized.** With phases (§6), it
becomes *a sequence of crews, one orchestrator, one channel.* The orchestrator
is the only thing that persists, and it is the thing holding the graph — never
the daemon.

---

## 2. The identity model everything rests on

This is first because every later decision follows from it. The in-flight
refactor replaces PID/tty identity with a typed attachment plus explicit health:

```rust
Attachment::Process    { id: "process:<boot_time>:<pid>:<start_time>:<exe>", .. }
Attachment::Managed    { id: "managed:<launch_id>:<mux_server>:<mux_pane>", .. }
Attachment::Unverified { id: "unverified:<seed>" }

SessionHealth { Healthy, Suspect, Unknown, Detached }   // + health_reason
```

**2.1 Attachment is not stable; the stable task id is.** Sessions legitimately
move between variants — `Unverified` → verified on exact registration,
`Process` → `Managed` on promote-to-managed — and `update_attachment` rewrites
the attachment when they do. Session id can also change (`PROTOCOL.md` §3 rekey
after compaction). The stable task id from `fpctl-agent launch` is the only
identifier surviving all of it.

> **Rule: every formation and grouping relationship keys on the stable task id.
> Never session id, never attachment id, never PID.**

**2.2 `launch_id` is per-attempt, not per-task.** Minted fresh by
`new_relaunch_id()` on both the launch and resume paths, so one task id
accumulates several launch ids across relaunches and history resumes. Useful as
a cross-reference from an attachment back to the attempt that produced it;
never a membership key.

**2.3 Health gives the saga a completion signal it previously lacked.** Before
the refactor, "has this role come up?" was only answerable by "a session with
this task id appeared" — ambiguous, since the appearing session might not be
the process just launched. Now a role counts as live only once its attachment
*verifies*. This is what makes the channel-ownership step safe to sequence, and
it directly de-risks the strongest objection in `REVIEW.md`.

---

## 3. Architecture

```text
agent types  ─┐
              ├─▶ orchestrator agent ──fpctl-agent──▶ focalpointd
formations  ──┘    (validates, preps,                  (validates every
                    sequences, waits,                   mutation; records
                    reports partial failure)            facts)
```

The orchestrator is a socket client that adds judgment without adding a second
authoritative surface (`ORCHESTRATOR-PLAN.md:15-27`) — the same shape as every
other component here that works.

**What the daemon does not gain:** manifest parsing, prompt interpolation,
provider selection, environment mutation, sequencing, retry, rollback, or
package installation. Package install stays outside both `fpctl-agent` and the
daemon's hot path; a fetched manifest must never become a daemon instruction.

---

## 4. Agent types

The smallest unit, and the one worth building first — useful for one-off
launches before any formation exists.

```text
~/.config/focalpoint/agents/security-reviewer/
    type.toml
    persona.md
```

```toml
[type]
name        = "security-reviewer"
version     = 1
description = "Adversarial reviewer; findings only, no fixes"

[provider]
prefer   = ["codex", "claude"]   # preference order, resolved by the orchestrator
model    = "gpt-5.6-sol"         # required; never inherited from provider/UI state
requires = ["channels"]          # checkable; excludes cursor --cursor-mode attachable

[persona]
prompt = "persona.md"            # durable identity, prepended to the task
title  = "Security review"       # default --title prefix

[advisory]                       # PROMPT TEXT. Not enforced. See §4.2.
scope       = "Report findings; never modify source."
output      = "Ranked list, most severe first, with file:line."
escalate_as = "blocker"          # channel kind for its escalations

[enforced]                       # satisfied during PREP, not by the daemon
read_only   = true
allow_paths = ["."]
```

A formation role becomes a binding rather than a blob:

```toml
[[phase.role]]
name = "reviewer"
type = "security-reviewer"
task = "Review the auth refactor described in HANDOFF.md."
```

### 4.1 Why this is more than a prompt library

Two FocalPoint-specific properties:

1. **Checkable provider affinity.** `requires = ["channels"]` is verifiable — a
   Cursor `attachable` launch is not a live FocalPoint session and cannot join
   channels, so a type needing them must not resolve to it. The orchestrator
   rejects the binding *before* launching rather than discovering it after.
2. **A declared escalation kind.** `escalate_as` ties the persona to the
   attention system: the type states how its output should interrupt you, which
   is what this product is about.

### 4.2 Advisory vs. enforced — *the highest-risk part of this design*

Getting this wrong produces a system that *looks* sandboxed and is not.

**`[advisory]` is prompt text.** Prepended to the task, genuinely effective, and
in the end a polite request to a language model. It must never be surfaced in
the UI as a restriction, permission, or sandbox. A reviewer with `scope =
"never modify source"` that writes a file is not a FocalPoint bug; it is the
expected failure mode of an unenforced instruction.

**`[enforced]` is real, and cannot be delivered through `launch`.**
`fpctl-agent launch` deliberately does not choose sandbox or approval settings
(`orchestrator/README.md`), and adding those flags would widen exactly the
surface Appendix A rejects. Enforcement therefore arrives during **prep**:

- For Claude Code: the orchestrator writes a `.claude/settings.json` into the
  prepared worktree carrying the declared permission set. Harness-enforced, and
  it lands via file preparation, already the orchestrator's job.
- The prepared `cwd` is itself the main enforced boundary available today — a
  worktree per role *is* the containment.
- **If a provider has no equivalent project-local enforcement surface, a type
  declaring `[enforced]` must refuse to launch on that provider** rather than
  silently downgrading to advisory. A type that quietly loses enforcement when
  the orchestrator picks a different provider is worse than one that never
  claimed it. (See open question §10.1.)

This split also disciplines the UI: advisory persona may be shown as
*description*; enforced constraints may be shown as *guarantees* only where the
provider actually delivered them.

### 4.3 Trust

A persona becomes the system framing of a launched process. Installing a type
is the same class of decision as installing a workflow: inert on disk,
consequential at launch. Local directories, no fetch-and-run, never treated as
instructions to the daemon.

---

## 5. Formations (single-phase)

### 5.1 The package

A manifest plus role bindings, under `~/.config/focalpoint/workflows/`. Inert
data, untrusted like every label, cwd, and task body.

```toml
[formation]
name        = "review-fanout"
version     = 1
description = "Three-perspective review, one synthesizer"

[[role]]
name = "synth"
kind = "orchestrator"            # launched first; owns the channel
type = "synthesizer"

[[role]]
name = "security"
type = "security-reviewer"
prep = "worktree"                # a REQUEST to the orchestrator, not the daemon

[[role]]
name = "perf"
type = "perf-reviewer"
prep = "worktree"

[escalate]
channel_kinds = ["blocker"]
states        = ["error", "approval"]   # approval is first-class, never hidden
completion    = "all-roles-done"        # lifecycle field, NOT a state reduction
```

`prep` names an intent the *orchestrator* satisfies before calling `launch`.
The daemon still receives only an already-existing absolute cwd. No new
execution capability crosses the socket — not a safer shell, but no shell.

### 5.2 The saga

Sequenced explicitly, because the gap between "terminal opened" and "session
verified" forces it:

1. Validate the manifest; resolve every role's type to an explicit provider and
   an absolute prepared cwd. Refuse on ambiguity rather than guessing.
2. Prepare the orchestrator role's environment; `launch --role orchestrator`
   with a derived stable task id.
3. Poll `status` until that session is live **and its attachment verifies**.
   `launch-session` replies on terminal-open acceptance, not registration, so
   the acknowledgement alone proves nothing.
4. As that live, verified owner, `channel create`; record the channel id.
5. For each worker: prepare cwd, then `launch --role worker
   --manager-task-id <orchestrator> --channel <id>`.
6. Poll for each role's verified attachment. A worker joins at the channel
   tail, so its assignment must be in its launch task or posted after it joins.
7. On partial failure: report to the human. Never silently retry, never stop
   successful roles, never fabricate ownership.

Every step is an existing, already-validated primitive. **Nothing new is
required in `fpctl-agent`.**

### 5.3 Provider policy

r1 proposed `provider = "balance"`, letting the daemon spend whichever
subscription had headroom. Rejected: usage records are free-form, last-known
snapshots whose freshness clients must interpret (`PROTOCOL.md:507-530`), and
API-billed providers are deliberately distinct from subscription ones. The
daemon has no canonical headroom model and should not silently decide how to
spend money.

Balancing belongs to the orchestrator, which already reads usage in `status`,
can state its reasoning, and can fall back explicitly. Types express a
*preference order*; the orchestrator resolves one explicit provider per launch
and says why.

---

## 6. Phases and handoffs

The motivating shape: a planner works to a point, fans out into *N*
implementers where the plan decides *N*, hands off to a reviewer, with one
orchestrator persisting across all of it.

**This is not the rejected step graph.** What was rejected is the *daemon*
executing control flow. This is the *orchestrator* running §5.2 more than once,
with a human-authorized gate at each transition. The daemon cannot tell a
phased formation from several unrelated ones.

### 6.1 Bounded fan-out

`N` is unknowable at authoring time, so the manifest declares a bound and the
plan chooses within it:

```toml
[[phase]]
name = "plan"
gate = "authorized"              # the human's initial go-ahead covers this
[[phase.role]]
name = "planner"
type = "planner"

[[phase]]
name  = "implement"
after = "plan"
gate  = "confirm"                # DEFAULT for fan-out: show me before launching
[phase.fanout]
from     = "planner"             # the plan names the slices
max      = 4                     # hard ceiling; the plan cannot raise it
type     = "implementer"
cwd_root = "worktrees/"          # every slice must prepare under here

[[phase]]
name  = "review"
after = "implement"
gate  = "auto"                   # defensible: fixed role, no plan-authored text
[[phase.role]]
name = "reviewer"
type = "security-reviewer"
```

**The security property.** A fan-out means an agent-authored plan decides how
many processes launch and what they are told to do. That is an escalation:
`launch` is process creation, and the standing rule is that it runs only what
the user provided or explicitly authorized. Planner output is untrusted data.
Containment is that the manifest fixes what the plan may not choose:

| Chosen by the plan | Fixed by the manifest |
| --- | --- |
| how many slices (≤ `max`) | the ceiling `max` |
| each slice's task text | the agent type, and so the provider set and persona |
| each slice's name | the `cwd_root` every slice must live under |
| | whether a human confirms (`gate`) |

`gate = "confirm"` is the default for any fan-out phase and is not silently
skippable. `gate = "auto"` is defensible only where no new authority appears:
fixed role count, fixed type, no plan-authored task text.

### 6.2 The handoff carrier — *not the channel*

**A reviewer launched in phase 3 cannot read anything from phase 2.**
`join_at_tail` sets a new member's cursor to `next_id - 1`, and its comment
states this is load-bearing: *"a late joiner never receives any message that
existed before it became a member."* `read` further returns only messages
addressed to that member or broadcast by the owner, and retention is bounded.

This is correct and must not be worked around by widening channel access.
Handoffs need an explicit carrier:

- **The orchestrator synthesizes it.** It has been a channel member from the
  beginning, so it has read every worker report as it arrived. Between phases
  it writes a **handoff artifact** into the next phase's prepared cwd and puts
  a pointer to it in the next role's launch task.
- **The launch task is the only inbound channel a fresh agent has.** Keep the
  brief short; point at the artifact for detail.
- **Never reconstruct a handoff from transcripts.** Transcript reads are for
  targeted diagnosis; a phase boundary is routine.

A useful consequence: once a phase's reports are in the orchestrator's
synthesis, those workers can be stopped without losing anything.

### 6.3 Transitions

Each transition is a fresh run of §5.2, plus a gate:

1. Evaluate the previous phase's completion (`all-roles-done`, or the declared
   condition) — a lifecycle check, not a state reduction (Appendix A.4).
2. Synthesize the handoff artifact into the next phase's prepared cwd.
3. If `gate = "confirm"`, present the resolved role list and wait.
4. Prepare each cwd; launch each role with the *same* `--manager-task-id` and
   `--channel` as every prior phase. The orchestrator and channel persist; only
   the crew changes.
5. Wait for verified attachments.
6. Decide, per policy, whether to `stop` the previous phase's workers. Their
   task ids are the orchestrator's own, so `fpctl-agent stop` is
   ownership-valid.

### 6.4 Slots are the real capacity limit

1 orchestrator + 1 planner + 4 implementers + 1 reviewer = **7 keys**, before
any unrelated work. Slots run 1-12; live sessions past 12 get `slot: null` —
still registered, still in the aggregate, but **no key to press**.

So phase teardown is capacity, not tidiness. A per-phase `retain =
"until-formation-ends" | "until-phase-ends"` should default to retaining —
never stop work implicitly — while making teardown one gesture when keys run
short.

---

## 7. Presentation: the widget grouping view

**Build this first.** It stands alone, needs no protocol change, and makes
today's orchestrator/worker launches legible before any formation exists.

The app may **visually** group. The physical key map does not: every live
member keeps its slot, its key, and its state, including `approval`. Grouping
is a rendering choice in `app/`, not a change to `SET_KEY_STATE`.

**A third widget axis**, orthogonal to the existing `DesktopWidgetMode`
(visibility) and `DesktopWidgetOrientation` (layout):

```swift
enum DesktopWidgetGrouping { case flat, byOrchestrator }
```

persisted in `UserDefaults` beside its siblings, toggled from the widget's
existing right-click context menu.

**The data exists and is rendered nowhere.** `fpctl-agent launch
--role/--manager-task-id` writes `orchestration_role`, `orchestrator_task_id`,
and `manager_task_id` into session meta; `AppModel` parses all three;
`SessionInfo` derives `isOrchestrator`. Nothing in `app/` displays any of it.
The refactor does not touch these three fields.

**Grouping rule.** Each orchestrator heads a block; workers naming that
orchestrator's task id as manager nest beneath it; everything else falls into
one trailing ungrouped block. Because every phase shares one
`--manager-task-id`, a phased formation is automatically one group whose
membership grows and shrinks over time — no extra mechanism.

**Ordering.** Source order is the daemon's existing sort (connected first, then
slot), so leads and members stay in slot order within a block for free. Only
the partition is new.

**What must not happen.** Every row's slot badge still reads whatever the daemon
assigned, so grouping makes badges intentionally non-monotonic down the list.
That is correct. Any impulse to renumber for tidiness is the sticky-slot
violation r1 was rejected for — slots stay stable while a session is live and
compact only after an explicit end/remove. No `swap-slots`, no reassignment, no
synthetic rows.

**Vertical only.** The horizontal strip *is* the pad — one keycap per slot in
slot order — so reordering breaks the muscle-memory mapping it exists to
reinforce. The toggle is hidden in that orientation, not silently ignored.

**Health interaction — most likely part to be got wrong:**

- A lead that goes `detached` or `suspect` **keeps its members**. Membership is
  a task-id fact, independent of the lead's attachment being alive.
  Re-parenting workers into "Ungrouped" the moment a lead goes stale rearranges
  the tree exactly when something is wrong — the worst time to move rows.
- The lead row surfaces its health glyph and `health_reason`, so a group headed
  by a detached orchestrator reads as *supervision lost*.
- `unknown` is the honest pre-verification state, not an error, and must not be
  styled as one.

**Degradation:**

- No orchestration meta at all → the grouped view would equal the flat list, so
  fall back to flat rather than draw a lone "Ungrouped" header over everything.
- A worker whose manager task id was **never** a live lead → ungrouped, never
  hidden. (Distinct from a lead that has *become* detached, above.)
- Backlogged sessions keep their existing separate section, ungrouped.

---

## 8. The UX, end to end

### 8.1 Installing

Agent types and formations are directories under `~/.config/focalpoint/`.
Installing is copying. Nothing fetches; nothing runs on install.

### 8.2 Starting

You tell an orchestrator agent, in words:

> "Run the review-fanout formation against the auth refactor."

That is the design, not a missing button. The orchestrator makes real judgment
calls before anything launches — provider per role, directories to prepare,
whether the request is even coherent — and those are the calls that cannot move
into a verb without re-creating everything Appendix A rejects. Later, a "Start
Formation ▸" menu becomes a shortcut for typing it; the orchestrator still does
the work.

### 8.3 Coming up

Keys light as roles verify:

```
key 1   synth      ● thinking     (orchestrator first)
key 2   security   ● thinking
key 3   perf       ○ unknown      ← launched, attachment not yet verified
```

`unknown` is neutral, not alarming — it resolves within a second or two. If a
role never verifies it stays visible and the orchestrator says which and why.
Nothing silently retries.

### 8.4 The grouping view

Right-click the widget → **Group by Orchestrator**:

```
FLAT (today)                      GROUP BY ORCHESTRATOR
①  synth        ● running         ①  synth        ● running
②  security     ● thinking            ②  security  ● thinking
③  perf         ◐ approval    ──▶     ③  perf      ◐ approval
④  loan-calc    ● waiting         ⑦  other-orch   ● thinking
⑤  widget-ui    ○ idle                ⑧  worker-a  ● running
⑦  other-orch   ● thinking
⑧  worker-a     ● running         ⋯ Ungrouped · 2
                                  ④  loan-calc    ● waiting
                                  ⑤  widget-ui    ○ idle
```

Deliberate, in order of how often it will be questioned:

- **The circled numbers do not run in order.** They are physical keys. Key ③ is
  key ③ whether drawn second or fifth. Muscle memory survives the view change;
  that constraint is what this design is built around.
- **Nothing is hidden.** Grouping reorders; it never filters.
- **Unrelated work is not swept away** — it drops to Ungrouped, still live,
  still clickable.
- **The horizontal strip is unaffected.** It is a picture of the pad, and a pad
  whose keys move is useless.

### 8.5 The fan-out gate

The one genuinely new interaction:

```
The plan proposes 3 implementation agents:

  1. auth-token-rotation   codex    worktrees/auth-rotation
  2. session-store         codex    worktrees/session-store
  3. migration-scripts     claude   worktrees/migrations

  ceiling 4 · all under worktrees/ · type: implementer

Launch these 3?  [y / edit / no]
```

You authorized the formation; you did not write those three task descriptions.
This is where you authorize them. Default for every fan-out phase.

### 8.6 When it needs you

Unchanged, deliberately: the key lights, you press it. A formation never
answers its own approvals — permanent, not a setting.

Grouping adds *context for the interruption*: an approval on key ③ currently
says a session needs you; grouped, it says which crew and who supervises it —
usually what decides whether you deal with it now.

### 8.7 When something breaks

```
①  synth      ⚠ detached — pane closed
    ②  security   ● running
    ③  perf       ● running
```

The group stays together. One legible signal: this crew lost its supervisor.

### 8.8 When it finishes

Keys go green. No automatic teardown — sessions stay until ended, like any
session today. Cleanup, re-running a failed role, or leaving a crew up is
yours.

---

## 9. Lifecycle: what exists, what is owed

`REVIEW.md` named a durable formation lifecycle as the blocker behind
everything else, stating nothing persisted can recover a half-expanded
formation. **That understates what exists.**

Already solved, per launch:

- a durable receipt at `~/.local/state/focalpoint/launches/<task_id>.json`;
- **task-id idempotency** — a duplicate reservation for a known task id returns
  the stored receipt with `ok: true` instead of erroring, so re-running a
  partially expanded formation with the same task ids is already safe at the
  individual-launch level;
- **restart reconciliation** — receipts still marked `opening` become
  `needs-user-retry` rather than being lost;
- **reservation expiry** — stale reservations expire on their own.

Genuinely missing, all one level up:

- an instance id + manifest version/digest stamped onto the existing receipts,
  so a resumed formation is provably the same one;
- per-role status for phases the receipt does not cover — `planned`,
  `prepared` — owned by the orchestrator;
- phase identity, once phases exist;
- an explicit human policy for cleanup versus leaving successful roles running.

Much cheaper than "build a durable workflow lifecycle", and it argues for
building it orchestrator-side on top of the receipt mechanism that exists.

---

## 10. Open questions

**10.1 Per-provider enforcement surface.** Claude Code takes a project-local
`.claude/settings.json`. Do Codex and Cursor expose an equivalent that a
prepared directory can carry? If not, `[enforced]` types must hard-refuse those
providers (§4.2). *I did not verify this and did not want to guess.*

**10.2 Collapsible groups.** Attractive with several formations live, but a
collapsed block hides member states, and hiding an `approval` defeats the
device. My position: if collapsing ships, a block containing `error` or
`approval` must refuse to collapse or surface it on the header. Not decided.

**10.3 Naming collision.** `skills/focalpoint-orchestrator/agents/openai.yaml`
already exists and is a skill-interface descriptor, not an agent type. Reusing
`agents/` for types will confuse — rename one.

**10.4 Fan-out gate delivery.** The gate (§8.5) is presented by the
orchestrator in its own terminal. Should it instead surface in the app, where
the human is already watching keys? That would make it a real UI feature rather
than text in a pane, at the cost of a new app↔orchestrator path that does not
exist today.

**10.5 `completion` semantics per phase.** `all-roles-done` is stated but not
specified against `error` or `detached` members. Does a phase with one errored
role ever complete, or does it always require a human decision?

---

## Appendix A — Rejected designs, and why

1. **Daemon-side manifest expansion** (`fpctl-agent workflow start`). Conflates
   authority with judgment. The repo's split is explicit: the orchestrator
   prepares and decides; the daemon owns live identity, order, launching, focus
   (`orchestrator/README.md:3-17`). One verb is not one capability — that verb
   meant policy reads, prompt interpolation, provider choice, repository
   mutation, task-id minting, channel creation, N process launches, and slot
   presentation changes. `fpctl-agent` excludes exactly those by design, and its
   surface test asserts `policy` never appears in its help.
2. **Treating expansion as a single call.** It is a saga: `launch-session`
   returns on terminal-open acceptance, and a channel must be created by an
   already-live managed orchestrator. A daemon-side verb would have to block
   indefinitely, return before the workflow exists, or grow a retry/rollback
   scheduler — the third contradicting the rejection of auto-retry.
3. **Collapse/expand of formation keys on the pad.** Changes key identity while
   members are live, violating "Key N stays key N"
   (`ORCHESTRATOR-PLAN.md:29-37`). The scaling premise was also stale: slots run
   1-12 with `slot: null` overflow, not ~8.
4. **`quorum = "all-done"` as a state reduction.** One member `done` and one
   `idle` reduces to `done`, but "all done" is false. Completion is a separate
   lifecycle field, never overloaded onto `State`.
5. **Typed prep verbs in the daemon** (`worktree`, `branch`, `copy-env`).
   `worktree`/`branch` over `git` still invoke repository- and user-configured
   filters — avoiding `sh -c` does not mean "no code execution". `copy-env` was
   an undeclared secret-distribution primitive with no source allowlist,
   destination root, symlink handling, or audit trail.
6. **`provider = "balance"` in the daemon.** See §5.3.
7. **`formation_id` as new session meta.** Superseded, not wrong: the existing
   task-id-keyed launch receipt already provides a durable home.
8. **Channel history as the handoff carrier.** Impossible by design, not merely
   unwise — see §6.2.

## Appendix B — Documentation defects found while writing this

- `CLAUDE.md` gave the aggregate lattice as `error > waiting > running >
  thinking > done > idle`, omitting `approval` and `compacting`. Real order:
  `error > approval > waiting > running > thinking > done > compacting > idle`.
  **Corrected on this branch** — it is what caused r1's escalation rules to omit
  `approval`.
- `CLAUDE.md` described slots as "kept for life"; `session.rs`'s header says
  they stay stable *while live* and compact after an explicit end/remove.
  **Corrected on this branch.**
- `CLAUDE.md` omitted the 1-12 slot range and `slot: null` overflow.
  **Corrected on this branch.**
- `skills/focalpoint-orchestrator/SKILL.md` claims the UI gives each
  orchestration group a matching `O1`/`O2` badge. No such rendering exists in
  `app/`. Build it as part of §7 or remove the sentence. **Not corrected.**

## Appendix C — Factual claims this design rests on

Check these first; sections depending on a false one are suspect.

| # | Claim | Verify at |
| --- | --- | --- |
| C1 | `launch-session` replies on terminal-open acceptance, not registration | `Request::LaunchSession` arm, `daemon/src/daemon.rs`; log `[managed-launch] terminal-open accepted` |
| C2 | A channel must be created by a live managed **orchestrator** | `channel_actor` + `Request::ChannelCreate`, `daemon/src/daemon.rs` |
| C3 | Channel is owned by `owner_session` + `owner_task_id` | `struct Channel`, `daemon/src/channel.rs` |
| C4 | A late joiner never receives pre-join messages | `join_at_tail`, `daemon/src/channel.rs` |
| C5 | `read` returns only messages to that member or owner broadcasts; retention bounded | `Channel::read`, `RETENTION`, `daemon/src/channel.rs` |
| C6 | Slots are 1-12; overflow gets `slot: None` | `daemon/src/session.rs` (slot validation, "slot must be 1-12") |
| C7 | Slots stable while live, compact after explicit end/remove | `daemon/src/session.rs` module header |
| C8 | Lattice is `error > approval > waiting > running > thinking > done > compacting > idle` | `PROTOCOL.md:320`; `State::priority`, `daemon/src/protocol.rs` |
| C9 | `fpctl-agent` help must not contain `policy`, `inject`, `accept`, `reject`, … | `command_surface_has_no_dangerous_or_obsolete_verbs`, `daemon/src/bin/fpctl-agent.rs` |
| C10 | Launch receipts exist, are task-id keyed, and duplicate reservations return them with `ok: true` | `reserve_managed_launch` error path, `daemon/src/daemon.rs` |
| C11 | `opening` receipts are reconciled to `needs-user-retry` on restart | `reconcile_opening_launch_receipts`, `daemon/src/daemon.rs` |
| C12 | `launch_id` is minted per attempt on both launch and resume paths | `new_relaunch_id()` call sites, `daemon/src/daemon.rs` |
| C13 | Orchestration meta (`orchestration_role`, `orchestrator_task_id`, `manager_task_id`) is parsed by the app and rendered nowhere | `app/Sources/AppModel.swift` session handler; `isOrchestrator` in `app/Sources/Protocol.swift`; no other references |
| C14 | `launch` does not choose sandbox or approval settings | `orchestrator/README.md` launch section |
| C15 | Cursor `attachable` launches are not live FocalPoint sessions | `orchestrator/README.md` Cursor section |
| C16 | Attachment variants and `SessionHealth` as described in §2 | uncommitted refactor: `Attachment`, `SessionHealth`, `update_attachment` in `daemon/src/session.rs` |
