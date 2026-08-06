//! Multi-session registry (PROTOCOL.md §3 Sessions).
//!
//! Pure, side-effect-free logic so it is fully unit-testable with a mockable
//! clock (methods take `now: Instant`). Mutating operations return a list of
//! [`Effect`]s; the daemon translates those into device commands
//! (`SET_KEY_STATE` / `SET_STATE`) and subscriber events.
//!
//! Slot rules: each identified session claims the lowest free numbered key
//! (1..=12) at registration. Slots stay stable while sessions are live, then
//! compact after an explicit end/remove; sessions beyond 12 get `slot: None`.
//! A `set-state` with no session id updates the sessionless
//! *default* session, which occupies no slot but still counts toward the
//! aggregate (back-compat). The default never expires and is never listed or
//! emitted as a session event.

use crate::protocol::{NavStates, State};
use serde_json::{Map, Value};
use std::collections::HashMap;
use std::time::{Duration, Instant};

pub(crate) const BACKLOGGED_META_KEY: &str = "_backlogged";

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

/// How a `meta` key's value accumulates across updates. Declared once per
/// key in `METRICS` and consumed by both `apply_meta_update` (every regular
/// update) and the rekey/recovery carry logic in `set_state`, so there is
/// exactly one place a metric's semantics are decided — see P1-B in
/// `docs/reviews/CODE-REVIEW-2026-08-01.md`.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum Accumulation {
    /// Latest reading wins: plain overwrite. Covers instantaneous readings
    /// (`context_tokens`, `context_window`, `model`, `pid`, `tty`, `cwd`,
    /// ...) and — deliberately — any key with no entry in `METRICS`, so a
    /// stat nobody classified yet fails safe as "just show the latest
    /// value" rather than silently compounding.
    Gauge,
    /// The adapter reports *this segment's* running total (Claude Code's
    /// `extract_stats`/`statusline-usage.sh`'s `cost_usd`), not a
    /// whole-lineage recompute. A genuine cross-process compaction fork
    /// starts a fresh transcript/process reporting only its own segment, so
    /// these must be *added* to the carried-forward base from any prior
    /// segment(s) on a real fork (`old_id != id`) — never on a same-id
    /// recovery, or a false reap would double them (P1-A).
    CumulativeSegments,
    /// The adapter recomputes and reports the WHOLE lineage's total every
    /// time (Codex/Cursor re-scan the entire transcript on every `Stop`:
    /// `adapters/codex-cli/hooks.sh:141-152`,
    /// `adapters/cursor/hooks.sh:84-112`) — verified against real rollout
    /// files that e.g. Codex's compaction happens in place (same
    /// `thread_id`, same transcript; SESSION-IDENTITY-PERSISTENCE-PLAN.md
    /// Part 2). The daemon always overwrites with whatever the adapter last
    /// reported, even across a rekey — never carries, never sums. This
    /// subsumes P1-A's guard by construction for these keys.
    CumulativeLineage,
}

/// One row per classified `meta` key. Unclassified keys default to
/// `Accumulation::Gauge` (see its doc comment) rather than requiring every
/// key to be listed.
pub struct MetricSpec {
    pub key: &'static str,
    pub accumulation: Accumulation,
}

/// `compactions` is `CumulativeLineage`: Codex/Cursor report a whole-lineage
/// recount of it on every `Stop` (`codex-cli/hooks.sh:153`) just like their
/// other stats, while Claude Code's adapter never reports it at all — the
/// daemon synthesizes it by incrementing on a genuine fork (see the rekey
/// branch in `set_state`). Declaring it `CumulativeLineage` means: if an
/// adapter *does* report it, that report always wins (plain overwrite,
/// consistent with Codex/Cursor); if nothing is reported, the daemon's own
/// increment is the only writer. Either way there is one unified home for
/// it instead of the previous daemon-only special case.
pub const METRICS: &[MetricSpec] = &[
    MetricSpec { key: "turns", accumulation: Accumulation::CumulativeSegments },
    MetricSpec { key: "tool_calls", accumulation: Accumulation::CumulativeSegments },
    // Current active count (started - finished), not cumulative — an
    // adapter reports a point-in-time reading each update, so this is a
    // Gauge like `context_tokens`, not a segment total to sum. Explicitly
    // listed (rather than relying on the unclassified-key default) so its
    // classification is a visible decision, not an accident.
    MetricSpec { key: "subagents", accumulation: Accumulation::Gauge },
    MetricSpec { key: "tokens_in", accumulation: Accumulation::CumulativeSegments },
    MetricSpec { key: "tokens_out", accumulation: Accumulation::CumulativeSegments },
    MetricSpec { key: "cost_usd", accumulation: Accumulation::CumulativeSegments },
    MetricSpec { key: "compactions", accumulation: Accumulation::CumulativeLineage },
    // A subset of Claude's compactions. The daemon increments this from a
    // trusted PreCompact lifecycle marker, so it is already a lineage total
    // when a Claude continuation rekeys to a new session id.
    MetricSpec { key: "plan_compactions", accumulation: Accumulation::CumulativeLineage },
];

/// Look up `key`'s accumulation kind in `METRICS`, defaulting to `Gauge` for
/// anything not (yet) classified — see `Accumulation::Gauge`.
fn accumulation_of(key: &str) -> Accumulation {
    METRICS
        .iter()
        .find(|m| m.key == key)
        .map(|m| m.accumulation)
        .unwrap_or(Accumulation::Gauge)
}

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

/// Apply an incoming meta update to `meta`, driven by each key's
/// `Accumulation` (`METRICS`/`accumulation_of`). `CumulativeSegments` keys
/// are added to their carried-forward base; `Gauge` and `CumulativeLineage`
/// keys are both a plain overwrite (they differ only in how the *rekey*
/// carry logic in `set_state` treats them, not in this merge step). Shared
/// by `set_state`'s update and rekey branches and by `merge_meta`, so
/// there's exactly one place this distinction is made.
fn apply_meta_update(
    meta: &mut Map<String, Value>,
    carry: &Map<String, Value>,
    incoming: Map<String, Value>,
) {
    for (k, v) in incoming {
        // Backlog membership is controlled only by set-session-backlogged;
        // adapters cannot move themselves between active and backlog by
        // smuggling the daemon's private storage key through arbitrary meta.
        if k == BACKLOGGED_META_KEY {
            continue;
        }
        if accumulation_of(&k) == Accumulation::CumulativeSegments && v.is_number() {
            let added = add_carry(carry, &k, &v);
            meta.insert(k, added);
            continue;
        }
        meta.insert(k, v);
    }
}

/// Consume Claude Code's explicit `PreCompact` marker and record the event
/// on the session lineage. A normal foreground compaction keeps the same
/// session id, so counting only at rekey time misses it. Conversely, a
/// background compaction can rekey to a new id, where `last_compaction_event`
/// tells the rekey path not to synthesize the same increment a second time.
///
/// `compaction_event` is transport-only and deliberately not exposed in
/// session metadata; the useful, durable facts are the count, trigger, and
/// permission mode of the latest compaction.
fn record_claude_precompact(
    session_meta: &mut Map<String, Value>,
    incoming_meta: &mut Map<String, Value>,
    state: State,
    is_claude: bool,
) {
    let is_precompact = incoming_meta
        .remove("compaction_event")
        .and_then(|value| value.as_str().map(str::to_owned))
        .as_deref()
        == Some("precompact");
    if !is_precompact || state != State::Compacting || !is_claude {
        return;
    }

    let compactions = session_meta
        .get("compactions")
        .and_then(Value::as_u64)
        .unwrap_or(0)
        + 1;
    session_meta.insert("compactions".to_string(), Value::from(compactions));
    session_meta.insert(
        "last_compaction_event".to_string(),
        Value::from("precompact"),
    );

    if let Some(trigger) = incoming_meta.get("compaction_trigger").cloned() {
        session_meta.insert("last_compaction_trigger".to_string(), trigger);
    }
    let permission_mode = incoming_meta
        .get("compaction_permission_mode")
        .and_then(Value::as_str);
    if let Some(permission_mode) = permission_mode {
        session_meta.insert(
            "last_compaction_permission_mode".to_string(),
            Value::from(permission_mode),
        );
        if permission_mode == "plan" {
            let plan_compactions = session_meta
                .get("plan_compactions")
                .and_then(Value::as_u64)
                .unwrap_or(0)
                + 1;
            session_meta.insert(
                "plan_compactions".to_string(),
                Value::from(plan_compactions),
            );
        }
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
    /// Backlog is daemon-owned presentation/routing state stored in private
    /// metadata so older snapshots and the many session construction paths
    /// remain compatible. It is exposed as a top-level protocol field, never
    /// as arbitrary adapter metadata.
    pub fn is_backlogged(&self) -> bool {
        self.meta
            .get(BACKLOGGED_META_KEY)
            .and_then(Value::as_bool)
            .unwrap_or(false)
    }

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
        self.meta
            .get("pid")
            .and_then(|v| v.as_i64())
            .map(|n| n as i32)
    }
}

/// A change the daemon must apply to the device and/or subscribers.
#[derive(Debug, Clone, PartialEq)]
pub enum Effect {
    /// Clear a physical numbered key without implying that its session ended.
    /// Used when moving a still-live session into the backlog before the
    /// remaining active slots are compacted.
    SlotCleared { slot: u8 },
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
    ManagedRelaunchCompleted {
        old_id: String,
        new_id: String,
        launch_id: String,
    },
    /// The daemon-owned attention order changed. This is independent of
    /// numbered-key slots: subscribers use it to highlight the next session.
    AttentionOrderChanged { sessions: Vec<String> },
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

#[derive(Debug, Clone)]
struct ManagedRelaunch {
    launch_id: String,
    original_state: State,
    original_last_update: Instant,
}

#[derive(Debug, Clone)]
struct ManagedLaunchReservation {
    slot: Option<u8>,
    reserved_at: Instant,
}

pub struct Registry {
    sessions: HashMap<String, Session>,
    tombstones: HashMap<String, Tombstone>,
    default_state: Option<State>,
    /// Last aggregate we emitted, for change detection.
    last_aggregate: State,
    /// TTL for identified sessions; `None` = never expire.
    // Retained only to accept existing construction/configuration paths.
    // Staleness is presentation-only; the daemon never reaps by age.
    _legacy_ttl: Option<Duration>,
    /// How long a tombstone stays recoverable; `None` = never expire.
    tombstone_ttl: Option<Duration>,
    managed_relaunches: HashMap<String, ManagedRelaunch>,
    relaunch_guards: HashMap<String, String>,
    /// A launch gets its numbered identity before its terminal is opened.
    /// Keeping that slot reserved until the provider's first hook prevents a
    /// concurrent registration from making the identity in its prompt wrong.
    managed_launch_reservations: HashMap<String, ManagedLaunchReservation>,
    /// Explicit complete live-session order set by the orchestrator. `None`
    /// means use the deterministic state/slot/id fallback.
    attention_order: Option<Vec<String>>,
    /// Last eligible session selected by next/previous attention cycling.
    attention_cursor: Option<String>,
    session_cursor: Option<String>,
}

impl Registry {
    pub fn new(ttl: Option<Duration>) -> Self {
        Registry {
            sessions: HashMap::new(),
            tombstones: HashMap::new(),
            default_state: None,
            last_aggregate: State::Idle,
            _legacy_ttl: ttl,
            tombstone_ttl: Some(DEFAULT_TOMBSTONE_TTL),
            managed_relaunches: HashMap::new(),
            relaunch_guards: HashMap::new(),
            managed_launch_reservations: HashMap::new(),
            attention_order: None,
            attention_cursor: None,
            session_cursor: None,
        }
    }

