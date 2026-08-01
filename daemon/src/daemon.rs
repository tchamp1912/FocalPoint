//! The `focalpointd` daemon: device thread(s), the Unix-socket API server, and
//! event -> action dispatch.
//!
//! Architecture:
//! ```text
//!   socket clients ──▶ tokio UnixListener ──▶ per-conn task
//!                                 │  set-state/set-led        ▲ subscribe
//!                       host_tx (mpsc) │              broadcast │ (events)
//!                                 ▼                             │
//!                    device thread (std) ── HID/mock ──▶ handle_device_event
//!                                 ▲ shared state (current state, present flag)
//! ```
//! The device thread does blocking HID I/O; the socket server is async. They
//! communicate over an unbounded mpsc (host->device) and a broadcast channel
//! (device->subscribers). Current state lives in `Shared` so it can be pushed
//! to a device that (re)appears.

use crate::config::{Action, Config};
use crate::protocol::{
    control_id, control_name, joy_id, joy_name, DeviceEvent, HostCmd, Pattern, State,
};
use crate::session::{Effect, Registry, Session};
use crate::styles::{Style, StyleTable};
use serde::{Deserialize, Serialize};
use serde_json::{Map, Value};
use std::sync::{Arc, Mutex};
use std::collections::HashMap;
use std::time::{Duration, Instant};

