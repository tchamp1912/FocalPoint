# Session identity, recovery, and persisted daemon state

This document describes the completed implementation of Rust-native identity
resolution, compaction-correct statistics, recoverable session tombstones, and
daemon-state persistence. Paths are repo-root-relative. The context below
records the design rationale as well as the resulting behavior.

## Implementation record

- [x] Part 1 — Rust-native identity resolution (`daemon/src/identity.rs`,
      adapter simplification). Done: `sysinfo` added, `identity.rs` written
      with `ProcessSource`/`resolve_pid`/`own_tty`/cache (5 unit tests
      green), `--refresh-identity` + auto-resolution wired into
      `client::set_state`/`set_meta`/`end_session`, both adapter scripts
      stripped of their `ps`-walk/cache logic and synced to
      `~/.config/focalpoint/adapters/`. `cargo build`/`cargo test` both
      green (72 tests). The live installed `/opt/homebrew/bin/focalpoint`
      binary now includes `--refresh-identity` (rebuilt in the final
      verification step below).
- [x] Part 2a — Claude Code compaction-correct cumulative meta (daemon-side).
      Done: `CUMULATIVE_META_KEYS`, `add_carry`/`apply_meta_update` in
      `daemon/src/session.rs`, wired into `set_state`'s update+rekey
      branches and `merge_meta`; rekey site snapshots `_carry_<key>` +
      bumps `compactions` off the old session. Integer arithmetic preferred
      over float so the common (never-compacted) case is a true no-op (e.g.
      `turns: 7`, not `7.0`). New tests
      `rekey_carries_forward_cumulative_stats_and_bumps_compactions` and
      `repeated_rekeys_compound_cumulative_stats_and_compactions` both pass;
      full suite 74/74 green.
- [x] Part 2b — Codex `compactions` counter (adapter-side only). Done and
      verified against real local rollout files
      (`~/.codex/sessions/**/*.jsonl`) containing 4 real compactions — jq
      query returns `compactions: 4` correctly alongside the existing
      `turns: 30`.
- [x] Part 3 — Generalized tombstone/recovery mechanism. Done: `Tombstone`
      struct + `tombstones` map on `Registry`; `reap_session` (tombstones,
      used by all 4 sweeps: TTL/dead-tty/dead-pid/expire_compacting) vs
      unchanged-contract `end_session` (never tombstones, clears any
      existing); `count_identity_matches`/`find_recovery_candidate` pooled
      `{label,cwd,tty,pid}` ≥2-match, subsuming the old Compacting-only
      cwd+tty check; `tombstone_ttl_minutes` config (`daemon/src/config.rs`,
      default 30min, `0`=never, mirrors `ttl_minutes`); periodic
      `expire_tombstones` sweep wired into `daemon.rs::run()`. 8 new tests
      (recovery via pid+cwd, via label+cwd, single-signal rejection,
      explicit end-session never recoverable, ttl expiry, infinite ttl,
      `expire_tombstones`) all pass. Full suite 82/82 green.
- [x] Part 4 — Persist sessions + tombstones + usage across daemon restarts.
      Done: `paths::daemon_state_path()`; `Registry::restore`/
      `tombstones_snapshot` (session.rs); `session_to_json`/
      `session_from_json`/`unix_ms_now`/`restore_instant`/`save_snapshot`/
      `load_snapshot`/`reconcile_on_startup` (daemon.rs); `apply_effects`
      saves after any session effect, `"set-usage"` handler saves after
      merge; `run()` loads+reconciles at startup instead of always starting
      fresh. 3 new unit tests (json round-trip, malformed-input rejection,
      elapsed/gap reconstruction math) + full suite 85/85 green. **Manually
      verified against a real `focalpointd --mock-device` in an isolated
      `/tmp` scratch dir**: registered a session (auto-resolved pid via
      identity.rs) + usage snapshot, confirmed `state.json` contents,
      killed and respawned the daemon pointed at the same state dir — both
      the session and usage reappeared immediately, zero new hook events,
      no reconciliation false-positive (the still-alive pid was correctly
      not tombstoned).
