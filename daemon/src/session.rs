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
    /// A session ended. `SET_KEY_STATE <slot> 0xFF` if it had a slot; always a
    /// `session-ended` event.
    SessionEnded { id: String, slot: Option<u8> },
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
pub struct Registry {
    sessions: HashMap<String, Session>,
    default_state: Option<State>,
    /// Last aggregate we emitted, for change detection.
    last_aggregate: State,
    /// TTL for identified sessions; `None` = never expire.
    ttl: Option<Duration>,
}

impl Registry {
    pub fn new(ttl: Option<Duration>) -> Self {
        Registry {
            sessions: HashMap::new(),
            default_state: None,
            last_aggregate: State::Idle,
            ttl,
        }
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
                        for (k, v) in m {
                            sess.meta.insert(k, v);
                        }
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
                    // Before registering a brand-new session, check for an
                    // orphaned `Compacting` one to reunite with: Claude
                    // Code's `PreCompact` hook marks the pre-compaction
                    // session `Compacting` (adapters/claude-code/hooks.sh)
                    // because it knows the conversation is about to get a
                    // new session_id, but Claude Code exposes no field
                    // linking the two — so the continuation's first hook
                    // event just looks like a brand-new session_id to us.
                    // Matching on cwd+tty (both set by the same adapter's
                    // ancestor-walk, PROTOCOL.md §4) within `COMPACT_GRACE`
                    // is how we tell "this is that session's continuation"
                    // apart from "this is a genuinely new session that
                    // happens to share a terminal" (which can't happen — a
                    // tty hosts one foreground session at a time).
                    let incoming_meta = meta.unwrap_or_default();
                    let incoming_cwd = incoming_meta.get("cwd").and_then(|v| v.as_str());
                    let incoming_tty = incoming_meta.get("tty").and_then(|v| v.as_str());
                    let rekey_from = incoming_cwd.and_then(|cwd| {
                        self.sessions
                            .iter()
                            .find(|(_, s)| {
                                s.state == State::Compacting
                                    && s.cwd() == cwd
                                    && s.tty() == incoming_tty.unwrap_or("")
                                    && now.saturating_duration_since(s.last_update) <= COMPACT_GRACE
                            })
                            .map(|(old_id, _)| old_id.clone())
                    });

                    if let Some(old_id) = rekey_from {
                        let mut sess = self.sessions.remove(&old_id).unwrap();
                        sess.id = id.to_string();
                        sess.state = state;
                        if kind.is_some() {
                            sess.kind = kind;
                        }
                        if label.is_some() {
                            sess.label = label;
                        }
                        for (k, v) in incoming_meta {
                            sess.meta.insert(k, v);
                        }
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
        for (k, v) in meta {
            sess.meta.insert(k, v);
        }
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
    pub fn end_session(&mut self, id: &str) -> Vec<Effect> {
        let mut effects = Vec::new();
        if let Some(sess) = self.sessions.remove(id) {
            effects.push(Effect::SessionEnded {
                id: id.to_string(),
                slot: sess.slot,
            });
            self.note_aggregate(&mut effects);
        }
        effects
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
            if let Some(sess) = self.sessions.remove(&id) {
                effects.push(Effect::SessionEnded {
                    id,
                    slot: sess.slot,
                });
            }
        }
        if !effects.is_empty() {
            self.note_aggregate(&mut effects);
        }
        effects
    }

    /// End any session stuck in `State::Compacting` past `COMPACT_GRACE` —
    /// its continuation never showed up (compaction was cancelled, or
    /// genuinely never claimed the slot). Runs unconditionally, unlike
    /// `expire`: a stuck "compacting" indicator is actively misleading (it
    /// promises "this is temporary"), so it can't be left to
    /// `session_ttl_minutes`, which may be configured to never expire.
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
            if let Some(sess) = self.sessions.remove(&id) {
                effects.push(Effect::SessionEnded {
                    id,
                    slot: sess.slot,
                });
            }
        }
        if !effects.is_empty() {
            self.note_aggregate(&mut effects);
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
        assert!(effects.contains(&Effect::SessionEnded {
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
        assert!(effects.contains(&Effect::SessionEnded {
            id: "a".into(),
            slot: Some(1),
        }));
        assert!(r.session_by_slot(2).is_some(), "unrelated session b untouched");
        assert_eq!(r.list().len(), 1);
    }
}