/// Socket requests defined by PROTOCOL.md §3 and the daemon-side CLI
/// extensions in §4.  Keep this as the single Rust representation of the
/// wire contract; dispatch only operates on this decoded form.
#[derive(Debug, Deserialize)]
#[serde(tag = "cmd", rename_all = "kebab-case")]
pub enum Request {
    SetState { state: String, session: Option<String>, kind: Option<String>, label: Option<String>, meta: Option<Map<String, Value>> },
    SetMeta { session: String, kind: Option<String>, label: Option<String>, #[serde(default)] meta: Map<String, Value> },
    GetState,
    ListSessions,
    RenameSession { session: String, name: Option<String> },
    SwapSlots { session1: String, session2: String },
    EndSession { session: String },
    QuitSession { session: String },
    FocusSession { session: String },
    SetLed { index: u64, rgb: Vec<u64> },
    GetStyles,
    SetStyle { state: String, rgb: Vec<u64>, pattern: String, period_ms: Option<u64> },
    SetUsage { provider: String, usage: Map<String, Value> },
    GetUsage,
    Subscribe,
    Inject { kind: String, control: Option<String>, action: Option<String>, delta: Option<i64>, gesture: Option<String> },
    Ping,
}

#[derive(Debug, Serialize)]
pub struct SessionDto {
    session: String,
    kind: Option<String>,
    label: Option<String>,
    name: Option<String>,
    slot: Option<u8>,
    state: String,
    meta: Map<String, Value>,
    #[serde(skip_serializing_if = "Option::is_none")]
    connected: Option<bool>,
}

#[derive(Debug, Serialize)]
pub struct StyleDto {
    rgb: [u8; 3],
    pattern: String,
    period_ms: u16,
}

#[derive(Debug)]
pub struct StyleMap(Vec<(String, StyleDto)>);

impl Serialize for StyleMap {
    fn serialize<S>(&self, serializer: S) -> Result<S::Ok, S::Error>
    where S: serde::Serializer {
        use serde::ser::SerializeMap;
        let mut map = serializer.serialize_map(Some(self.0.len()))?;
        for (name, style) in &self.0 { map.serialize_entry(name, style)?; }
        map.end()
    }
}

/// All subscriber event shapes (PROTOCOL.md §3).
#[derive(Debug, Serialize)]
#[serde(tag = "event", rename_all = "kebab-case")]
pub enum Event {
    State { state: String },
    Session { #[serde(flatten)] session: SessionDto },
    SessionEnded { session: String, slot: Option<u8> },
    SessionDisconnected { session: String, slot: Option<u8> },
    SessionRekeyed { old_session: String, new_session: String },
    Key { control: String, pressed: bool },
    Dial { delta: i8 },
    Joy { gesture: String },
    Usage { provider: String, usage: Map<String, Value> },
    Style { state: String, rgb: [u8; 3], pattern: String, period_ms: u16 },
}

/// All one-line non-stream responses.
#[derive(Debug, Serialize)]
#[serde(untagged)]
pub enum Response {
    Ok { ok: bool },
    State { ok: bool, state: String },
    Sessions { ok: bool, sessions: Vec<SessionDto> },
    Usage { ok: bool, usage: HashMap<String, Map<String, Value>> },
    Styles { ok: bool, styles: StyleMap },
    Ping { ok: bool, device: bool },
    Error { ok: bool, error: String },
}

fn event_line(event: Event) -> String {
    serde_json::to_string(&event).expect("event DTO must serialize")
}

/// True if a process with this pid exists, via `kill(pid, 0)` — sends no
/// signal, just checks. `ESRCH` means it doesn't; any other errno (e.g.
/// `EPERM`, which would mean it exists but we lack permission to signal it —
/// not expected here since these are always our own user's descendant
/// processes) is treated as "still alive" so a transient/unexpected errno
/// never causes a false-positive reap.
fn process_is_alive(pid: i32) -> bool {
    if unsafe { libc::kill(pid as libc::pid_t, 0) } == 0 {
        return true;
    }
    std::io::Error::last_os_error().raw_os_error() != Some(libc::ESRCH)
}

/// Send `sig` to `pid` (best-effort; ignores the result). Used by the
/// graceful-quit escalation in the `quit-session` handler.
#[cfg(unix)]
fn send_signal(pid: i32, sig: i32) {
    unsafe {
        libc::kill(pid as libc::pid_t, sig);
    }
}

/// Ask an agent process to exit the way a user pressing its exit key would,
/// so the tool runs its own teardown and its `SessionEnd` hook fires (which
/// itself calls `focalpoint end-session`, removing the session through the
/// real path). Both Claude Code (Ctrl-C twice, alongside its `/exit`) and
/// Codex ("Ctrl+C to exit" — its only interactive quit) exit on SIGINT, so
/// this sends SIGINT, gives it a moment, sends a second SIGINT, and only then
/// escalates to SIGTERM if it's still alive — never SIGKILL, which would skip
/// the very teardown this exists to trigger. Runs on its own thread (it
/// sleeps between signals); best-effort throughout — a process that's already
/// gone just no-ops.
#[cfg(unix)]
fn quit_agent_process(pid: i32) {
    use std::time::Duration;
    if !process_is_alive(pid) {
        return;
    }
    send_signal(pid, libc::SIGINT);
    std::thread::sleep(Duration::from_millis(600));
    if process_is_alive(pid) {
        send_signal(pid, libc::SIGINT); // Claude's "twice to exit"
        std::thread::sleep(Duration::from_millis(1200));
    }
    if process_is_alive(pid) {
        send_signal(pid, libc::SIGTERM);
    }
}

/// Parse an RGB triple from a JSON value (array of 3 integers 0..=255).
fn parse_rgb(v: Option<&serde_json::Value>) -> Result<[u8; 3], String> {
    let arr = v
        .and_then(|v| v.as_array())
        .filter(|a| a.len() == 3)
        .ok_or_else(|| "'rgb' must be an array of 3 integers".to_string())?;
    let mut out = [0u8; 3];
    for (slot, item) in out.iter_mut().zip(arr) {
        match item.as_u64() {
            Some(n) if n <= 255 => *slot = n as u8,
            _ => return Err("rgb values must be integers 0..=255".to_string()),
        }
    }
    Ok(out)
}

fn parse_rgb_values(values: &[u64]) -> Result<[u8; 3], String> {
    if values.len() != 3 {
        return Err("'rgb' must be an array of 3 integers".to_string());
    }
    let mut rgb = [0; 3];
    for (out, value) in rgb.iter_mut().zip(values) {
        if *value > 255 {
            return Err("rgb values must be integers 0..=255".to_string());
        }
        *out = *value as u8;
    }
    Ok(rgb)
}

fn parse_set_style_fields(
    state_name: &str, rgb: &[u64], pattern_name: &str, period_ms: Option<u64>,
) -> Result<(State, Style), String> {
    let state = State::from_name(state_name)
        .ok_or_else(|| format!("unknown state: {state_name:?}"))?;
    let pattern = Pattern::from_name(pattern_name).ok_or_else(|| {
        format!("unknown pattern {pattern_name:?}; expected solid|breathe|blink|strobe|off")
    })?;
    let period_ms = match period_ms {
        None => crate::styles::default_style(state).period_ms,
        Some(n) if n <= u16::MAX as u64 => n as u16,
        Some(_) => return Err("period_ms must be an integer 0..=65535".to_string()),
    };
    Ok((state, Style::new(parse_rgb_values(rgb)?, pattern, period_ms)))
}

fn parse_inject_fields(
    kind: &str, control: Option<&str>, action: Option<&str>, delta: Option<i64>, gesture: Option<&str>,
) -> Result<Vec<DeviceEvent>, String> {
    match kind {
        "key" => {
            let control = control.ok_or_else(|| "inject key requires 'control'".to_string())?;
            let id = control_id(control).ok_or_else(|| format!("unknown control: {control:?}"))?;
            match action.unwrap_or("tap") {
                "press" => Ok(vec![DeviceEvent::Key { control: id, pressed: true }]),
                "release" => Ok(vec![DeviceEvent::Key { control: id, pressed: false }]),
                "tap" => Ok(vec![DeviceEvent::Key { control: id, pressed: true }, DeviceEvent::Key { control: id, pressed: false }]),
                other => Err(format!("unknown key action {other:?}; expected press|release|tap")),
            }
        }
        "dial" => {
            let delta = delta.ok_or_else(|| "inject dial requires integer 'delta'".to_string())?;
            if !(-128..=127).contains(&delta) { return Err(format!("delta {delta} out of range (-128..=127)")); }
            Ok(vec![DeviceEvent::Dial { delta: delta as i8 }])
        }
        "joy" => {
            let gesture = gesture.ok_or_else(|| "inject joy requires 'gesture'".to_string())?;
            let id = joy_id(gesture).ok_or_else(|| format!("unknown gesture: {gesture:?}"))?;
            Ok(vec![DeviceEvent::Joy { gesture: id }])
        }
        other => Err(format!("unknown inject kind {other:?}; expected key|dial|joy")),
    }
}

/// Merge a numeric provider usage update into its last-known snapshot.
fn merge_usage(
    snapshots: &mut HashMap<String, serde_json::Map<String, serde_json::Value>>,
    provider: &str,
    update: &serde_json::Map<String, serde_json::Value>,
) -> Result<serde_json::Map<String, serde_json::Value>, String> {
    if provider.is_empty() {
        return Err("set-usage provider must not be empty".to_string());
    }
    if update.is_empty() || update.values().any(|value| !value.is_number()) {
        return Err("set-usage usage must be a non-empty object of numeric values".to_string());
    }
    let entry = snapshots.entry(provider.to_string()).or_default();
    for (key, value) in update {
        entry.insert(key.clone(), value.clone());
    }
    Ok(entry.clone())
}

/// Parse a `set-style` request body (PROTOCOL.md §3) into a `(state, style)`.
/// `period_ms` defaults to the state's default when omitted; `Style::new`
/// clamps it to 100..=5000. Pure/protocol-only, so unit-testable everywhere.
pub fn parse_set_style(value: &serde_json::Value) -> Result<(State, Style), String> {
    let state_name = value
        .get("state")
        .and_then(|s| s.as_str())
        .ok_or_else(|| "set-style requires 'state'".to_string())?;
    let state = State::from_name(state_name)
        .ok_or_else(|| format!("unknown state: {state_name:?}"))?;
    let rgb = parse_rgb(value.get("rgb"))?;
    let pattern_name = value
        .get("pattern")
        .and_then(|s| s.as_str())
        .ok_or_else(|| "set-style requires 'pattern'".to_string())?;
    let pattern = Pattern::from_name(pattern_name).ok_or_else(|| {
        format!("unknown pattern {pattern_name:?}; expected solid|breathe|blink|strobe|off")
    })?;
    let period_ms = match value.get("period_ms") {
        None | Some(serde_json::Value::Null) => crate::styles::default_style(state).period_ms,
        Some(v) => match v.as_u64() {
            Some(n) if n <= u16::MAX as u64 => n as u16,
            _ => return Err("period_ms must be an integer 0..=65535".to_string()),
        },
    };
    Ok((state, Style::new(rgb, pattern, period_ms)))
}

/// Parse an `inject` request body (PROTOCOL.md §3) into one or more synthetic
/// device events. A key `tap` expands to a press followed by a release. This
/// is platform-independent (pure protocol) so it is unit-testable everywhere.
pub fn parse_inject(value: &serde_json::Value) -> Result<Vec<DeviceEvent>, String> {
    let kind = value
        .get("kind")
        .and_then(|k| k.as_str())
        .ok_or_else(|| "inject requires 'kind' (key|dial|joy)".to_string())?;
    match kind {
        "key" => {
            let control = value
                .get("control")
                .and_then(|c| c.as_str())
                .ok_or_else(|| "inject key requires 'control'".to_string())?;
            let id = control_id(control).ok_or_else(|| format!("unknown control: {control:?}"))?;
            let action = value.get("action").and_then(|a| a.as_str()).unwrap_or("tap");
            match action {
                "press" => Ok(vec![DeviceEvent::Key {
                    control: id,
                    pressed: true,
                }]),
                "release" => Ok(vec![DeviceEvent::Key {
                    control: id,
                    pressed: false,
                }]),
                "tap" => Ok(vec![
                    DeviceEvent::Key {
                        control: id,
                        pressed: true,
                    },
                    DeviceEvent::Key {
                        control: id,
                        pressed: false,
                    },
                ]),
                other => Err(format!(
                    "unknown key action {other:?}; expected press|release|tap"
                )),
            }
        }
        "dial" => {
            let delta = value
                .get("delta")
                .and_then(|d| d.as_i64())
                .ok_or_else(|| "inject dial requires integer 'delta'".to_string())?;
            if !(-128..=127).contains(&delta) {
                return Err(format!("delta {delta} out of range (-128..=127)"));
            }
            Ok(vec![DeviceEvent::Dial {
                delta: delta as i8,
            }])
        }
        "joy" => {
            let gesture = value
                .get("gesture")
                .and_then(|g| g.as_str())
                .ok_or_else(|| "inject joy requires 'gesture'".to_string())?;
            let id = joy_id(gesture).ok_or_else(|| format!("unknown gesture: {gesture:?}"))?;
            Ok(vec![DeviceEvent::Joy { gesture: id }])
        }
        other => Err(format!(
            "unknown inject kind {other:?}; expected key|dial|joy"
        )),
    }
}

/// Options parsed from the CLI.
#[derive(Debug, Clone, Default)]
pub struct DaemonOpts {
    pub mock_device: bool,
}

/// State shared between the socket server and the device thread. The registry
/// is the source of truth for session/aggregate state (replayed to a device on
/// (re)connect).
pub struct Shared {
    pub registry: Registry,
    /// Provider-wide quota snapshots. These intentionally outlive sessions:
    /// subscription limits belong to the account, not to a numbered key.
    pub usage: HashMap<String, serde_json::Map<String, serde_json::Value>>,
    /// Per-state render styles (defaults + config/`set-style` overrides).
    pub styles: StyleTable,
    /// Whether a device is currently attached and responsive.
    pub device_present: bool,
}

/// Context shared by the device thread and the socket handlers, so injected and
/// real events take the same dispatch path and focus can consult the registry.
#[cfg(unix)]
#[derive(Clone)]
struct EventCtx {
    evt_tx: tokio::sync::broadcast::Sender<String>,
    config: Arc<Config>,
    shared: Arc<Mutex<Shared>>,
}

#[cfg(unix)]
impl EventCtx {
    fn broadcast(&self, line: &str) {
        // Err just means no subscribers; that's fine.
        let _ = self.evt_tx.send(line.to_string());
    }
}

/// JSON line for a `state` event (PROTOCOL.md §3): the aggregate state.
#[cfg(unix)]
fn state_event_line(state: State) -> String {
    event_line(Event::State { state: state.name().to_string() })
}

/// JSON line for a `session` event (registration or update). Carries
/// `label`/`meta` alongside kind/slot/state so subscribers (menu bar app,
/// desktop widget) see label and per-session stats update live instead of
/// only at the next `list-sessions` poll.
#[cfg(unix)]
#[allow(clippy::too_many_arguments)]
fn session_event_line(
    id: &str,
    kind: &Option<String>,
    label: &Option<String>,
    name: &Option<String>,
    meta: &serde_json::Map<String, serde_json::Value>,
    slot: Option<u8>,
    state: State,
) -> String {
    event_line(Event::Session {
        session: SessionDto {
            session: id.to_string(), kind: kind.clone(), label: label.clone(), name: name.clone(),
            slot, state: state.name().to_string(), meta: public_meta(meta), connected: None,
        },
    })
}

/// JSON line for a `session-ended` event.
#[cfg(unix)]
fn session_ended_line(id: &str, slot: Option<u8>) -> String {
    event_line(Event::SessionEnded { session: id.to_string(), slot })
}

/// JSON line for a `session-disconnected` event (PROTOCOL.md §3): a session
/// was reaped by a sweep rather than explicitly ended. Subscribers keep the
/// row but mark it disconnected (`connected: false`) rather than removing it
/// (as `session-ended` means) — it's still recoverable and shown until it's
/// explicitly ended, dismissed, recovered, or its tombstone TTL expires.
#[cfg(unix)]
fn session_disconnected_line(id: &str, slot: Option<u8>) -> String {
    event_line(Event::SessionDisconnected { session: id.to_string(), slot })
}

/// JSON line for a `session-rekeyed` event (PROTOCOL.md §3): a `Compacting`
/// session was reunited with its post-compaction continuation under a new
/// id. Subscribers should relabel their existing record for `old_session`
/// in place (preserving name/history/stats) rather than treat it as an end
/// followed by a new registration.
#[cfg(unix)]
fn session_rekeyed_line(old_id: &str, new_id: &str) -> String {
    event_line(Event::SessionRekeyed { old_session: old_id.to_string(), new_session: new_id.to_string() })
}

/// JSON line for a provider-wide quota snapshot.
#[cfg(unix)]
fn usage_event_line(
    provider: &str,
    usage: &serde_json::Map<String, serde_json::Value>,
) -> String {
    event_line(Event::Usage { provider: provider.to_string(), usage: usage.clone() })
}

/// JSON line for a `style` event (PROTOCOL.md §3).
#[cfg(unix)]
fn style_event_line(state: State, style: &Style) -> String {
    event_line(Event::Style { state: state.name().to_string(), rgb: style.rgb, pattern: style.pattern.name().to_string(), period_ms: style.period_ms })
}

/// JSON object of all six styles, keyed by state name in id order (for the
/// `get-styles` response).
#[cfg(unix)]
fn styles_json(table: &StyleTable) -> StyleMap {
    let mut styles = Vec::new();
    for (state, style) in table.iter() {
        styles.push((
            state.name().to_string(),
            StyleDto { rgb: style.rgb, pattern: style.pattern.name().to_string(), period_ms: style.period_ms },
        ));
    }
    StyleMap(styles)
}

/// The full set of device commands to (re)send on connect: all six styles,
/// the aggregate `SET_STATE`, then each occupied slot's `SET_KEY_STATE`.
#[cfg(unix)]
fn replay_state_cmds(shared: &Mutex<Shared>) -> Vec<HostCmd> {
    let s = shared.lock().unwrap();
    let mut cmds = Vec::new();
    for (state, style) in s.styles.iter() {
        cmds.push(style.to_host_cmd(state));
    }
    cmds.push(HostCmd::SetState(s.registry.aggregate()));
    for (key, state) in s.registry.slot_states() {
        cmds.push(HostCmd::SetKeyState {
            key,
            state: Some(state),
        });
    }
    cmds
}

/// Translate registry effects into device commands (`SET_KEY_STATE` /
/// `SET_STATE`) and subscriber events (PROTOCOL.md §3). Also persists a
/// fresh snapshot (Part 4) whenever any effect actually touched session
/// state — `AggregateChanged` alone (e.g. only the sessionless default
/// changed, which is deliberately never persisted) doesn't count.
#[cfg(unix)]
fn apply_effects(
    effects: Vec<Effect>,
    ctx: &EventCtx,
    host_tx: &tokio::sync::mpsc::UnboundedSender<HostCmd>,
) {
    let mut session_effect = false;
    for effect in effects {
        match effect {
            Effect::SessionUpsert {
                id,
                kind,
                label,
                name,
                meta,
                slot,
                state,
            } => {
                session_effect = true;
                if let Some(key) = slot {
                    let _ = host_tx.send(HostCmd::SetKeyState {
                        key,
                        state: Some(state),
                    });
                }
                ctx.broadcast(&session_event_line(
                    &id, &kind, &label, &name, &meta, slot, state,
                ));
            }
            Effect::SessionEnded { id, slot } => {
                session_effect = true;
                if let Some(key) = slot {
                    let _ = host_tx.send(HostCmd::SetKeyState { key, state: None });
                }
                ctx.broadcast(&session_ended_line(&id, slot));
            }
            Effect::SessionDisconnected { id, slot } => {
                // Frees the numbered-key slot on the device exactly like
                // `SessionEnded` (the slot is now available to a new
                // session), but subscribers keep the row as *disconnected*
                // rather than dropping it.
                session_effect = true;
                if let Some(key) = slot {
                    let _ = host_tx.send(HostCmd::SetKeyState { key, state: None });
                }
                ctx.broadcast(&session_disconnected_line(&id, slot));
            }
            Effect::SessionRekeyed { old_id, new_id } => {
                // No device command: the slot/state don't change here — the
                // SessionUpsert that immediately follows (Registry::set_state
                // always emits both together) carries those.
                session_effect = true;
                ctx.broadcast(&session_rekeyed_line(&old_id, &new_id));
            }
            Effect::AggregateChanged { state } => {
                let _ = host_tx.send(HostCmd::SetState(state));
                ctx.broadcast(&state_event_line(state));
            }
        }
    }
    if session_effect {
        save_snapshot(&ctx.shared);
    }
}

/// `Session` -> the JSON shape both `"list-sessions"` and the persisted
/// snapshot use (PROTOCOL.md §3) — one place so they can't drift apart.
#[cfg(unix)]
fn session_to_dto(s: &Session, connected: Option<bool>) -> SessionDto {
    let meta = public_meta(&s.meta);
    SessionDto {
        session: s.id.clone(), kind: s.kind.clone(), label: s.label.clone(), name: s.name.clone(),
        slot: s.slot, state: s.state.name().to_string(), meta, connected,
    }
}

fn public_meta(meta: &Map<String, Value>) -> Map<String, Value> {
    meta.iter()
        .filter(|(key, _)| !key.starts_with("_carry_"))
        .map(|(key, value)| (key.clone(), value.clone()))
        .collect()
}

#[cfg(unix)]
fn session_to_json(s: &Session) -> Value {
    serde_json::to_value(session_to_dto(s, None)).expect("session DTO must serialize")
}

/// The inverse of `session_to_json`, given the `Instant` to use for
/// `last_update`/`reaped_at` (reconstructed by the caller — see
/// `restore_instant`). `None` on any malformed/missing required field.
#[cfg(unix)]
fn session_from_json(v: &serde_json::Value, last_update: Instant) -> Option<Session> {
    let id = v.get("session")?.as_str()?.to_string();
    let state = crate::protocol::State::from_name(v.get("state")?.as_str()?)?;
    let mut meta = v.get("meta").and_then(|m| m.as_object()).cloned().unwrap_or_default();
    // Read snapshots written before carry-forward data was made internal, but
    // never expose those legacy keys again.
    let mut carry = v.get("carry").and_then(|c| c.as_object()).cloned().unwrap_or_default();
    for key in ["turns", "tool_calls", "subagents", "tokens_in", "tokens_out", "cost_usd"] {
        if let Some(value) = meta.remove(&format!("_carry_{key}")) {
            carry.entry(key.to_string()).or_insert(value);
        }
    }
    Some(Session {
        id,
        kind: v.get("kind").and_then(|x| x.as_str()).map(str::to_string),
        label: v.get("label").and_then(|x| x.as_str()).map(str::to_string),
        name: v.get("name").and_then(|x| x.as_str()).map(str::to_string),
        meta,
        carry,
        slot: v.get("slot").and_then(|x| x.as_u64()).map(|n| n as u8),
        state,
        last_update,
    })
}

/// Milliseconds since the Unix epoch, wall-clock — `0` on a clock that
/// somehow predates 1970 (never in practice), rather than panicking.
#[cfg(unix)]
fn unix_ms_now() -> u64 {
    std::time::SystemTime::now()
        .duration_since(std::time::UNIX_EPOCH)
        .map(|d| d.as_millis() as u64)
        .unwrap_or(0)
}

/// Reconstruct an `Instant` from a snapshot's elapsed-ms-since-`saved_at`
/// offset: `Instant::now() - (elapsed_ms + gap since the snapshot was
/// written)`. `Instant` is monotonic and meaningless across a process
/// restart, so this is the only way to carry `last_update`/`reaped_at`
/// forward accurately — without it, every TTL/COMPACT_GRACE/tombstone_ttl
/// clock would silently reset to "now" on every restart.
#[cfg(unix)]
fn restore_instant(saved_at_unix_ms: u64, elapsed_ms: u64) -> Instant {
    let gap_ms = unix_ms_now().saturating_sub(saved_at_unix_ms);
    let total = Duration::from_millis(elapsed_ms.saturating_add(gap_ms));
    Instant::now().checked_sub(total).unwrap_or_else(Instant::now)
}

/// Persist the full current session/tombstone/usage state (Part 4) —
/// called after any session-affecting `Effect` (`apply_effects`) and after
/// a successful `set-usage`. Best-effort: a write failure (disk full,
/// permissions) is silently swallowed, same tolerance every other
/// persistence path in this codebase already has for its own I/O.
#[cfg(unix)]
fn save_snapshot(shared: &Mutex<Shared>) {
    let now = Instant::now();
    let (sessions, tombstones, usage) = {
        let s = shared.lock().unwrap();
        let sessions: Vec<serde_json::Value> = s
            .registry
            .list()
            .iter()
            .map(|sess| {
                let mut v = session_to_json(sess);
                v["carry"] = serde_json::json!(sess.carry);
                v["elapsed_ms_since_update"] = serde_json::json!(
                    now.saturating_duration_since(sess.last_update).as_millis() as u64
                );
                v
            })
            .collect();
        let tombstones: Vec<serde_json::Value> = s
            .registry
            .tombstones_snapshot()
            .iter()
            .map(|(_, sess, reaped_at)| {
                let mut v = session_to_json(sess);
                v["carry"] = serde_json::json!(sess.carry);
                v["elapsed_ms_since_reaped"] = serde_json::json!(
                    now.saturating_duration_since(*reaped_at).as_millis() as u64
                );
                v
            })
            .collect();
        (sessions, tombstones, s.usage.clone())
    };
    let snapshot = serde_json::json!({
        "saved_at_unix_ms": unix_ms_now(),
        "sessions": sessions,
        "tombstones": tombstones,
        "usage": usage,
    });
    let path = crate::paths::daemon_state_path();
    if let Some(parent) = path.parent() {
        let _ = std::fs::create_dir_all(parent);
    }
    if let Ok(data) = serde_json::to_string(&snapshot) {
        let _ = std::fs::write(&path, data);
    }
}

/// Load a previously-persisted snapshot, reconstructing `Instant`s via
/// `restore_instant`. Missing, corrupt, or unreadable: silent no-op,
/// returning an empty registry/usage map — same tolerance `Config::load()`
/// already has for a missing `config.toml` (`CLAUDE.md`: graceful
/// degradation is load-bearing throughout this codebase, not optional).
#[cfg(unix)]
fn load_snapshot(
    ttl: Option<Duration>,
    tombstone_ttl: Option<Duration>,
) -> (
    Registry,
    HashMap<String, serde_json::Map<String, serde_json::Value>>,
) {
    let empty = || (Registry::new(ttl).with_tombstone_ttl(tombstone_ttl), HashMap::new());
    let Ok(data) = std::fs::read_to_string(crate::paths::daemon_state_path()) else {
        return empty();
    };
    let Ok(root) = serde_json::from_str::<serde_json::Value>(&data) else {
        return empty();
    };
    let saved_at_unix_ms = root
        .get("saved_at_unix_ms")
        .and_then(|v| v.as_u64())
        .unwrap_or(0);

    let sessions: Vec<Session> = root
        .get("sessions")
        .and_then(|v| v.as_array())
        .into_iter()
        .flatten()
        .filter_map(|v| {
            let elapsed = v
                .get("elapsed_ms_since_update")
                .and_then(|x| x.as_u64())
                .unwrap_or(0);
            session_from_json(v, restore_instant(saved_at_unix_ms, elapsed))
        })
        .collect();

    let tombstones: Vec<(String, Session, Instant)> = root
        .get("tombstones")
        .and_then(|v| v.as_array())
        .into_iter()
        .flatten()
        .filter_map(|v| {
            let elapsed = v
                .get("elapsed_ms_since_reaped")
                .and_then(|x| x.as_u64())
                .unwrap_or(0);
            let reaped_at = restore_instant(saved_at_unix_ms, elapsed);
            let sess = session_from_json(v, reaped_at)?;
            let id = sess.id.clone();
            Some((id, sess, reaped_at))
        })
        .collect();

    let usage: HashMap<String, serde_json::Map<String, serde_json::Value>> = root
        .get("usage")
        .and_then(|v| v.as_object())
        .into_iter()
        .flatten()
        .filter_map(|(k, v)| v.as_object().map(|m| (k.clone(), m.clone())))
        .collect();

    (
        Registry::restore(ttl, tombstone_ttl, sessions, tombstones),
        usage,
    )
}

/// One-shot startup reconciliation (Part 4): a restored session might have
/// actually died *while the daemon was down* — reuses the same tty/pid
/// liveness facts the periodic dead-tty/dead-process sweeps check (see
/// `run()` below), but runs once, synchronously, before the daemon answers
/// its first request or replays anything to a device. Routes through
/// `reap_session` (tombstoned, not hard-dropped) so a session that died
/// while the daemon was down is still recoverable via the pooled matcher —
/// consistent with every other non-explicit disappearance.
#[cfg(unix)]
fn reconcile_on_startup(shared: &Mutex<Shared>) {
    let now = Instant::now();
    let dead: Vec<String> = {
        let s = shared.lock().unwrap();
        s.registry
            .list()
            .into_iter()
            .filter(|sess| {
                let tty = sess.tty();
                let tty_dead = !tty.is_empty() && !std::path::Path::new(&tty).exists();
                let pid_dead = matches!(sess.pid(), Some(pid) if !process_is_alive(pid));
                tty_dead || pid_dead
            })
            .map(|sess| sess.id)
            .collect()
    };
    if dead.is_empty() {
        return;
    }
    let mut s = shared.lock().unwrap();
    for id in dead {
        s.registry.reap_session(&id, now);
    }
}

/// Run the focus action for `session` (PROTOCOL.md §3 Focus), exposing the
/// session via `FOCALPOINT_SESSION_*` env vars (empty string for missing values).
#[cfg(unix)]
fn run_focus(ctx: &EventCtx, session: &crate::session::Session, slot: u8) {
    let focus = ctx.config.session.focus.clone().unwrap_or(Action::None);
    let env = vec![
        ("FOCALPOINT_SESSION_ID", session.id.clone()),
        (
            "FOCALPOINT_SESSION_KIND",
            session.kind.clone().unwrap_or_default(),
        ),
        (
            "FOCALPOINT_SESSION_LABEL",
            session.label.clone().unwrap_or_default(),
        ),
        (
            "FOCALPOINT_SESSION_NAME",
            session.name.clone().unwrap_or_default(),
        ),
        ("FOCALPOINT_SESSION_DISPLAY", session.display_name()),
        ("FOCALPOINT_SESSION_CWD", session.cwd()),
        ("FOCALPOINT_SESSION_TTY", session.tty()),
        ("FOCALPOINT_SLOT", slot.to_string()),
    ];
    crate::actions::run_with_env(&focus, &env);
}

/// Translate a device event into a JSON event line, broadcast it to
/// subscribers, and run the configured action.
#[cfg(unix)]
fn handle_device_event(ev: DeviceEvent, ctx: &EventCtx) {
    match ev {
        DeviceEvent::Pong { major, minor, keys } => {
            eprintln!("[device] PONG protocol v{major}.{minor}, {keys} keys");
        }
        DeviceEvent::Key { control, pressed } => {
            let name = control_name(control);
            let line = event_line(Event::Key { control: name.clone(), pressed });
            ctx.broadcast(&line);
            // Fire the bound action on press (release is reported but not acted
            // on, to avoid double-firing).
            if pressed {
                // Numbered keys (control 4..=15 => slot 1..=12) with a live
                // session run the focus action instead of [actions] (§3 Focus);
                // empty slots fall back to their normal [actions] mapping.
                if (4..=15).contains(&control) {
                    let slot = control - 3;
                    let session = ctx
                        .shared
                        .lock()
                        .unwrap()
                        .registry
                        .session_by_slot(slot)
                        .cloned();
                    match session {
                        Some(session) => run_focus(ctx, &session, slot),
                        None => crate::actions::run(&ctx.config.action_for(&name)),
                    }
                } else {
                    crate::actions::run(&ctx.config.action_for(&name));
                }
            }
        }
        DeviceEvent::Dial { delta } => {
            let line = event_line(Event::Dial { delta });
            ctx.broadcast(&line);
            if ctx.config.dial.mode.as_deref() == Some("shell") {
                let cmd = if delta > 0 {
                    ctx.config.dial.cw.clone()
                } else if delta < 0 {
                    ctx.config.dial.ccw.clone()
                } else {
                    None
                };
                if let Some(run) = cmd {
                    crate::actions::run(&Action::Shell { run });
                }
            }
        }
        DeviceEvent::Joy { gesture } => {
            let name = joy_name(gesture);
            let line = event_line(Event::Joy { gesture: name.to_string() });
            ctx.broadcast(&line);
            crate::actions::run(&ctx.config.joystick_for(name));
        }
    }
}

// ---------------------------------------------------------------------------
// Real HID device thread
// ---------------------------------------------------------------------------

#[cfg(unix)]
fn run_hid_device(mut host_rx: tokio::sync::mpsc::UnboundedReceiver<HostCmd>, ctx: EventCtx) {
    use hidapi::HidApi;

    let mut api = match HidApi::new() {
        Ok(api) => api,
        Err(e) => {
            eprintln!("[device] failed to init hidapi: {e}; running without a device");
            // Keep draining host commands so the channel doesn't grow unbounded.
            while host_rx.blocking_recv().is_some() {}
            return;
        }
    };

    loop {
        let _ = api.refresh_devices();
        match open_device(&api) {
            Some(device) => {
                eprintln!("[device] connected");
                ctx.shared.lock().unwrap().device_present = true;

                // On connect: attach as host, then replay the full remembered
                // state — all six styles, the aggregate, and every occupied
                // slot.
                let _ = hid_write(&device, HostCmd::SetHostMode(true).encode());
                for cmd in replay_state_cmds(&ctx.shared) {
                    let _ = hid_write(&device, cmd.encode());
                }
                let _ = hid_write(&device, HostCmd::Ping.encode());

                let disconnected = device_io_loop(&device, &mut host_rx, &ctx);

                ctx.shared.lock().unwrap().device_present = false;
                if disconnected {
                    eprintln!("[device] disconnected; will retry");
                }
            }
            None => {
                ctx.shared.lock().unwrap().device_present = false;
                // Discard any queued commands (registry state is re-pushed on
                // reconnect) so the channel stays bounded.
                while host_rx.try_recv().is_ok() {}
                std::thread::sleep(std::time::Duration::from_millis(1000));
            }
        }
    }
}

/// Inner loop while a device is attached. Returns `true` on disconnect/error.
#[cfg(unix)]
fn device_io_loop(
    device: &hidapi::HidDevice,
    host_rx: &mut tokio::sync::mpsc::UnboundedReceiver<HostCmd>,
    ctx: &EventCtx,
) -> bool {
    let mut buf = [0u8; crate::protocol::REPORT_LEN];
    loop {
        // Flush any pending host->device commands.
        while let Ok(cmd) = host_rx.try_recv() {
            if hid_write(device, cmd.encode()).is_err() {
                return true;
            }
        }
        match device.read_timeout(&mut buf, 50) {
            Ok(0) => {} // timeout, no data
            Ok(_) => {
                if let Some(ev) = DeviceEvent::decode(&buf) {
                    handle_device_event(ev, ctx);
                }
            }
            Err(e) => {
                eprintln!("[device] read error: {e}");
                return true;
            }
        }
    }
}

/// Find and open the first matching device (PROTOCOL.md §2): usage page 0xFF60
/// / usage 0x61, preferring VID 0xFEED / PID 0x5642.
#[cfg(unix)]
fn open_device(api: &hidapi::HidApi) -> Option<hidapi::HidDevice> {
    use crate::protocol::{PID, USAGE, USAGE_PAGE, VID};

    let matching: Vec<_> = api
        .device_list()
        .filter(|d| d.usage_page() == USAGE_PAGE && d.usage() == USAGE)
        .collect();

    // Prefer the canonical VID/PID, then fall back to any usage-page match.
    let chosen = matching
        .iter()
        .find(|d| d.vendor_id() == VID && d.product_id() == PID)
        .or_else(|| matching.first())?;

    match chosen.open_device(api) {
        Ok(dev) => Some(dev),
        Err(e) => {
            eprintln!("[device] found matching device but failed to open: {e}");
            None
        }
    }
}

/// Write a 32-byte report, prepending the platform report-ID byte (0x00) that
/// hidapi expects for QMK Raw HID.
#[cfg(unix)]
fn hid_write(
    device: &hidapi::HidDevice,
    report: [u8; crate::protocol::REPORT_LEN],
) -> Result<(), ()> {
    let mut framed = [0u8; crate::protocol::REPORT_LEN + 1];
    framed[1..].copy_from_slice(&report);
    match device.write(&framed) {
        Ok(_) => Ok(()),
        Err(e) => {
            eprintln!("[device] write error: {e}");
            Err(())
        }
    }
}

// ---------------------------------------------------------------------------
// Mock device thread
// ---------------------------------------------------------------------------

#[cfg(unix)]
fn run_mock_device(host_rx: tokio::sync::mpsc::UnboundedReceiver<HostCmd>, ctx: EventCtx) {
    ctx.shared.lock().unwrap().device_present = true;
    eprintln!("[mock] virtual device attached. Inject events on stdin, e.g.:");
    eprintln!("[mock]   key accept 1     (control press)   key accept 0  (release)");
    eprintln!("[mock]   dial 2           (dial delta)      dial -1");
    eprintln!("[mock]   joy north        (joystick gesture: north|east|south|west|press)");

    // Emulate a device connect: replay the full remembered state (host mode,
    // all six styles, aggregate, and any occupied slots).
    log_host_cmd(&HostCmd::SetHostMode(true));
    for cmd in replay_state_cmds(&ctx.shared) {
        log_host_cmd(&cmd);
    }

    // Thread A: log host->device commands (LED changes).
    std::thread::spawn(move || {
        let mut host_rx = host_rx;
        while let Some(cmd) = host_rx.blocking_recv() {
            log_host_cmd(&cmd);
        }
    });

    // Thread B (this thread): read stdin and inject events.
    use std::io::BufRead;
    let stdin = std::io::stdin();
    for line in stdin.lock().lines() {
        let Ok(line) = line else { break };
        let line = line.trim();
        if line.is_empty() {
            continue;
        }
        match parse_mock_line(line) {
            Some(ev) => handle_device_event(ev, &ctx),
            None => eprintln!("[mock] unrecognized input: {line:?}"),
        }
    }
}

#[cfg(unix)]
fn log_host_cmd(cmd: &HostCmd) {
    match cmd {
        HostCmd::SetState(s) => {
            eprintln!("[mock] LED <- SET_STATE {} ({})", s.id(), s.name())
        }
        HostCmd::SetLed { index, r, g, b } => {
            let idx = if *index == 0xFF {
                "all".to_string()
            } else {
                index.to_string()
            };
            eprintln!("[mock] LED <- SET_LED index={idx} rgb=({r},{g},{b})")
        }
        HostCmd::SetHostMode(on) => eprintln!("[mock] SET_HOST_MODE {}", u8::from(*on)),
        HostCmd::SetKeyState { key, state } => match state {
            Some(s) => eprintln!(
                "[mock] LED <- SET_KEY_STATE key={key} state={} ({})",
                s.id(),
                s.name()
            ),
            None => eprintln!("[mock] LED <- SET_KEY_STATE key={key} EMPTY"),
        },
        HostCmd::SetStateStyle {
            state,
            rgb,
            pattern,
            period_ms,
        } => eprintln!(
            "[mock] LED <- SET_STATE_STYLE state={} ({}) rgb=({},{},{}) pattern={} period={}ms",
            state.id(),
            state.name(),
            rgb[0],
            rgb[1],
            rgb[2],
            pattern.name(),
            period_ms
        ),
        HostCmd::Ping => eprintln!("[mock] PING"),
    }
}

/// Parse a mock injection line into a device event.
#[cfg(unix)]
fn parse_mock_line(line: &str) -> Option<DeviceEvent> {
    use crate::protocol::{control_id, joy_id};
    let toks: Vec<&str> = line.split_whitespace().collect();
    match toks.as_slice() {
        ["key", name] => Some(DeviceEvent::Key {
            control: control_id(name)?,
            pressed: true,
        }),
        ["key", name, p] => Some(DeviceEvent::Key {
            control: control_id(name)?,
            pressed: matches!(*p, "1" | "press" | "down" | "true"),
        }),
        ["dial", d] => Some(DeviceEvent::Dial {
            delta: d.parse().ok()?,
        }),
        ["joy", g] => Some(DeviceEvent::Joy {
            gesture: joy_id(g)?,
        }),
        _ => None,
    }
}

// ---------------------------------------------------------------------------
// Socket server
// ---------------------------------------------------------------------------

#[cfg(unix)]
pub async fn run(opts: DaemonOpts) -> Result<(), String> {
    use tokio::net::UnixListener;

    let config = Arc::new(Config::load()?);
    let ttl = config.session.ttl();
    let tombstone_ttl = config.session.tombstone_ttl();
    // Restore sessions/tombstones/usage from the last run (Part 4) instead
    // of always starting fresh — a daemon restart shouldn't blank
    // `focalpoint sessions`/`focalpoint usage` until adapters naturally
    // re-report. Missing/corrupt snapshot: silently empty, same as before
    // this feature existed.
    let (registry, usage) = load_snapshot(ttl, tombstone_ttl);
    let shared = Arc::new(Mutex::new(Shared {
        registry,
        usage,
        styles: config.style_table(),
        device_present: false,
    }));
    // One-shot reconciliation against live OS facts, before anything else
    // can see the restored state: a session that actually died while the
    // daemon was down must not resurrect as a zombie, just become a
    // recoverable tombstone like any other non-explicit disappearance.
    reconcile_on_startup(&shared);
    let (evt_tx, _keep) = tokio::sync::broadcast::channel::<String>(256);
    let (host_tx, host_rx) = tokio::sync::mpsc::unbounded_channel::<HostCmd>();

    // Shared event/action context, used by both the device thread and the
    // socket handlers (so injected events take the same dispatch path).
    let ctx = EventCtx {
        evt_tx: evt_tx.clone(),
        config: config.clone(),
        shared: shared.clone(),
    };

    // Launch the device thread (real or mock).
    {
        let ctx = ctx.clone();
        if opts.mock_device {
            std::thread::spawn(move || run_mock_device(host_rx, ctx));
        } else {
            std::thread::spawn(move || run_hid_device(host_rx, ctx));
        }
    }

    // Periodic TTL sweep: expire idle sessions (no-op when ttl = never).
    if ttl.is_some() {
        let ctx = ctx.clone();
        let host_tx = host_tx.clone();
        tokio::spawn(async move {
            let mut tick = tokio::time::interval(std::time::Duration::from_secs(30));
            loop {
                tick.tick().await;
                let effects = { ctx.shared.lock().unwrap().registry.expire(Instant::now()) };
                if !effects.is_empty() {
                    apply_effects(effects, &ctx, &host_tx);
                }
            }
        });
    }

    // Periodic tombstone sweep: age out reaped-but-not-explicitly-ended
    // sessions' recoverable history past `tombstone_ttl_minutes` (no-op when
    // never-expire). A tombstone is now surfaced as a *disconnected* session
    // (`list-sessions` `connected: false`), so aging one out emits a
    // `SessionEnded` to remove that row — "auto-remove after TTL" — unlike
    // before, when a tombstone was invisible bookkeeping.
    if tombstone_ttl.is_some() {
        let ctx = ctx.clone();
        let host_tx = host_tx.clone();
        tokio::spawn(async move {
            let mut tick = tokio::time::interval(std::time::Duration::from_secs(30));
            loop {
                tick.tick().await;
                let effects = {
                    ctx.shared
                        .lock()
                        .unwrap()
                        .registry
                        .expire_tombstones(Instant::now())
                };
                if !effects.is_empty() {
                    apply_effects(effects, &ctx, &host_tx);
                }
            }
        });
    }

    // Periodic compacting-timeout sweep: end any session stuck in
    // `State::Compacting` (set by the Claude Code adapter's `PreCompact`
    // hook, session.rs COMPACT_GRACE) whose continuation never claimed the
    // slot — compaction cancelled, or the continuation genuinely never
    // appeared. Runs regardless of `session_ttl_minutes` (including "never
    // expire"): a stuck "compacting" indicator is actively misleading, not
    // just stale.
    {
        let ctx = ctx.clone();
        let host_tx = host_tx.clone();
        tokio::spawn(async move {
            let mut tick = tokio::time::interval(std::time::Duration::from_secs(30));
            loop {
                tick.tick().await;
                let effects = {
                    ctx.shared
                        .lock()
                        .unwrap()
                        .registry
                        .expire_compacting(Instant::now())
                };
                if !effects.is_empty() {
                    apply_effects(effects, &ctx, &host_tx);
                }
            }
        });
    }

    // Periodic dead-tty sweep: reap a session whose focus target was a real
    // terminal (Claude Code sets `--meta tty=$(tty)`) the moment that pty
    // device stops existing — closing the terminal destroys it, a hard OS
    // fact, unlike inferring death from a failed AppleScript window match
    // (which would misfire for any terminal app other than Terminal/iTerm,
    // or when the daemon lacks Accessibility access). Runs independent of
    // session_ttl_minutes/the TTL sweep above — sessions with no `tty` meta
    // (Codex, Cursor) are untouched by this and keep relying on TTL or their
    // own adapter-side end-session signal.
    {
        let ctx = ctx.clone();
        let host_tx = host_tx.clone();
        tokio::spawn(async move {
            let mut tick = tokio::time::interval(std::time::Duration::from_secs(30));
            loop {
                tick.tick().await;
                let dead: Vec<String> = {
                    let shared = ctx.shared.lock().unwrap();
                    shared
                        .registry
                        .list()
                        .into_iter()
                        .filter(|s| {
                            let tty = s.tty();
                            !tty.is_empty() && !std::path::Path::new(&tty).exists()
                        })
                        .map(|s| s.id)
                        .collect()
                };
                if dead.is_empty() {
                    continue;
                }
                let effects: Vec<Effect> = {
                    let mut shared = ctx.shared.lock().unwrap();
                    let now = Instant::now();
                    dead.iter()
                        .flat_map(|id| shared.registry.reap_session(id, now))
                        .collect()
                };
                apply_effects(effects, &ctx, &host_tx);
            }
        });
    }

    // Periodic dead-process sweep: reap a session whose own agent process
    // has verifiably exited (Claude Code sets `--meta pid=<pid>`, found by
    // walking the hook's process ancestry to the nearest `claude` process —
    // see adapters/claude-code/hooks.sh) via kill(pid, 0) — a hard OS fact,
    // same tier of confidence as the dead-tty sweep above, for the one
    // failure mode that sweep can't see: the agent crashes (OOM, segfault,
    // force-quit) but the terminal it ran in stays open, so its pty never
    // disappears. PID reuse by the OS after the real process exits is a
    // known, low-probability false-negative — the same class of risk the
    // tty sweep already accepts for pty reuse — not worth guarding against
    // at this scale. Sessions with no `pid` meta (Codex, Cursor, or a Claude
    // session where ancestry-walking failed) are untouched by this and keep
    // relying on the tty sweep, TTL, or their own end-session signal.
    {
        let ctx = ctx.clone();
        let host_tx = host_tx.clone();
        tokio::spawn(async move {
            let mut tick = tokio::time::interval(std::time::Duration::from_secs(30));
            loop {
                tick.tick().await;
                let dead: Vec<String> = {
                    let shared = ctx.shared.lock().unwrap();
                    shared
                        .registry
                        .list()
                        .into_iter()
                        .filter(|s| matches!(s.pid(), Some(pid) if !process_is_alive(pid)))
                        .map(|s| s.id)
                        .collect()
                };
                if dead.is_empty() {
                    continue;
                }
                let effects: Vec<Effect> = {
                    let mut shared = ctx.shared.lock().unwrap();
                    let now = Instant::now();
                    dead.iter()
                        .flat_map(|id| shared.registry.reap_session(id, now))
                        .collect()
                };
                apply_effects(effects, &ctx, &host_tx);
            }
        });
    }

    // Bind the socket.
    let path = crate::paths::socket_path();
    if let Some(parent) = path.parent() {
        std::fs::create_dir_all(parent)
            .map_err(|e| format!("failed to create {}: {e}", parent.display()))?;
    }
    // Remove a stale socket file if present.
    let _ = std::fs::remove_file(&path);
    let listener = UnixListener::bind(&path)
        .map_err(|e| format!("failed to bind {}: {e}", path.display()))?;
    eprintln!("[daemon] listening on {}", path.display());

    loop {
        match listener.accept().await {
            Ok((stream, _addr)) => {
                let shared = shared.clone();
                let ctx = ctx.clone();
                let host_tx = host_tx.clone();
                tokio::spawn(async move {
                    handle_client(stream, shared, ctx, host_tx).await;
                });
            }
            Err(e) => {
                eprintln!("[daemon] accept error: {e}");
            }
        }
    }
}

/// Outcome of dispatching one request line.
#[cfg(unix)]
enum Dispatch {
    Reply(Response),
    Subscribe,
}

#[cfg(unix)]
async fn handle_client(
    stream: tokio::net::UnixStream,
    shared: Arc<Mutex<Shared>>,
    ctx: EventCtx,
    host_tx: tokio::sync::mpsc::UnboundedSender<HostCmd>,
) {
    use tokio::io::{AsyncBufReadExt, AsyncWriteExt, BufReader};

    let (reader, mut writer) = stream.into_split();
    let mut lines = BufReader::new(reader).lines();

    loop {
        let line = match lines.next_line().await {
            Ok(Some(l)) => l,
            Ok(None) | Err(_) => return, // client closed
        };
        if line.trim().is_empty() {
            continue;
        }
        match dispatch(&line, &shared, &ctx, &host_tx) {
            Dispatch::Reply(value) => {
                let mut out = serde_json::to_string(&value).expect("response DTO must serialize");
                out.push('\n');
                if writer.write_all(out.as_bytes()).await.is_err() {
                    return;
                }
            }
            Dispatch::Subscribe => {
                // Subscribe to the stream first, then send the snapshot, so no
                // change can slip between the two. Snapshot = aggregate `state`
                // event, one `session` event per live session, then one `style`
                // event per state (all six) (§3).
                let mut rx = ctx.evt_tx.subscribe();
                let (aggregate, sessions, usage, styles) = {
                    let s = shared.lock().unwrap();
                    (
                        s.registry.aggregate(),
                        s.registry.list(),
                        s.usage.clone(),
                        s.styles,
                    )
                };
                let mut snapshot = state_event_line(aggregate);
                for sess in &sessions {
                    snapshot.push('\n');
                    snapshot.push_str(&session_event_line(
                        &sess.id,
                        &sess.kind,
                        &sess.label,
                        &sess.name,
                        &sess.meta,
                        sess.slot,
                        sess.state,
                    ));
                }
                for (provider, usage_snapshot) in usage {
                    snapshot.push('\n');
                    snapshot.push_str(&usage_event_line(&provider, &usage_snapshot));
                }
                for (state, style) in styles.iter() {
                    snapshot.push('\n');
                    snapshot.push_str(&style_event_line(state, &style));
                }
                snapshot.push('\n');
                if writer.write_all(snapshot.as_bytes()).await.is_err() {
                    return;
                }
                loop {
                    match rx.recv().await {
                        Ok(mut event_line) => {
                            event_line.push('\n');
                            if writer.write_all(event_line.as_bytes()).await.is_err() {
                                return;
                            }
                        }
                        Err(tokio::sync::broadcast::error::RecvError::Lagged(_)) => continue,
                        Err(tokio::sync::broadcast::error::RecvError::Closed) => return,
                    }
                }
            }
        }
    }
}

#[cfg(unix)]
fn dispatch(
    line: &str,
    shared: &Arc<Mutex<Shared>>,
    ctx: &EventCtx,
    host_tx: &tokio::sync::mpsc::UnboundedSender<HostCmd>,
) -> Dispatch {
    let request: Request = match serde_json::from_str(line) {
        Ok(request) => request,
        Err(e) => return err(&format!("invalid request: {e}")),
    };
    match request {
        Request::SetState { state: name, session, kind, label, meta } => {
            let state = match State::from_name(&name) {
                Some(s) => s,
                None => return err(&format!("unknown state: {name:?}")),
            };
            let effects = shared.lock().unwrap().registry.set_state(
                session.as_deref(),
                state,
                kind,
                label,
                meta,
                Instant::now(),
            );
            apply_effects(effects, ctx, host_tx);
            ok()
        }
        Request::SetMeta { session, kind, label, meta } => {
            // Unknown sessions are a silent no-op (never registers one) —
            // see `Registry::merge_meta`.
            let effects = shared
                .lock()
                .unwrap()
                .registry
                .merge_meta(&session, kind, label, meta, Instant::now());
            apply_effects(effects, ctx, host_tx);
            ok()
        }
        Request::ListSessions => {
            // Live sessions first (marked `connected: true`), then any
            // tombstoned ones as `connected: false` (PROTOCOL.md §3) — a
            // sweep-reaped session stays visible/disconnected here until it's
            // explicitly ended, dismissed, recovered, or its tombstone TTL
            // expires. A fresh subscriber gets the full picture (live +
            // disconnected) from this one poll; live `session-disconnected`
            // events keep an already-connected subscriber in sync.
            let (sessions, tombstones) = {
                let s = shared.lock().unwrap();
                (s.registry.list(), s.registry.tombstones_snapshot())
            };
            let mut arr: Vec<SessionDto> = sessions.iter().map(|s| session_to_dto(s, Some(true))).collect();
            for (_id, sess, _reaped_at) in &tombstones {
                arr.push(session_to_dto(sess, Some(false)));
            }
            Dispatch::Reply(Response::Sessions { ok: true, sessions: arr })
        }
        Request::SetUsage { provider, usage } => {
            let snapshot = {
                let mut s = shared.lock().unwrap();
                match merge_usage(&mut s.usage, &provider, &usage) {
                    Ok(snapshot) => snapshot,
                    Err(message) => return err(&message),
                }
            };
            ctx.broadcast(&usage_event_line(&provider, &snapshot));
            save_snapshot(shared);
            ok()
        }
        Request::GetUsage => {
            let usage = shared.lock().unwrap().usage.clone();
            Dispatch::Reply(Response::Usage { ok: true, usage })
        }
        Request::RenameSession { session: id, name } => {
            // A missing/null `name`, or an empty one, clears the rename so
            // the session falls back to the adapter's label.
            let effects = shared.lock().unwrap().registry.rename(&id, name.as_deref());
            let Some(effects) = effects else {
                return err(&format!("unknown session: {id}"));
            };
            apply_effects(effects, ctx, host_tx);
            ok()
        }
        Request::SwapSlots { session1: id1, session2: id2 } => {
            let result = shared.lock().unwrap().registry.swap_slots(&id1, &id2);
            match result {
                Ok(effects) => {
                    apply_effects(effects, ctx, host_tx);
                    ok()
                }
                Err(message) => err(&message),
            }
        }
        Request::EndSession { session: id } => {
            let effects = shared.lock().unwrap().registry.end_session(&id);
            apply_effects(effects, ctx, host_tx);
            ok()
        }
        Request::QuitSession { session: id } => {
            // Destructively end a session: ask the actual agent process to
            // exit gracefully (SIGINT→SIGTERM, so its own SessionEnd teardown
            // runs), then guarantee the session is removed even if that hook
            // never lands (no hooks installed, a wedged process, or a
            // pid-less/disconnected session we can't signal). Distinct from
            // `end-session`, which only removes the row and leaves the agent
            // running. When we can signal, the removal rides the agent's real
            // SessionEnd hook; the thread's own end_session is the idempotent
            // safety net after the process is gone (or the grace elapses).
            let pid = shared
                .lock()
                .unwrap()
                .registry
                .session_or_tombstone(&id)
                .and_then(|s| s.pid());
            match pid {
                Some(pid) => {
                    let ctx = ctx.clone();
                    let host_tx = host_tx.clone();
                    let id = id.clone();
                    std::thread::spawn(move || {
                        quit_agent_process(pid);
                        let effects = ctx.shared.lock().unwrap().registry.end_session(&id);
                        apply_effects(effects, &ctx, &host_tx);
                    });
                }
                None => {
                    // Nothing to signal (no resolved pid) — just remove it,
                    // same as end-session.
                    let effects = shared.lock().unwrap().registry.end_session(&id);
                    apply_effects(effects, ctx, host_tx);
                }
            }
            ok()
        }
        Request::FocusSession { session: id } => {
            // Run the [session] focus action for a session looked up by id —
            // including a disconnected (tombstoned) one, whose terminal is
            // usually still open (idle past the TTL, or an agent crash that
            // left the window). Unlike pressing a numbered key (which resolves
            // by slot on the device), this can't go through the slot: a
            // tombstone holds no live slot, and a disconnected session's old
            // slot may have been reclaimed. Runs on a detached thread so the
            // focus script's osascript (with its own hard timeouts) never
            // blocks the socket dispatch.
            let session = shared.lock().unwrap().registry.session_or_tombstone(&id);
            match session {
                Some(sess) => {
                    let ctx = ctx.clone();
                    let slot = sess.slot.unwrap_or(0);
                    std::thread::spawn(move || run_focus(&ctx, &sess, slot));
                    ok()
                }
                None => err(&format!("unknown session: {id}")),
            }
        }
        Request::Inject { kind, control, action, delta, gesture } => match parse_inject_fields(
            &kind, control.as_deref(), action.as_deref(), delta, gesture.as_deref(),
        ) {
            Ok(events) => {
                // Feed through the exact same dispatch path as real hardware
                // input: actions fire and subscribers see the event.
                for ev in events {
                    handle_device_event(ev, ctx);
                }
                ok()
            }
            Err(e) => err(&e),
        },
        Request::GetState => {
            let state = shared.lock().unwrap().registry.aggregate();
            Dispatch::Reply(Response::State { ok: true, state: state.name().to_string() })
        }
        Request::SetLed { index, rgb } => {
            let index = match u8::try_from(index) {
                Ok(index) => index,
                Err(_) => return err("set-led requires integer 'index' in 0..=255 (255 = all)"),
            };
            let c = match parse_rgb_values(&rgb) { Ok(rgb) => rgb, Err(message) => return err(&message) };
            let _ = host_tx.send(HostCmd::SetLed {
                index,
                r: c[0],
                g: c[1],
                b: c[2],
            });
            ok()
        }
        Request::GetStyles => {
            let styles = shared.lock().unwrap().styles;
            Dispatch::Reply(Response::Styles { ok: true, styles: styles_json(&styles) })
        }
        Request::SetStyle { state: state_name, rgb, pattern, period_ms } => {
            let (state, style) = match parse_set_style_fields(&state_name, &rgb, &pattern, period_ms) {
                Ok(pair) => pair,
                Err(e) => return err(&e),
            };
            // Persist first: if the config write fails, don't mutate runtime
            // (keeps runtime and on-disk config consistent).
            let path = match Config::path() {
                Some(p) => p,
                None => return err("cannot resolve config path for persistence"),
            };
            if let Err(e) = Config::write_style(&path, state, style) {
                return err(&format!("failed to persist style: {e}"));
            }
            shared.lock().unwrap().styles.set(state, style);
            let _ = host_tx.send(style.to_host_cmd(state));
            ctx.broadcast(&style_event_line(state, &style));
            ok()
        }
        Request::Subscribe => Dispatch::Subscribe,
        Request::Ping => {
            let present = shared.lock().unwrap().device_present;
            Dispatch::Reply(Response::Ping { ok: true, device: present })
        }
    }
}

#[cfg(unix)]
fn err(msg: &str) -> Dispatch {
    Dispatch::Reply(Response::Error { ok: false, error: msg.to_string() })
}

#[cfg(unix)]
fn ok() -> Dispatch {
    Dispatch::Reply(Response::Ok { ok: true })
}

// ---------------------------------------------------------------------------
// Non-unix stub
// ---------------------------------------------------------------------------

#[cfg(not(unix))]
pub async fn run(_opts: DaemonOpts) -> Result<(), String> {
    Err("Windows named pipe (\\\\.\\pipe\\focalpoint) is not yet implemented; \
         FocalPoint currently supports macOS and Linux."
        .to_string())
}

#[cfg(test)]
mod tests {
    use super::*;
    use serde_json::json;