    fn fallback_attention_order(&self) -> Vec<String> {
        let mut sessions: Vec<&Session> = self
            .sessions
            .values()
            .filter(|session| !session.is_backlogged())
            .collect();
        sessions.sort_by_key(|session| {
            let state_rank = match session.state {
                State::Error => 0,
                State::Approval => 1,
                State::Waiting => 2,
                _ => 3,
            };
            (
                state_rank,
                session.slot.is_none(),
                session.slot.unwrap_or(0),
                session.id.clone(),
            )
        });
        sessions
            .into_iter()
            .map(|session| session.id.clone())
            .collect()
    }

    /// Complete current active-session order. An explicit orchestrator order
    /// is followed first; sessions registered or restored from the backlog
    /// afterward are appended in deterministic fallback order until the
    /// orchestrator replaces it.
    pub fn attention_order(&self) -> Vec<String> {
        let fallback = self.fallback_attention_order();
        let Some(explicit) = &self.attention_order else {
            return fallback;
        };
        let mut order: Vec<String> = explicit
            .iter()
            .filter(|id| {
                self.sessions
                    .get(id.as_str())
                    .is_some_and(|session| !session.is_backlogged())
            })
            .cloned()
            .collect();
        for id in fallback {
            if !order.contains(&id) {
                order.push(id);
            }
        }
        order
    }

    /// Replace the complete order. The input must contain every active live
    /// session exactly once. Backlogged sessions are deliberately absent.
    pub fn set_attention_order(&mut self, order: Vec<String>) -> Result<Vec<Effect>, String> {
        let live: std::collections::HashSet<&str> = self
            .sessions
            .values()
            .filter(|session| !session.is_backlogged())
            .map(|session| session.id.as_str())
            .collect();
        let supplied: std::collections::HashSet<&str> = order.iter().map(String::as_str).collect();
        if supplied.len() != order.len() {
            return Err("attention order contains duplicate session ids".into());
        }
        if supplied != live {
            let mut missing: Vec<&str> = live.difference(&supplied).copied().collect();
            let mut unknown: Vec<&str> = supplied.difference(&live).copied().collect();
            missing.sort_unstable();
            unknown.sort_unstable();
            return Err(format!(
                "attention order must contain every active session exactly once (missing: [{}]; unknown: [{}])",
                missing.join(", "),
                unknown.join(", ")
            ));
        }
        if self.attention_order.as_ref() == Some(&order) {
            return Ok(Vec::new());
        }
        self.attention_order = Some(order.clone());
        if self
            .attention_cursor
            .as_ref()
            .is_some_and(|id| {
                !self
                    .sessions
                    .get(id)
                    .is_some_and(|session| !session.is_backlogged())
            })
        {
            self.attention_cursor = None;
        }
        Ok(vec![Effect::AttentionOrderChanged { sessions: order }])
    }

    fn maintain_attention_order(&mut self, effects: &mut Vec<Effect>) {
        let Some(mut order) = self.attention_order.take() else {
            if self
                .attention_cursor
                .as_ref()
                .is_some_and(|id| {
                    !self
                        .sessions
                        .get(id)
                        .is_some_and(|session| !session.is_backlogged())
                })
            {
                self.attention_cursor = None;
            }
            return;
        };
        let old = order.clone();
        for effect in effects.iter() {
            if let Effect::SessionRekeyed { old_id, new_id } = effect {
                if let Some(entry) = order.iter_mut().find(|id| *id == old_id) {
                    *entry = new_id.clone();
                }
                if self.attention_cursor.as_deref() == Some(old_id) {
                    self.attention_cursor = Some(new_id.clone());
                }
            }
        }
        let mut seen = std::collections::HashSet::new();
        order.retain(|id| {
            self.sessions
                .get(id)
                .is_some_and(|session| !session.is_backlogged())
                && seen.insert(id.clone())
        });
        for id in self.fallback_attention_order() {
            if !order.contains(&id) {
                order.push(id);
            }
        }
        if self
            .attention_cursor
            .as_ref()
            .is_some_and(|id| {
                !self
                    .sessions
                    .get(id)
                    .is_some_and(|session| !session.is_backlogged())
            })
        {
            self.attention_cursor = None;
        }
        self.attention_order = Some(order.clone());
        if order != old {
            effects.push(Effect::AttentionOrderChanged { sessions: order });
        }
    }

    fn navigation_index(len: usize, current: Option<usize>, forward: bool) -> Option<usize> {
        if len == 0 { return None; }
        Some(current
            .map(|index| if forward { (index + 1) % len } else if index == 0 { len - 1 } else { index - 1 })
            .unwrap_or(if forward { 0 } else { len - 1 }))
    }

    fn attention_target(&self, forward: bool) -> Option<&Session> {
        let eligible: Vec<&Session> = self.attention_order().iter()
            .filter_map(|id| self.sessions.get(id))
            .filter(|session| {
                !session.is_backlogged()
                    && matches!(session.state, State::Waiting | State::Approval | State::Error)
            })
            .collect();
        let current = self.attention_cursor.as_ref()
            .and_then(|id| eligible.iter().position(|session| &session.id == id));
        Self::navigation_index(eligible.len(), current, forward).map(|index| eligible[index])
    }

    fn cycle_attention(&mut self, forward: bool) -> Option<Session> {
        let session = self.attention_target(forward).cloned();
        self.attention_cursor = session.as_ref().map(|session| session.id.clone());
        session
    }

    pub fn next_attention(&mut self) -> Option<Session> {
        self.cycle_attention(true)
    }

    pub fn previous_attention(&mut self) -> Option<Session> {
        self.cycle_attention(false)
    }

    /// State of the session which a following attention navigation selects,
    /// without advancing the cursor.
    fn attention_target_state(&self, forward: bool) -> Option<State> {
        self.attention_target(forward).map(|session| session.state)
    }

    pub fn next_attention_state(&self) -> Option<State> {
        self.attention_target_state(true)
    }

    pub fn previous_attention_state(&self) -> Option<State> {
        self.attention_target_state(false)
    }

    fn session_target(&self, forward: bool) -> Option<&Session> {
        let mut ordered: Vec<&Session> = self
            .sessions
            .values()
            .filter(|session| !session.is_backlogged())
            .collect();
        ordered.sort_by_key(|s| (s.slot.is_none(), s.slot.unwrap_or(u8::MAX), s.id.clone()));
        let current = self.session_cursor.as_ref()
            .and_then(|id| ordered.iter().position(|s| &s.id == id));
        Self::navigation_index(ordered.len(), current, forward).map(|index| ordered[index])
    }

    fn cycle_sessions(&mut self, forward: bool) -> Option<Session> {
        let session = self.session_target(forward).cloned();
        self.session_cursor = session.as_ref().map(|session| session.id.clone());
        session
    }

    pub fn next_session(&mut self) -> Option<Session> { self.cycle_sessions(true) }
    pub fn previous_session(&mut self) -> Option<Session> { self.cycle_sessions(false) }

    /// State of the session which a following chronological/slot-order
    /// navigation selects, without advancing the cursor.
    fn session_target_state(&self, forward: bool) -> Option<State> {
        self.session_target(forward).map(|session| session.state)
    }

    pub fn navigation_states(&self) -> NavStates {
        NavStates {
            attention_next: self.next_attention_state(),
            attention_previous: self.previous_attention_state(),
            session_next: self.session_target_state(true),
            session_previous: self.session_target_state(false),
        }
    }

    pub fn is_managed_relaunch_pending(&self, id: &str, launch_id: &str) -> bool {
        self.managed_relaunches
            .get(id)
            .map(|pending| pending.launch_id == launch_id)
            .unwrap_or(false)
    }

    /// Atomically validate and reserve an unmanaged Claude/Codex session for
    /// relaunch. The returned session is the original validated snapshot;
    /// the registry copy has already transitioned to `Compacting`.
    pub fn begin_managed_relaunch(
        &mut self,
        id: &str,
        launch_id: &str,
        now: Instant,
    ) -> Result<(Session, Vec<Effect>), String> {
        if launch_id.is_empty()
            || launch_id.len() > 128
            || !launch_id
                .bytes()
                .all(|b| b.is_ascii_alphanumeric() || matches!(b, b'.' | b'_' | b'-'))
        {
            return Err("invalid managed relaunch id".into());
        }
        if self.managed_relaunches.contains_key(id) {
            return Err(format!("managed relaunch already pending: {id}"));
        }
        if self
            .managed_relaunches
            .values()
            .any(|pending| pending.launch_id == launch_id)
            || self
                .relaunch_guards
                .iter()
                .any(|(guarded_id, guarded_launch)| guarded_id != id && guarded_launch == launch_id)
        {
            return Err(format!("managed relaunch id already in use: {launch_id}"));
        }

        let source = self
            .sessions
            .get(id)
            .cloned()
            .ok_or_else(|| format!("unknown live session: {id}"))?;
        if !matches!(source.kind.as_deref(), Some("claude" | "codex")) {
            return Err("managed relaunch requires a claude or codex session".into());
        }
        let already_managed = source
            .meta
            .get("managed")
            .map(|v| {
                v == &Value::Bool(true)
                    || matches!(v.as_str(), Some("true" | "1"))
                    || v.as_i64().map(|n| n != 0).unwrap_or(false)
            })
            .unwrap_or(false);
        if already_managed {
            return Err("session is already managed".into());
        }
        let valid_pid = source
            .meta
            .get("pid")
            .and_then(Value::as_i64)
            .map(|pid| pid > 0 && pid <= i32::MAX as i64)
            .unwrap_or(false);
        if !valid_pid {
            return Err("managed relaunch requires a positive pid".into());
        }
        if !matches!(source.state, State::Idle | State::Waiting | State::Done) {
            return Err("session is not in a safe relaunch state".into());
        }

        self.managed_relaunches.insert(
            id.to_string(),
            ManagedRelaunch {
                launch_id: launch_id.to_string(),
                original_state: source.state,
                original_last_update: source.last_update,
            },
        );
        self.relaunch_guards
            .insert(id.to_string(), launch_id.to_string());
        let sess = self.sessions.get_mut(id).expect("validated live session");
        sess.state = State::Compacting;
        sess.last_update = now;
        let mut effects = vec![Effect::SessionUpsert {
            id: sess.id.clone(),
            kind: sess.kind.clone(),
            label: sess.label.clone(),
            name: sess.name.clone(),
            meta: sess.meta.clone(),
            slot: sess.slot,
            state: State::Compacting,
        }];
        self.note_aggregate(&mut effects);
        Ok((source, effects))
    }

