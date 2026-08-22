# Parallel implementation split — READ BEFORE EDITING

Two agents are working in **this same worktree at the same time**. The split is
by strict file ownership. Staying inside your lane is what makes this safe.

Spec: `WORKFLOWS-PROPOSAL.md` (revision 4). Build order is §11 of that doc;
this split covers steps 1 and 2 only.

## Ownership

| Owner | May create/edit | Deliverable |
| --- | --- | --- |
| **Claude** (agent A) | `app/Sources/AppModel.swift`, `app/Sources/DesktopOverlay.swift` | §7 widget grouping view — **done, compiling** |
| **Codex** (agent B) | `packages/**`, `docs/workflows-schema.md`, `skills/**` | §4 agent types + §5.1 formation manifest |
| **Cursor** (agent C) | `app/Sources/WorkflowLauncher.swift` (new), `app/Sources/MenuContentView.swift` | §8.2 workflow launcher UI |

**Agent A and agent C both work inside `app/Sources/`.** The partition is by
file and it is strict — A owns `AppModel.swift` + `DesktopOverlay.swift`, C owns
`WorkflowLauncher.swift` + `MenuContentView.swift`. Neither edits the other's
files. If agent C needs state on `AppModel`, put it in `WorkflowLauncher.swift`
as its own `ObservableObject` and note the desired wiring in `HANDOFF.md`;
agent A will do the `AppModel` side.

Both A and C build with `cd app && ./build.sh`, which compiles the whole module
— **a broken file from either agent breaks the other's build.** Do not leave
the tree non-compiling between edits.

**Neither agent touches:** `daemon/**`, `adapters/**`, `firmware/**`,
`orchestrator/**`, `PROTOCOL.md`, `CLAUDE.md`, `install.sh`. This work requires
no daemon or protocol change (spec §1, §3). If you believe it does, stop and
say so rather than editing.

**Neither agent commits, pushes, or runs `git checkout`/`git reset`/`git
stash`.** The human integrates. Leave your work as uncommitted changes.

If you need something in the other agent's lane, write it in `HANDOFF.md`
(create it, append only, name yourself) instead of reaching across.

## Critical context: `REVIEW.md` is stale

An earlier Codex review of revision 1 of the plan exists in a sibling worktree.
**It was written against the pre-refactor codebase and its identity claims no
longer hold.** A large attachment/health refactor has since landed on `master`
(commits `47dcd54..382a881`). Do not treat that review as authoritative about
session identity, PID handling, or health. Read the current code.

## The identity model both halves depend on (spec §2)

Session identity is now a typed attachment plus explicit health:

```rust
Attachment::Process    { id: "process:<boot_time>:<pid>:<start_time>:<exe>", .. }
Attachment::Managed    { id: "managed:<launch_id>:<mux_server>:<mux_pane>", .. }
Attachment::Unverified { id: "unverified:<seed>" }

SessionHealth { Healthy, Suspect, Unknown, Detached }   // + health_reason
```

**Rule for both halves: key every relationship on the stable task id.** Never
session id, never attachment id, never PID. Attachments legitimately change
under a session that is continuously the same work; `launch_id` is minted per
*attempt*, not per task.

## Verification

- Agent A: `cd app && ./build.sh` must succeed. Visual/interactive checks
  against a live daemon are the human's — say plainly what you could not verify.
- Agent B: no build. `bash -n` any script; validate example packages parse.

Report what you did **not** finish or could not verify. Do not report success
for anything you did not actually run.