    #[test]
    fn process_is_alive_matches_reality() {
        assert!(process_is_alive(std::process::id() as i32));
        // Not a real pid on any sane system (max_pid ceilings are far below
        // this on macOS/Linux) — exercises the ESRCH -> false path.
        assert!(!process_is_alive(999_999_999));
    }

    #[test]
    fn session_to_json_and_back_round_trips() {
        let mut meta = serde_json::Map::new();
        meta.insert("turns".into(), json!(7));
        meta.insert("tty".into(), json!("/dev/ttys004"));
        let original = Session {
            id: "abc".into(),
            kind: Some("claude".into()),
            label: Some("My Chat".into()),
            name: Some("Renamed".into()),
            meta,
            carry: serde_json::Map::new(),
            slot: Some(3),
            state: State::Thinking,
            last_update: Instant::now(),
        };
        let v = session_to_json(&original);
        let restored = session_from_json(&v, original.last_update).expect("parses");
        assert_eq!(restored.id, original.id);
        assert_eq!(restored.kind, original.kind);
        assert_eq!(restored.label, original.label);
        assert_eq!(restored.name, original.name);
        assert_eq!(restored.slot, original.slot);
        assert_eq!(restored.state, original.state);
        assert_eq!(restored.meta, original.meta);
    }

    #[test]
    fn request_dto_decodes_protocol_commands() {
        let request: Request = serde_json::from_value(json!({
            "cmd": "set-state", "state": "running", "session": "s1",
            "kind": "claude", "meta": {"cwd": "/repo"}
        })).expect("typed request decodes");
        assert!(matches!(request, Request::SetState { state, session: Some(session), .. }
            if state == "running" && session == "s1"));

        let request: Request = serde_json::from_value(json!({
            "cmd": "inject", "kind": "dial", "delta": -1
        })).expect("typed inject decodes");
        assert!(matches!(request, Request::Inject { kind, delta: Some(-1), .. } if kind == "dial"));
    }

