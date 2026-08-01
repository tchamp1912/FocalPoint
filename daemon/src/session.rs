//! Multi-session registry (PROTOCOL.md §3 Sessions).
//!
//! Pure, side-effect-free logic so it is fully unit-testable with a mockable
//! clock (methods take `now: Instant`). Mutating operations return a list of
//! [`Effect`]s; the daemon translates those into device commands
//! (`SET_KEY_STATE` / `SET_STATE`) and subscriber events.
//!
//! Slot rules: each identified session claims the lowest free numbered key
//! (1..=12) at registration and keeps it for its lifetime; sessions beyond 12
//! get `slot: None`. A `set-state` with no session id updates the sessionless
//! *default* session, which occupies no slot but still counts toward the
//! aggregate (back-compat). The default never expires and is never listed or
//! emitted as a session event.

use crate::protocol::State;
use serde_json::{Map, Value};
use std::collections::HashMap;
use std::time::{Duration, Instant};

/// How long a session may sit in `State::Compacting` waiting to be reunited
/// with its post-compaction continuation (see `Registry::set_state`'s rekey
/// match below) before it's treated as abandoned and reaped outright by
/// `Registry::expire_compacting`. Generous relative to how fast a
/// continuation actually shows up (well under a second on an interactive
/// terminal; a few seconds at most on a background job that has to fork a
/// new process) but still a hard bound, independent of
/// `session_ttl_minutes`/`None`, so a compaction that never completes (the
/// user cancels it, or the continuation genuinely never appears) can't leave
/// a "compacting" indicator stuck on-screen indefinitely.
const COMPACT_GRACE: Duration = Duration::from_secs(300);

/// Meta keys Claude Code's adapter reports as "cumulative since this
/// segment's transcript/process started," not "current instantaneous
/// reading" (`adapters/claude-code/hooks.sh`'s `extract_stats`,
/// `statusline-usage.sh`'s `cost_usd`). A compaction rekey (below) starts a
/// new transcript/process, so these must be *added* to the carried-forward
/// base from any prior segment(s), never overwritten outright, or a
/// compaction would silently erase everything before it. Everything else
/// (`tty`, `pid`, `cwd`, `model`, `context_tokens`, `context_window`, ...)
/// is a plain overwrite as always — `context_tokens`/`context_window`
/// resetting on compaction is correct, not a bug, since that's what
/// compaction means. Codex needs none of this: verified against real
/// rollout files that its compaction happens in place (same `thread_id`,
/// same transcript), so its adapter-side full-transcript recompute is
/// already correctly cumulative with no daemon involvement — see
/// SESSION-IDENTITY-PERSISTENCE-PLAN.md Part 2.
const CUMULATIVE_META_KEYS: &[&str] =
    &["turns", "tool_calls", "subagents", "tokens_in", "tokens_out", "cost_usd"];

/// Add `incoming` to the carried-forward base for `key` (`carry`, 0 if
/// absent — the common, never-compacted case).
/// Prefers integer arithmetic when both sides are whole numbers so a
/// never-compacted session's counters keep displaying as plain integers
/// (`7`, not `7.0`) — what makes this mechanism a true no-op for the common
/// case, not just numerically equivalent.
fn add_carry(carry: &Map<String, Value>, key: &str, incoming: &Value) -> Value {
    let base = carry.get(key);
    let base_is_int = base.map_or(true, |b| b.is_i64() || b.is_u64());
    if base_is_int {
        if let Some(vi) = incoming.as_i64() {
            let bi = base.and_then(Value::as_i64).unwrap_or(0);
            return Value::from(bi + vi);
        }
    }
    let bf = base.and_then(Value::as_f64).unwrap_or(0.0);
    let vf = incoming.as_f64().unwrap_or(0.0);
    Value::from(bf + vf)
}

/// Apply an incoming meta update to `meta`. Cumulative keys
/// (`CUMULATIVE_META_KEYS`) are added to their carried-forward base rather
/// than overwritten; everything else is a plain overwrite, same as always.
/// Shared by `set_state`'s update and rekey branches and by `merge_meta`, so
/// there's exactly one place this distinction is made.
fn apply_meta_update(
    meta: &mut Map<String, Value>,
    carry: &Map<String, Value>,
    incoming: Map<String, Value>,
) {
    for (k, v) in incoming {
        if CUMULATIVE_META_KEYS.contains(&k.as_str()) && v.is_number() {
            let added = add_carry(carry, &k, &v);
            meta.insert(k, added);
            continue;
        }
        meta.insert(k, v);
    }
}

/// How many of `{label, cwd, tty, pid}` agree between `candidate` and the
/// incoming registration's own values. Each field only counts when
/// non-empty/present on *both* sides — an empty-vs-empty "match" (e.g. two
/// sessions that both failed to resolve a tty) must never count, or two
/// unrelated sessions sharing nothing real could still hit the threshold.
/// See `Registry::find_recovery_candidate` for how the resulting score is
/// used (≥2 required).
fn count_identity_matches(
    candidate: &Session,
    incoming_label: &str,
    incoming_cwd: &str,
    incoming_tty: &str,
    incoming_pid: Option<i32>,
) -> u32 {
    let mut n = 0;
    if !incoming_label.is_empty() && Some(incoming_label) == candidate.label.as_deref() {
        n += 1;
    }
    if !incoming_cwd.is_empty() && incoming_cwd == candidate.cwd() {
        n += 1;
    }
    if !incoming_tty.is_empty() && incoming_tty == candidate.tty() {
        n += 1;
    }
    if let (Some(a), Some(b)) = (incoming_pid, candidate.pid()) {
        if a == b {
            n += 1;
        }
    }
    n
}

/// A live, identified session.
#[derive(Debug, Clone)]
pub struct Session {
    pub id: String,
    pub kind: Option<String>,
    pub label: Option<String>,
    /// User-assigned display name (`rename-session`), overriding `label`.
    ///
    /// Deliberately a *separate* field rather than a write to `label`:
    /// adapters re-send `--label` on every hook event (see
    /// `adapters/claude-code/hooks.sh`), so a rename stored in `label` would
    /// be clobbered by the session's very next state change. Nothing but
    /// `rename-session` ever writes this.
    pub name: Option<String>,
    pub meta: Map<String, Value>,
    /// Carried-forward bases for cumulative meta counters across a rekey.
    /// This is daemon bookkeeping, deliberately separate from public `meta`.
    pub carry: Map<String, Value>,
    /// Numbered key 1..=12, or `None` if this session overflowed (>12 live).
    pub slot: Option<u8>,
    pub state: State,
    pub last_update: Instant,
}

impl Session {
    /// What a UI should show for this session: the user's name if they set
    /// one, else the adapter's label, else the kind.
    pub fn display_name(&self) -> String {
        [&self.name, &self.label, &self.kind]
            .into_iter()
            .flatten()
            .find(|v| !v.is_empty())
            .cloned()
            .unwrap_or_else(|| self.id.clone())
    }

    /// The well-known `cwd` from `meta`, or `""`.
    pub fn cwd(&self) -> String {
        self.meta
            .get("cwd")
            .and_then(|v| v.as_str())
            .unwrap_or("")
            .to_string()
    }

    /// The well-known `tty` from `meta` (e.g. `/dev/ttys003`), or `""`. Set via
    /// `--meta tty=$(tty)`; lets a focus action match the exact terminal
    /// session instead of guessing from window titles (which agents may not
    /// set to the cwd at all).
    pub fn tty(&self) -> String {
        self.meta
            .get("tty")
            .and_then(|v| v.as_str())
            .unwrap_or("")
            .to_string()
    }

    /// The well-known `pid` from `meta` — Claude Code's own process id,
    /// found by walking the hook's process ancestry (see
    /// adapters/claude-code/hooks.sh). `None` if absent or not a valid
    /// integer. Used by the daemon's dead-process sweep (daemon.rs) to reap
    /// a session whose agent crashed but whose terminal is still open, which
    /// the tty sweep alone can't see.
    pub fn pid(&self) -> Option<i32> {
        self.meta.get("pid").and_then(|v| v.as_i64()).map(|n| n as i32)
    }
}