- [x] Part 5 — Integration test harness (`daemon/tests/session_lifecycle.rs`).
      Done: 7 integration tests covering basic lifecycle (register/update/
      end-session + explicit end leaves no tombstone), compaction carry-forward,
      dead-pid sweep + pid recovery, label+cwd recovery after dead-tty reap,
      daemon restart (live session + usage persistence, tombstone persistence
      + recovery), and infinite tombstone TTL via seeded snapshot. Fixed
      `TestDaemon::restart` compile error (can't move out of `Drop` type).
      `cargo test --test session_lifecycle` 7/7 green; full suite 92/92 green.
- [x] Final live end-to-end verification against the real installed daemon —
      **must include rebuilding and installing `focalpointd`/`focalpoint` to
      `/opt/homebrew/bin/`** (see Part 1 caveat above), then
      `launchctl kickstart -k gui/$(id -u)/dev.focalpoint.daemon`. Done:
      `./install.sh --yes` rebuilt+linked both binaries, refreshed all adapter
      scripts under `~/.config/focalpoint/adapters/`, kickstarted launchd.
      Live smoke: basic lifecycle, compaction carry-forward (turns/context/
      compactions), session+usage persistence across daemon restart, `state.json`
      present and valid — 12/12 automated checks green. Identity resolution
      verified indirectly: live Codex session already carries resolved
      `tty`/`pid` from adapter hooks; bare-shell `--refresh-identity` correctly
      no-ops without a claude/codex ancestor (expected). `bash -n` both adapter
      scripts green. PROTOCOL.md updated (identity resolution, cumulative stats,
      tombstones/recovery, persistence, `tombstone_ttl_minutes`, `compactions`,
      `--refresh-identity`, `_carry_*`).

Build order matters and is reflected in the part numbering: **2a must land
before 4** (persistence must not make wrong numbers durable), **5 is last**,
after the unit tests for 1-4 each pass on their own.

## Context

Five connected findings, arrived at through discussion and — where noted —
verified against real local evidence, not assumed:

1. **Codex/Claude Code adapter drift.** `adapters/claude-code/hooks.sh` was
   fixed (in a prior session) to cache `tty`/`pid` once per process instance
   instead of re-walking `ps` ancestry on every hook call. `adapters/codex-cli/
   hooks.sh` has the *identical uncached walk*, unfixed — proof that
   duplicating this logic in two bash scripts is itself the risk: one gets
   fixed, the other silently doesn't. Root fix: stop duplicating it. Move
   identity resolution into the Rust binary that both adapters already shell
   out to, so there's exactly one implementation.

2. **Compaction currently under-preserves cumulative stats.** `turns`,
   `tool_calls`, `subagents`, `tokens_in`, `tokens_out` (recomputed from the
   transcript every `Stop`) and `cost_usd` (Claude Code's own live total,
   `adapters/claude-code/statusline-usage.sh`) are all "cumulative since
   *this* transcript/process started," not "cumulative since the user's
   logical conversation started." A compaction fork starts a new
   transcript/process, so the daemon's current rekey (`Registry::set_state`,
   `daemon/src/session.rs`) — which does `old_meta, then overwrite with
   incoming` — lets the new segment's small fresh numbers clobber the
   pre-compaction totals. `context_tokens`/`context_window` are the one
   thing that's *already* correct as a plain overwrite: resetting on
   compaction is the point, not a bug.

   **Codex needs a different mechanism, not none** — verified against real
   local rollout files (`~/.codex/sessions/**/*.jsonl` on the machine this
   plan was written on), not assumed. Codex's hook set has no `PreCompact`
   equivalent, but its transcript *does* record compaction inline:
   `{"type":"compacted", "payload":{"replacement_history":[...]}}` paired
   with an `event_msg`/`context_compacted` entry, at the point Codex prunes
   older context. Critically, this happens **in the same rollout file, under
   the same `thread_id`** — nothing forks. Confirmed by running the
   adapter's existing jq stats query against a real file containing 4 such
   compactions: `turns: 30` matched that file's actual `task_complete` count
   exactly, and `tool_calls`/`tokens_in` were large, clearly whole-session
   totals — i.e. the existing full-transcript recompute is *already*
   correctly cumulative across Codex compactions, for free, because there's
   no identity change to bridge (unlike Claude Code, where the
   process/transcript itself changes). So Codex doesn't need the daemon-side
   rekey/carry-forward machinery Claude Code needs — but it was still
   missing the `compactions` *counter*, since nothing was watching for that
   event at all. Fix: adapter-side only, one more field in the existing jq
   stats query, counting `context_compacted` events in the transcript
   (naturally cumulative already, same as everything else in that query) —
   no daemon changes for Codex's case.