    #[test]
    fn dto_session_payload_never_exposes_carry_bookkeeping() {
        let session = Session {
            id: "s1".into(), kind: Some("claude".into()), label: None, name: None,
            meta: Map::from_iter([("turns".into(), json!(8)), ("_carry_turns".into(), json!(5))]),
            carry: Map::from_iter([("turns".into(), json!(5))]),
            slot: Some(1), state: State::Running, last_update: Instant::now(),
        };
        let payload = session_to_json(&session);
        assert!(payload["meta"].get("_carry_turns").is_none());
        assert!(payload.get("carry").is_none());
        let event = session_event_line(&session.id, &session.kind, &session.label, &session.name,
            &session.meta, session.slot, session.state);
        assert!(!event.contains("_carry_"));
    }

    #[test]
    fn session_from_json_rejects_malformed_input() {
        assert!(session_from_json(&json!({"kind": "claude"}), Instant::now()).is_none());
        assert!(session_from_json(
            &json!({"session": "x", "state": "not-a-real-state"}),
            Instant::now()
        )
        .is_none());
    }

    #[test]
    fn restore_instant_accounts_for_elapsed_and_gap_since_saved() {
        let saved_at = unix_ms_now();
        // A session that was already 5s idle at the moment the snapshot was
        // written must still be at least ~5s "old" once reconstructed —
        // this is what keeps TTL/COMPACT_GRACE/tombstone_ttl clocks correct
        // immediately after a restart instead of resetting to "just now".
        let restored = restore_instant(saved_at, 5_000);
        let age = Instant::now().saturating_duration_since(restored);
        assert!(
            age.as_millis() >= 5_000,
            "reconstructed instant should be at least the elapsed offset old, got {age:?}"
        );
    }