/// A change the daemon must apply to the device and/or subscribers.
#[derive(Debug, Clone, PartialEq)]
pub enum Effect {
    /// A session was registered or updated. `SET_KEY_STATE` if it has a slot;
    /// always a `session` event.
    SessionUpsert {
        id: String,
        kind: Option<String>,
        label: Option<String>,
        name: Option<String>,
        meta: Map<String, Value>,
        slot: Option<u8>,
        state: State,
    },
    /// A session ended for good — an explicit `end-session`, a user
    /// dismissing an already-disconnected session, or a tombstone aging out
    /// past `tombstone_ttl`. `SET_KEY_STATE <slot> 0xFF` if it still held a
    /// slot; always a `session-ended` event. Subscribers remove it.
    SessionEnded { id: String, slot: Option<u8> },
    /// A session was reaped by a *sweep* (TTL / dead-tty / dead-pid /
    /// stuck-compacting) rather than explicitly ended. It moves to a
    /// recoverable tombstone and frees its numbered-key slot on the device,
    /// but — unlike `SessionEnded` — subscribers must keep rendering it as a
    /// *disconnected* session (PROTOCOL.md §3) until it's explicitly ended,
    /// manually dismissed, recovered, or its tombstone TTL expires. `slot` is
    /// the slot it just vacated (so the device key can be cleared).
    SessionDisconnected { id: String, slot: Option<u8> },
    /// A `Compacting` session was reunited with its post-compaction
    /// continuation under a new id (same slot, name, and history) — see
    /// `Registry::set_state`. No device command (the slot doesn't change);
    /// always a `session-rekeyed` event, emitted before the `SessionUpsert`
    /// that carries the continuation's actual state.
    SessionRekeyed { old_id: String, new_id: String },
    /// The aggregate state changed. `SET_STATE` + a `state` event.
    AggregateChanged { state: State },
}

/// The session registry.
/// A session's last-known state, kept around after it disappeared via a
/// sweep (TTL/dead-tty/dead-pid/stuck-compacting) rather than an explicit
/// `end-session` — so that if a matching session reappears (a false-reap
/// that was never really dead, or a genuine resume after an unexplained
/// gap), it can be reunited instead of starting over at zero. Never created
/// by `end_session` (a deliberate "this is over" must never be
/// resurrected) — see `reap_session` vs `end_session`.
#[derive(Debug, Clone)]
struct Tombstone {
    session: Session,
    reaped_at: Instant,
}

/// Default tombstone lifetime when `tombstone_ttl_minutes` isn't set in
/// config.toml — long enough to survive a real coffee-break-length gap, not
/// so long that a stale tombstone lingers and gets picked up as a spurious
/// "match" far later than makes sense. Explicitly overridable, including to
/// `None` (never expire) via `with_tombstone_ttl` — see `config.rs`.
const DEFAULT_TOMBSTONE_TTL: Duration = Duration::from_secs(30 * 60);

pub struct Registry {
    sessions: HashMap<String, Session>,
    tombstones: HashMap<String, Tombstone>,
    default_state: Option<State>,
    /// Last aggregate we emitted, for change detection.
    last_aggregate: State,
    /// TTL for identified sessions; `None` = never expire.
    ttl: Option<Duration>,
    /// How long a tombstone stays recoverable; `None` = never expire.
    tombstone_ttl: Option<Duration>,
}

impl Registry {
    pub fn new(ttl: Option<Duration>) -> Self {
        Registry {
            sessions: HashMap::new(),
            tombstones: HashMap::new(),
            default_state: None,
            last_aggregate: State::Idle,
            ttl,
            tombstone_ttl: Some(DEFAULT_TOMBSTONE_TTL),
        }
    }

    /// Override the default tombstone lifetime (`daemon.rs` applies the
    /// configured `tombstone_ttl_minutes` after construction). `None` means
    /// never expire — a session "left through a reboot" stays recoverable
    /// indefinitely, which Part 4's restart persistence is what makes that
    /// meaningful rather than moot.
    pub fn with_tombstone_ttl(mut self, tombstone_ttl: Option<Duration>) -> Self {
        self.tombstone_ttl = tombstone_ttl;
        self
    }

    /// Worst state across the default session (if set) and all live sessions.
    pub fn aggregate(&self) -> State {
        let mut worst = State::Idle;
        let mut consider = |s: State| {
            if s.priority() > worst.priority() {
                worst = s;
            }
        };
        if let Some(ds) = self.default_state {
            consider(ds);
        }
        for s in self.sessions.values() {
            consider(s.state);
        }
        worst
    }

    fn lowest_free_slot(&self) -> Option<u8> {
        let used: std::collections::HashSet<u8> =
            self.sessions.values().filter_map(|s| s.slot).collect();
        (1..=12).find(|n| !used.contains(n))
    }

    /// Append an `AggregateChanged` effect iff the aggregate actually moved.
    fn note_aggregate(&mut self, effects: &mut Vec<Effect>) {
        let agg = self.aggregate();
        if agg != self.last_aggregate {
            self.last_aggregate = agg;
            effects.push(Effect::AggregateChanged { state: agg });
        }
    }

    /// Find the best recovery candidate for a newly-registering session, if
    /// any — either a live `State::Compacting` session within
    /// `COMPACT_GRACE` (the fast compaction-continuation path — a
    /// still-visible "compacting" key almost always claimed within
    /// seconds) or a tombstoned one within `tombstone_ttl` (the general
    /// "reappeared after an unexplained sweep-driven disappearance" path).
    /// Same pooled signal matcher either way: `label` (Claude Code's
    /// `ai-title`, verified to survive a compaction fork even though pid/tty
    /// don't — see identity.rs's doc comment for why those two are
    /// OS-process-identity signals that a real fork/resume can't preserve),
    /// `cwd`, `tty`, `pid` — **at least 2 must agree**, and `cwd` alone is
    /// never enough (it's explicitly not unique — multiple simultaneous
    /// sessions commonly share one). The right pair falls out naturally per
    /// cause: label+cwd for a compaction/resume fork (new pid, maybe new
    /// tty), pid+cwd or pid+tty for a false-reap (same process, never
    /// actually died). Ties (same score) broken by most recent activity.
    fn find_recovery_candidate(
        &self,
        incoming_label: &str,
        incoming_cwd: &str,
        incoming_tty: &str,
        incoming_pid: Option<i32>,
        now: Instant,
    ) -> Option<String> {
        let mut best: Option<(String, u32, Instant)> = None;
        let mut consider = |id: &str, candidate: &Session, ts: Instant| {
            let score = count_identity_matches(candidate, incoming_label, incoming_cwd, incoming_tty, incoming_pid);
            if score < 2 {
                return;
            }
            let better = match &best {
                None => true,
                Some((_, best_score, best_ts)) => score > *best_score || (score == *best_score && ts > *best_ts),
            };
            if better {
                best = Some((id.to_string(), score, ts));
            }
        };

        for s in self.sessions.values() {
            if s.state == State::Compacting && now.saturating_duration_since(s.last_update) <= COMPACT_GRACE {
                consider(&s.id, s, s.last_update);
            }
        }
        for (id, t) in self.tombstones.iter() {
            let within_grace = self
                .tombstone_ttl
                .map(|ttl| now.saturating_duration_since(t.reaped_at) <= ttl)
                .unwrap_or(true); // None = never expire
            if within_grace {
                consider(id, &t.session, t.reaped_at);
            }
        }

        best.map(|(id, _, _)| id)
    }