3. **Sessions that vanish without an explicit stop should stay recoverable.**
   Today, only a session in `State::Compacting` gets a reunification chance
   (cwd+tty match, `COMPACT_GRACE` = 5 min), and only for that one specific
   cause of disappearance. But a session can also disappear via the TTL
   sweep, the dead-tty sweep, or the dead-pid sweep — false positives (a
   flaky tty check, a sweep racing a legitimate reconnect) or genuine gaps
   (the user steps away, comes back later) are indistinguishable from a
   truly-dead session at the moment of reaping. These should leave a
   recoverable trace, not be silently dropped, *unless* the disappearance was
   an explicit `end-session` — that one's a real, deliberate "this is over"
   and must never be resurrected.

4. **Matching signals, refined through discussion.** Initially proposed
   `{pid, tty, cwd}`, 2-of-3. Wrong: **pid is guaranteed to differ** on a
   real compaction/resume fork (that's the whole point of forking a new
   process) — it's only useful for the *other* recovery case, a session that
   was never actually dead (false-reap, same pid still running). Conversely,
   Claude Code's `ai-title` (`extract_title` in `hooks.sh`, surfaced today as
   `--label`) is generated once early in a conversation and — per direct
   observation — carries forward into a post-compaction continuation's
   transcript, making it a *conversation-identity* signal that survives
   exactly the case where pid/tty (both *OS-process-identity* signals)
   can't. Final design: a pooled candidate set `{label, cwd, tty, pid}`, ≥2
   must agree, cwd never counts alone (already documented as non-unique).
   The right pair falls out naturally per scenario — title+cwd for a
   compaction/resume fork, pid+cwd or pid+tty for a false-reap — without
   hardcoding which two apply to which cause.

5. **`Registry`/`Shared.usage` are pure in-memory today**
   (`daemon.rs::run()` always starts fresh). A daemon restart wipes both
   `focalpoint sessions` and `focalpoint usage` until adapters naturally
   re-report — this was watched happening firsthand. Both should survive a
   restart, and since the tombstone grace window (point 3) can be configured
   to *never* expire (explicitly requested — sessions carried through a
   reboot should still be recoverable), tombstones need to survive a restart
   too, not just live sessions.

## Part 1 — Rust-native identity resolution (replaces bash `ps`-walking)

### New module: `daemon/src/identity.rs`

Pure, trait-driven, same testing philosophy as `session.rs`'s mockable
`Instant` (`ProcessSource` stands in for what `now: Instant` does there):

```rust
/// Everything the resolver needs to know about one process. Abstracted
/// behind a trait so the walk logic is unit-testable against a fixed fake
/// process tree (see tests) without spawning real processes.
pub trait ProcessSource {
    fn ppid(&self, pid: i32) -> Option<i32>;
    fn comm(&self, pid: i32) -> Option<String>;   // process name only
    fn cmd(&self, pid: i32) -> Option<Vec<String>>; // full argv, for the
                                                      // "daemon run --origin
                                                      // transient" rejection
}

pub struct SysinfoProcessSource(sysinfo::System);
impl ProcessSource for SysinfoProcessSource { /* wraps sysinfo::System::refresh_processes + Process::parent/name/cmd */ }

/// Walk from `start_pid` up through parents, remembering the OUTERMOST
/// (nearest-to-terminal) ancestor whose comm matches `target_comm` — not
/// the first hit climbing up — since transient helpers (Claude Code's own
/// `claude daemon run --origin transient --spawned-by ...`) nest *below*
/// the real interactive process, closer to the hook. The argv-based
/// rejection of "daemon run" stays as defense-in-depth on top of the
/// structural rule, not a replacement for it.
pub fn resolve_pid(source: &impl ProcessSource, start_pid: i32, target_comm: &str) -> Option<i32> { ... }
```