    #[test]
    fn inject_key_tap_expands_to_press_then_release() {
        let events = parse_inject(&json!({
            "cmd": "inject", "kind": "key", "control": "accept", "action": "tap"
        }))
        .expect("parse");
        assert_eq!(
            events,
            vec![
                DeviceEvent::Key { control: 0, pressed: true },
                DeviceEvent::Key { control: 0, pressed: false },
            ]
        );
    }

    #[test]
    fn inject_key_press_and_release() {
        let press = parse_inject(&json!({"kind":"key","control":"reject","action":"press"})).unwrap();
        assert_eq!(press, vec![DeviceEvent::Key { control: 1, pressed: true }]);
        let release =
            parse_inject(&json!({"kind":"key","control":"reject","action":"release"})).unwrap();
        assert_eq!(release, vec![DeviceEvent::Key { control: 1, pressed: false }]);
    }

    #[test]
    fn inject_key_defaults_to_tap_when_action_missing() {
        let events = parse_inject(&json!({"kind":"key","control":"key1"})).unwrap();
        assert_eq!(events.len(), 2);
        assert_eq!(events[0], DeviceEvent::Key { control: 4, pressed: true });
    }

    #[test]
    fn inject_dial_and_joy() {
        assert_eq!(
            parse_inject(&json!({"kind":"dial","delta":1})).unwrap(),
            vec![DeviceEvent::Dial { delta: 1 }]
        );
        assert_eq!(
            parse_inject(&json!({"kind":"dial","delta":-3})).unwrap(),
            vec![DeviceEvent::Dial { delta: -3 }]
        );
        assert_eq!(
            parse_inject(&json!({"kind":"joy","gesture":"north"})).unwrap(),
            vec![DeviceEvent::Joy { gesture: 0 }]
        );
    }