    /// Apply a `set-state`. `id == None` updates the sessionless default.
    pub fn set_state(
        &mut self,
        id: Option<&str>,
        state: State,
        kind: Option<String>,
        label: Option<String>,
        meta: Option<Map<String, Value>>,
        now: Instant,
    ) -> Vec<Effect> {
        let mut effects = Vec::new();
        match id {
            None => {
                self.default_state = Some(state);
            }
            Some(id) => {
                if let Some(sess) = self.sessions.get_mut(id) {
                    // Update + merge.
                    sess.state = state;
                    if kind.is_some() {
                        sess.kind = kind;
                    }
                    if label.is_some() {
                        sess.label = label;
                    }
                    if let Some(m) = meta {
                        apply_meta_update(&mut sess.meta, &sess.carry, m);
                    }
                    sess.last_update = now;
                    effects.push(Effect::SessionUpsert {
                        id: id.to_string(),
                        kind: sess.kind.clone(),
                        label: sess.label.clone(),
                        name: sess.name.clone(),
                        meta: sess.meta.clone(),
                        slot: sess.slot,
                        state,
                    });
                } else {
                    // Before registering a brand-new session, check for a
                    // session it might be the continuation of — either a
                    // live `State::Compacting` one (Claude Code's
                    // `PreCompact` hook, adapters/claude-code/hooks.sh) or a
                    // tombstoned one (a session that disappeared via a sweep
                    // rather than an explicit end-session — see
                    // `reap_session`/`Tombstone` below). Claude Code exposes
                    // no field linking a compaction continuation back to its
                    // predecessor, and a sweep-reaped session obviously
                    // can't link forward either, so `find_recovery_candidate`
                    // matches on a pooled set of signals instead — see its
                    // own doc comment for why pid/tty/cwd/label are each in
                    // the pool and why ≥2 must agree.
                    let incoming_meta = meta.unwrap_or_default();
                    let incoming_cwd = incoming_meta.get("cwd").and_then(|v| v.as_str()).unwrap_or("");
                    let incoming_tty = incoming_meta.get("tty").and_then(|v| v.as_str()).unwrap_or("");
                    let incoming_pid = incoming_meta.get("pid").and_then(|v| v.as_i64()).map(|n| n as i32);
                    let incoming_label = label.as_deref().unwrap_or("");

                    let recovered = self
                        .find_recovery_candidate(incoming_label, incoming_cwd, incoming_tty, incoming_pid, now)
                        .and_then(|old_id| {
                            self.sessions
                                .remove(&old_id)
                                .or_else(|| self.tombstones.remove(&old_id).map(|t| t.session))
                                .map(|sess| (old_id, sess))
                        });

                    if let Some((old_id, mut sess)) = recovered {
                        // Snapshot the outgoing segment's cumulative totals
                        // as the new segment's carried-forward base, and
                        // bump the compaction counter — reading it off the
                        // *old* session so repeated compactions compound
                        // correctly instead of resetting to 1 each time.
                        // See CUMULATIVE_META_KEYS/apply_meta_update above.
                        for key in CUMULATIVE_META_KEYS {
                            if let Some(v) = sess.meta.get(*key).cloned() {
                                sess.carry.insert((*key).to_string(), v);
                            }
                        }
                        let compactions = sess
                            .meta
                            .get("compactions")
                            .and_then(Value::as_u64)
                            .unwrap_or(0)
                            + 1;
                        sess.meta
                            .insert("compactions".to_string(), Value::from(compactions));

                        sess.id = id.to_string();
                        sess.state = state;
                        if kind.is_some() {
                            sess.kind = kind;
                        }
                        if label.is_some() {
                            sess.label = label;
                        }
                        apply_meta_update(&mut sess.meta, &sess.carry, incoming_meta);
                        sess.last_update = now;
                        effects.push(Effect::SessionRekeyed {
                            old_id,
                            new_id: id.to_string(),
                        });
                        effects.push(Effect::SessionUpsert {
                            id: id.to_string(),
                            kind: sess.kind.clone(),
                            label: sess.label.clone(),
                            name: sess.name.clone(),
                            meta: sess.meta.clone(),
                            slot: sess.slot,
                            state,
                        });
                        self.sessions.insert(id.to_string(), sess);
                    } else {
                        // Register.
                        let slot = self.lowest_free_slot();
                        let sess = Session {
                            id: id.to_string(),
                            kind,
                            label,
                            name: None,
                            meta: incoming_meta,
                            carry: Map::new(),
                            slot,
                            state,
                            last_update: now,
                        };
                        effects.push(Effect::SessionUpsert {
                            id: id.to_string(),
                            kind: sess.kind.clone(),
                            label: sess.label.clone(),
                            name: sess.name.clone(),
                            meta: sess.meta.clone(),
                            slot,
                            state,
                        });
                        self.sessions.insert(id.to_string(), sess);
                    }
                }
            }
        }
        self.note_aggregate(&mut effects);
        effects
    }

    /// Apply a `set-meta`: merge `meta` (and optionally `kind`/`label`) into
    /// an **existing** session without touching its `state`. Unlike
    /// `set_state`, an unknown `id` is a no-op — `set-meta` never registers a
    /// new session, since a state-less session has no state to key a
    /// `SET_KEY_STATE` off of. Touches `last_update` like `set_state` does:
    /// a meta report (e.g. the status-line hook reporting cost) is the
    /// session reporting activity, same as a state change — unlike
    /// `rename`, which is the user acting on the session, not the session
    /// itself.
    pub fn merge_meta(
        &mut self,
        id: &str,
        kind: Option<String>,
        label: Option<String>,
        meta: Map<String, Value>,
        now: Instant,
    ) -> Vec<Effect> {
        let Some(sess) = self.sessions.get_mut(id) else {
            return Vec::new();
        };
        if kind.is_some() {
            sess.kind = kind;
        }
        if label.is_some() {
            sess.label = label;
        }
        apply_meta_update(&mut sess.meta, &sess.carry, meta);
        sess.last_update = now;
        vec![Effect::SessionUpsert {
            id: sess.id.clone(),
            kind: sess.kind.clone(),
            label: sess.label.clone(),
            name: sess.name.clone(),
            meta: sess.meta.clone(),
            slot: sess.slot,
            state: sess.state,
        }]
    }

    /// Set (or clear) a session's user-assigned display name.
    ///
    /// `name` is trimmed; empty or whitespace-only clears it, so the UI falls
    /// back to the adapter's label. Returns `None` for an unknown id so the
    /// caller can report that, rather than silently succeeding.
    ///
    /// Does not touch `last_update`: renaming is the *user* acting on a
    /// session, not the session reporting activity, so it must not keep an
    /// otherwise-dead session alive past its TTL.
    pub fn rename(&mut self, id: &str, name: Option<&str>) -> Option<Vec<Effect>> {
        let sess = self.sessions.get_mut(id)?;
        sess.name = name
            .map(str::trim)
            .filter(|n| !n.is_empty())
            .map(str::to_string);
        Some(vec![Effect::SessionUpsert {
            id: sess.id.clone(),
            kind: sess.kind.clone(),
            label: sess.label.clone(),
            name: sess.name.clone(),
            meta: sess.meta.clone(),
            slot: sess.slot,
            state: sess.state,
        }])
    }

    /// End a session by id (idempotent — unknown ids yield no effects).
    /// Explicit only — an adapter's `SessionEnd`, or a user running
    /// `focalpoint end-session` directly: a deliberate "this is over," never
    /// a sweep's guess. Never leaves a recoverable tombstone behind, and
    /// clears one if it somehow already exists for this id — manually
    /// ending a session must actually clear its entries, not just hide them
    /// until a future registration accidentally resurrects it. Contrast
    /// with `reap_session`, used by every sweep instead.
    pub fn end_session(&mut self, id: &str) -> Vec<Effect> {
        let mut effects = Vec::new();
        let tomb = self.tombstones.remove(id);
        if let Some(sess) = self.sessions.remove(id) {
            effects.push(Effect::SessionEnded {
                id: id.to_string(),
                slot: sess.slot,
            });
            self.note_aggregate(&mut effects);
        } else if tomb.is_some() {
            // Dismissing an already-disconnected (tombstoned) session — the
            // "user manually reaps them" path. Its device key was already
            // freed when it was reaped, and a tombstone counts toward neither
            // slots nor the aggregate, so there's nothing to clear on the
            // device (slot: None) and no aggregate to recompute — just tell
            // subscribers to drop the disconnected row.
            effects.push(Effect::SessionEnded {
                id: id.to_string(),
                slot: None,
            });
        }
        effects
    }