Add `sysinfo` to `Cargo.toml` (decided over hand-rolling against `libc` +
macOS `sysctl`/`kinfo_proc`: mature, cross-platform, avoids unsafe FFI
against a struct layout that's easy to get subtly wrong).

### tty resolution needs no ancestor walk at all

The bash version walked ancestors for tty because it wasn't sure the hook's
own process had one attached on fd 0/1/2 (stdin is the hook-JSON pipe). But a
process's *controlling* terminal is independent of what its stdio fds are
redirected to — `open("/dev/tty")` then `ttyname()` on that fd gets it
directly, no ancestor walk needed, since a subprocess normally inherits the
same controlling terminal as its parent unless deliberately detached. `fn
own_tty() -> Option<String>` (self only). This alone is a real simplification
over the original bash design, not just a port of it — only pid resolution
(finding the nearest *outermost* `claude`/`codex`-comm ancestor) genuinely
needs the walk.

### Identity cache

Same lifecycle as today, moved into Rust: `${XDG_STATE_HOME:-$HOME/.local/state}/
focalpoint/sessions/<session_id>.json` (JSON now, not shell-sourceable env —
nothing needs to `source` it anymore). Read/write lives in `identity.rs`
too — `load_identity(session_id)` / `save_identity(session_id, Identity)`.

### CLI integration (`src/client.rs` / `src/bin/focalpoint.rs`)

`set-state`/`set-meta`, when called with `--session <id>` **and** `--kind
claude|codex` (skip for `cursor`/`generic`/unknown — no ancestor walk wanted
there, same reasoning as today), automatically resolve identity unless the
caller already passed an explicit `--meta tty=`/`--meta pid=`:

- New `--refresh-identity` flag: forces a fresh walk + cache overwrite.
  `hooks.sh`/`codex-cli/hooks.sh` pass this exactly on `SessionStart`, mirror
  of the current `if event == SessionStart || !load_identity` gate, just
  moved server-side-of-the-CLI-call instead of client-side-in-bash.
- Otherwise: load the cache; only walk (and save) if no cache exists yet.
- `client::end_session` deletes the cache file for that id — the one
  natural chokepoint every adapter's `SessionEnd` already calls through.

### Adapter simplification

Both `adapters/claude-code/hooks.sh` and `adapters/codex-cli/hooks.sh` **lose
their entire ancestry-walk block and cache load/save logic** (~30-70 lines
each) — replaced with just passing `--kind claude|codex` and
`--refresh-identity` conditionally on `SessionStart`. This is the actual fix
for point 1: there's now one implementation, shared, so a future adapter
(or Cursor, if tty/pid derivation is ever wanted there) gets it for free by
passing `--kind`, instead of a third copy to maintain and forget to fix.
Remember to sync both adapter changes to their installed copies under
`~/.config/focalpoint/adapters/` after editing the repo source, same pattern
used throughout the prior session's hook fixes.

### Unit tests

`FakeProcessSource` (a small `HashMap`-backed fixture) reproducing: the exact
`daemon run --origin transient` scenario (a known real bug from a prior
session — outermost match must skip it); a plain nested-shell ancestry
(finds the one real match); no match found (returns `None` cleanly);
multiple `claude`-comm ancestors (keeps climbing to the outermost, doesn't
stop at the first). Fully deterministic, no process spawning required.

## Part 2 — Compaction-correct cumulative meta

Two mechanisms, because the two tools' compaction is architecturally
different — not an oversight that Codex only gets one of them. Claude Code
forks a new process/`session_id`/transcript on compaction, so the *daemon*
has to bridge the identity gap. Codex compacts in place (verified above —
same `thread_id`, same rollout file, nothing forks), so its existing
full-transcript recompute is already correct for free; it was only missing
the `compactions` counter itself.

### 2a. Claude Code — daemon-side carry-forward (identity changes)

**Cumulative vs. instantaneous keys:**
- **Cumulative-since-lineage-start** (must survive a rekey/recovery by
  *adding*, never overwriting): `turns`, `tool_calls`, `subagents`,
  `tokens_in`, `tokens_out`, `cost_usd`.
- **Instantaneous** (plain overwrite, unchanged): `tty`, `pid`, `cwd`,
  `model`, `context_tokens`, `context_window`, rate-limit fields. Resetting
  `context_tokens`/`context_window` on compaction is correct, not a bug.

**Mechanism: carry-forward base, applied uniformly.** `daemon/src/session.rs`
gains:

```rust
const CUMULATIVE_META_KEYS: &[&str] =
    &["turns", "tool_calls", "subagents", "tokens_in", "tokens_out", "cost_usd"];

/// Cumulative keys are added to a per-session carried-forward base
/// (`_carry_<key>`, bumped only when a session is recovered — see Part 3);
/// everything else is a plain overwrite, same as always. A session with no
/// recovery history has base 0 for every key, so this is a no-op behavior
/// change for the common (never-compacted, never-recovered) case.
fn apply_meta_update(meta: &mut Map<String, Value>, incoming: Map<String, Value>) { ... }
```

Replaces the three separate `for (k, v) in meta { sess.meta.insert(k, v); }`
loops currently duplicated across `set_state`'s update branch, `set_state`'s
rekey branch, and `merge_meta`.

At the point a session is recovered (Part 3 — this subsumes what's currently
the Compacting-specific rekey branch as one special case of the general
mechanism): snapshot the outgoing/tombstoned session's final cumulative
totals into the new session's `_carry_<key>` fields, and bump `compactions`
by reading it off the *old* session (so repeated compactions compound
correctly, never reset to 1).

`_carry_*` keys ride along in the plain `meta` map — `list-sessions`/
`SessionUpsert`/app UI already see them with no new plumbing (worth a
one-line PROTOCOL.md note that they're internal bookkeeping, safely
ignorable, not a promise never to add more).

### 2b. Codex — adapter-side transcript scan (identity stable)

No daemon changes. `adapters/codex-cli/hooks.sh`'s existing jq stats query
(the one already computing `turns`/`tool_calls`/`tokens_in`/etc. from
`transcript_path` on every `Stop`) gets one more field:

```
compactions: ([.[] | select(.type=="event_msg" and .payload.type=="context_compacted")] | length)
```

(Verified both `{"type":"compacted", "payload":{"replacement_history":...}}`
and the paired `event_msg`/`context_compacted` line appear exactly once per
compaction in real local rollout files — counting the `event_msg` form
matches this query's existing style, filtering on `.type=="event_msg" and
.payload.type==...` the same way `token_count`/`task_complete` already are.)
Sent as `--meta compactions=$compactions` alongside the rest — naturally
cumulative already, same as `turns`, since it's recomputed from the whole
transcript every time. `cost_usd` doesn't exist for Codex today (no
equivalent of `statusline-usage.sh`) — out of scope here, not a gap this plan
needs to close.

## Part 3 — Generalized recovery: tombstones for non-explicit disappearance

### Two removal paths, kept distinct

- **`end_session` (explicit)** — unchanged signature, used by the
  `"end-session"` socket handler (adapter's `SessionEnd`, or a user running
  `focalpoint end-session` directly). Never creates a tombstone; if one
  somehow already exists for that id, removes it. This is the "manual
  removal must clear entries" requirement — applies to the identity cache
  file (Part 1, already covered by `client::end_session`), any tombstone
  (this part), and is naturally reflected in the next persisted snapshot
  (Part 4, since it's just another mutating effect).
- **`reap_session` (new, internal)** — used by every sweep (TTL, dead-tty,
  dead-pid, `expire_compacting`) and by Part 4's startup reconciliation.
  Does what `end_session` does *plus* stashes a tombstone first.

### Tombstone pool

```rust
struct Tombstone {
    session: Session,      // full last-known state, incl. meta/label/kind
    reaped_at: Instant,
}
// on Registry: tombstones: HashMap<String /* old id */, Tombstone>
```

### Matching, on every new/unknown session_id registration

Candidate pool `{label, cwd, tty, pid}` (pulling from the incoming event's
own values vs. each live tombstone's stored `Session`) — **≥2 must agree**,
cwd never counts alone. `State::Compacting`'s existing cwd+tty fast-path
match stays as-is functionally (it's just the pooled rule evaluated at the
moment a `Compacting`-marked session's continuation shows up, almost always
before `COMPACT_GRACE` elapses) but now uses the same general matcher instead
of a separate hardcoded cwd+tty check — one implementation instead of two.

On match: reuse the existing `Effect::SessionRekeyed { old_id, new_id }` (no
new effect type needed — recovery *is* a rekey, just from a wider set of
causes than compaction alone), apply the carry-forward from Part 2, consume
the tombstone.

### Tombstone grace period — new config knob, supports infinite

`[session] tombstone_ttl_minutes` in `config.toml`, mirroring the exact
`ttl_minutes` convention already in `daemon/src/config.rs` (`0` = never
expire → `None` Duration; unset → a sane default). Kept separate from the
small hardcoded `COMPACT_GRACE` (5 min), which still governs how long a
*visible* `Compacting` key stays on-screen before being demoted to an
invisible tombstone via `expire_compacting` (now calling `reap_session`
instead of `end_session`, so a very-late compaction continuation isn't lost
outright, just no longer shown as "compacting"). The user who commissioned
this plan wants this set to infinite personally (sessions left through
reboots) — `0` must genuinely mean never-expire end to end, not just at the
config-parsing layer, so verify it holds through Part 4's persistence too.

## Part 4 — Persist sessions + tombstones + usage across daemon restarts

Extended to cover tombstones (required now that their grace period can be
infinite — a session "left through a reboot" must still be there to recover
after restart):

- One snapshot file, `paths::daemon_state_path()` → `${XDG_STATE_HOME:-
  $HOME/.local/state}/focalpoint/state.json`:
  `{ saved_at_unix_ms, sessions: [...], tombstones: [...], usage: {...} }`.
- **Write**: `apply_effects()` re-saves after any session-affecting effect
  (now including reap-driven `SessionEnded`s that also touched
  `tombstones`); `"set-usage"` gets its own explicit save call (doesn't flow
  through `apply_effects`).
- **Read**: `run()` loads the snapshot in place of `Registry::new(ttl)` /
  `usage: HashMap::new()`.
- **Timestamp reconstruction** (sessions' `last_update`, tombstones'
  `reaped_at` — both `Instant`, meaningless across a restart): persist as an
  elapsed-ms offset + one top-level wall-clock `saved_at_unix_ms`; on load,
  `restored_instant = Instant::now() - (elapsed_ms + gap_since_saved_at)`.
  Keeps the TTL sweep, `COMPACT_GRACE`, and `tombstone_ttl_minutes` all
  correct immediately post-restart instead of resetting their clocks.
- **Startup reconciliation**: after restoring live sessions, run the
  existing tty/pid liveness checks once synchronously — anything actually
  dead now goes through `reap_session` (tombstoned), not a hard drop, so a
  session that died *while the daemon was down* is still recoverable via
  label+cwd, not silently gone. `usage` and infinite-TTL tombstones have no
  liveness concept — restored as-is, no reconciliation needed.
- **`Registry::restore(...)`**: rebuild both `sessions` and `tombstones` from
  the loaded snapshot; slot collisions (shouldn't happen from a snapshot the
  daemon itself wrote) fall back to `lowest_free_slot`.
- Missing/corrupt/unreadable snapshot: silent no-op, start empty — same
  tolerance `Config::load()` already has for a missing `config.toml`. No new
  "enable persistence" flag; always on, matching the existing "graceful
  degradation is load-bearing" pattern (`CLAUDE.md`).
- Downstream is free: `list-sessions`/`get-usage`/`replay_state_cmds`
  (device reconnect) already treat "whatever's in `Shared`" as ground truth,
  restored-from-disk or not — no new socket-event plumbing.

## Part 5 — Integration test harness (built last, after unit tests)

New `daemon/tests/session_lifecycle.rs`, reusing the daemon's already-
documented `--mock-device` + `focalpoint inject`/`set-state` smoke-test
pattern (`daemon/README.md`) instead of inventing new infrastructure:

- Locate the real binaries via Cargo's `CARGO_BIN_EXE_focalpointd` /
  `CARGO_BIN_EXE_focalpoint` (no manual build step).
- Spawn `focalpointd --mock-device` per test with `XDG_RUNTIME_DIR`/
  `XDG_STATE_HOME` pointed at a per-test tempdir (full isolation, both from
  the real user daemon and between parallel tests — the existing path
  resolution in `paths.rs` already reads these env vars, no source changes
  needed for this).
- Poll for readiness (socket file exists + a `get-state` call succeeds) with
  a bounded retry loop rather than a fixed sleep — a real daemon restart was
  observed taking a highly variable amount of time under system load during
  the prior debugging session; don't assume a fixed short sleep is safe.
- Drive it through real CLI subprocess calls end to end and assert on real
  `focalpoint sessions --json` / `focalpoint usage --json` output over the
  actual socket protocol:
  - Basic register → update → end-session lifecycle.
  - Compaction continuation: stats carry and add correctly, `compactions`
    increments, `context_tokens` still resets.
  - False-reap-and-recover via pid match (same pid, new session_id, reaped
    then un-reaped).
  - Idle-disappear-and-recover via label+cwd match (different pid/tty,
    simulating a resumed session after the original process is long gone).
  - Explicit `end-session` leaves no recoverable tombstone (a
    would-otherwise-match session afterward registers fresh, stats at zero).
  - Daemon restart mid-session: kill and respawn `focalpointd` pointed at
    the same state dir — session, tombstone, and usage all survive.
  - `tombstone_ttl_minutes = 0` (infinite): survives a restart *and* an
    artificially-aged tombstone still recovers well past what the default
    would have allowed.

## Files

- `daemon/Cargo.toml` — add `sysinfo`.
- `daemon/src/identity.rs` — new: `ProcessSource` trait + `sysinfo` impl,
  `resolve_pid`, `own_tty`, identity cache read/write.
- `daemon/src/client.rs` / `src/bin/focalpoint.rs` — wire automatic identity
  resolution + `--refresh-identity` into `set-state`/`set-meta`; cache
  cleanup in `end_session`.
- `adapters/claude-code/hooks.sh`, `adapters/codex-cli/hooks.sh` (+ installed
  copies) — delete the ancestry-walk/cache blocks; pass `--kind`/
  `--refresh-identity` instead; codex-cli/hooks.sh also gets the 2b
  `compactions` jq field.
- `daemon/src/session.rs` — `CUMULATIVE_META_KEYS` + `apply_meta_update`;
  `Tombstone` + `tombstones` map; `reap_session` (new) vs `end_session`
  (unchanged contract); pooled recovery matcher; `Registry::restore(...)`.
- `daemon/src/config.rs` — `tombstone_ttl_minutes` in `[session]`, mirroring
  `ttl_minutes`'s existing `0 = never` convention.
- `daemon/src/paths.rs` — `daemon_state_path()`.
- `daemon/src/daemon.rs` — extract `session_to_json`; `save_snapshot`
  (called from `apply_effects` and `"set-usage"`); load + startup
  reconciliation in `run()` (now reaping-with-tombstone, not dropping);
  sweeps call `reap_session` instead of `end_session`.
- `daemon/tests/session_lifecycle.rs` — new, Part 5.
- `PROTOCOL.md` — identity resolution is now daemon-side (adapters no longer
  compute tty/pid themselves); compaction preserves cumulative stats +
  `compactions` counter; general recovery/tombstone model and its matching
  rule; `tombstone_ttl_minutes` config; session/usage state survives a
  daemon restart. All additive/doc-only, no wire-format change.

## Verification

1. `cargo test` — full suite green throughout, plus new unit tests for each
   mechanism above (identity walk fixtures, cumulative-carry across repeated
   compactions, pooled-match recovery with each qualifying/non-qualifying
   pair, `Registry::restore`, config parsing for `tombstone_ttl_minutes`
   including `0`).
2. `bash -n` both simplified adapter scripts.
3. `cargo test --test session_lifecycle` (Part 5) green.
4. Live end-to-end against the real daemon, mirroring Part 5's scenarios one
   more time against the actual installed adapters with a real Claude
   Code/Codex session: identity still resolves correctly post-refactor,
   compaction stats survive a real `/compact`, a real daemon restart
   preserves everything, `end-session` leaves nothing recoverable behind.