    #[test]
    fn inject_rejects_bad_input() {
        assert!(parse_inject(&json!({"kind":"key","control":"nope","action":"tap"})).is_err());
        assert!(parse_inject(&json!({"kind":"key","control":"accept","action":"hold"})).is_err());
        assert!(parse_inject(&json!({"kind":"dial","delta":9999})).is_err());
        assert!(parse_inject(&json!({"kind":"joy","gesture":"nowhere"})).is_err());
        assert!(parse_inject(&json!({"kind":"bogus"})).is_err());
        assert!(parse_inject(&json!({})).is_err());
        assert!(parse_inject(&json!({"kind":"key"})).is_err()); // missing control
        assert!(parse_inject(&json!({"kind":"dial"})).is_err()); // missing delta
    }

    #[cfg(unix)]
    #[test]
    fn state_event_line_matches_protocol() {
        assert_eq!(
            state_event_line(State::Thinking),
            r#"{"event":"state","state":"thinking"}"#
        );
    }

    #[cfg(unix)]
    #[test]
    fn usage_event_line_matches_protocol() {
        let usage = serde_json::Map::from_iter([
            ("five_hour_used".into(), json!(42.5)),
            ("five_hour_resets_at".into(), json!(1_738_425_600)),
        ]);
        assert_eq!(
            usage_event_line("claude", &usage),
            // Insertion order, not alphabetical: serde_json's preserve_order
            // feature is on so emitted events match the key order in
            // PROTOCOL.md §3.
            r#"{"event":"usage","provider":"claude","usage":{"five_hour_used":42.5,"five_hour_resets_at":1738425600}}"#
        );
    }