    /// End a session the way a sweep does — its tty/pid/TTL genuinely looks
    /// dead, but nothing *said* it was over. Unlike `end_session`, stashes
    /// a `Tombstone` so a later matching registration can be reunited with
    /// its history instead of starting over at zero (`find_recovery_candidate`).
    /// Used by every sweep (TTL, dead-tty, dead-pid, stuck-compacting) and
    /// by Part 4's startup reconciliation — never by an explicit
    /// end-session (see `end_session`).
    pub fn reap_session(&mut self, id: &str, now: Instant) -> Vec<Effect> {
        let mut effects = Vec::new();
        if let Some(sess) = self.sessions.remove(id) {
            // Not `SessionEnded`: a swept session stays visible as
            // *disconnected* (still rendered until explicitly ended,
            // dismissed, recovered, or its tombstone TTL expires), while its
            // device key is freed and it drops out of slots/aggregate — see
            // `Effect::SessionDisconnected`.
            effects.push(Effect::SessionDisconnected {
                id: id.to_string(),
                slot: sess.slot,
            });
            self.tombstones.insert(
                id.to_string(),
                Tombstone {
                    session: sess,
                    reaped_at: now,
                },
            );
            self.note_aggregate(&mut effects);
        }
        effects
    }

    /// Drop tombstones past `tombstone_ttl`. No-op when `None` (never).
    /// A tombstone is now surfaced to subscribers as a *disconnected* session
    /// (PROTOCOL.md §3, `list-sessions` `connected: false`), so aging one out
    /// emits a `SessionEnded` to remove that row — the "auto-remove after
    /// `tombstone_ttl_minutes`" the config knob controls (`0` = never, so this
    /// returns nothing at all). `slot: None` — the device key was already
    /// freed when the session was reaped, and the vacated slot may since have
    /// been reclaimed by a live session we must not clear.
    pub fn expire_tombstones(&mut self, now: Instant) -> Vec<Effect> {
        let Some(ttl) = self.tombstone_ttl else {
            return Vec::new();
        };
        let mut expired: Vec<String> = self
            .tombstones
            .iter()
            .filter(|(_, t)| now.saturating_duration_since(t.reaped_at) >= ttl)
            .map(|(id, _)| id.clone())
            .collect();
        expired.sort();
        expired
            .into_iter()
            .map(|id| {
                self.tombstones.remove(&id);
                Effect::SessionEnded { id, slot: None }
            })
            .collect()
    }

    /// Swap the numbered-key slots of two live sessions — manual reorder
    /// (drag-and-drop in the app's dropdown), distinct from the automatic
    /// "lowest free slot, kept for life" assignment every other path uses.
    /// Both sessions must currently hold a slot; a slotless session (>12
    /// live, overflow) can't participate since there's no slot to give it.
    /// Doesn't touch `last_update` for either — a reorder isn't activity.
    pub fn swap_slots(&mut self, id1: &str, id2: &str) -> Result<Vec<Effect>, String> {
        if id1 == id2 {
            return Ok(Vec::new());
        }
        let slot1 = self
            .sessions
            .get(id1)
            .and_then(|s| s.slot)
            .ok_or_else(|| format!("unknown session or no slot: {id1:?}"))?;
        let slot2 = self
            .sessions
            .get(id2)
            .and_then(|s| s.slot)
            .ok_or_else(|| format!("unknown session or no slot: {id2:?}"))?;
        if let Some(s) = self.sessions.get_mut(id1) {
            s.slot = Some(slot2);
        }
        if let Some(s) = self.sessions.get_mut(id2) {
            s.slot = Some(slot1);
        }
        let effects = [id1, id2]
            .into_iter()
            .filter_map(|id| self.sessions.get(id))
            .map(|s| Effect::SessionUpsert {
                id: s.id.clone(),
                kind: s.kind.clone(),
                label: s.label.clone(),
                name: s.name.clone(),
                meta: s.meta.clone(),
                slot: s.slot,
                state: s.state,
            })
            .collect();
        Ok(effects)
    }

    /// End all sessions past their TTL. No-op when TTL is `None` (never).
    /// Routes through `reap_session` — an idle timeout isn't a deliberate
    /// "this is over," so the session stays recoverable as a tombstone.
    pub fn expire(&mut self, now: Instant) -> Vec<Effect> {
        let mut effects = Vec::new();
        let Some(ttl) = self.ttl else {
            return effects;
        };
        let mut expired: Vec<String> = self
            .sessions
            .values()
            .filter(|s| now.saturating_duration_since(s.last_update) >= ttl)
            .map(|s| s.id.clone())
            .collect();
        expired.sort();
        for id in expired {
            effects.extend(self.reap_session(&id, now));
        }
        effects
    }

    /// End any session stuck in `State::Compacting` past `COMPACT_GRACE` —
    /// its continuation never showed up (compaction was cancelled, or
    /// genuinely never claimed the slot). Runs unconditionally, unlike
    /// `expire`: a stuck "compacting" indicator is actively misleading (it
    /// promises "this is temporary"), so it can't be left to
    /// `session_ttl_minutes`, which may be configured to never expire.
    /// Routes through `reap_session` — a very-late continuation shouldn't be
    /// lost outright, just no longer shown as "compacting" (Part 3).
    pub fn expire_compacting(&mut self, now: Instant) -> Vec<Effect> {
        let mut effects = Vec::new();
        let mut stuck: Vec<String> = self
            .sessions
            .values()
            .filter(|s| {
                s.state == State::Compacting
                    && now.saturating_duration_since(s.last_update) >= COMPACT_GRACE
            })
            .map(|s| s.id.clone())
            .collect();
        stuck.sort();
        for id in stuck {
            effects.extend(self.reap_session(&id, now));
        }
        effects
    }

    /// Live sessions in slot order; slotless ones last (PROTOCOL.md §3).
    pub fn list(&self) -> Vec<Session> {
        let mut v: Vec<Session> = self.sessions.values().cloned().collect();
        v.sort_by_key(|s| (s.slot.is_none(), s.slot.unwrap_or(0), s.id.clone()));
        v
    }

    /// `(slot, state)` pairs for sessions with slots, in slot order. Used to
    /// replay per-key state to a (re)connected device.
    pub fn slot_states(&self) -> Vec<(u8, State)> {
        let mut v: Vec<(u8, State)> = self
            .sessions
            .values()
            .filter_map(|s| s.slot.map(|slot| (slot, s.state)))
            .collect();
        v.sort_by_key(|(slot, _)| *slot);
        v
    }

    /// The live session occupying `slot`, if any (for focus dispatch).
    pub fn session_by_slot(&self, slot: u8) -> Option<&Session> {
        self.sessions.values().find(|s| s.slot == Some(slot))
    }

    /// A session by id — live, or its last-known record if it's a tombstoned
    /// (disconnected) session. Used by `focus-session` so a disconnected
    /// session can still be focused by id: a reap frequently just means "idle
    /// past the TTL" (the agent and its terminal are still very much alive,
    /// the user simply hasn't prompted it in a while) or a dead-pid crash
    /// where the terminal window remains — in both cases the tty is still
    /// worth switching to. The slot-based `session_by_slot` can't reach a
    /// tombstone, and its vacated slot may since have been reclaimed.
    pub fn session_or_tombstone(&self, id: &str) -> Option<Session> {
        self.sessions
            .get(id)
            .cloned()
            .or_else(|| self.tombstones.get(id).map(|t| t.session.clone()))
    }

    /// All current tombstones as `(old_id, session, reaped_at)` — for
    /// persistence (`daemon.rs`'s `save_snapshot`) only, never part of any
    /// visible API (a tombstone is invisible bookkeeping, not shown in
    /// `list()`).
    pub fn tombstones_snapshot(&self) -> Vec<(String, Session, Instant)> {
        self.tombstones
            .iter()
            .map(|(id, t)| (id.clone(), t.session.clone(), t.reaped_at))
            .collect()
    }