    /// Restore a preflight-failed reservation without changing its apparent
    /// age or any identity/display data.
    pub fn cancel_managed_relaunch(&mut self, id: &str, launch_id: &str) -> Vec<Effect> {
        if !self.is_managed_relaunch_pending(id, launch_id) {
            return Vec::new();
        }
        let pending = self.managed_relaunches.remove(id).expect("checked above");
        self.relaunch_guards.remove(id);
        let Some(sess) = self.sessions.get_mut(id) else {
            return Vec::new();
        };
        sess.state = pending.original_state;
        sess.last_update = pending.original_last_update;
        let mut effects = vec![Effect::SessionUpsert {
            id: sess.id.clone(),
            kind: sess.kind.clone(),
            label: sess.label.clone(),
            name: sess.name.clone(),
            meta: sess.meta.clone(),
            slot: sess.slot,
            state: sess.state,
        }];
        self.note_aggregate(&mut effects);
        effects
    }

    /// Convert a post-quit launch failure into a recoverable disconnected
    /// tombstone, freeing the reserved slot.
    pub fn fail_managed_relaunch(
        &mut self,
        id: &str,
        launch_id: &str,
        now: Instant,
    ) -> Vec<Effect> {
        if !self.is_managed_relaunch_pending(id, launch_id) {
            return Vec::new();
        }
        self.managed_relaunches.remove(id);
        self.relaunch_guards.remove(id);
        self.reap_session(id, now)
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
            if !s.is_backlogged() {
                consider(s.state);
            }
        }
        worst
    }

    fn lowest_free_slot(&self) -> Option<u8> {
        let mut used: std::collections::HashSet<u8> =
            self.sessions.values().filter_map(|s| s.slot).collect();
        used.extend(
            self.managed_launch_reservations
                .values()
                .filter_map(|reservation| reservation.slot),
        );
        (1..=12).find(|n| !used.contains(n))
    }

    /// Claim the numbered identity embedded in a managed agent's initial
    /// prompt. The reservation is consumed by the first registration carrying
    /// this stable orchestrator task id.
    pub fn reserve_managed_launch(
        &mut self,
        task_id: &str,
        now: Instant,
    ) -> Result<Option<u8>, String> {
        if self.managed_launch_reservations.contains_key(task_id)
            || self.sessions.values().any(|session| {
                session
                    .meta
                    .get("orchestrator_task_id")
                    .and_then(Value::as_str)
                    == Some(task_id)
            })
        {
            return Err(format!("managed task id is already active: {task_id}"));
        }
        let slot = self.lowest_free_slot();
        self.managed_launch_reservations.insert(
            task_id.to_string(),
            ManagedLaunchReservation { slot, reserved_at: now },
        );
        Ok(slot)
    }

    pub fn cancel_managed_launch(&mut self, task_id: &str) -> Option<u8> {
        self.managed_launch_reservations
            .remove(task_id)
            .and_then(|reservation| reservation.slot)
    }

    /// Release launches which LaunchServices accepted but which never
    /// produced a provider registration. This prevents a failed terminal
    /// launch from leaving a numbered-key hole forever.
    pub fn expire_managed_launches(
        &mut self,
        now: Instant,
        ttl: Duration,
    ) -> Vec<(String, Option<u8>)> {
        let mut expired: Vec<String> = self
            .managed_launch_reservations
            .iter()
            .filter(|(_, reservation)| {
                now.saturating_duration_since(reservation.reserved_at) >= ttl
            })
            .map(|(task_id, _)| task_id.clone())
            .collect();
        expired.sort();
        expired
            .into_iter()
            .filter_map(|task_id| {
                self.managed_launch_reservations
                    .remove(&task_id)
                    .map(|reservation| (task_id, reservation.slot))
            })
            .collect()
    }

    /// Compact live numbered slots after an explicit end/remove. This keeps
    /// both the rendered list and physical numbered-key map contiguous (1,
    /// 2, 3, ...) instead of leaving a hole until some unrelated future
    /// registration happens to reuse it. Preserve the existing slot order;
    /// slotless overflow sessions follow it and can be promoted if a slot is
    /// now available.
    fn compact_slots(&mut self) -> Vec<Effect> {
        let mut ordered: Vec<(String, Option<u8>)> = self
            .sessions
            .values()
            .filter(|session| !session.is_backlogged())
            .map(|session| (session.id.clone(), session.slot))
            .collect();
        ordered.sort_by_key(|(id, slot)| (slot.is_none(), slot.unwrap_or(u8::MAX), id.clone()));

        let mut effects = Vec::new();
        let reserved: std::collections::HashSet<u8> = self
            .managed_launch_reservations
            .values()
            .filter_map(|reservation| reservation.slot)
            .collect();
        let mut available = (1..=12).filter(|slot| !reserved.contains(slot));
        let assignments: Vec<(String, Option<u8>, Option<u8>)> = ordered
            .into_iter()
            .map(|(id, old_slot)| (id, old_slot, available.next()))
            .collect();

        // Moving sessions downward repaints their destinations, but nothing
        // implicitly erases their old source LEDs. Clear only source slots
        // which are absent from the final map, and do it before repainting.
        // Example: [1:a, 2:b, 3:c] - b => clear 3, then paint c at 2.
        let final_slots: std::collections::HashSet<u8> =
            assignments.iter().filter_map(|(_, _, slot)| *slot).collect();
        let mut vacated: Vec<u8> = assignments
            .iter()
            .filter_map(|(_, old_slot, _)| *old_slot)
            .filter(|old_slot| !final_slots.contains(old_slot))
            .collect();
        vacated.sort_unstable();
        vacated.dedup();
        effects.extend(vacated.into_iter().map(|slot| Effect::SlotCleared { slot }));

        for (id, old_slot, new_slot) in assignments {
            if old_slot == new_slot {
                continue;
            }
            let session = self.sessions.get_mut(&id).expect("collected live session");
            session.slot = new_slot;
            effects.push(Effect::SessionUpsert {
                id: session.id.clone(),
                kind: session.kind.clone(),
                label: session.label.clone(),
                name: session.name.clone(),
                meta: session.meta.clone(),
                slot: session.slot,
                state: session.state,
            });
        }
        effects
    }

    /// Move a live session into or out of the backlog. A backlogged session
    /// remains registered and focusable by id, but releases its numbered key
    /// and no longer participates in aggregate/attention routing.
    pub fn set_backlogged(&mut self, id: &str, backlogged: bool) -> Result<Vec<Effect>, String> {
        let Some(current) = self.sessions.get(id) else {
            return Err(format!("unknown live session: {id}"));
        };
        if current.is_backlogged() == backlogged {
            return Ok(Vec::new());
        }

        let mut effects = Vec::new();
        if backlogged {
            let old_slot = self.sessions.get(id).and_then(|session| session.slot);
            let session = self.sessions.get_mut(id).expect("validated live session");
            session.meta.insert(BACKLOGGED_META_KEY.into(), Value::Bool(true));
            session.slot = None;
            if let Some(slot) = old_slot {
                effects.push(Effect::SlotCleared { slot });
            }
        } else {
            let slot = self.lowest_free_slot();
            let session = self.sessions.get_mut(id).expect("validated live session");
            session.meta.remove(BACKLOGGED_META_KEY);
            session.slot = slot;
        }

        let session = self.sessions.get(id).expect("updated live session");
        effects.push(Effect::SessionUpsert {
            id: session.id.clone(),
            kind: session.kind.clone(),
            label: session.label.clone(),
            name: session.name.clone(),
            meta: session.meta.clone(),
            slot: session.slot,
            state: session.state,
        });
        if backlogged {
            effects.extend(self.compact_slots());
        }
        self.maintain_attention_order(&mut effects);
        self.note_aggregate(&mut effects);
        Ok(effects)
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
    /// seconds) or a tombstoned one within `tombstone_ttl` (only a false-reap
    /// of the same still-running process). Live compacting candidates use the
    /// pooled signal matcher: `label` (Claude Code's
    /// `ai-title`, verified to survive a compaction fork even though pid/tty
    /// don't — see identity.rs's doc comment for why those two are
    /// OS-process-identity signals that a real fork/resume can't preserve),
    /// `cwd`, `tty`, `pid` — **at least 2 must agree**, and `cwd` alone is
    /// never enough (it's explicitly not unique — multiple simultaneous
    /// sessions commonly share one). The right pair falls out naturally per
    /// cause: label+cwd for a compaction fork (new pid, maybe new tty),
    /// pid+cwd or pid+tty for a false-reap (same process, never actually
    /// died). A tombstone additionally requires a matching pid: title+cwd is
    /// not process identity and is routinely shared by unrelated fresh
    /// sessions. Fresh-process history recovery is only allowed through the
    /// exact `resume_session_id` marker below. Ties (same score) break by most
    /// recent activity.
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
            let score = count_identity_matches(
                candidate,
                incoming_label,
                incoming_cwd,
                incoming_tty,
                incoming_pid,
            );
            if score < 2 {
                return;
            }
            let better = match &best {
                None => true,
                Some((_, best_score, best_ts)) => {
                    score > *best_score || (score == *best_score && ts > *best_ts)
                }
            };
            if better {
                best = Some((id.to_string(), score, ts));
            }
        };