    #[test]
    fn usage_snapshots_merge_and_reject_invalid_values() {
        let mut snapshots = std::collections::HashMap::new();
        let first = serde_json::Map::from_iter([
            ("five_hour_used".into(), json!(42.5)),
            ("five_hour_resets_at".into(), json!(1_738_425_600)),
        ]);
        merge_usage(&mut snapshots, "claude", &first).expect("first snapshot");

        let second = serde_json::Map::from_iter([("seven_day_used".into(), json!(18))]);
        let merged = merge_usage(&mut snapshots, "claude", &second).expect("merged snapshot");
        assert_eq!(merged.get("five_hour_used"), Some(&json!(42.5)));
        assert_eq!(merged.get("seven_day_used"), Some(&json!(18)));

        let invalid = serde_json::Map::from_iter([("label".into(), json!("not numeric"))]);
        assert!(merge_usage(&mut snapshots, "claude", &invalid).is_err());
        assert!(merge_usage(&mut snapshots, "", &second).is_err());
    }

    #[test]
    fn set_style_parses_full_request() {
        let (state, style) = parse_set_style(&json!({
            "cmd": "set-style", "state": "waiting",
            "rgb": [30, 144, 255], "pattern": "blink", "period_ms": 800
        }))
        .expect("parse");
        assert_eq!(state, State::Waiting);
        assert_eq!(style.rgb, [30, 144, 255]);
        assert_eq!(style.pattern, Pattern::Blink);
        assert_eq!(style.period_ms, 800);
    }