    /// Rebuild a registry from a previously-persisted snapshot (`daemon.rs`
    /// startup, `paths::daemon_state_path`). Slots are preserved as saved; a
    /// collision (shouldn't happen from a snapshot the daemon itself wrote)
    /// falls back to the next free slot rather than dropping/overwriting.
    /// Reconstructing `last_update`/`reaped_at` from the snapshot's elapsed-
    /// ms offsets is the caller's job (daemon.rs) — this just inserts
    /// whatever `Instant`s it's given.
    pub fn restore(
        ttl: Option<Duration>,
        tombstone_ttl: Option<Duration>,
        sessions: Vec<Session>,
        tombstones: Vec<(String, Session, Instant)>,
    ) -> Registry {
        let mut r = Registry::new(ttl).with_tombstone_ttl(tombstone_ttl);
        for mut s in sessions {
            if let Some(slot) = s.slot {
                if r.sessions.values().any(|x| x.slot == Some(slot)) {
                    s.slot = r.lowest_free_slot();
                }
            }
            r.sessions.insert(s.id.clone(), s);
        }
        for (old_id, session, reaped_at) in tombstones {
            r.tombstones.insert(old_id, Tombstone { session, reaped_at });
        }
        r.last_aggregate = r.aggregate();
        r
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    fn t0() -> Instant {
        Instant::now()
    }

    #[test]
    fn registers_and_assigns_lowest_free_slot() {
        let mut r = Registry::new(Some(Duration::from_secs(3600)));
        let now = t0();
        let e = r.set_state(Some("a"), State::Thinking, Some("claude".into()), None, None, now);
        assert!(e.contains(&Effect::SessionUpsert {
            id: "a".into(),
            kind: Some("claude".into()),
            label: None,
            name: None,
            meta: Map::new(),
            slot: Some(1),
            state: State::Thinking,
        }));
        r.set_state(Some("b"), State::Running, Some("codex".into()), None, None, now);
        r.set_state(Some("c"), State::Idle, None, None, None, now);
        let slots: Vec<_> = r.list().iter().map(|s| (s.id.clone(), s.slot)).collect();
        assert_eq!(
            slots,
            vec![
                ("a".into(), Some(1)),
                ("b".into(), Some(2)),
                ("c".into(), Some(3))
            ]
        );
    }

    #[test]
    fn ending_frees_slot_and_next_registration_reuses_it() {
        let mut r = Registry::new(None);
        let now = t0();
        r.set_state(Some("a"), State::Running, None, None, None, now);
        r.set_state(Some("b"), State::Running, None, None, None, now);
        r.set_state(Some("c"), State::Running, None, None, None, now);
        // End b (slot 2). Its slot should free up.
        let e = r.end_session("b");
        assert!(e.contains(&Effect::SessionEnded {
            id: "b".into(),
            slot: Some(2),
        }));
        // New session reuses slot 2 (lowest free), not slot 4.
        r.set_state(Some("d"), State::Running, None, None, None, now);
        assert_eq!(r.session_by_slot(2).unwrap().id, "d");
    }

    #[test]
    fn swap_slots_exchanges_two_sessions() {
        let mut r = Registry::new(None);
        let now = t0();
        r.set_state(Some("a"), State::Running, None, None, None, now);
        r.set_state(Some("b"), State::Running, None, None, None, now);
        r.set_state(Some("c"), State::Running, None, None, None, now);
        let effects = r.swap_slots("a", "c").unwrap();
        assert_eq!(r.sessions.get("a").unwrap().slot, Some(3));
        assert_eq!(r.sessions.get("b").unwrap().slot, Some(2));
        assert_eq!(r.sessions.get("c").unwrap().slot, Some(1));
        assert!(effects.iter().any(|e| matches!(e,
            Effect::SessionUpsert { id, slot: Some(3), .. } if id == "a")));
        assert!(effects.iter().any(|e| matches!(e,
            Effect::SessionUpsert { id, slot: Some(1), .. } if id == "c")));
    }

    #[test]
    fn swap_slots_rejects_unknown_or_slotless() {
        let mut r = Registry::new(None);
        let now = t0();
        r.set_state(Some("a"), State::Running, None, None, None, now);
        assert!(r.swap_slots("a", "ghost").is_err());
        // Same id is a no-op, not an error.
        assert_eq!(r.swap_slots("a", "a").unwrap(), Vec::new());
    }

    #[test]
    fn slots_are_stable_across_updates() {
        let mut r = Registry::new(None);
        let now = t0();
        r.set_state(Some("a"), State::Running, None, None, None, now);
        r.set_state(Some("b"), State::Running, None, None, None, now);
        r.end_session("a"); // frees slot 1
                            // Updating b must NOT move it to slot 1.
        r.set_state(Some("b"), State::Waiting, None, None, None, now);
        assert_eq!(r.sessions.get("b").unwrap().slot, Some(2));
    }

    #[test]
    fn overflow_beyond_twelve_gets_no_slot() {
        let mut r = Registry::new(None);
        let now = t0();
        for i in 0..13 {
            r.set_state(Some(&format!("s{i}")), State::Idle, None, None, None, now);
        }
        let slotless: Vec<_> = r.list().into_iter().filter(|s| s.slot.is_none()).collect();
        assert_eq!(slotless.len(), 1);
        // Slotless sorts last.
        assert!(r.list().last().unwrap().slot.is_none());
    }

    #[test]
    fn aggregate_is_worst_across_sessions_and_default() {
        let mut r = Registry::new(None);
        let now = t0();
        assert_eq!(r.aggregate(), State::Idle);
        r.set_state(Some("a"), State::Thinking, None, None, None, now);
        assert_eq!(r.aggregate(), State::Thinking);
        r.set_state(Some("b"), State::Running, None, None, None, now);
        assert_eq!(r.aggregate(), State::Running);
        // done is *lower* severity than running, so aggregate stays running.
        r.set_state(Some("c"), State::Done, None, None, None, now);
        assert_eq!(r.aggregate(), State::Running);
        // waiting beats running.
        r.set_state(Some("d"), State::Waiting, None, None, None, now);
        assert_eq!(r.aggregate(), State::Waiting);
        // error beats all.
        r.set_state(None, State::Error, None, None, None, now); // default session
        assert_eq!(r.aggregate(), State::Error);
    }

    #[test]
    fn aggregate_change_only_emitted_on_actual_change() {
        let mut r = Registry::new(None);
        let now = t0();
        let e1 = r.set_state(Some("a"), State::Running, None, None, None, now);
        assert!(e1
            .iter()
            .any(|e| matches!(e, Effect::AggregateChanged { state: State::Running })));
        // Second session also running: aggregate unchanged -> no AggregateChanged.
        let e2 = r.set_state(Some("b"), State::Running, None, None, None, now);
        assert!(!e2.iter().any(|e| matches!(e, Effect::AggregateChanged { .. })));
    }

    #[test]
    fn ttl_expiry_with_mock_clock() {
        let ttl = Duration::from_secs(600); // 10 min
        let mut r = Registry::new(Some(ttl));
        let t = Instant::now();
        r.set_state(Some("a"), State::Running, None, None, None, t);
        r.set_state(Some("b"), State::Waiting, None, None, None, t);
        // Refresh b just before the deadline.
        let t_mid = t.checked_add(Duration::from_secs(300)).unwrap();
        r.set_state(Some("b"), State::Waiting, None, None, None, t_mid);
        // Advance past a's deadline but not b's.
        let t_late = t.checked_add(Duration::from_secs(601)).unwrap();
        let effects = r.expire(t_late);
        // A TTL sweep disconnects (keeps recoverable/visible), never ends.
        assert!(effects.contains(&Effect::SessionDisconnected {
            id: "a".into(),
            slot: Some(1),
        }));
        assert!(r.session_by_slot(2).is_some(), "b should survive");
        // Aggregate dropped from waiting(b)+running(a) — still waiting (b lives).
        assert_eq!(r.aggregate(), State::Waiting);
    }

    #[test]
    fn ttl_never_disables_expiry() {
        let mut r = Registry::new(None);
        let t = Instant::now();
        r.set_state(Some("a"), State::Running, None, None, None, t);
        let far = t.checked_add(Duration::from_secs(10_000_000)).unwrap();
        assert!(r.expire(far).is_empty());
    }

    #[test]
    fn meta_merges_across_updates() {
        let mut r = Registry::new(None);
        let now = t0();
        let mut m1 = Map::new();
        m1.insert("cwd".into(), Value::from("/a"));
        r.set_state(Some("a"), State::Idle, None, None, Some(m1), now);
        let mut m2 = Map::new();
        m2.insert("branch".into(), Value::from("main"));
        r.set_state(Some("a"), State::Idle, None, None, Some(m2), now);
        let s = &r.list()[0];
        assert_eq!(s.cwd(), "/a"); // preserved
        assert_eq!(s.meta.get("branch").unwrap(), &Value::from("main")); // merged
    }

    #[test]
    fn pid_reads_well_known_meta_key() {
        let mut r = Registry::new(None);
        let now = t0();
        let mut m = Map::new();
        m.insert("pid".into(), Value::from(4242));
        r.set_state(Some("a"), State::Running, None, None, Some(m), now);
        assert_eq!(r.list()[0].pid(), Some(4242));

        // Absent / non-numeric meta both read as None rather than panicking.
        r.set_state(Some("b"), State::Running, None, None, None, now);
        assert_eq!(r.list().iter().find(|s| s.id == "b").unwrap().pid(), None);
    }

    #[test]
    fn set_meta_merges_without_changing_state() {
        let mut r = Registry::new(None);
        let now = t0();
        r.set_state(Some("a"), State::Running, Some("claude".into()), None, None, now);
        let mut m = Map::new();
        m.insert("cost_usd".into(), Value::from(0.42));
        let effects = r.merge_meta("a", None, None, m, now);
        let mut expected_meta = Map::new();
        expected_meta.insert("cost_usd".into(), Value::from(0.42));
        assert!(effects.contains(&Effect::SessionUpsert {
            id: "a".into(),
            kind: Some("claude".into()),
            label: None,
            name: None,
            meta: expected_meta,
            slot: Some(1),
            state: State::Running,
        }));
        // State (and therefore aggregate) must be untouched by a meta-only update.
        assert_eq!(r.list()[0].state, State::Running);
        assert_eq!(r.aggregate(), State::Running);
    }

    #[test]
    fn set_meta_on_unknown_session_is_a_noop() {
        let mut r = Registry::new(None);
        let now = t0();
        let mut m = Map::new();
        m.insert("cost_usd".into(), Value::from(0.1));
        let effects = r.merge_meta("ghost", None, None, m, now);
        assert!(effects.is_empty());
        // Must NOT have registered a new stateless session.
        assert!(r.list().is_empty());
        assert!(r.session_by_slot(1).is_none());
    }

    #[test]
    fn rename_sets_name_and_emits_upsert() {
        let mut r = Registry::new(None);
        let now = t0();
        r.set_state(Some("a"), State::Running, Some("claude".into()), Some("daemon".into()), None, now);
        let effects = r.rename("a", Some("Backend")).expect("known session");
        assert!(effects.contains(&Effect::SessionUpsert {
            id: "a".into(),
            kind: Some("claude".into()),
            label: Some("daemon".into()),
            name: Some("Backend".into()),
            meta: Map::new(),
            slot: Some(1),
            state: State::Running,
        }));
        assert_eq!(r.list()[0].display_name(), "Backend");
    }

    #[test]
    fn rename_survives_adapter_label_updates() {
        // The whole reason `name` is separate from `label`: adapters re-send
        // --label on every hook event, which must not undo a user's rename.
        let mut r = Registry::new(None);
        let now = t0();
        r.set_state(Some("a"), State::Idle, None, Some("focalpoint".into()), None, now);
        r.rename("a", Some("Backend")).unwrap();
        r.set_state(Some("a"), State::Running, None, Some("focalpoint".into()), None, now);
        let s = &r.list()[0];
        assert_eq!(s.name.as_deref(), Some("Backend"));
        assert_eq!(s.label.as_deref(), Some("focalpoint"));
        assert_eq!(s.display_name(), "Backend");
    }

    #[test]
    fn empty_rename_clears_and_falls_back_to_label() {
        let mut r = Registry::new(None);
        let now = t0();
        r.set_state(Some("a"), State::Idle, Some("claude".into()), Some("focalpoint".into()), None, now);
        r.rename("a", Some("Backend")).unwrap();
        for clearing in [Some("   "), Some(""), None] {
            r.rename("a", clearing).unwrap();
            assert_eq!(r.list()[0].name, None, "{clearing:?} should clear the name");
            assert_eq!(r.list()[0].display_name(), "focalpoint");
        }
    }

    #[test]
    fn rename_trims_and_reports_unknown_sessions() {
        let mut r = Registry::new(None);
        let now = t0();
        r.set_state(Some("a"), State::Idle, None, None, None, now);
        r.rename("a", Some("  Backend  ")).unwrap();
        assert_eq!(r.list()[0].name.as_deref(), Some("Backend"));
        assert!(r.rename("nope", Some("x")).is_none());
    }

    #[test]
    fn rename_does_not_extend_ttl() {
        let ttl = Duration::from_secs(600);
        let mut r = Registry::new(Some(ttl));
        let t = Instant::now();
        r.set_state(Some("a"), State::Running, None, None, None, t);
        let t_late = t.checked_add(Duration::from_secs(300)).unwrap();
        r.rename("a", Some("Backend")).unwrap();
        // Renaming is the user acting, not the session reporting activity.
        let t_expired = t_late.checked_add(Duration::from_secs(301)).unwrap();
        assert!(!r.expire(t_expired).is_empty());
    }

    #[test]
    fn display_name_prefers_name_then_label_then_kind() {
        let mut r = Registry::new(None);
        let now = t0();
        r.set_state(Some("a"), State::Idle, Some("claude".into()), None, None, now);
        assert_eq!(r.list()[0].display_name(), "claude");
        r.set_state(Some("a"), State::Idle, None, Some("focalpoint".into()), None, now);
        assert_eq!(r.list()[0].display_name(), "focalpoint");
        r.rename("a", Some("Backend")).unwrap();
        assert_eq!(r.list()[0].display_name(), "Backend");
    }

    #[test]
    fn default_session_not_listed_but_counts_in_aggregate() {
        let mut r = Registry::new(None);
        let now = t0();
        r.set_state(None, State::Error, None, None, None, now);
        assert!(r.list().is_empty());
        assert_eq!(r.aggregate(), State::Error);
    }

    fn meta(cwd: &str, tty: &str) -> Map<String, Value> {
        let mut m = Map::new();
        m.insert("cwd".into(), Value::from(cwd));
        m.insert("tty".into(), Value::from(tty));
        m
    }

    #[test]
    fn compacting_session_rekeys_to_continuation_on_cwd_tty_match() {
        let mut r = Registry::new(None);
        let now = t0();
        r.set_state(
            Some("old"),
            State::Running,
            Some("claude".into()),
            Some("adapter-label".into()),
            Some(meta("/repo", "/dev/ttys004")),
            now,
        );
        r.rename("old", Some("My Session")).unwrap();
        assert_eq!(r.session_by_slot(1).unwrap().id, "old");

        // PreCompact: mark it Compacting instead of ending it.
        r.set_state(Some("old"), State::Compacting, None, None, None, now);
        assert_eq!(r.list()[0].state, State::Compacting);

        // The continuation appears under a brand-new session_id a moment
        // later, same cwd/tty (same terminal, same adapter ancestor-walk).
        let later = now.checked_add(Duration::from_secs(2)).unwrap();
        let effects = r.set_state(
            Some("new"),
            State::Thinking,
            Some("claude".into()),
            Some("adapter-label".into()),
            Some(meta("/repo", "/dev/ttys004")),
            later,
        );

        assert!(effects.contains(&Effect::SessionRekeyed {
            old_id: "old".into(),
            new_id: "new".into(),
        }));
        // Same slot, same user-assigned name, new id, new (real) state —
        // and the old id is gone, not lingering as a second entry.
        assert!(r.list().iter().all(|s| s.id != "old"));
        let s = r.session_by_slot(1).expect("slot 1 still occupied");
        assert_eq!(s.id, "new");
        assert_eq!(s.state, State::Thinking);
        assert_eq!(s.name.as_deref(), Some("My Session"));
        assert_eq!(r.list().len(), 1);
    }

    #[test]
    fn rekey_carries_forward_cumulative_stats_and_bumps_compactions() {
        let mut r = Registry::new(None);
        let now = t0();
        let mut old_meta = meta("/repo", "/dev/ttys004");
        old_meta.insert("turns".into(), Value::from(30));
        old_meta.insert("tool_calls".into(), Value::from(550));
        old_meta.insert("cost_usd".into(), Value::from(1.5));
        old_meta.insert("context_tokens".into(), Value::from(116_821));
        r.set_state(Some("old"), State::Running, None, None, Some(old_meta), now);
        r.set_state(Some("old"), State::Compacting, None, None, None, now);

        // The continuation's own first Stop event reports only ITS segment's
        // recomputed totals (small, fresh — a new transcript/process), same
        // as the real adapter does.
        let later = now.checked_add(Duration::from_secs(2)).unwrap();
        let mut new_meta = meta("/repo", "/dev/ttys004");
        new_meta.insert("turns".into(), Value::from(3));
        new_meta.insert("tool_calls".into(), Value::from(12));
        new_meta.insert("cost_usd".into(), Value::from(0.2));
        new_meta.insert("context_tokens".into(), Value::from(4_000));
        r.set_state(
            Some("new"),
            State::Thinking,
            None,
            None,
            Some(new_meta),
            later,
        );

        let s = r.session_by_slot(1).expect("slot 1 still occupied");
        assert_eq!(s.id, "new");
        // Cumulative keys: old segment's total + this segment's own total.
        assert_eq!(s.meta.get("turns"), Some(&Value::from(33)));
        assert_eq!(s.meta.get("tool_calls"), Some(&Value::from(562)));
        assert_eq!(s.meta.get("cost_usd").and_then(Value::as_f64), Some(1.7));
        // Instantaneous key: plain overwrite, NOT carried — resetting on
        // compaction is correct, not a bug.
        assert_eq!(s.meta.get("context_tokens"), Some(&Value::from(4_000)));
        assert_eq!(s.meta.get("compactions"), Some(&Value::from(1u64)));
    }

    #[test]
    fn repeated_rekeys_compound_cumulative_stats_and_compactions() {
        let mut r = Registry::new(None);
        let now = t0();
        let mut m1 = meta("/repo", "/dev/ttys004");
        m1.insert("turns".into(), Value::from(10));
        r.set_state(Some("a"), State::Running, None, None, Some(m1), now);
        r.set_state(Some("a"), State::Compacting, None, None, None, now);

        let t1 = now.checked_add(Duration::from_secs(1)).unwrap();
        let mut m2 = meta("/repo", "/dev/ttys004");
        m2.insert("turns".into(), Value::from(5));
        r.set_state(Some("b"), State::Running, None, None, Some(m2), t1);
        r.set_state(Some("b"), State::Compacting, None, None, None, t1);

        let t2 = t1.checked_add(Duration::from_secs(1)).unwrap();
        let mut m3 = meta("/repo", "/dev/ttys004");
        m3.insert("turns".into(), Value::from(2));
        r.set_state(Some("c"), State::Thinking, None, None, Some(m3), t2);

        let s = r.session_by_slot(1).expect("slot 1 still occupied");
        assert_eq!(s.id, "c");
        assert_eq!(s.meta.get("turns"), Some(&Value::from(17))); // 10 + 5 + 2
        assert_eq!(s.meta.get("compactions"), Some(&Value::from(2u64))); // not reset to 1
    }

    #[test]
    fn end_session_never_leaves_a_recoverable_tombstone() {
        let mut r = Registry::new(None);
        let now = t0();
        let mut m = meta("/repo", "/dev/ttys004");
        m.insert("pid".into(), Value::from(555));
        m.insert("turns".into(), Value::from(9));
        r.set_state(Some("old"), State::Running, None, Some("My Chat".into()), Some(m), now);

        // A deliberate end-session — never a sweep's guess.
        r.end_session("old");

        // A brand-new registration with all the same signals must NOT
        // recover "old"'s history — it's a fresh session at zero.
        let later = now.checked_add(Duration::from_secs(5)).unwrap();
        let mut m2 = meta("/repo", "/dev/ttys004");
        m2.insert("pid".into(), Value::from(555));
        let effects = r.set_state(
            Some("new"),
            State::Thinking,
            None,
            Some("My Chat".into()),
            Some(m2),
            later,
        );
        assert!(!effects.iter().any(|e| matches!(e, Effect::SessionRekeyed { .. })));
        let s = r.session_by_slot(1).expect("slot 1 occupied");
        assert_eq!(s.id, "new");
        assert_eq!(s.meta.get("turns"), None);
        assert_eq!(s.meta.get("compactions"), None);
    }

    #[test]
    fn reap_session_creates_a_tombstone_recoverable_by_pid_and_cwd() {
        // The "false-reap" case: a sweep's guess was wrong (tty check
        // raced, or the process never actually died) — same pid, same cwd,
        // but a genuinely different tty this time (e.g. reattached in a new
        // terminal), and no label at all. pid+cwd is 2 signals, enough.
        let mut r = Registry::new(None);
        let now = t0();
        let mut m = meta("/repo", "/dev/ttys004");
        m.insert("pid".into(), Value::from(555));
        m.insert("turns".into(), Value::from(9));
        r.set_state(Some("old"), State::Running, None, None, Some(m), now);

        let reap_effects = r.reap_session("old", now);
        assert!(reap_effects
            .iter()
            .any(|e| matches!(e, Effect::SessionDisconnected { id, .. } if id == "old")));
        assert!(r.list().is_empty(), "tombstone must not be in live list()");

        let later = now.checked_add(Duration::from_secs(5)).unwrap();
        let mut m2 = meta("/repo", "/dev/ttys009");
        m2.insert("pid".into(), Value::from(555));
        let effects = r.set_state(Some("new"), State::Thinking, None, None, Some(m2), later);

        assert!(effects.contains(&Effect::SessionRekeyed {
            old_id: "old".into(),
            new_id: "new".into(),
        }));
        let s = r.session_by_slot(1).expect("slot 1 occupied");
        assert_eq!(s.id, "new");
        assert_eq!(s.meta.get("turns"), Some(&Value::from(9)));
    }

    #[test]
    fn reap_session_creates_a_tombstone_recoverable_by_label_and_cwd() {
        // The "resumed after an unexplained gap" case: a genuinely
        // different process (new pid, and this time no tty resolved at
        // all), but the same conversation — label survives even though
        // pid/tty can't (see identity.rs's doc comment).
        let mut r = Registry::new(None);
        let now = t0();
        let m = meta("/repo", "/dev/ttys004");
        r.set_state(Some("old"), State::Running, None, Some("Fix drag stutter".into()), Some(m), now);
        r.reap_session("old", now);

        let later = now.checked_add(Duration::from_secs(5)).unwrap();
        let m2 = meta("/repo", "");
        let effects = r.set_state(
            Some("new"),
            State::Thinking,
            None,
            Some("Fix drag stutter".into()),
            Some(m2),
            later,
        );

        assert!(effects.contains(&Effect::SessionRekeyed {
            old_id: "old".into(),
            new_id: "new".into(),
        }));
    }

    #[test]
    fn reap_session_tombstone_does_not_recover_on_single_signal() {
        // Only cwd matches — must never be enough on its own.
        let mut r = Registry::new(None);
        let now = t0();
        let m = meta("/repo", "/dev/ttys004");
        r.set_state(Some("old"), State::Running, None, Some("Old Chat".into()), Some(m), now);
        r.reap_session("old", now);

        let later = now.checked_add(Duration::from_secs(5)).unwrap();
        let m2 = meta("/repo", "/dev/ttys009");
        let effects = r.set_state(
            Some("new"),
            State::Thinking,
            None,
            Some("Unrelated Chat".into()),
            Some(m2),
            later,
        );
        assert!(!effects.iter().any(|e| matches!(e, Effect::SessionRekeyed { .. })));
        assert_eq!(r.list().len(), 1);
        assert_eq!(r.list()[0].id, "new");
    }

    #[test]
    fn tombstone_past_ttl_is_not_recoverable() {
        let mut r = Registry::new(None).with_tombstone_ttl(Some(Duration::from_secs(60)));
        let now = t0();
        let mut m = meta("/repo", "/dev/ttys004");
        m.insert("pid".into(), Value::from(555));
        r.set_state(Some("old"), State::Running, None, None, Some(m), now);
        r.reap_session("old", now);

        let too_late = now.checked_add(Duration::from_secs(61)).unwrap();
        let mut m2 = meta("/repo", "/dev/ttys004");
        m2.insert("pid".into(), Value::from(555));
        let effects = r.set_state(Some("new"), State::Thinking, None, None, Some(m2), too_late);
        assert!(!effects.iter().any(|e| matches!(e, Effect::SessionRekeyed { .. })));
    }

    #[test]
    fn tombstone_infinite_ttl_recovers_arbitrarily_late() {
        let mut r = Registry::new(None).with_tombstone_ttl(None);
        let now = t0();
        let mut m = meta("/repo", "/dev/ttys004");
        m.insert("pid".into(), Value::from(555));
        r.set_state(Some("old"), State::Running, None, None, Some(m), now);
        r.reap_session("old", now);

        let way_later = now.checked_add(Duration::from_secs(60 * 60 * 24 * 30)).unwrap();
        let mut m2 = meta("/repo", "/dev/ttys004");
        m2.insert("pid".into(), Value::from(555));
        let effects = r.set_state(Some("new"), State::Thinking, None, None, Some(m2), way_later);
        assert!(effects.contains(&Effect::SessionRekeyed {
            old_id: "old".into(),
            new_id: "new".into(),
        }));
    }

    #[test]
    fn expire_tombstones_drops_entries_past_ttl() {
        let mut r = Registry::new(None).with_tombstone_ttl(Some(Duration::from_secs(60)));
        let now = t0();
        let m = meta("/repo", "/dev/ttys004");
        r.set_state(Some("old"), State::Running, None, None, Some(m), now);
        r.reap_session("old", now);
        assert_eq!(r.tombstones.len(), 1);

        let early = r.expire_tombstones(now.checked_add(Duration::from_secs(30)).unwrap());
        assert_eq!(r.tombstones.len(), 1, "well within ttl");
        assert!(early.is_empty(), "nothing expired yet -> no effects");

        let late = r.expire_tombstones(now.checked_add(Duration::from_secs(61)).unwrap());
        assert_eq!(r.tombstones.len(), 0, "past ttl");
        // Aging out a (now-visible) tombstone must tell subscribers to drop
        // the disconnected row — with slot None, since the device key was
        // freed at reap and its old slot may have been reclaimed.
        assert!(late.contains(&Effect::SessionEnded {
            id: "old".into(),
            slot: None,
        }));
    }

    #[test]
    fn dismissing_a_disconnected_session_ends_it() {
        // The "user manually reaps them" path: a reaped (disconnected)
        // session, then an explicit end-session, must remove the row and
        // leave nothing recoverable behind.
        let mut r = Registry::new(None);
        let now = t0();
        let mut m = meta("/repo", "/dev/ttys004");
        m.insert("pid".into(), Value::from(555));
        r.set_state(Some("old"), State::Running, None, Some("Chat".into()), Some(m), now);
        r.reap_session("old", now);
        assert_eq!(r.tombstones.len(), 1);

        let effects = r.end_session("old");
        assert!(effects.contains(&Effect::SessionEnded {
            id: "old".into(),
            slot: None,
        }));
        assert_eq!(r.tombstones.len(), 0, "dismiss clears the tombstone");

        // A later identical registration is fresh (no recovery).
        let later = now.checked_add(Duration::from_secs(5)).unwrap();
        let mut m2 = meta("/repo", "/dev/ttys004");
        m2.insert("pid".into(), Value::from(555));
        let e = r.set_state(Some("new"), State::Thinking, None, Some("Chat".into()), Some(m2), later);
        assert!(!e.iter().any(|x| matches!(x, Effect::SessionRekeyed { .. })));
    }

    #[test]
    fn compacting_session_does_not_rekey_across_different_terminals() {
        let mut r = Registry::new(None);
        let now = t0();
        r.set_state(
            Some("old"),
            State::Compacting,
            None,
            None,
            Some(meta("/repo", "/dev/ttys004")),
            now,
        );
        // Different tty (a genuinely unrelated new session in the same repo)
        // must not be mistaken for old's continuation.
        r.set_state(
            Some("new"),
            State::Thinking,
            None,
            None,
            Some(meta("/repo", "/dev/ttys009")),
            now,
        );
        assert_eq!(r.list().len(), 2);
        assert!(r.list().iter().any(|s| s.id == "old" && s.state == State::Compacting));
        assert!(r.list().iter().any(|s| s.id == "new" && s.slot == Some(2)));
    }

    #[test]
    fn compacting_session_does_not_rekey_on_empty_tty_match() {
        // Regression test: `cwd` is not unique — two independent live
        // sessions sharing one is normal (multiple agents in the same
        // repo). Before this guard, a compacting session with no resolved
        // tty and a brand-new session that also had no resolved tty would
        // "match" on `"" == ""` plus the shared cwd and get silently merged
        // — an unrelated live session losing its own identity to someone
        // else's stale compacting slot.
        let mut r = Registry::new(None);
        let now = t0();
        r.set_state(
            Some("old"),
            State::Compacting,
            None,
            None,
            Some(meta("/repo", "")),
            now,
        );
        let effects = r.set_state(
            Some("new"),
            State::Thinking,
            None,
            None,
            Some(meta("/repo", "")),
            now,
        );
        assert!(!effects
            .iter()
            .any(|e| matches!(e, Effect::SessionRekeyed { .. })));
        assert_eq!(r.list().len(), 2);
        assert!(r.list().iter().any(|s| s.id == "old" && s.state == State::Compacting));
        assert!(r.list().iter().any(|s| s.id == "new" && s.slot == Some(2)));
    }

    #[test]
    fn expire_compacting_reaps_stuck_sessions_regardless_of_ttl() {
        // ttl = None ("never expire") must not stop the compacting-specific
        // grace timeout from still applying.
        let mut r = Registry::new(None);
        let t = Instant::now();
        r.set_state(Some("a"), State::Compacting, None, None, Some(meta("/repo", "/dev/ttys004")), t);
        r.set_state(Some("b"), State::Running, None, None, None, t);

        let too_soon = t.checked_add(Duration::from_secs(60)).unwrap();
        assert!(r.expire_compacting(too_soon).is_empty(), "well within grace");

        let past_grace = t.checked_add(COMPACT_GRACE + Duration::from_secs(1)).unwrap();
        let effects = r.expire_compacting(past_grace);
        // A stuck-compacting reap disconnects (recoverable), never ends.
        assert!(effects.contains(&Effect::SessionDisconnected {
            id: "a".into(),
            slot: Some(1),
        }));
        assert!(r.session_by_slot(2).is_some(), "unrelated session b untouched");
        assert_eq!(r.list().len(), 1);
    }
}