        for s in self.sessions.values() {
            if s.state == State::Compacting
                && !self.managed_relaunches.contains_key(&s.id)
                && now.saturating_duration_since(s.last_update) <= COMPACT_GRACE
            {
                consider(&s.id, s, s.last_update);
            }
        }
        for (id, t) in self.tombstones.iter() {
            let within_grace = self
                .tombstone_ttl
                .map(|ttl| now.saturating_duration_since(t.reaped_at) <= ttl)
                .unwrap_or(true); // None = never expire
            if within_grace
                && incoming_pid.is_some()
                && incoming_pid == t.session.pid()
            {
                // A tombstone is only a false-reap candidate when this is
                // demonstrably the same process. `consider` still requires a
                // second agreeing signal, preventing a recycled pid by itself
                // from linking two sessions.
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
                let relaunch_token = meta
                    .as_ref()
                    .and_then(|m| m.get("relaunch_id"))
                    .and_then(Value::as_str)
                    .filter(|s| !s.is_empty())
                    .map(str::to_string);
                let source_id = relaunch_token.as_ref().and_then(|token| {
                    self.managed_relaunches
                        .iter()
                        .find(|(_, pending)| pending.launch_id == *token)
                        .map(|(source_id, _)| source_id.clone())
                });
                if let Some(source_id) = source_id {
                    if source_id != id && self.sessions.contains_key(id) {
                        return Vec::new();
                    }
                    let pending = self
                        .managed_relaunches
                        .remove(&source_id)
                        .expect("matched relaunch exists");
                    self.relaunch_guards.remove(&source_id);
                    if let Some(mut sess) = self.sessions.remove(&source_id) {
                        let mut incoming_meta = meta.unwrap_or_default();
                        let is_claude = kind.as_deref() == Some("claude")
                            || sess.kind.as_deref() == Some("claude");
                        sess.id = id.to_string();
                        sess.state = state;
                        if kind.is_some() {
                            sess.kind = kind;
                        }
                        if label.is_some() {
                            sess.label = label;
                        }
                        record_claude_precompact(
                            &mut sess.meta,
                            &mut incoming_meta,
                            state,
                            is_claude,
                        );
                        apply_meta_update(&mut sess.meta, &sess.carry, incoming_meta);
                        sess.last_update = now;
                        if source_id != id {
                            effects.push(Effect::SessionRekeyed {
                                old_id: source_id.clone(),
                                new_id: id.to_string(),
                            });
                        }
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
                        effects.push(Effect::ManagedRelaunchCompleted {
                            old_id: source_id,
                            new_id: id.to_string(),
                            launch_id: pending.launch_id,
                        });
                        self.maintain_attention_order(&mut effects);
                        self.note_aggregate(&mut effects);
                        return effects;
                    }
                }
                if self.managed_relaunches.contains_key(id) {
                    return Vec::new();
                }
                let launch_task_id = meta
                    .as_ref()
                    .and_then(|fields| fields.get("orchestrator_task_id"))
                    .and_then(Value::as_str)
                    .map(str::to_string);
                let reserved_launch = launch_task_id.as_deref().and_then(|task_id| {
                    self.managed_launch_reservations.remove(task_id)
                });
                if let Some(sess) = self.sessions.get_mut(id) {
                    // Update + merge.
                    let is_claude = kind.as_deref() == Some("claude")
                        || sess.kind.as_deref() == Some("claude");
                    sess.state = state;
                    if kind.is_some() {
                        sess.kind = kind;
                    }
                    if label.is_some() {
                        sess.label = label;
                    }
                    if let Some(mut m) = meta {
                        record_claude_precompact(&mut sess.meta, &mut m, state, is_claude);
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
                    let mut incoming_meta = meta.unwrap_or_default();
                    let incoming_cwd = incoming_meta
                        .get("cwd")
                        .and_then(|v| v.as_str())
                        .unwrap_or("");
                    let incoming_tty = incoming_meta
                        .get("tty")
                        .and_then(|v| v.as_str())
                        .unwrap_or("");
                    let incoming_pid = incoming_meta
                        .get("pid")
                        .and_then(|v| v.as_i64())
                        .map(|n| n as i32);
                    let incoming_label = label.as_deref().unwrap_or("");
                    // History recovery has stronger identity than the pooled
                    // matcher: focalpoint-run stamps the literal provider
                    // resume id into every hook. If present, select only that
                    // exact tombstone (or none). In particular, never let an
                    // unrelated same-label/same-cwd session stand in for it.
                    let explicit_resume_id = incoming_meta
                        .get("resume_session_id")
                        .and_then(Value::as_str)
                        .filter(|resume_id| !resume_id.is_empty());

                    let same_id_tombstone = self.tombstones.get(id).is_some_and(|tombstone| {
                        self.tombstone_ttl
                            .map(|ttl| now.saturating_duration_since(tombstone.reaped_at) <= ttl)
                            .unwrap_or(true)
                    });
                    let recovery_id = match explicit_resume_id {
                        Some(resume_id) if self.tombstones.contains_key(resume_id) => {
                            Some(resume_id.to_string())
                        }
                        Some(_) => None,
                        // The provider's own exact id is stronger than fuzzy
                        // signals and safely reunites a false reap even while
                        // identity resolution has not supplied pid/tty yet.
                        None if same_id_tombstone => Some(id.to_string()),
                        None => self.find_recovery_candidate(
                            incoming_label,
                            incoming_cwd,
                            incoming_tty,
                            incoming_pid,
                            now,
                        ),
                    };
                    let recovered = recovery_id.and_then(|old_id| {
                        if let Some(sess) = self.sessions.remove(&old_id) {
                            Some((old_id, sess, false))
                        } else {
                            self.tombstones
                                .remove(&old_id)
                                .map(|t| (old_id, t.session, true))
                        }
                    });

                    if let Some((old_id, mut sess, was_tombstoned)) = recovered {
                        if was_tombstoned {
                            // A sweep explicitly freed this slot for reuse.
                            // Prefer the old slot only while it is still free;
                            // otherwise allocate the next free key. Reusing a
                            // tombstone's stale slot blindly creates two live
                            // sessions on one physical key.
                            let preferred_is_free = sess.slot.map_or(false, |slot| {
                                !self.sessions.values().any(|live| live.slot == Some(slot))
                            });
                            if !preferred_is_free {
                                sess.slot = self.lowest_free_slot();
                            }
                        }
                        // Snapshot the outgoing segment's CumulativeSegments
                        // totals as the new segment's carried-forward base,
                        // and bump `compactions` — reading it off the *old*
                        // session so repeated compactions compound correctly
                        // instead of resetting to 1 each time. See
                        // METRICS/apply_meta_update above.
                        //
                        // Only do this for a genuine cross-process fork
                        // (`old_id != id`): a fresh transcript/process that
                        // reports just its own segment's totals, which must
                        // be added to what came before. When `old_id == id`
                        // (a tombstone resurfacing under the *same* id after
                        // a false-reap — e.g. Codex/Cursor's whole-transcript
                        // recompute racing a transient dead-pid sweep false
                        // positive), it's the same lineage/same transcript,
                        // not a new segment — carrying forward would double
                        // every cumulative counter. Treat that as a plain
                        // overwrite via apply_meta_update below, same as any
                        // other update. This guard is what makes P1-A's fix
                        // hold for `CumulativeSegments` keys; `compactions`
                        // (`CumulativeLineage`) never needs it — it's either
                        // overwritten by an adapter's own report or
                        // daemon-incremented below, both of which are safe
                        // to run unconditionally on same-id recovery too
                        // (see the `old_id != id` check on the increment).
                        if old_id != id {
                            for spec in METRICS {
                                if spec.accumulation == Accumulation::CumulativeSegments {
                                    if let Some(v) = sess.meta.get(spec.key).cloned() {
                                        sess.carry.insert(spec.key.to_string(), v);
                                    }
                                }
                            }
                            // `compactions` (CumulativeLineage): Claude's
                            // adapter never reports this key, so the daemon
                            // is its only writer — synthesize the increment
                            // here, on a genuine fork only. If the incoming
                            // update *does* report `compactions` (Codex/
                            // Cursor's whole-transcript recount), skip the
                            // daemon's own increment and let
                            // apply_meta_update's plain overwrite below take
                            // the adapter's value as-is — never stack a
                            // daemon increment on top of an adapter's own
                            // recount.
                            // Suppress only the rekey directly following the
                            // PreCompact marker. A session that subsequently
                            // resumed normal work may compact again even if a
                            // hook was lost, and must not be suppressed by an
                            // old marker retained for display/diagnostics.
                            let already_recorded_at_precompact = sess.state == State::Compacting
                                && sess
                                    .meta
                                    .get("last_compaction_event")
                                    .and_then(Value::as_str)
                                    == Some("precompact");
                            if !incoming_meta.contains_key("compactions")
                                && !already_recorded_at_precompact
                            {
                                let compactions = sess
                                    .meta
                                    .get("compactions")
                                    .and_then(Value::as_u64)
                                    .unwrap_or(0)
                                    + 1;
                                sess.meta
                                    .insert("compactions".to_string(), Value::from(compactions));
                            }
                        }

                        let is_claude = kind.as_deref() == Some("claude")
                            || sess.kind.as_deref() == Some("claude");
                        sess.id = id.to_string();
                        sess.state = state;
                        if kind.is_some() {
                            sess.kind = kind;
                        }
                        if label.is_some() {
                            sess.label = label;
                        }
                        record_claude_precompact(
                            &mut sess.meta,
                            &mut incoming_meta,
                            state,
                            is_claude,
                        );
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
                        let slot = match reserved_launch {
                            Some(reservation) => reservation.slot,
                            None => incoming_meta
                                .get("requested_slot")
                                .and_then(Value::as_u64)
                                .and_then(|value| u8::try_from(value).ok())
                                .filter(|value| (1..=12).contains(value))
                                .filter(|requested| {
                                    !self.sessions.values().any(|session| {
                                        session.slot == Some(*requested)
                                    }) && !self.managed_launch_reservations.values().any(
                                        |reservation| reservation.slot == Some(*requested),
                                    )
                                })
                                .or_else(|| self.lowest_free_slot()),
                        };
                        let mut session_meta = Map::new();
                        record_claude_precompact(
                            &mut session_meta,
                            &mut incoming_meta,
                            state,
                            kind.as_deref() == Some("claude"),
                        );
                        apply_meta_update(&mut session_meta, &Map::new(), incoming_meta);
                        let sess = Session {
                            id: id.to_string(),
                            kind,
                            label,
                            name: None,
                            meta: session_meta,
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
        self.maintain_attention_order(&mut effects);
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
        if self.managed_relaunches.contains_key(id) {
            return Vec::new();
        }
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
        if self.managed_relaunches.contains_key(id) {
            return Vec::new();
        }
        let mut effects = Vec::new();
        let tomb = self.tombstones.remove(id);
        if let Some(sess) = self.sessions.remove(id) {
            effects.push(Effect::SessionEnded {
                id: id.to_string(),
                slot: sess.slot,
            });
            effects.extend(self.compact_slots());
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
        self.maintain_attention_order(&mut effects);
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
        self.maintain_attention_order(&mut effects);
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

    /// Move a live, active session onto a specific free numbered slot —
    /// manual sparse placement (the app's Move to Slot menu), companion to
    /// `swap_slots`. Unlike the compaction that follows an end or a backlog
    /// move, this NEVER closes the gap it leaves: the hole is the point. A
    /// slotless overflow session (>12 live) can be moved INTO a free slot
    /// the same way. Rejects backlogged sessions (they hold no slot — move
    /// them back to active first), occupied targets (that's `swap_slots`),
    /// and out-of-range slots. Doesn't touch `last_update` — placement
    /// isn't activity.
    pub fn move_slot(&mut self, id: &str, slot: u64) -> Result<Vec<Effect>, String> {
        let target = u8::try_from(slot)
            .ok()
            .filter(|n| (1..=12).contains(n))
            .ok_or_else(|| format!("slot must be 1-12, got {slot}"))?;
        {
            let session = self
                .sessions
                .get(id)
                .ok_or_else(|| format!("unknown live session: {id}"))?;
            if session.is_backlogged() {
                return Err(format!("session is backlogged and holds no slot: {id}"));
            }
            if session.slot == Some(target) {
                return Ok(Vec::new());
            }
        }
        let occupied_by = self
            .sessions
            .values()
            .find(|s| s.id != id && !s.is_backlogged() && s.slot == Some(target))
            .map(|s| s.id.clone());
        if let Some(holder) = occupied_by {
            return Err(format!(
                "slot {target} is held by session {holder}; use swap-slots to exchange"
            ));
        }
        let old_slot = self.sessions.get(id).and_then(|s| s.slot);
        let session = self.sessions.get_mut(id).expect("validated live session");
        session.slot = Some(target);
        let mut effects = Vec::new();
        if let Some(old) = old_slot {
            effects.push(Effect::SlotCleared { slot: old });
        }
        effects.push(Effect::SessionUpsert {
            id: session.id.clone(),
            kind: session.kind.clone(),
            label: session.label.clone(),
            name: session.name.clone(),
            meta: session.meta.clone(),
            slot: session.slot,
            state: session.state,
        });
        Ok(effects)
    }

    /// Kept as a compatibility no-op for callers built around the old TTL
    /// sweep. Age is not evidence that an agent died: the app marks stale
    /// rows visually, while daemon removal requires explicit SessionEnd or a
    /// verified dead pid/tty sweep.
    pub fn expire(&mut self, _now: Instant) -> Vec<Effect> {
        Vec::new()
    }

    /// Kept as a compatibility no-op. A delayed/cancelled compaction is stale
    /// presentation state, not proof the session ended; it must not make the
    /// daemon discard a still-live session.
    pub fn expire_compacting(&mut self, _now: Instant) -> Vec<Effect> {
        Vec::new()
    }

    /// Live active sessions in slot order, then backlogged sessions. Slotless
    /// overflow sessions come after numbered active sessions but before the
    /// backlog (PROTOCOL.md §3).
    pub fn list(&self) -> Vec<Session> {
        let mut v: Vec<Session> = self.sessions.values().cloned().collect();
        v.sort_by_key(|s| {
            (
                s.is_backlogged(),
                s.slot.is_none(),
                s.slot.unwrap_or(0),
                s.id.clone(),
            )
        });
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

    /// Explicit order for persistence. `None` preserves fallback semantics.
    pub fn attention_order_override(&self) -> Option<Vec<String>> {
        self.attention_order.clone()
    }

    /// Restore a persisted order leniently: corrupt/stale ids are dropped and
    /// current live ids missing from an older snapshot are appended.
    pub fn restore_attention_order(&mut self, order: Option<Vec<String>>) {
        self.attention_order = order;
        let mut ignored = Vec::new();
        self.maintain_attention_order(&mut ignored);
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
            r.tombstones
                .insert(old_id, Tombstone { session, reaped_at });
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
        let e = r.set_state(
            Some("a"),
            State::Thinking,
            Some("claude".into()),
            None,
            None,
            now,
        );
        assert!(e.contains(&Effect::SessionUpsert {
            id: "a".into(),
            kind: Some("claude".into()),
            label: None,
            name: None,
            meta: Map::new(),
            slot: Some(1),
            state: State::Thinking,
        }));
        r.set_state(
            Some("b"),
            State::Running,
            Some("codex".into()),
            None,
            None,
            now,
        );
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
    fn managed_launch_reserves_its_prompted_slot_until_registration() {
        let mut registry = Registry::new(None);
        let now = Instant::now();
        assert_eq!(registry.reserve_managed_launch("worker-1", now).unwrap(), Some(1));

        registry.set_state(
            Some("unrelated"), State::Thinking, Some("codex".into()), None,
            None, now,
        );
        assert_eq!(registry.sessions.get("unrelated").unwrap().slot, Some(2));

        let mut meta = Map::new();
        meta.insert("orchestrator_task_id".into(), Value::from("worker-1"));
        registry.set_state(
            Some("provider-session"), State::Thinking, Some("codex".into()),
            Some("Parser implementation".into()), Some(meta), now,
        );
        assert_eq!(registry.sessions.get("provider-session").unwrap().slot, Some(1));
        assert!(registry.cancel_managed_launch("worker-1").is_none());
    }

    #[test]
    fn abandoned_managed_launch_reservation_expires_and_releases_slot() {
        let mut registry = Registry::new(None);
        let now = Instant::now();
        assert_eq!(registry.reserve_managed_launch("orphan", now).unwrap(), Some(1));
        assert!(registry
            .expire_managed_launches(now + Duration::from_secs(119), Duration::from_secs(120))
            .is_empty());
        assert_eq!(
            registry.expire_managed_launches(
                now + Duration::from_secs(120),
                Duration::from_secs(120),
            ),
            vec![("orphan".into(), Some(1))],
        );
        assert_eq!(registry.reserve_managed_launch("next", now).unwrap(), Some(1));
    }

    #[test]
    fn pane_reregistration_reclaims_requested_slot_only_when_free() {
        let mut registry = Registry::new(None);
        let now = Instant::now();
        registry.set_state(Some("first"), State::Running, None, None, None, now);

        let mut requested = Map::new();
        requested.insert("requested_slot".into(), Value::from(4));
        requested.insert("reregistered".into(), Value::Bool(true));
        registry.set_state(
            Some("recovered"), State::Thinking, Some("codex".into()),
            Some("Parser implementation".into()), Some(requested), now,
        );
        assert_eq!(registry.sessions.get("recovered").unwrap().slot, Some(4));

        let mut occupied = Map::new();
        occupied.insert("requested_slot".into(), Value::from(4));
        occupied.insert("reregistered".into(), Value::Bool(true));
        registry.set_state(
            Some("fallback"), State::Thinking, Some("codex".into()), None,
            Some(occupied), now,
        );
        assert_eq!(registry.sessions.get("fallback").unwrap().slot, Some(2));
    }

    #[test]
    fn attention_order_requires_the_complete_live_set() {
        let mut r = Registry::new(None);
        let now = t0();
        r.set_state(Some("a"), State::Waiting, None, None, None, now);
        r.set_state(Some("b"), State::Error, None, None, None, now);

        assert!(r
            .set_attention_order(vec!["a".into(), "a".into()])
            .unwrap_err()
            .contains("duplicate"));
        assert!(r
            .set_attention_order(vec!["a".into()])
            .unwrap_err()
            .contains("missing: [b]"));
        assert!(r
            .set_attention_order(vec!["a".into(), "ghost".into()])
            .unwrap_err()
            .contains("unknown: [ghost]"));

        let effects = r.set_attention_order(vec!["a".into(), "b".into()]).unwrap();
        assert_eq!(r.attention_order(), vec!["a", "b"]);
        assert_eq!(
            effects,
            vec![Effect::AttentionOrderChanged {
                sessions: vec!["a".into(), "b".into()]
            }]
        );
    }

    #[test]
    fn attention_fallback_is_error_approval_waiting_then_slot_and_cycles_eligible_only() {
        let mut r = Registry::new(None);
        let now = t0();
        r.set_state(Some("idle"), State::Idle, None, None, None, now);
        r.set_state(Some("wait"), State::Waiting, None, None, None, now);
        r.set_state(Some("approval"), State::Approval, None, None, None, now);
        r.set_state(Some("err"), State::Error, None, None, None, now);
        r.set_state(Some("running"), State::Running, None, None, None, now);

        assert_eq!(r.attention_order(), vec!["err", "approval", "wait", "idle", "running"]);
        assert_eq!(r.next_attention().unwrap().id, "err");
        assert_eq!(r.next_attention().unwrap().id, "approval");
        assert_eq!(r.next_attention().unwrap().id, "wait");
        assert_eq!(r.next_attention().unwrap().id, "err");
        assert_eq!(r.previous_attention().unwrap().id, "wait");
    }

    #[test]
    fn navigation_target_and_sequential_cycles_follow_live_sessions() {
        let mut r = Registry::new(None);
        let now = t0();
        r.set_state(Some("run"), State::Running, None, None, None, now);
        r.set_state(Some("wait"), State::Waiting, None, None, None, now);
        r.set_state(Some("approval"), State::Approval, None, None, None, now);
        r.set_state(Some("err"), State::Error, None, None, None, now);
        assert_eq!(r.navigation_states(), NavStates {
            attention_next: Some(State::Error),
            attention_previous: Some(State::Waiting),
            session_next: Some(State::Running),
            session_previous: Some(State::Error),
        });
        assert_eq!(r.next_attention().unwrap().id, "err");
        assert_eq!(r.next_attention_state(), Some(State::Approval));
        assert_eq!(r.previous_attention_state(), Some(State::Waiting));
        assert_eq!(r.next_attention().unwrap().id, "approval");
        assert_eq!(r.next_attention_state(), Some(State::Waiting));
        assert_eq!(r.next_session().unwrap().id, "run");
        assert_eq!(r.next_session().unwrap().id, "wait");
        assert_eq!(r.previous_session().unwrap().id, "run");
        assert_eq!(r.navigation_states(), NavStates {
            attention_next: Some(State::Waiting),
            attention_previous: Some(State::Error),
            session_next: Some(State::Waiting),
            session_previous: Some(State::Error),
        });
    }

    #[test]
    fn explicit_attention_order_survives_lifecycle_changes() {
        let mut r = Registry::new(None);
        let now = t0();
        r.set_state(Some("a"), State::Waiting, None, None, None, now);
        r.set_state(Some("b"), State::Error, None, None, None, now);
        r.set_attention_order(vec!["a".into(), "b".into()]).unwrap();

        let ended = r.end_session("a");
        assert_eq!(r.attention_order(), vec!["b"]);
        assert!(ended.contains(&Effect::AttentionOrderChanged {
            sessions: vec!["b".into()]
        }));

        let registered = r.set_state(Some("c"), State::Waiting, None, None, None, now);
        assert_eq!(r.attention_order(), vec!["b", "c"]);
        assert!(registered.contains(&Effect::AttentionOrderChanged {
            sessions: vec!["b".into(), "c".into()]
        }));

        let persisted = r.attention_order_override();
        let sessions = r.list();
        let mut restored = Registry::restore(None, None, sessions, Vec::new());
        restored.restore_attention_order(persisted);
        assert_eq!(restored.attention_order(), vec!["b", "c"]);
    }

    #[test]
    fn ending_compacts_slots_before_next_registration() {
        let mut r = Registry::new(None);
        let now = t0();
        r.set_state(Some("a"), State::Running, None, None, None, now);
        r.set_state(Some("b"), State::Running, None, None, None, now);
        r.set_state(Some("c"), State::Running, None, None, None, now);
        // End b (slot 2). c shifts down, so the next registration takes #3.
        let e = r.end_session("b");
        assert!(e.contains(&Effect::SessionEnded {
            id: "b".into(),
            slot: Some(2),
        }));
        let clear_source = e
            .iter()
            .position(|effect| matches!(effect, Effect::SlotCleared { slot: 3 }))
            .expect("compaction clears c's old source slot");
        let repaint_destination = e
            .iter()
            .position(|effect| matches!(effect,
                Effect::SessionUpsert { id, slot: Some(2), .. } if id == "c"
            ))
            .expect("compaction repaints c at its destination slot");
        assert!(clear_source < repaint_destination);
        assert_eq!(r.session_by_slot(2).unwrap().id, "c");
        r.set_state(Some("d"), State::Running, None, None, None, now);
        assert_eq!(r.session_by_slot(3).unwrap().id, "d");
    }

    #[test]
    fn backlog_releases_slot_and_routing_but_remains_focusable() {
        let mut r = Registry::new(None);
        let now = t0();
        r.set_state(Some("a"), State::Running, None, None, None, now);
        r.set_state(Some("b"), State::Error, None, None, None, now);
        r.set_state(Some("c"), State::Waiting, None, None, None, now);
        r.set_attention_order(vec!["b".into(), "c".into(), "a".into()])
            .unwrap();

        let effects = r.set_backlogged("b", true).unwrap();
        assert!(effects.contains(&Effect::SlotCleared { slot: 2 }));
        assert!(effects.contains(&Effect::SlotCleared { slot: 3 }));
        let backlogged = r.session_or_tombstone("b").expect("still live/focusable");
        assert!(backlogged.is_backlogged());
        assert_eq!(backlogged.slot, None);
        assert_eq!(r.session_by_slot(2).unwrap().id, "c");
        assert_eq!(r.aggregate(), State::Waiting, "backlog is not aggregate-active");
        assert_eq!(r.attention_order(), vec!["c", "a"]);
        assert_eq!(r.next_attention().unwrap().id, "c");
        assert_eq!(r.next_session().unwrap().id, "a");
        assert_eq!(r.next_session().unwrap().id, "c");
        assert_eq!(r.list().last().unwrap().id, "b");

        let restored = r.set_backlogged("b", false).unwrap();
        assert!(restored.iter().any(|effect| matches!(effect,
            Effect::SessionUpsert { id, slot: Some(3), .. } if id == "b"
        )));
        let active = r.session_or_tombstone("b").unwrap();
        assert!(!active.is_backlogged());
        assert_eq!(active.slot, Some(3));
        assert_eq!(r.aggregate(), State::Error);
        assert_eq!(r.attention_order(), vec!["c", "a", "b"]);
    }

    #[test]
    fn backlog_is_idempotent_rejects_unknown_and_ignores_adapter_meta() {
        let mut r = Registry::new(None);
        let now = t0();
        r.set_state(Some("a"), State::Running, None, None, None, now);
        assert!(r.set_backlogged("missing", true).is_err());
        assert!(!r.set_backlogged("a", true).unwrap().is_empty());
        assert!(r.set_backlogged("a", true).unwrap().is_empty());

        let mut spoofed = Map::new();
        spoofed.insert(BACKLOGGED_META_KEY.into(), Value::Bool(false));
        r.set_state(
            Some("a"),
            State::Waiting,
            None,
            None,
            Some(spoofed),
            now,
        );
        assert!(r.session_or_tombstone("a").unwrap().is_backlogged());
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
    fn move_slot_places_on_free_slot_and_keeps_the_gap() {
        let mut r = Registry::new(None);
        let now = t0();
        r.set_state(Some("a"), State::Running, None, None, None, now);
        r.set_state(Some("b"), State::Running, None, None, None, now);
        r.set_state(Some("c"), State::Running, None, None, None, now);
        let effects = r.move_slot("a", 5).unwrap();
        assert_eq!(r.sessions.get("a").unwrap().slot, Some(5));
        // The gap is deliberate: b and c stay exactly where they were (no
        // end/backlog-style compaction on a manual move).
        assert_eq!(r.sessions.get("b").unwrap().slot, Some(2));
        assert_eq!(r.sessions.get("c").unwrap().slot, Some(3));
        assert!(effects
            .iter()
            .any(|e| matches!(e, Effect::SlotCleared { slot: 1 })));
        assert!(effects.iter().any(|e| matches!(e,
            Effect::SessionUpsert { id, slot: Some(5), .. } if id == "a")));
        // Moving to the slot it already holds is a no-op, not an error.
        assert_eq!(r.move_slot("a", 5).unwrap(), Vec::new());
    }

    #[test]
    fn move_slot_rejects_occupied_unknown_backlogged_and_out_of_range() {
        let mut r = Registry::new(None);
        let now = t0();
        r.set_state(Some("a"), State::Running, None, None, None, now);
        r.set_state(Some("b"), State::Running, None, None, None, now);
        assert!(r.move_slot("a", 2).is_err()); // occupied — that's swap-slots
        assert!(r.move_slot("ghost", 4).is_err());
        assert!(r.move_slot("a", 0).is_err());
        assert!(r.move_slot("a", 13).is_err());
        assert!(r.move_slot("a", 999).is_err());
        r.set_backlogged("b", true).unwrap();
        assert!(r.move_slot("b", 4).is_err()); // parked sessions hold no slot
        assert_eq!(r.sessions.get("a").unwrap().slot, Some(1)); // untouched
    }

    #[test]
    fn explicit_end_compacts_slots_and_later_updates_keep_the_new_order() {
        let mut r = Registry::new(None);
        let now = t0();
        r.set_state(Some("a"), State::Running, None, None, None, now);
        r.set_state(Some("b"), State::Running, None, None, None, now);
        r.end_session("a"); // b moves from slot 2 to slot 1
                            // An update must preserve that compacted mapping.
        r.set_state(Some("b"), State::Waiting, None, None, None, now);
        assert_eq!(r.sessions.get("b").unwrap().slot, Some(1));
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
        assert!(e1.iter().any(|e| matches!(
            e,
            Effect::AggregateChanged {
                state: State::Running
            }
        )));
        // Second session also running: aggregate unchanged -> no AggregateChanged.
        let e2 = r.set_state(Some("b"), State::Running, None, None, None, now);
        assert!(!e2
            .iter()
            .any(|e| matches!(e, Effect::AggregateChanged { .. })));
    }

    #[test]
    fn time_passage_never_reaps_live_sessions() {
        let ttl = Duration::from_secs(600); // 10 min
        let mut r = Registry::new(Some(ttl));
        let t = Instant::now();
        r.set_state(Some("a"), State::Running, None, None, None, t);
        r.set_state(Some("b"), State::Waiting, None, None, None, t);
        // Advance far beyond the old TTL. Staleness belongs to the UI, not
        // session lifecycle, so both sessions remain live.
        let t_late = t.checked_add(Duration::from_secs(10_000)).unwrap();
        let effects = r.expire(t_late);
        assert!(effects.is_empty());
        assert!(r.session_by_slot(1).is_some());
        assert!(r.session_by_slot(2).is_some());
        assert_eq!(r.aggregate(), State::Waiting);
    }

    #[test]
    fn legacy_ttl_none_is_also_a_lifecycle_noop() {
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
        r.set_state(
            Some("a"),
            State::Running,
            Some("claude".into()),
            None,
            None,
            now,
        );
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
        r.set_state(
            Some("a"),
            State::Running,
            Some("claude".into()),
            Some("daemon".into()),
            None,
            now,
        );
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
        r.set_state(
            Some("a"),
            State::Idle,
            None,
            Some("focalpoint".into()),
            None,
            now,
        );
        r.rename("a", Some("Backend")).unwrap();
        r.set_state(
            Some("a"),
            State::Running,
            None,
            Some("focalpoint".into()),
            None,
            now,
        );
        let s = &r.list()[0];
        assert_eq!(s.name.as_deref(), Some("Backend"));
        assert_eq!(s.label.as_deref(), Some("focalpoint"));
        assert_eq!(s.display_name(), "Backend");
    }

    #[test]
    fn empty_rename_clears_and_falls_back_to_label() {
        let mut r = Registry::new(None);
        let now = t0();
        r.set_state(
            Some("a"),
            State::Idle,
            Some("claude".into()),
            Some("focalpoint".into()),
            None,
            now,
        );
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
    fn rename_does_not_change_stale_session_lifecycle() {
        let ttl = Duration::from_secs(600);
        let mut r = Registry::new(Some(ttl));
        let t = Instant::now();
        r.set_state(Some("a"), State::Running, None, None, None, t);
        let t_late = t.checked_add(Duration::from_secs(300)).unwrap();
        r.rename("a", Some("Backend")).unwrap();
        // Renaming is the user acting, not the session reporting activity.
        let t_expired = t_late.checked_add(Duration::from_secs(301)).unwrap();
        assert!(r.expire(t_expired).is_empty());
        assert!(r.session_by_slot(1).is_some());
    }

    #[test]
    fn display_name_prefers_name_then_label_then_kind() {
        let mut r = Registry::new(None);
        let now = t0();
        r.set_state(
            Some("a"),
            State::Idle,
            Some("claude".into()),
            None,
            None,
            now,
        );
        assert_eq!(r.list()[0].display_name(), "claude");
        r.set_state(
            Some("a"),
            State::Idle,
            None,
            Some("focalpoint".into()),
            None,
            now,
        );
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
    fn same_id_recovery_after_false_reap_does_not_double_count() {
        // Codex/Cursor-style false reap: the dead-pid sweep transiently
        // mis-fires, tombstoning "T" even though the process is alive. The
        // adapter's very next event reports under the SAME id "T" with a
        // whole-transcript recompute (turns=105, not a fresh segment's own
        // small delta). Because old_id == new_id here, this must be treated
        // as a plain overwrite — no carry, no compactions bump — or the
        // cumulative counters silently double (P1-A).
        let mut r = Registry::new(None);
        let now = t0();
        let mut m = meta("/repo", "/dev/ttys004");
        m.insert("pid".into(), Value::from(555));
        m.insert("turns".into(), Value::from(100));
        m.insert("tool_calls".into(), Value::from(400));
        r.set_state(Some("T"), State::Running, None, None, Some(m), now);

        // False reap: process never actually died.
        r.reap_session("T", now);

        // Adapter's next Stop, same id, whole-transcript recompute.
        let later = now.checked_add(Duration::from_secs(1)).unwrap();
        let mut m2 = meta("/repo", "/dev/ttys004");
        m2.insert("pid".into(), Value::from(555));
        m2.insert("turns".into(), Value::from(105));
        m2.insert("tool_calls".into(), Value::from(420));
        r.set_state(Some("T"), State::Thinking, None, None, Some(m2), later);

        let s = r.session_by_slot(1).expect("slot 1 occupied");
        assert_eq!(s.id, "T");
        assert_eq!(s.meta.get("turns"), Some(&Value::from(105)), "overwritten, not doubled to 205");
        assert_eq!(s.meta.get("tool_calls"), Some(&Value::from(420)));
        assert_eq!(s.meta.get("compactions"), None, "no compaction actually happened");
    }

    #[test]
    fn same_id_recovers_its_tombstone_without_identity_metadata() {
        let mut r = Registry::new(None);
        let now = t0();
        r.set_state(
            Some("same-id"),
            State::Running,
            Some("claude".into()),
            Some("Original".into()),
            Some(meta("/repo", "/dev/ttys004")),
            now,
        );
        r.reap_session("same-id", now);

        let later = now.checked_add(Duration::from_secs(1)).unwrap();
        let effects = r.set_state(
            Some("same-id"),
            State::Thinking,
            Some("claude".into()),
            Some("Original".into()),
            Some(Map::new()),
            later,
        );

        assert!(effects.contains(&Effect::SessionRekeyed {
            old_id: "same-id".into(),
            new_id: "same-id".into(),
        }));
        assert!(r.tombstones_snapshot().is_empty());
        assert!(r.list().iter().any(|session| session.id == "same-id"));
    }

    #[test]
    fn differing_id_fork_still_carries_forward_after_reap_recovery() {
        // Contrast with the same-id case above: a genuinely different id
        // recovering from a tombstone (real cross-process fork, just routed
        // through the reap/tombstone path rather than State::Compacting)
        // must still carry+add and bump compactions.
        let mut r = Registry::new(None);
        let now = t0();
        let mut m = meta("/repo", "/dev/ttys004");
        m.insert("pid".into(), Value::from(555));
        m.insert("turns".into(), Value::from(30));
        r.set_state(Some("old"), State::Running, None, None, Some(m), now);
        r.reap_session("old", now);

        let later = now.checked_add(Duration::from_secs(1)).unwrap();
        let mut m2 = meta("/repo", "/dev/ttys004");
        m2.insert("pid".into(), Value::from(555));
        m2.insert("turns".into(), Value::from(3));
        let effects = r.set_state(Some("new"), State::Thinking, None, None, Some(m2), later);

        assert!(effects.contains(&Effect::SessionRekeyed {
            old_id: "old".into(),
            new_id: "new".into(),
        }));
        let s = r.session_by_slot(1).expect("slot 1 occupied");
        assert_eq!(s.id, "new");
        assert_eq!(s.meta.get("turns"), Some(&Value::from(33)), "carried forward: 30 + 3");
        assert_eq!(s.meta.get("compactions"), Some(&Value::from(1u64)));
    }

    #[test]
    fn gauge_metric_never_carries_even_across_a_genuine_fork() {
        // context_tokens has no METRICS entry -> defaults to Accumulation::
        // Gauge -> must be a plain overwrite on both a regular update and a
        // genuine rekey fork, never summed via _carry_.
        let mut r = Registry::new(None);
        let now = t0();
        let mut m1 = meta("/repo", "/dev/ttys004");
        m1.insert("context_tokens".into(), Value::from(50_000));
        r.set_state(Some("old"), State::Running, None, None, Some(m1), now);
        r.set_state(Some("old"), State::Compacting, None, None, None, now);

        let later = now.checked_add(Duration::from_secs(1)).unwrap();
        let mut m2 = meta("/repo", "/dev/ttys004");
        m2.insert("context_tokens".into(), Value::from(1_200));
        r.set_state(Some("new"), State::Thinking, None, None, Some(m2), later);

        let s = r.session_by_slot(1).expect("slot 1 occupied");
        assert_eq!(s.meta.get("context_tokens"), Some(&Value::from(1_200)));
        assert!(s.carry.get("context_tokens").is_none());
    }

    #[test]
    fn cumulative_lineage_compactions_from_adapter_overwrites_instead_of_stacking() {
        // Codex/Cursor style: the adapter itself reports `compactions` as a
        // whole-lineage recount on a genuine fork. The daemon must respect
        // that value as-is (CumulativeLineage overwrite) rather than adding
        // its own +1 synthesized increment on top of it.
        let mut r = Registry::new(None);
        let now = t0();
        let mut m1 = meta("/repo", "/dev/ttys004");
        m1.insert("pid".into(), Value::from(555));
        m1.insert("compactions".into(), Value::from(4u64));
        r.set_state(Some("old"), State::Running, None, None, Some(m1), now);
        r.reap_session("old", now);

        let later = now.checked_add(Duration::from_secs(1)).unwrap();
        let mut m2 = meta("/repo", "/dev/ttys004");
        m2.insert("pid".into(), Value::from(555));
        m2.insert("compactions".into(), Value::from(7u64));
        let effects = r.set_state(Some("new"), State::Thinking, None, None, Some(m2), later);

        assert!(effects.contains(&Effect::SessionRekeyed {
            old_id: "old".into(),
            new_id: "new".into(),
        }));
        let s = r.session_by_slot(1).expect("slot 1 occupied");
        assert_eq!(
            s.meta.get("compactions"),
            Some(&Value::from(7u64)),
            "adapter-reported whole-lineage value wins, not old(4)+daemon-increment(1)"
        );
    }

    #[test]
    fn cumulative_lineage_compactions_synthesized_by_daemon_when_adapter_silent() {
        // Claude Code style: the adapter never reports `compactions` at
        // all, so the daemon is the sole writer and must still increment on
        // a genuine fork, compounding across repeated forks like before.
        let mut r = Registry::new(None);
        let now = t0();
        let m1 = meta("/repo", "/dev/ttys004");
        r.set_state(Some("old"), State::Running, None, None, Some(m1), now);
        r.set_state(Some("old"), State::Compacting, None, None, None, now);

        let later = now.checked_add(Duration::from_secs(1)).unwrap();
        let m2 = meta("/repo", "/dev/ttys004");
        r.set_state(Some("new"), State::Thinking, None, None, Some(m2), later);

        let s = r.session_by_slot(1).expect("slot 1 occupied");
        assert_eq!(s.meta.get("compactions"), Some(&Value::from(1u64)));
    }

    #[test]
    fn claude_plan_precompact_is_recorded_without_a_rekey_or_double_count() {
        // Claude foreground compaction (including from plan mode) keeps the
        // same session id. PreCompact must therefore record it immediately;
        // when a background continuation does rekey, that already-recorded
        // event must not become a second generic compaction.
        let mut r = Registry::new(None);
        let now = t0();
        r.set_state(
            Some("old"),
            State::Running,
            Some("claude".into()),
            Some("Plan the migration".into()),
            Some(meta("/repo", "/dev/ttys004")),
            now,
        );

        let mut precompact = meta("/repo", "/dev/ttys004");
        precompact.insert("compaction_event".into(), Value::from("precompact"));
        precompact.insert("compaction_trigger".into(), Value::from("auto"));
        precompact.insert(
            "compaction_permission_mode".into(),
            Value::from("plan"),
        );
        r.set_state(
            Some("old"),
            State::Compacting,
            Some("claude".into()),
            None,
            Some(precompact),
            now,
        );
        let s = r.session_by_slot(1).unwrap();
        assert_eq!(s.meta.get("compactions"), Some(&Value::from(1u64)));
        assert_eq!(s.meta.get("plan_compactions"), Some(&Value::from(1u64)));
        assert_eq!(s.meta.get("last_compaction_trigger"), Some(&Value::from("auto")));
        assert_eq!(
            s.meta.get("last_compaction_permission_mode"),
            Some(&Value::from("plan"))
        );
        assert!(
            s.meta.get("compaction_event").is_none(),
            "the transport marker must not leak into displayed metadata"
        );

        let later = now.checked_add(Duration::from_secs(1)).unwrap();
        let effects = r.set_state(
            Some("new"),
            State::Thinking,
            Some("claude".into()),
            Some("Plan the migration".into()),
            Some(meta("/repo", "/dev/ttys004")),
            later,
        );
        assert!(effects.contains(&Effect::SessionRekeyed {
            old_id: "old".into(),
            new_id: "new".into(),
        }));
        let s = r.session_by_slot(1).unwrap();
        assert_eq!(s.meta.get("compactions"), Some(&Value::from(1u64)));
        assert_eq!(s.meta.get("plan_compactions"), Some(&Value::from(1u64)));
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
        r.set_state(
            Some("old"),
            State::Running,
            None,
            Some("My Chat".into()),
            Some(m),
            now,
        );

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
        assert!(!effects
            .iter()
            .any(|e| matches!(e, Effect::SessionRekeyed { .. })));
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
    fn tombstone_does_not_recover_a_fresh_session_by_shared_label_and_cwd() {
        // Generated titles and a repository directory are not a stable
        // conversation identity. A fresh Claude/Codex session can share both
        // with a disconnected row, so only an explicit resume marker may
        // recover a fresh process from a tombstone.
        let mut r = Registry::new(None);
        let now = t0();
        let m = meta("/repo", "/dev/ttys004");
        r.set_state(
            Some("old"),
            State::Running,
            None,
            Some("Fix drag stutter".into()),
            Some(m),
            now,
        );
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

        assert!(!effects.iter().any(|effect| matches!(
            effect,
            Effect::SessionRekeyed { old_id, new_id }
                if old_id == "old" && new_id == "new"
        )));
        assert!(r.list().iter().any(|session| session.id == "new"));
        assert!(r
            .tombstones_snapshot()
            .iter()
            .any(|(id, _, _)| id == "old"));
    }

    #[test]
    fn reap_session_tombstone_does_not_recover_on_single_signal() {
        // Only cwd matches — must never be enough on its own.
        let mut r = Registry::new(None);
        let now = t0();
        let m = meta("/repo", "/dev/ttys004");
        r.set_state(
            Some("old"),
            State::Running,
            None,
            Some("Old Chat".into()),
            Some(m),
            now,
        );
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
        assert!(!effects
            .iter()
            .any(|e| matches!(e, Effect::SessionRekeyed { .. })));
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
        assert!(!effects
            .iter()
            .any(|e| matches!(e, Effect::SessionRekeyed { .. })));
    }

    #[test]
    fn tombstone_infinite_ttl_recovers_arbitrarily_late() {
        let mut r = Registry::new(None).with_tombstone_ttl(None);
        let now = t0();
        let mut m = meta("/repo", "/dev/ttys004");
        m.insert("pid".into(), Value::from(555));
        r.set_state(Some("old"), State::Running, None, None, Some(m), now);
        r.reap_session("old", now);

        let way_later = now
            .checked_add(Duration::from_secs(60 * 60 * 24 * 30))
            .unwrap();
        let mut m2 = meta("/repo", "/dev/ttys004");
        m2.insert("pid".into(), Value::from(555));
        let effects = r.set_state(
            Some("new"),
            State::Thinking,
            None,
            None,
            Some(m2),
            way_later,
        );
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
        r.set_state(
            Some("old"),
            State::Running,
            None,
            Some("Chat".into()),
            Some(m),
            now,
        );
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
        let e = r.set_state(
            Some("new"),
            State::Thinking,
            None,
            Some("Chat".into()),
            Some(m2),
            later,
        );
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
        assert!(r
            .list()
            .iter()
            .any(|s| s.id == "old" && s.state == State::Compacting));
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
        assert!(r
            .list()
            .iter()
            .any(|s| s.id == "old" && s.state == State::Compacting));
        assert!(r.list().iter().any(|s| s.id == "new" && s.slot == Some(2)));
    }

    #[test]
    fn time_passage_never_reaps_a_stuck_compacting_session() {
        let mut r = Registry::new(None);
        let t = Instant::now();
        r.set_state(
            Some("a"),
            State::Compacting,
            None,
            None,
            Some(meta("/repo", "/dev/ttys004")),
            t,
        );
        r.set_state(Some("b"), State::Running, None, None, None, t);

        let past_grace = t
            .checked_add(COMPACT_GRACE + Duration::from_secs(1))
            .unwrap();
        let effects = r.expire_compacting(past_grace);
        assert!(effects.is_empty());
        assert!(r.session_by_slot(1).is_some());
        assert!(
            r.session_by_slot(2).is_some(),
            "unrelated session b untouched"
        );
        assert_eq!(r.list().len(), 2);
    }

    fn resumable_session(registry: &mut Registry, id: &str, state: State, now: Instant) {
        let mut m = meta("/tmp", "/dev/ttys004");
        m.insert("pid".into(), Value::from(4242));
        m.insert("managed".into(), Value::from(false));
        m.insert("turns".into(), Value::from(7));
        registry.set_state(
            Some(id),
            state,
            Some("claude".into()),
            Some("Work".into()),
            Some(m),
            now,
        );
    }

    #[test]
    fn managed_relaunch_blocks_old_events_and_preserves_same_id_session() {
        let mut r = Registry::new(None);
        let now = t0();
        resumable_session(&mut r, "source", State::Idle, now);
        r.rename("source", Some("Important"));
        let (_, effects) = r.begin_managed_relaunch("source", "launch-1", now).unwrap();
        assert!(effects.iter().any(|e| matches!(
            e,
            Effect::SessionUpsert {
                state: State::Compacting,
                ..
            }
        )));

        assert!(r
            .set_state(Some("source"), State::Running, None, None, None, now)
            .is_empty());
        assert!(r.end_session("source").is_empty());
        assert_eq!(r.list()[0].state, State::Compacting);

        let mut replacement = meta("/tmp", "/dev/ttys009");
        replacement.insert("pid".into(), Value::from(5252));
        replacement.insert("managed".into(), Value::from(true));
        replacement.insert("relaunch_id".into(), Value::from("launch-1"));
        let completed = r.set_state(
            Some("source"),
            State::Thinking,
            Some("claude".into()),
            None,
            Some(replacement),
            now,
        );
        assert!(completed.contains(&Effect::ManagedRelaunchCompleted {
            old_id: "source".into(),
            new_id: "source".into(),
            launch_id: "launch-1".into(),
        }));
        let session = &r.list()[0];
        assert_eq!(session.slot, Some(1));
        assert_eq!(session.name.as_deref(), Some("Important"));
        assert_eq!(session.meta.get("turns"), Some(&Value::from(7)));
    }

    #[test]
    fn managed_relaunch_can_rekey_and_failure_is_recoverable() {
        let mut r = Registry::new(None);
        let now = t0();
        resumable_session(&mut r, "old", State::Done, now);
        r.begin_managed_relaunch("old", "launch-2", now).unwrap();
        let mut replacement = meta("/tmp", "/dev/ttys010");
        replacement.insert("pid".into(), Value::from(6262));
        replacement.insert("managed".into(), Value::from(true));
        replacement.insert("relaunch_id".into(), Value::from("launch-2"));
        let effects = r.set_state(
            Some("new"),
            State::Thinking,
            Some("claude".into()),
            None,
            Some(replacement),
            now,
        );
        assert!(effects.contains(&Effect::SessionRekeyed {
            old_id: "old".into(),
            new_id: "new".into()
        }));
        assert!(effects.contains(&Effect::ManagedRelaunchCompleted {
            old_id: "old".into(),
            new_id: "new".into(),
            launch_id: "launch-2".into(),
        }));

        resumable_session(&mut r, "failed", State::Waiting, now);
        r.begin_managed_relaunch("failed", "launch-3", now).unwrap();
        let failed = r.fail_managed_relaunch("failed", "launch-3", now);
        assert!(failed.contains(&Effect::SessionDisconnected {
            id: "failed".into(),
            slot: Some(2)
        }));
        assert!(r
            .tombstones_snapshot()
            .iter()
            .any(|(id, _, _)| id == "failed"));
    }

    #[test]
    fn explicit_history_resume_uses_exact_tombstone_and_fresh_process_identity() {
        let mut r = Registry::new(None);
        let now = t0();

        let mut intended = meta("/same/repo", "/dev/ttys003");
        intended.insert("pid".into(), Value::from(300));
        intended.insert("turns".into(), Value::from(33));
        r.set_state(
            Some("session-3"),
            State::Done,
            Some("claude".into()),
            Some("Same label".into()),
            Some(intended),
            now,
        );

        // A more recent tombstone has the same two fuzzy recovery signals.
        // Before the explicit resume marker, this one won the recency tie and
        // was incorrectly rekeyed as session-3.
        let later = now.checked_add(Duration::from_secs(1)).unwrap();
        let mut wrong = meta("/same/repo", "/dev/ttys004");
        wrong.insert("pid".into(), Value::from(100));
        wrong.insert("turns".into(), Value::from(11));
        r.set_state(
            Some("session-1"),
            State::Done,
            Some("claude".into()),
            Some("Same label".into()),
            Some(wrong),
            later,
        );
        // Create both as independent live sessions first, then sweep them.
        // Otherwise registering session-1 after session-3 was already swept
        // would itself exercise (and consume) the generic recovery matcher.
        r.reap_session("session-3", now);
        r.reap_session("session-1", later);

        let resumed_at = later.checked_add(Duration::from_secs(1)).unwrap();
        let mut resumed = meta("/same/repo", "/dev/ttys009");
        resumed.insert("pid".into(), Value::from(9003));
        resumed.insert("managed".into(), Value::from(true));
        resumed.insert("mux_pane".into(), Value::from("%3"));
        resumed.insert("resume_session_id".into(), Value::from("session-3"));
        let effects = r.set_state(
            Some("session-3"),
            State::Thinking,
            Some("claude".into()),
            Some("Same label".into()),
            Some(resumed),
            resumed_at,
        );

        assert!(effects.contains(&Effect::SessionRekeyed {
            old_id: "session-3".into(),
            new_id: "session-3".into(),
        }));
        let live = r.list();
        assert_eq!(live.len(), 1);
        assert_eq!(live[0].id, "session-3");
        assert_eq!(
            live[0].pid(),
            Some(9003),
            "new process must replace old pid"
        );
        assert_eq!(live[0].meta.get("mux_pane"), Some(&Value::from("%3")));
        assert_eq!(live[0].meta.get("turns"), Some(&Value::from(33)));
        assert!(
            r.tombstones_snapshot()
                .iter()
                .any(|(id, _, _)| id == "session-1"),
            "the same-directory session must remain untouched"
        );
    }

    #[test]
    fn tombstone_recovery_never_reuses_a_slot_claimed_by_another_live_session() {
        let mut r = Registry::new(None);
        let now = t0();
        let mut old = meta("/repo", "/dev/ttys003");
        old.insert("pid".into(), Value::from(300));
        r.set_state(
            Some("old"),
            State::Done,
            Some("codex".into()),
            Some("Work".into()),
            Some(old),
            now,
        );
        assert_eq!(r.list()[0].slot, Some(1));
        r.reap_session("old", now);

        let later = now.checked_add(Duration::from_secs(1)).unwrap();
        r.set_state(
            Some("current"),
            State::Thinking,
            Some("codex".into()),
            Some("Other".into()),
            Some(meta("/repo", "/dev/ttys004")),
            later,
        );
        assert_eq!(
            r.list()[0].slot,
            Some(1),
            "freed key was legitimately reused"
        );

        let mut resumed = meta("/repo", "/dev/ttys009");
        resumed.insert("pid".into(), Value::from(999));
        resumed.insert("resume_session_id".into(), Value::from("old"));
        r.set_state(
            Some("old"),
            State::Thinking,
            Some("codex".into()),
            Some("Work".into()),
            Some(resumed),
            later,
        );

        let live = r.list();
        assert_eq!(live.len(), 2);
        assert_eq!(
            live.iter().find(|s| s.id == "current").unwrap().slot,
            Some(1)
        );
        let resumed = live.iter().find(|s| s.id == "old").unwrap();
        assert_eq!(resumed.slot, Some(2));
        assert_eq!(resumed.pid(), Some(999));
    }

    #[test]
    fn explicit_history_resume_without_its_tombstone_skips_fuzzy_recovery() {
        let mut r = Registry::new(None);
        let now = t0();
        r.set_state(
            Some("unrelated"),
            State::Done,
            Some("codex".into()),
            Some("Same label".into()),
            Some(meta("/same/repo", "/dev/ttys003")),
            now,
        );
        r.reap_session("unrelated", now);

        let mut resumed = meta("/same/repo", "/dev/ttys009");
        resumed.insert("pid".into(), Value::from(303));
        resumed.insert("resume_session_id".into(), Value::from("history-id"));
        let effects = r.set_state(
            Some("history-id"),
            State::Thinking,
            Some("codex".into()),
            Some("Same label".into()),
            Some(resumed),
            now,
        );

        assert!(!effects.iter().any(|effect| matches!(
            effect,
            Effect::SessionRekeyed { old_id, .. } if old_id == "unrelated"
        )));
        assert!(r
            .list()
            .iter()
            .any(|s| s.id == "history-id" && s.pid() == Some(303)));
        assert!(r
            .tombstones_snapshot()
            .iter()
            .any(|(id, _, _)| id == "unrelated"));
    }
}