    #[test]
    fn set_style_clamps_period() {
        let (_, lo) =
            parse_set_style(&json!({"state":"idle","rgb":[0,0,0],"pattern":"off","period_ms":1}))
                .unwrap();
        assert_eq!(lo.period_ms, crate::styles::PERIOD_MIN);
        // 9000 fits u16 but exceeds PERIOD_MAX -> clamps to 5000.
        let (_, hi) =
            parse_set_style(&json!({"state":"idle","rgb":[0,0,0],"pattern":"off","period_ms":9000}))
                .unwrap();
        assert_eq!(hi.period_ms, crate::styles::PERIOD_MAX);
        // Above u16 range is rejected (can't be represented on the wire).
        assert!(parse_set_style(
            &json!({"state":"idle","rgb":[0,0,0],"pattern":"off","period_ms":99999})
        )
        .is_err());
    }

    #[test]
    fn set_style_missing_period_uses_state_default() {
        let (_, style) =
            parse_set_style(&json!({"state":"running","rgb":[1,2,3],"pattern":"solid"})).unwrap();
        assert_eq!(
            style.period_ms,
            crate::styles::default_style(State::Running).period_ms
        );
    }

    #[test]
    fn set_style_rejects_bad_input() {
        // bad pattern
        assert!(parse_set_style(
            &json!({"state":"waiting","rgb":[0,0,0],"pattern":"sparkle"})
        )
        .is_err());
        // bad state
        assert!(parse_set_style(&json!({"state":"nope","rgb":[0,0,0],"pattern":"solid"})).is_err());
        // rgb wrong length
        assert!(parse_set_style(&json!({"state":"idle","rgb":[0,0],"pattern":"solid"})).is_err());
        // rgb out of range
        assert!(parse_set_style(&json!({"state":"idle","rgb":[0,0,300],"pattern":"solid"})).is_err());
        // missing fields
        assert!(parse_set_style(&json!({"state":"idle"})).is_err());
        assert!(parse_set_style(&json!({"rgb":[0,0,0],"pattern":"solid"})).is_err());
    }
}
