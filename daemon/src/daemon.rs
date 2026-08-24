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

use crate::channel::{valid_kind, Channels, BODY_MAX_CHARS};
use crate::config::{Action, Config};
use crate::protocol::{
    control_id, control_name, joy_id, joy_name, DeviceEvent, HostCmd, Pattern, State,
};
use crate::session::{Attachment, Effect, Registry, Session, SessionHealth, TerminalEndpoint};
use crate::styles::{Style, StyleTable};
use serde::{Deserialize, Serialize};
use serde_json::{json, Map, Value};
use std::collections::HashMap;
use std::fs::OpenOptions;
use std::io::Write;
use std::path::{Path, PathBuf};
use std::process::Command;
use std::sync::atomic::{AtomicU64, Ordering};
use std::sync::{Arc, Mutex};
use std::time::{Duration, Instant, SystemTime, UNIX_EPOCH};

const WORKFLOW_ASSIGNMENT_MAX: usize = 128;
const WORKFLOW_FANOUT_MAX: u16 = 64;

#[derive(Debug, Clone, Deserialize, Serialize, PartialEq, Eq)]
#[serde(deny_unknown_fields)]
pub struct WorkflowAssignmentAuthorization {
    assignment_id: String,
    phase: String,
    agent_type: String,
    provider: String,
    model: String,
    gate: String,
    fanout: bool,
    fanout_limit: u16,
}

/// Socket requests defined by PROTOCOL.md §3 and the daemon-side CLI
/// extensions in §4.  Keep this as the single Rust representation of the
/// wire contract; dispatch only operates on this decoded form.
#[derive(Debug, Deserialize)]
#[serde(tag = "cmd", rename_all = "kebab-case")]
pub enum Request {
    SetState {
        state: String,
        session: Option<String>,
        kind: Option<String>,
        label: Option<String>,
        meta: Option<Map<String, Value>>,
    },
    SetMeta {
        session: String,
        kind: Option<String>,
        label: Option<String>,
        #[serde(default)]
        meta: Map<String, Value>,
    },
    GetState,
    ListSessions,
    RenameSession {
        session: String,
        name: Option<String>,
    },
    SetSessionBacklogged {
        session: String,
        backlogged: bool,
    },
    SwapSlots {
        session1: String,
        session2: String,
    },
    MoveSlot {
        session: String,
        slot: u64,
    },
    EndSession {
        session: String,
    },
    QuitSession {
        session: String,
    },
    /// Confirmation-bearing replacement for destructive managed stops.
    /// The legacy ownership-gated verb remains accepted for older clients.
    StopManagedSession {
        session: String,
        task_id: String,
        confirmation: String,
    },
    StopOrchestratedSession {
        session: String,
        task_id: String,
    },
    ReadSessionTranscript {
        session: String,
        task_id: String,
        tail: Option<u64>,
        search: Option<String>,
    },
    FocusSession {
        session: String,
    },
    SetLed {
        index: u64,
        rgb: Vec<u64>,
    },
    GetStyles,
    SetStyle {
        state: String,
        rgb: Vec<u64>,
        pattern: String,
        period_ms: Option<u64>,
    },
    SetUsage {
        provider: String,
        usage: Map<String, Value>,
    },
    GetUsage,
    Subscribe,
    Inject {
        kind: String,
        control: Option<String>,
        action: Option<String>,
        delta: Option<i64>,
        gesture: Option<String>,
    },
    ChannelCreate {
        task_id: String,
    },
    ChannelMembers {
        task_id: String,
        channel: String,
    },
    ChannelClose {
        task_id: String,
        channel: String,
    },
    ChannelRead {
        task_id: String,
        channel: String,
        since: Option<u64>,
        tail: Option<u64>,
        ack: Option<bool>,
    },
    ChannelAck {
        task_id: String,
        channel: String,
        through: u64,
    },
    ChannelPost {
        task_id: String,
        channel: String,
        body: String,
        kind: Option<String>,
        to: Option<String>,
    },
    RelaunchManagedSession {
        session: String,
    },
    GetAttentionOrder,
    SetAttentionOrder {
        sessions: Vec<String>,
    },
    FocusNextAttention,
    FocusPrevAttention,
    LaunchSession {
        provider: String,
        cwd: String,
        model: Option<String>,
        agent_type: Option<String>,
        cursor_mode: Option<String>,
        task: String,
        task_id: String,
        title: Option<String>,
        role: Option<String>,
        manager_task_id: Option<String>,
        channel_id: Option<String>,
        workflow_id: Option<String>,
        workflow_run_id: Option<String>,
        workflow_phase: Option<String>,
        workflow_gate: Option<String>,
        workflow_fanout: Option<bool>,
        workflow_assignment: Option<String>,
        workflow_assignments: Option<Vec<WorkflowAssignmentAuthorization>>,
        transition_confirmation: Option<String>,
    },
    ApproveWorkflowTransition {
        workflow_run_id: String,
        workflow_phase: String,
    },
    ResumeSession {
        provider: String,
        cwd: String,
        session: String,
        title: Option<String>,
    },
    Ping,
    GetCapabilities,
    GetDiagnostics,
    ListWorkflowRuns,
}

#[derive(Debug, Serialize)]
pub struct SessionDto {
    session: String,
    kind: Option<String>,
    label: Option<String>,
    name: Option<String>,
    slot: Option<u8>,
    state: String,
    backlogged: bool,
    meta: Map<String, Value>,
    #[serde(skip_serializing_if = "Option::is_none")]
    connected: Option<bool>,
    health: String,
    #[serde(skip_serializing_if = "Option::is_none")]
    health_reason: Option<String>,
    #[serde(skip_serializing_if = "Option::is_none")]
    attachment_id: Option<String>,
    #[serde(skip_serializing_if = "Option::is_none")]
    attachment_type: Option<String>,
    last_activity_unix_ms: u64,
    #[serde(skip_serializing_if = "Option::is_none")]
    last_verified_unix_ms: Option<u64>,
    #[serde(skip_serializing_if = "Option::is_none")]
    terminal_host: Option<TerminalHostDto>,
}

#[derive(Debug, Clone, Serialize)]
pub struct TerminalHostDto {
    bundle_id: Option<String>,
    application_pid: Option<i32>,
    window_id: Option<String>,
    session_id: Option<String>,
    host_tty: Option<String>,
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
    where
        S: serde::Serializer,
    {
        use serde::ser::SerializeMap;
        let mut map = serializer.serialize_map(Some(self.0.len()))?;
        for (name, style) in &self.0 {
            map.serialize_entry(name, style)?;
        }
        map.end()
    }
}

/// All subscriber event shapes (PROTOCOL.md §3).
///
/// Newer, less-standardized broadcast shapes (`managed-relaunch`,
/// `attention-order`, `channel-notify`) are still built ad hoc via
/// `serde_json::json!` right where they're emitted rather than added here —
/// only the original, well-established event set has been ported to this
/// typed form so far.
#[derive(Debug, Serialize)]
#[serde(tag = "event", rename_all = "kebab-case")]
pub enum Event {
    SnapshotBegin {
        generation: u64,
    },
    SnapshotEnd {
        generation: u64,
    },
    State {
        state: String,
    },
    Session {
        #[serde(flatten)]
        session: SessionDto,
    },
    SessionEnded {
        session: String,
        slot: Option<u8>,
    },
    SessionDisconnected {
        session: String,
        slot: Option<u8>,
    },
    SessionHealthChanged {
        session: String,
        health: String,
        reason: Option<String>,
    },
    SessionRekeyed {
        old_session: String,
        new_session: String,
    },
    /// A controller selected this session for the configured focus action.
    /// This is presentation state for clients; the daemon never treats it as
    /// durable session metadata.
    Focus {
        session: String,
    },
    FocusResult {
        session: String,
        slot: Option<u8>,
        attachment_id: Option<String>,
        strategy: String,
        result: String,
        terminal_pid: Option<i32>,
        terminal_session_id: Option<String>,
        reason: Option<String>,
    },
    Key {
        control: String,
        pressed: bool,
    },
    Dial {
        delta: i8,
    },
    Joy {
        gesture: String,
    },
    Usage {
        provider: String,
        usage: Map<String, Value>,
    },
    Style {
        state: String,
        rgb: [u8; 3],
        pattern: String,
        period_ms: u16,
    },
}

/// All one-line non-stream responses.
///
/// `Json` is an escape hatch for newer, less-standardized reply shapes
/// (channel ops, managed-relaunch, attention order, launch-session) that
/// haven't been given dedicated DTOs yet — they're built with
/// `serde_json::json!` at the call site and wrapped here so dispatch can stay
/// on one `Response` return type.
#[derive(Debug, Serialize)]
#[serde(untagged)]
pub enum Response {
    Ok {
        ok: bool,
    },
    State {
        ok: bool,
        state: String,
    },
    Sessions {
        ok: bool,
        sessions: Vec<SessionDto>,
    },
    Usage {
        ok: bool,
        usage: HashMap<String, Map<String, Value>>,
    },
    Styles {
        ok: bool,
        styles: StyleMap,
    },
    Ping {
        ok: bool,
        device: bool,
    },
    Json(Value),
    Error {
        ok: bool,
        error: String,
    },
}

fn event_line(event: Event) -> String {
    serde_json::to_string(&event).expect("event DTO must serialize")
}

/// True if a process with this pid is still capable of doing work. `kill(pid,
/// 0)` alone is insufficient here: a terminated process can remain in the
/// process table as a zombie until its parent reaps it, and `kill(pid, 0)`
/// reports that zombie as present. A zombie is exited for session lifecycle
/// and managed-relaunch purposes.
fn process_is_alive(pid: i32) -> bool {
    if unsafe { libc::kill(pid as libc::pid_t, 0) } != 0 {
        return std::io::Error::last_os_error().raw_os_error() != Some(libc::ESRCH);
    }

    let sys_pid = sysinfo::Pid::from_u32(pid as u32);
    let mut system = sysinfo::System::new();
    system.refresh_processes(sysinfo::ProcessesToUpdate::Some(&[sys_pid]), true);
    match system.process(sys_pid).map(|process| process.status()) {
        Some(sysinfo::ProcessStatus::Zombie | sysinfo::ProcessStatus::Dead) | None => false,
        Some(_) => true,
    }
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
fn quit_agent_process(pid: i32) -> bool {
    use std::time::Duration;
    if !process_is_alive(pid) {
        return true;
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
    let deadline = Instant::now() + Duration::from_secs(5);
    while process_is_alive(pid) && Instant::now() < deadline {
        std::thread::sleep(Duration::from_millis(100));
    }
    !process_is_alive(pid)
}

static RELAUNCH_SEQUENCE: AtomicU64 = AtomicU64::new(1);
static SNAPSHOT_SEQUENCE: AtomicU64 = AtomicU64::new(1);

/// Render one allow-listed diagnostic field without permitting newlines,
/// control characters, or unbounded client-provided text into daemon logs.
#[cfg(unix)]
fn diagnostic_text(value: &str) -> String {
    let mut rendered = String::new();
    for ch in value.chars() {
        if rendered.chars().count() >= 160 {
            break;
        }
        match ch {
            '\n' => rendered.push_str("\\n"),
            '\r' => rendered.push_str("\\r"),
            ch if ch.is_control() => rendered.push('?'),
            ch => rendered.push(ch),
        }
    }
    rendered
}

#[cfg(unix)]
fn diagnostic_meta(meta: &serde_json::Map<String, serde_json::Value>, key: &str) -> String {
    let Some(value) = meta.get(key) else {
        return "-".into();
    };
    if let Some(text) = value.as_str() {
        diagnostic_text(text)
    } else if value.is_number() || value.is_boolean() {
        diagnostic_text(&value.to_string())
    } else {
        "-".into()
    }
}

#[cfg(unix)]
fn new_relaunch_id() -> String {
    let nanos = SystemTime::now()
        .duration_since(UNIX_EPOCH)
        .unwrap_or_default()
        .as_nanos();
    let seq = RELAUNCH_SEQUENCE.fetch_add(1, Ordering::Relaxed);
    format!("{nanos:x}-{seq:x}")
}

#[cfg(unix)]
fn executable_named(name: &str) -> Option<PathBuf> {
    let mut candidates = Vec::new();
    if let Some(path) = std::env::var_os("PATH") {
        candidates.extend(std::env::split_paths(&path).map(|dir| dir.join(name)));
    }
    candidates.extend([
        PathBuf::from("/opt/homebrew/bin").join(name),
        PathBuf::from("/usr/local/bin").join(name),
    ]);
    if let Some(home) = dirs::home_dir() {
        candidates.push(home.join(".local/bin").join(name));
    }
    candidates
        .into_iter()
        .find(|path| path.is_file() && is_executable(path))
}

#[cfg(unix)]
fn is_executable(path: &Path) -> bool {
    use std::os::unix::fs::PermissionsExt;
    path.metadata()
        .map(|m| m.permissions().mode() & 0o111 != 0)
        .unwrap_or(false)
}

#[cfg(unix)]
fn managed_tmux_config_from(
    xdg_config_home: Option<PathBuf>,
    home_dir: Option<PathBuf>,
) -> PathBuf {
    xdg_config_home
        .filter(|path| !path.as_os_str().is_empty())
        .or_else(|| home_dir.map(|home| home.join(".config")))
        .unwrap_or_else(|| PathBuf::from(".config"))
        .join("focalpoint/tmux.conf")
}

#[cfg(unix)]
fn managed_tmux_config() -> PathBuf {
    managed_tmux_config_from(
        std::env::var_os("XDG_CONFIG_HOME").map(PathBuf::from),
        dirs::home_dir(),
    )
}

#[cfg(unix)]
struct ManagedResumeLaunch {
    tmux: PathBuf,
    focalpoint: PathBuf,
    config: PathBuf,
    cwd: PathBuf,
    provider: PathBuf,
    launch_path: std::ffi::OsString,
    kind: String,
    source_session_id: String,
    launch_id: String,
    tmux_server: String,
    tmux_session: String,
}

#[cfg(unix)]
fn prepare_managed_resume(
    session: &Session,
    launch_id: &str,
) -> Result<ManagedResumeLaunch, String> {
    let cwd = std::fs::canonicalize(session.cwd())
        .map_err(|e| format!("working directory is unavailable: {e}"))?;
    if !cwd.is_dir() {
        return Err("working directory is not a directory".to_string());
    }
    let kind = session.kind.as_deref().unwrap_or("");
    let provider =
        executable_named(kind).ok_or_else(|| format!("provider executable not found: {kind}"))?;
    let tmux = executable_named("tmux").ok_or_else(|| "tmux is not installed".to_string())?;
    let focalpoint = executable_named("focalpoint")
        .ok_or_else(|| "focalpoint CLI is not installed".to_string())?;
    let mut path_dirs = Vec::new();
    for executable in [&provider, &tmux, &focalpoint] {
        if let Some(parent) = executable.parent() {
            let parent = parent.to_path_buf();
            if !path_dirs.contains(&parent) {
                path_dirs.push(parent);
            }
        }
    }
    if let Some(path) = std::env::var_os("PATH") {
        for directory in std::env::split_paths(&path) {
            if !path_dirs.contains(&directory) {
                path_dirs.push(directory);
            }
        }
    }
    let launch_path = std::env::join_paths(path_dirs)
        .map_err(|e| format!("failed to construct managed-session PATH: {e}"))?;
    let config = managed_tmux_config();
    if !config.is_file() {
        return Err(format!(
            "managed tmux config is missing: {}",
            config.display()
        ));
    }
    let suffix = launch_id
        .chars()
        .rev()
        .take(12)
        .collect::<String>()
        .chars()
        .rev()
        .collect::<String>();
    let tmux_session = format!("fp-relaunch-{suffix}");
    // Never use tmux's implicit/default server. This name is generated by the
    // daemon for one relaunch and is used for every later operation on it.
    let tmux_server = format!("fp-relaunch-{suffix}");
    Ok(ManagedResumeLaunch {
        tmux,
        focalpoint,
        config,
        cwd,
        provider,
        launch_path,
        kind: kind.to_string(),
        source_session_id: session.id.clone(),
        launch_id: launch_id.to_string(),
        tmux_server,
        tmux_session,
    })
}

#[cfg(unix)]
fn launch_managed_resume(prepared: &ManagedResumeLaunch) -> Result<(), String> {
    let mut command = Command::new(&prepared.tmux);
    command
        .arg("-L")
        .arg(&prepared.tmux_server)
        .arg("-f")
        .arg(&prepared.config)
        .arg("new-session")
        .arg("-d")
        .arg("-e")
        .arg("FOCALPOINT_MANAGED=1")
        .arg("-e")
        .arg(format!("FOCALPOINT_TMUX_SERVER={}", prepared.tmux_server))
        .arg("-e")
        .arg(format!("FOCALPOINT_RELAUNCH_ID={}", prepared.launch_id))
        .arg("-e")
        .arg(format!(
            "FOCALPOINT_PATH={}",
            prepared.focalpoint.to_string_lossy()
        ))
        .arg("-e")
        .arg(format!("PATH={}", prepared.launch_path.to_string_lossy()))
        .arg("-s")
        .arg(&prepared.tmux_session)
        .arg("-c")
        .arg(&prepared.cwd)
        .arg("--")
        .arg(&prepared.provider);
    match prepared.kind.as_str() {
        "claude" => {
            command.arg("--resume").arg(&prepared.source_session_id);
        }
        "codex" => {
            command.arg("resume").arg(&prepared.source_session_id);
        }
        _ => return Err(format!("provider cannot be resumed: {}", prepared.kind)),
    }
    let output = command
        .output()
        .map_err(|e| format!("failed to start tmux: {e}"))?;
    if !output.status.success() {
        let detail = String::from_utf8_lossy(&output.stderr).trim().to_string();
        return Err(if detail.is_empty() {
            "tmux failed to create the managed session".to_string()
        } else {
            detail
        });
    }
    Ok(())
}

/// A tmux server name created by FocalPoint's launcher.  Deliberately reject
/// `default` and arbitrary socket names reported by an adapter: channel wake
/// must degrade rather than ever consult a user's normal tmux server.
#[cfg(unix)]
fn valid_focalpoint_tmux_server(server: &str) -> bool {
    server.starts_with("fp-")
        && server.len() <= 96
        && server
            .chars()
            .all(|ch| ch.is_ascii_alphanumeric() || matches!(ch, '-' | '_'))
}

/// Recover daemon-owned launch identity even when a provider strips every
/// FOCALPOINT_* variable before invoking hooks. The provider PID/tty is
/// matched against exact panes on pending private tmux servers; task metadata
/// comes only from the daemon's persisted receipt, never from a fuzzy title,
/// cwd, provider kind, PID alone, or tty alone.
#[cfg(unix)]
fn managed_launch_provider_kind(kind: Option<&str>) -> Option<&str> {
    match kind {
        Some("cursor-cli") => Some("cursor"),
        value => value,
    }
}

#[cfg(unix)]
const CURSOR_LAUNCH_REGISTRATION_TIMEOUT: Duration = Duration::from_secs(15);

/// A terminal-open acknowledgement only means LaunchServices accepted a
/// wrapper.  Cursor must also prove that its real chat (headless) or its
/// launch-scoped pane (attachable) registered against this exact receipt.
/// Keep the wait bounded: a broken CLI must not leave callers believing an
/// invisible agent was launched, or hold their socket forever.
#[cfg(unix)]
fn await_cursor_launch_registration(receipt: &Path, timeout: Duration) -> Result<(), String> {
    let deadline = Instant::now() + timeout;
    loop {
        let status = std::fs::read(receipt)
            .ok()
            .and_then(|data| serde_json::from_slice::<Value>(&data).ok())
            .and_then(|value| {
                value
                    .get("status")
                    .and_then(Value::as_str)
                    .map(str::to_string)
            });
        match status.as_deref() {
            Some("registered") => return Ok(()),
            Some("failed") => return Err("Cursor launch registration failed".into()),
            _ if Instant::now() >= deadline => {
                return Err("Cursor did not register within 15 seconds; its CLI or managed wrapper may have exited before starting. Check the managed terminal, then retry with a new task id.".into())
            }
            _ => std::thread::sleep(Duration::from_millis(50)),
        }
    }
}

#[cfg(unix)]
fn update_launch_receipt_status(receipt: &Path, status: &str, error: Option<&str>) {
    let Ok(data) = std::fs::read(receipt) else {
        return;
    };
    let Ok(mut value) = serde_json::from_slice::<Value>(&data) else {
        return;
    };
    value["status"] = status.into();
    if let Some(error) = error {
        value["error"] = error.into();
    }
    let temporary = receipt.with_extension(format!("json.{}.tmp", std::process::id()));
    if let Ok(data) = serde_json::to_vec_pretty(&value) {
        if std::fs::write(&temporary, data).is_ok() {
            let _ = std::fs::rename(temporary, receipt);
        }
    }
}

#[cfg(unix)]
fn correlate_pending_managed_launch(
    registry: &Registry,
    kind: Option<&str>,
    meta: &mut Map<String, Value>,
) -> Option<String> {
    // The headless wrapper reports a more descriptive public kind, while its
    // daemon launch receipt is owned by the Cursor provider.
    let receipt_provider = managed_launch_provider_kind(kind);
    let reported_task = meta
        .get("orchestrator_task_id")
        .and_then(Value::as_str)
        .map(str::to_string);
    let tty = meta.get("tty").and_then(Value::as_str)?.to_string();
    let pid = meta.get("pid").and_then(Value::as_i64)? as i32;
    let tmux = executable_named("tmux")?;
    let receipt_dir = crate::paths::daemon_state_dir().join("launches");
    let mut matches = Vec::new();
    let uid = unsafe { libc::geteuid() };
    let mut socket_dirs = vec![
        PathBuf::from(format!("/tmp/tmux-{uid}")),
        PathBuf::from(format!("/private/tmp/tmux-{uid}")),
    ];
    if let Some(tmp) = std::env::var_os("TMPDIR") {
        socket_dirs.push(PathBuf::from(tmp).join(format!("tmux-{uid}")));
    }
    socket_dirs.sort();
    socket_dirs.dedup();
    let mut candidate_tasks: Vec<String> = registry
        .pending_managed_launches()
        .into_iter()
        .map(|(task_id, _)| task_id)
        .collect();
    if let Some(task_id) = reported_task
        .as_deref()
        .filter(|task_id| valid_orchestrator_task_id(task_id))
    {
        candidate_tasks.push(task_id.to_string());
    }
    // Reservations are in-memory, while receipts are durable. After a daemon
    // restart, rediscover receipt-owned tasks so a provider that stripped all
    // FOCALPOINT_* hook variables can still prove its exact pane ownership.
    if let Ok(entries) = std::fs::read_dir(&receipt_dir) {
        for entry in entries.flatten().take(256) {
            let path = entry.path();
            if path.extension().and_then(|value| value.to_str()) != Some("json") {
                continue;
            }
            let Some(task_id) = path.file_stem().and_then(|value| value.to_str()) else {
                continue;
            };
            if !valid_orchestrator_task_id(task_id)
                || std::fs::metadata(&path).map_or(true, |meta| meta.len() > 64 * 1024)
            {
                continue;
            }
            let Ok(receipt) = std::fs::read(&path)
                .ok()
                .and_then(|data| serde_json::from_slice::<Value>(&data).ok())
                .ok_or(())
            else {
                continue;
            };
            let active_status =
                receipt
                    .get("status")
                    .and_then(Value::as_str)
                    .map_or(true, |status| {
                        matches!(
                            status,
                            "opening"
                                | "awaiting-registration"
                                | "launched"
                                | "launching"
                                | "registered"
                        )
                    });
            if active_status
                && receipt.get("task_id").and_then(Value::as_str) == Some(task_id)
                && receipt.get("provider").and_then(Value::as_str) == receipt_provider
            {
                candidate_tasks.push(task_id.to_string());
            }
        }
    }
    candidate_tasks.sort();
    candidate_tasks.dedup();
    for task_id in candidate_tasks {
        if reported_task
            .as_deref()
            .is_some_and(|reported| reported != task_id)
        {
            continue;
        }
        let prefix = format!("fp-{task_id}-");
        let mut candidate_servers = Vec::new();
        if let Some(server) = meta
            .get("mux_server")
            .and_then(Value::as_str)
            .filter(|server| server.starts_with(&prefix) && valid_focalpoint_tmux_server(server))
        {
            candidate_servers.push(server.to_string());
        }
        for directory in &socket_dirs {
            let Ok(entries) = std::fs::read_dir(directory) else {
                continue;
            };
            for entry in entries.flatten() {
                let Some(server) = entry.file_name().to_str().map(str::to_string) else {
                    continue;
                };
                if server.starts_with(&prefix) && valid_focalpoint_tmux_server(&server) {
                    candidate_servers.push(server);
                }
            }
        }
        candidate_servers.sort();
        candidate_servers.dedup();
        for server in candidate_servers {
            let Ok(output) = Command::new(&tmux)
                .args([
                    "-L",
                    &server,
                    "list-panes",
                    "-a",
                    "-F",
                    "#{session_name}|#{pane_id}|#{pane_tty}|#{pane_pid}|#{pane_current_command}",
                ])
                .output()
            else {
                continue;
            };
            if !output.status.success() {
                continue;
            }
            for line in String::from_utf8_lossy(&output.stdout).lines() {
                let fields: Vec<&str> = line.split('|').collect();
                if fields.len() != 5 || fields[2] != tty {
                    continue;
                }
                let pane_pid = fields[3].parse::<i32>().ok();
                if pane_pid != Some(pid) {
                    continue;
                }
                matches.push((
                    task_id.clone(),
                    server.clone(),
                    fields[0].to_string(),
                    fields[1].to_string(),
                ));
            }
        }
    }
    matches.sort();
    matches.dedup();
    if matches.len() != 1 {
        return None;
    }
    let (task_id, server, session, pane) = matches.pop()?;
    let receipt_path = receipt_dir.join(format!("{task_id}.json"));
    let mut receipt: Value = serde_json::from_slice(&std::fs::read(&receipt_path).ok()?).ok()?;
    if receipt.get("task_id").and_then(Value::as_str) != Some(task_id.as_str())
        || receipt.get("provider").and_then(Value::as_str) != receipt_provider
    {
        return None;
    }
    let client_tty = Command::new(&tmux)
        .args([
            "-L",
            &server,
            "list-clients",
            "-t",
            &session,
            "-F",
            "#{client_tty}",
        ])
        .output()
        .ok()
        .filter(|out| out.status.success())
        .and_then(|out| String::from_utf8(out.stdout).ok())
        .and_then(|text| {
            text.lines()
                .find(|line| !line.is_empty())
                .map(str::to_string)
        });
    meta.insert("managed".into(), true.into());
    meta.insert("orchestrator_task_id".into(), task_id.clone().into());
    meta.insert("_correlated_launch_task_id".into(), task_id.clone().into());
    if let Some(slot) = receipt.get("slot").and_then(Value::as_u64) {
        meta.insert("_authorized_requested_slot".into(), slot.into());
    }
    meta.insert("mux_server".into(), server.into());
    meta.insert("mux_session".into(), session.into());
    meta.insert("mux_pane".into(), pane.into());
    meta.insert("attachment_registration".into(), true.into());
    for key in [
        "launch_id",
        "title",
        "role",
        "manager_task_id",
        "channel_id",
        "terminal_bundle_id",
        "agent_type",
        "provider",
        "model",
        "workflow_id",
        "workflow_run_id",
        "workflow_phase",
        "workflow_gate",
        "workflow_fanout",
        "workflow_assignment",
    ] {
        if let Some(value) = receipt.get(key).filter(|value| !value.is_null()).cloned() {
            let target = match key {
                "title" => "session_title",
                "role" => "orchestration_role",
                key => key,
            };
            meta.insert(target.into(), value);
        }
    }
    if let Some(client_tty) = client_tty {
        meta.insert("mux_client_tty".into(), client_tty.clone().into());
        meta.insert("terminal_host_tty".into(), client_tty.into());
    }
    receipt["status"] = "registered".into();
    receipt["mux_server"] = meta.get("mux_server").cloned().unwrap_or(Value::Null);
    receipt["mux_session"] = meta.get("mux_session").cloned().unwrap_or(Value::Null);
    receipt["mux_pane"] = meta.get("mux_pane").cloned().unwrap_or(Value::Null);
    receipt["pane_tty"] = tty.clone().into();
    if let Ok(data) = serde_json::to_vec_pretty(&receipt) {
        let temporary = receipt_path.with_extension(format!("json.{}.tmp", std::process::id()));
        if std::fs::write(&temporary, data).is_ok() {
            let _ = std::fs::rename(temporary, receipt_path);
        }
    }
    eprintln!("[managed-launch] correlated task_id={} pid={} pane_tty={} server={} pane={} hook_metadata=missing",
        diagnostic_text(&task_id), pid, diagnostic_text(&tty), diagnostic_meta(meta, "mux_server"), diagnostic_meta(meta, "mux_pane"));
    Some(task_id)
}

#[cfg(unix)]
fn channel_wake_target(recipient: &Session) -> Option<(String, String, String, String)> {
    if recipient.state != State::Idle
        || !meta_truthy(recipient.meta.get("managed"))
        || !matches!(recipient.kind.as_deref(), Some("claude" | "codex"))
    {
        return None;
    }
    let server = recipient.meta.get("mux_server")?.as_str()?;
    let session = recipient.meta.get("mux_session")?.as_str()?;
    let pane = recipient.meta.get("mux_pane")?.as_str()?;
    let tty = recipient.meta.get("tty")?.as_str()?;
    if !valid_focalpoint_tmux_server(server)
        || session.is_empty()
        || session.len() > 128
        || pane.len() < 2
        || !pane.starts_with('%')
        || !pane[1..].chars().all(|ch| ch.is_ascii_digit())
        || tty.is_empty()
    {
        return None;
    }
    Some((
        server.to_string(),
        session.to_string(),
        pane.to_string(),
        tty.to_string(),
    ))
}

/// The server is private and daemon-created; still verify the exact session,
/// pane, and pty before injecting. A stale pane id, a reused id, or a member
/// on any normal/default tmux server is notification-only.
#[cfg(unix)]
fn send_channel_wake(server: &str, session: &str, pane: &str, tty: &str) {
    let Some(tmux) = executable_named("tmux") else {
        return;
    };
    let output = match Command::new(&tmux)
        .args([
            "-L",
            server,
            "list-panes",
            "-t",
            session,
            "-F",
            "#{pane_id}|#{pane_tty}",
        ])
        .output()
    {
        Ok(output) if output.status.success() => output,
        _ => return,
    };
    let target_is_owned = std::str::from_utf8(&output.stdout)
        .ok()
        .is_some_and(|lines| lines.lines().any(|line| line == format!("{pane}|{tty}")));
    if target_is_owned {
        let _ = Command::new(tmux)
            .args([
                "-L",
                server,
                "send-keys",
                "-t",
                pane,
                CHANNEL_WAKE_PING,
                "Enter",
            ])
            .status();
    }
}

#[cfg(unix)]
fn kill_managed_resume(prepared: &ManagedResumeLaunch) {
    // Only tear down the exact session we just created, on its private server.
    let output = match Command::new(&prepared.tmux)
        .args([
            "-L",
            &prepared.tmux_server,
            "list-sessions",
            "-F",
            "#{session_name}",
        ])
        .output()
    {
        Ok(output) if output.status.success() => output,
        _ => return,
    };
    if std::str::from_utf8(&output.stdout)
        .ok()
        .is_some_and(|names| names.lines().any(|name| name == prepared.tmux_session))
    {
        let _ = Command::new(&prepared.tmux)
            .args([
                "-L",
                &prepared.tmux_server,
                "kill-session",
                "-t",
                &prepared.tmux_session,
            ])
            .status();
    }
}

#[cfg(unix)]
fn open_managed_tmux_terminal(prepared: &ManagedResumeLaunch) -> Result<(), String> {
    use std::os::unix::fs::{OpenOptionsExt, PermissionsExt};
    let directory = crate::paths::daemon_state_dir().join("launchers");
    std::fs::create_dir_all(&directory).map_err(|e| e.to_string())?;
    std::fs::set_permissions(&directory, std::fs::Permissions::from_mode(0o700))
        .map_err(|e| e.to_string())?;
    let launcher = directory.join(format!("attach-{}.command", prepared.launch_id));
    if launcher.exists() {
        return Ok(());
    }
    let script = format!(
        "#!/bin/zsh -l\nset -e\nrm -f -- {}\nexec {} -L {} attach-session -t {}\n",
        shell_quote(&launcher.display().to_string()),
        shell_quote(&prepared.tmux.display().to_string()),
        shell_quote(&prepared.tmux_server),
        shell_quote(&prepared.tmux_session)
    );
    let mut file = OpenOptions::new()
        .create_new(true)
        .write(true)
        .mode(0o700)
        .open(&launcher)
        .map_err(|e| e.to_string())?;
    file.write_all(script.as_bytes())
        .and_then(|_| file.sync_all())
        .map_err(|e| e.to_string())?;
    open_terminal_launcher(&preferred_terminal_bundle_id(), &launcher)
}

#[cfg(unix)]
fn valid_orchestrator_task_id(id: &str) -> bool {
    let mut chars = id.chars();
    matches!(chars.next(), Some(ch) if ch.is_ascii_alphanumeric())
        && id.len() <= 64
        && chars.all(|ch| ch.is_ascii_alphanumeric() || matches!(ch, '.' | '_' | '-'))
}

#[cfg(unix)]
fn valid_orchestrator_model_id(id: &str) -> bool {
    let mut chars = id.chars();
    matches!(chars.next(), Some(ch) if ch.is_ascii_alphanumeric())
        && id.len() <= 128
        && chars
            .all(|ch| ch.is_ascii_alphanumeric() || matches!(ch, '.' | '_' | '-' | '/' | ':' | '@'))
}

#[cfg(unix)]
fn valid_roadmap_id(id: &str, max: usize) -> bool {
    let mut chars = id.chars();
    matches!(chars.next(), Some(ch) if ch.is_ascii_alphanumeric())
        && id.len() <= max
        && chars.all(|ch| ch.is_ascii_alphanumeric() || matches!(ch, '.' | '_' | '-'))
}

#[cfg(unix)]
fn valid_workflow_assignment_id(id: &str) -> bool {
    let mut chars = id.chars();
    matches!(chars.next(), Some(ch) if ch.is_ascii_alphanumeric())
        && id.len() <= 128
        && chars.all(|ch| ch.is_ascii_alphanumeric() || matches!(ch, '.' | '_' | '-' | ':'))
}

#[cfg(unix)]
fn required_launch_selection<'a>(
    agent_type: Option<&'a str>,
    model: Option<&'a str>,
) -> Result<(&'a str, &'a str), String> {
    let agent_type = agent_type
        .ok_or("agent_type is required; resolve a task-appropriate agent before launch")?;
    if matches!(
        agent_type.to_ascii_lowercase().as_str(),
        "auto" | "default" | "general"
    ) {
        return Err("agent_type must be concrete; auto/default/general are not launchable".into());
    }
    if !valid_roadmap_id(agent_type, 128) {
        return Err(
            "agent_type must use 1-128 letters, digits, dots, underscores, or dashes".into(),
        );
    }

    let model = model
        .ok_or("model is required; resolve a task-appropriate provider model before launch")?;
    if matches!(
        model.to_ascii_lowercase().as_str(),
        "auto" | "default" | "provider-default"
    ) {
        return Err(
            "model must be concrete; auto/default/provider-default are not launchable".into(),
        );
    }
    if !valid_orchestrator_model_id(model) {
        return Err("model must be 1-128 letters, digits, dots, underscores, dashes, slashes, colons, or @ signs".into());
    }
    Ok((agent_type, model))
}

fn validate_workflow_assignment_manifest(
    assignments: &[WorkflowAssignmentAuthorization],
) -> Result<(), String> {
    if assignments.is_empty() || assignments.len() > WORKFLOW_ASSIGNMENT_MAX {
        return Err(format!(
            "workflow_assignments must contain 1-{WORKFLOW_ASSIGNMENT_MAX} entries"
        ));
    }
    let mut ids = std::collections::HashSet::new();
    let mut phase_gates: HashMap<&str, &str> = HashMap::new();
    for assignment in assignments {
        if !valid_workflow_assignment_id(&assignment.assignment_id)
            || !valid_roadmap_id(&assignment.phase, 128)
        {
            return Err("workflow assignment ids and phases must use letters, digits, dots, underscores, or dashes".into());
        }
        if !ids.insert(assignment.assignment_id.as_str()) {
            return Err(format!(
                "duplicate workflow assignment id: {}",
                assignment.assignment_id
            ));
        }
        required_launch_selection(Some(&assignment.agent_type), Some(&assignment.model))?;
        if !matches!(assignment.provider.as_str(), "claude" | "codex" | "cursor") {
            return Err(
                "workflow assignment provider must be 'claude', 'codex', or 'cursor'".into(),
            );
        }
        if !matches!(assignment.gate.as_str(), "authorized" | "confirm" | "auto") {
            return Err(
                "workflow assignment gate must be 'authorized', 'confirm', or 'auto'".into(),
            );
        }
        if !(1..=WORKFLOW_FANOUT_MAX).contains(&assignment.fanout_limit) {
            return Err(format!(
                "workflow assignment fanout_limit must be 1-{WORKFLOW_FANOUT_MAX}"
            ));
        }
        if !assignment.fanout && assignment.fanout_limit != 1 {
            return Err("non-fanout workflow assignments must have fanout_limit 1".into());
        }
        if assignment.fanout && assignment.gate == "auto" {
            return Err("fan-out workflow assignments cannot use the automatic gate".into());
        }
        if let Some(existing) = phase_gates.insert(&assignment.phase, &assignment.gate) {
            if existing != assignment.gate {
                return Err(format!(
                    "workflow phase {} has inconsistent gates",
                    assignment.phase
                ));
            }
        }
    }
    Ok(())
}

/// Validate workflow fields before any process or ledger mutation. The
/// structured manifest is accepted only on the run's initial orchestrator;
/// workers must claim exactly one assignment. A caller-supplied confirmation
/// token is never authority.
#[cfg(unix)]
fn validate_workflow_launch_metadata(
    role: &str,
    workflow_id: Option<&str>,
    run_id: Option<&str>,
    phase: Option<&str>,
    gate: Option<&str>,
    fanout: bool,
    assignment: Option<&str>,
    assignments: Option<&[WorkflowAssignmentAuthorization]>,
    confirmation: Option<&str>,
) -> Result<(), String> {
    if confirmation.is_some() {
        return Err("transition_confirmation is not accepted; a human must approve the run and phase through the daemon".into());
    }
    let any = workflow_id.is_some()
        || run_id.is_some()
        || phase.is_some()
        || gate.is_some()
        || fanout
        || assignment.is_some()
        || assignments.is_some();
    if !any {
        return Ok(());
    }
    let (Some(workflow_id), Some(run_id), Some(phase), Some(gate)) =
        (workflow_id, run_id, phase, gate)
    else {
        return Err("workflow launches require workflow_id, workflow_run_id, workflow_phase, and workflow_gate".into());
    };
    if !valid_roadmap_id(workflow_id, 128)
        || !valid_roadmap_id(run_id, 128)
        || !valid_roadmap_id(phase, 128)
    {
        return Err(
            "workflow identifiers must use letters, digits, dots, underscores, or dashes".into(),
        );
    }
    if !matches!(gate, "authorized" | "confirm" | "auto") {
        return Err("workflow_gate must be 'authorized', 'confirm', or 'auto'".into());
    }
    if fanout && gate == "auto" {
        return Err("fan-out workflow phases cannot use the automatic gate".into());
    }
    match role {
        "orchestrator" => {
            if assignment.is_some() {
                return Err("a workflow orchestrator cannot claim a worker assignment".into());
            }
            let assignments = assignments
                .ok_or("the initial workflow orchestrator launch requires workflow_assignments")?;
            validate_workflow_assignment_manifest(assignments)?;
            if phase != "orchestration" || gate != "authorized" || fanout {
                return Err("the initial workflow orchestrator must use phase 'orchestration', gate 'authorized', and non-fanout launch metadata".into());
            }
        }
        "worker" => {
            if assignments.is_some() {
                return Err(
                    "workflow_assignments are valid only on the initial orchestrator launch".into(),
                );
            }
            let assignment = assignment
                .ok_or("a managed workflow worker launch requires workflow_assignment")?;
            if !valid_workflow_assignment_id(assignment) {
                return Err(
                    "workflow_assignment must use letters, digits, dots, underscores, or dashes"
                        .into(),
                );
            }
        }
        _ => return Err("role must be 'orchestrator' or 'worker'".into()),
    }
    Ok(())
}

#[cfg(unix)]
fn workflow_receipt_path(run_id: &str) -> PathBuf {
    crate::paths::daemon_state_dir()
        .join("launches")
        .join(format!("{run_id}.json"))
}

#[cfg(unix)]
fn manager_workflow_run_id(manager_task_id: &str) -> Option<String> {
    let receipt: Value =
        serde_json::from_slice(&std::fs::read(workflow_receipt_path(manager_task_id)).ok()?)
            .ok()?;
    (receipt.get("task_id").and_then(Value::as_str) == Some(manager_task_id)
        && receipt.get("role").and_then(Value::as_str) == Some("orchestrator")
        && receipt
            .get("workflow_assignments")
            .and_then(Value::as_array)
            .is_some())
    .then(|| {
        receipt
            .get("workflow_run_id")
            .and_then(Value::as_str)
            .unwrap_or_default()
            .to_string()
    })
}

#[cfg(unix)]
fn write_json_atomic(path: &Path, value: &Value) -> Result<(), String> {
    use std::os::unix::fs::OpenOptionsExt;
    let temporary = path.with_extension(format!("json.{}.tmp", std::process::id()));
    let result = (|| -> Result<(), String> {
        let mut file = OpenOptions::new()
            .create_new(true)
            .write(true)
            .mode(0o600)
            .open(&temporary)
            .map_err(|e| format!("cannot create receipt update: {e}"))?;
        serde_json::to_writer_pretty(&mut file, value)
            .map_err(|e| format!("cannot encode receipt update: {e}"))?;
        writeln!(file).map_err(|e| format!("cannot write receipt update: {e}"))?;
        file.sync_all()
            .map_err(|e| format!("cannot sync receipt update: {e}"))?;
        std::fs::rename(&temporary, path)
            .map_err(|e| format!("cannot publish receipt update: {e}"))?;
        Ok(())
    })();
    if result.is_err() {
        let _ = std::fs::remove_file(&temporary);
    }
    result
}

#[cfg(unix)]
fn workflow_ledger_value(assignments: &[WorkflowAssignmentAuthorization]) -> Value {
    Value::Array(
        assignments
            .iter()
            .map(|assignment| {
                let mut value = serde_json::to_value(assignment).expect("assignment serializes");
                value["launches_consumed"] = json!(0);
                value
            })
            .collect(),
    )
}

#[cfg(unix)]
fn receipt_workflow_manifest_matches(
    receipt: &Value,
    requested: Option<&[WorkflowAssignmentAuthorization]>,
) -> bool {
    match (receipt.get("workflow_assignments"), requested) {
        (None | Some(Value::Null), None) => true,
        (Some(Value::Array(stored)), Some(requested)) if stored.len() == requested.len() => {
            stored.iter().zip(requested).all(|(stored, requested)| {
                serde_json::to_value(requested).is_ok_and(|requested| {
                    requested.as_object().is_some_and(|fields| {
                        fields
                            .iter()
                            .all(|(key, value)| stored.get(key) == Some(value))
                    })
                })
            })
        }
        _ => false,
    }
}

#[cfg(unix)]
#[derive(Debug)]
struct WorkflowLedgerClaim {
    run_id: String,
    assignment_id: String,
    task_id: String,
    approval_id: Option<String>,
}

#[cfg(unix)]
#[allow(clippy::too_many_arguments)]
fn consume_workflow_assignment(
    workflow_id: &str,
    run_id: &str,
    phase: &str,
    gate: &str,
    fanout: bool,
    assignment_id: &str,
    agent_type: &str,
    provider: &str,
    model: &str,
    manager_task_id: Option<&str>,
    task_id: &str,
) -> Result<WorkflowLedgerClaim, String> {
    let path = workflow_receipt_path(run_id);
    consume_workflow_assignment_at(
        &path,
        workflow_id,
        run_id,
        phase,
        gate,
        fanout,
        assignment_id,
        agent_type,
        provider,
        model,
        manager_task_id,
        task_id,
    )
}

#[cfg(unix)]
#[allow(clippy::too_many_arguments)]
fn consume_workflow_assignment_at(
    path: &Path,
    workflow_id: &str,
    run_id: &str,
    phase: &str,
    gate: &str,
    fanout: bool,
    assignment_id: &str,
    agent_type: &str,
    provider: &str,
    model: &str,
    manager_task_id: Option<&str>,
    task_id: &str,
) -> Result<WorkflowLedgerClaim, String> {
    if manager_task_id != Some(run_id) {
        return Err("a workflow worker's manager_task_id must match workflow_run_id".into());
    }
    let mut receipt: Value =
        serde_json::from_slice(&std::fs::read(path).map_err(|_| "unknown workflow run")?)
            .map_err(|_| "invalid workflow run receipt")?;
    if receipt.get("task_id").and_then(Value::as_str) != Some(run_id)
        || receipt.get("workflow_run_id").and_then(Value::as_str) != Some(run_id)
        || receipt.get("workflow_id").and_then(Value::as_str) != Some(workflow_id)
        || receipt.get("role").and_then(Value::as_str) != Some("orchestrator")
    {
        return Err("workflow run receipt does not authorize this worker launch".into());
    }
    let entries = receipt
        .get_mut("workflow_assignments")
        .and_then(Value::as_array_mut)
        .ok_or("workflow run has no persisted assignment ledger")?;
    let entry = entries
        .iter_mut()
        .find(|entry| entry.get("assignment_id").and_then(Value::as_str) == Some(assignment_id))
        .ok_or("unknown workflow assignment")?;
    let expected = [
        ("phase", phase),
        ("gate", gate),
        ("agent_type", agent_type),
        ("provider", provider),
        ("model", model),
    ];
    let mismatches = expected
        .into_iter()
        .filter(|(field, value)| entry.get(*field).and_then(Value::as_str) != Some(*value))
        .map(|(field, _)| field)
        .collect::<Vec<_>>();
    if !mismatches.is_empty() {
        return Err(format!(
            "workflow assignment does not authorize requested {}",
            mismatches.join(", ")
        ));
    }
    let limit = entry
        .get("fanout_limit")
        .and_then(Value::as_u64)
        .ok_or("invalid workflow assignment fanout limit")?;
    if entry.get("fanout").and_then(Value::as_bool) != Some(fanout) {
        return Err("workflow_fanout does not match the assignment fanout authorization".into());
    }
    let consumed = entry
        .get("launches_consumed")
        .and_then(Value::as_u64)
        .unwrap_or(0);
    if consumed >= limit {
        return Err("workflow assignment launch limit is exhausted".into());
    }
    entry["launches_consumed"] = json!(consumed + 1);

    let approval_id = if gate == "confirm" {
        let approval = receipt
            .get_mut("workflow_approvals")
            .and_then(Value::as_object_mut)
            .and_then(|approvals| approvals.get_mut(phase))
            .and_then(Value::as_object_mut)
            .ok_or("confirm-gated workflow launch has no daemon-recorded human approval")?;
        if approval
            .get("consumed_by")
            .is_some_and(|value| !value.is_null())
        {
            return Err("workflow phase approval was already consumed".into());
        }
        let approval_id = approval
            .get("approval_id")
            .and_then(Value::as_str)
            .ok_or("invalid workflow phase approval")?
            .to_string();
        approval.insert("consumed_by".into(), json!(task_id));
        approval.insert("consumed_at_unix_ms".into(), json!(unix_ms_now()));
        Some(approval_id)
    } else {
        None
    };
    write_json_atomic(path, &receipt)?;
    Ok(WorkflowLedgerClaim {
        run_id: run_id.into(),
        assignment_id: assignment_id.into(),
        task_id: task_id.into(),
        approval_id,
    })
}

#[cfg(unix)]
fn rollback_workflow_assignment(claim: &WorkflowLedgerClaim) {
    let path = workflow_receipt_path(&claim.run_id);
    let Ok(data) = std::fs::read(&path) else {
        return;
    };
    let Ok(mut receipt) = serde_json::from_slice::<Value>(&data) else {
        return;
    };
    if let Some(entry) = receipt
        .get_mut("workflow_assignments")
        .and_then(Value::as_array_mut)
        .and_then(|entries| {
            entries.iter_mut().find(|entry| {
                entry.get("assignment_id").and_then(Value::as_str)
                    == Some(claim.assignment_id.as_str())
            })
        })
    {
        let consumed = entry
            .get("launches_consumed")
            .and_then(Value::as_u64)
            .unwrap_or(0);
        entry["launches_consumed"] = json!(consumed.saturating_sub(1));
    }
    if let Some(approval_id) = &claim.approval_id {
        if let Some(approval) = receipt
            .get_mut("workflow_approvals")
            .and_then(Value::as_object_mut)
            .and_then(|approvals| {
                approvals.values_mut().find(|approval| {
                    approval.get("approval_id").and_then(Value::as_str)
                        == Some(approval_id.as_str())
                        && approval.get("consumed_by").and_then(Value::as_str)
                            == Some(claim.task_id.as_str())
                })
            })
            .and_then(Value::as_object_mut)
        {
            approval.insert("consumed_by".into(), Value::Null);
            approval.remove("consumed_at_unix_ms");
        }
    }
    let _ = write_json_atomic(&path, &receipt);
}

#[cfg(unix)]
fn approve_workflow_transition(run_id: &str, phase: &str) -> Result<Value, String> {
    if !valid_roadmap_id(run_id, 128) || !valid_roadmap_id(phase, 128) {
        return Err("workflow run and phase ids are invalid".into());
    }
    let path = workflow_receipt_path(run_id);
    approve_workflow_transition_at(&path, run_id, phase)
}

#[cfg(unix)]
fn approve_workflow_transition_at(path: &Path, run_id: &str, phase: &str) -> Result<Value, String> {
    let mut receipt: Value =
        serde_json::from_slice(&std::fs::read(path).map_err(|_| "unknown workflow run")?)
            .map_err(|_| "invalid workflow run receipt")?;
    if receipt.get("task_id").and_then(Value::as_str) != Some(run_id)
        || receipt.get("workflow_run_id").and_then(Value::as_str) != Some(run_id)
        || receipt.get("role").and_then(Value::as_str) != Some("orchestrator")
    {
        return Err("workflow run receipt is not an initial orchestrator launch".into());
    }
    let assignments = receipt
        .get("workflow_assignments")
        .and_then(Value::as_array)
        .ok_or("workflow run has no persisted assignment ledger")?;
    let confirm_phase = assignments.iter().any(|entry| {
        entry.get("phase").and_then(Value::as_str) == Some(phase)
            && entry.get("gate").and_then(Value::as_str) == Some("confirm")
    });
    if !confirm_phase {
        return Err("workflow phase is unknown or is not confirm-gated".into());
    }
    let has_capacity = assignments.iter().any(|entry| {
        entry.get("phase").and_then(Value::as_str) == Some(phase)
            && entry.get("gate").and_then(Value::as_str) == Some("confirm")
            && entry
                .get("launches_consumed")
                .and_then(Value::as_u64)
                .unwrap_or(0)
                < entry
                    .get("fanout_limit")
                    .and_then(Value::as_u64)
                    .unwrap_or(0)
    });
    if !has_capacity {
        return Err("workflow phase assignment launch limits are exhausted".into());
    }
    let approvals = receipt
        .as_object_mut()
        .expect("receipt is an object")
        .entry("workflow_approvals")
        .or_insert_with(|| json!({}))
        .as_object_mut()
        .ok_or("invalid workflow approval ledger")?;
    if approvals.get(phase).is_some_and(|approval| {
        approval
            .get("consumed_by")
            .is_some_and(|value| value.is_null())
    }) {
        return Err("workflow phase already has an unconsumed approval".into());
    }
    let approval_id = new_relaunch_id();
    approvals.insert(
        phase.into(),
        json!({
            "approval_id": approval_id,
            "approved_at_unix_ms": unix_ms_now(),
            "consumed_by": null
        }),
    );
    write_json_atomic(path, &receipt)?;
    Ok(json!({
        "ok": true,
        "workflow_run_id": run_id,
        "workflow_phase": phase,
        "approval_id": approval_id
    }))
}

#[cfg(unix)]
fn orchestrator_session_title(title: Option<&str>, task_id: &str) -> Result<String, String> {
    let title = title.unwrap_or(task_id).trim();
    if title.is_empty() || title.chars().count() > 120 || title.chars().any(char::is_control) {
        return Err("title must contain 1-120 printable characters".into());
    }
    Ok(title.to_string())
}

#[cfg(unix)]
fn validate_orchestration_relationship(
    registry: &Registry,
    role: &str,
    task_id: &str,
    manager_task_id: Option<&str>,
) -> Result<(), String> {
    if !matches!(role, "orchestrator" | "worker") {
        return Err("role must be 'orchestrator' or 'worker'".into());
    }
    if role == "orchestrator" && manager_task_id.is_some() {
        return Err("an orchestrator cannot also declare a manager".into());
    }
    let Some(manager_task_id) = manager_task_id else {
        return Ok(());
    };
    if role != "worker" {
        return Err("manager_task_id is valid only for a worker".into());
    }
    if !valid_orchestrator_task_id(manager_task_id) || manager_task_id == task_id {
        return Err("manager_task_id must be a different valid stable task id".into());
    }
    let managers: Vec<Session> = registry
        .list()
        .into_iter()
        .filter(|session| {
            meta_truthy(session.meta.get("managed"))
                && session
                    .meta
                    .get("orchestration_role")
                    .and_then(serde_json::Value::as_str)
                    == Some("orchestrator")
                && session
                    .meta
                    .get("orchestrator_task_id")
                    .and_then(serde_json::Value::as_str)
                    == Some(manager_task_id)
        })
        .collect();
    match managers.len() {
        1 => Ok(()),
        0 => Err(format!(
            "no live managed orchestrator owns task id {manager_task_id}"
        )),
        _ => Err(format!(
            "multiple live orchestrators claim task id {manager_task_id}"
        )),
    }
}

#[cfg(unix)]
fn shell_quote(value: &str) -> String {
    format!("'{}'", value.replace('\'', "'\\''"))
}

#[cfg(unix)]
fn orchestrated_provider_command(provider_bin: &Path, model: Option<&str>, prompt: &str) -> String {
    let mut args = vec![provider_bin.display().to_string()];
    if let Some(model) = model {
        args.push("--model".into());
        args.push(model.into());
    }
    args.push(prompt.into());
    args.iter()
        .map(|arg| shell_quote(arg))
        .collect::<Vec<_>>()
        .join(" ")
}

#[cfg(unix)]
#[allow(clippy::too_many_arguments)]
fn orchestrated_prompt(
    provider: &str,
    cursor_mode: &str,
    numbered_identity: &str,
    title: &str,
    task_id: &str,
    role: &str,
    has_channel: bool,
    task: &str,
) -> String {
    let registration = if provider == "cursor" && cursor_mode == "attachable" {
        "\nFocalPoint registration (required):\n- Before any other work, use your terminal tool to run exactly: focalpoint register\n- Immediately before your final response, run exactly: focalpoint register --state done\n- Do not alter either command or run them outside this managed pane.\n"
    } else {
        ""
    };
    let coordination = if has_channel {
        "\nFocalPoint coordination (required):\n- Claim your assignment with the focalpoint_claim_assignment MCP tool before repository work.\n- Use focalpoint_ask for questions, focalpoint_report_blocker for blockers, focalpoint_report_progress for meaningful milestones, and focalpoint_complete immediately before your final response.\n- Read and acknowledge pending coordination before crossing a workflow gate. If MCP tools are unavailable, use fpctl-agent channel commands with $FOCALPOINT_CHANNEL_ID and report that degraded state.\n"
    } else {
        ""
    };
    format!(
        "FocalPoint identity:\n- You are {numbered_identity}.\n- Your title is {title:?}.\n- Your stable task id is {task_id:?}.\n- Your orchestration role is {role:?}.\nUse this number and title when identifying yourself in progress, blocker, and completion messages.\n{registration}{coordination}\nTask:\n{task}"
    )
}

/// Cursor has two materially different CLI modes.  Interactive mode is kept
/// attachable in the managed tmux pane; headless mode goes through the
/// installed stream wrapper so FocalPoint receives lifecycle events.
#[cfg(unix)]
fn cursor_provider_command(
    provider_bin: &Path,
    model: Option<&str>,
    prompt: &str,
    mode: &str,
    cursor_wrapper: Option<&Path>,
) -> Result<String, String> {
    let mut args: Vec<String> = if mode == "headless" {
        let wrapper = cursor_wrapper.ok_or_else(|| {
            "Cursor headless adapter is not installed: ~/.config/focalpoint/adapters/cursor-cli-focalpoint.sh".to_string()
        })?;
        vec![wrapper.display().to_string()]
    } else {
        let mut direct = vec![provider_bin.display().to_string()];
        // Cursor's current primary entrypoint is `cursor agent`; retain the
        // older dedicated `cursor-agent` binary when that is what we found.
        if provider_bin.file_name().and_then(|name| name.to_str()) == Some("cursor") {
            direct.push("agent".into());
        }
        direct
    };
    if let Some(model) = model {
        args.push("--model".into());
        args.push(model.into());
    }
    args.push(prompt.into());
    Ok(args
        .iter()
        .map(|arg| shell_quote(arg))
        .collect::<Vec<_>>()
        .join(" "))
}

#[cfg(unix)]
const DEFAULT_TERMINAL_BUNDLE_ID: &str = "com.apple.Terminal";

/// Parse the menu-bar app's preferred-terminal default without allowing the
/// preference to become a command or an option to `open`.
#[cfg(unix)]
fn parse_terminal_bundle_id(value: &str) -> Option<String> {
    let value = value.trim();
    (matches!(value.chars().next(), Some(ch) if ch.is_ascii_alphanumeric())
        && value.contains('.')
        && value.len() <= 255
        && value
            .chars()
            .all(|ch| ch.is_ascii_alphanumeric() || matches!(ch, '.' | '_' | '-')))
    .then(|| value.to_string())
}

/// Read the same UserDefaults key used by the menu-bar Settings picker. This
/// is intentionally resolved for every launch, so changing the preference
/// takes effect without restarting focalpointd.
#[cfg(unix)]
fn preferred_terminal_bundle_id() -> String {
    #[cfg(target_os = "macos")]
    {
        if let Ok(output) = Command::new("/usr/bin/defaults")
            .args(["read", "dev.focalpoint.menubar", "terminalBundleID"])
            .output()
        {
            if output.status.success() {
                if let Ok(value) = std::str::from_utf8(&output.stdout) {
                    if let Some(bundle_id) = parse_terminal_bundle_id(value) {
                        return bundle_id;
                    }
                }
            }
        }
    }
    DEFAULT_TERMINAL_BUNDLE_ID.to_string()
}

#[cfg(unix)]
fn terminal_open_args(bundle_id: &str) -> [&str; 2] {
    ["-b", bundle_id]
}

#[cfg(unix)]
fn applescript_escape(value: &str) -> String {
    value.replace('\\', "\\\\").replace('"', "\\\"")
}

#[cfg(unix)]
fn open_terminal_launcher(bundle_id: &str, launcher: &Path) -> Result<(), String> {
    let status = if bundle_id == "com.googlecode.iterm2" {
        let command = format!("/bin/zsh -l {}", shell_quote(&launcher.display().to_string()));
        let script = format!(
            "tell application id \"com.googlecode.iterm2\" to create window with default profile command \"{}\"",
            applescript_escape(&command),
        );
        Command::new("/usr/bin/osascript").args(["-e", &script]).status()
    } else {
        Command::new("/usr/bin/open").args(terminal_open_args(bundle_id)).arg(launcher).status()
    }.map_err(|error| format!("could not open agent terminal: {error}"))?;
    if status.success() {
        Ok(())
    } else {
        Err(format!("could not open agent terminal ({status})"))
    }
}

#[cfg(unix)]
fn close_exact_terminal_endpoint(endpoint: &TerminalEndpoint) -> Result<(), String> {
    let helper = std::env::var_os("FOCALPOINT_ITERM_FOCUS_HELPER")
        .filter(|value| !value.is_empty())
        .map(PathBuf::from)
        .or_else(|| {
            dirs::home_dir()
                .map(|home| home.join(".config/focalpoint/adapters/focalpoint-iterm-focus"))
        });
    close_exact_terminal_endpoint_with_helper(endpoint, helper.as_deref())
}

#[cfg(unix)]
fn close_exact_terminal_endpoint_with_helper(
    endpoint: &TerminalEndpoint,
    helper: Option<&Path>,
) -> Result<(), String> {
    let (bundle, session_id, host_tty) = (
        endpoint.bundle_id.as_deref(),
        endpoint.session_id.as_deref(),
        endpoint.host_tty.as_deref(),
    );
    if let (Some("com.googlecode.iterm2"), Some(session_id)) = (bundle, session_id) {
        if let Some(helper) = helper.filter(|path| path.is_file()) {
            let mut command = Command::new(helper);
            command.args(["--close", "--session-id", session_id]);
            if let Some(pid) = endpoint.application_pid {
                command.args(["--application-pid", &pid.to_string()]);
            }
            let status = command.status().map_err(|error| error.to_string())?;
            if status.success() {
                return Ok(());
            }
        }
    }
    let script = match (bundle, session_id, host_tty) {
        (Some("com.googlecode.iterm2"), Some(session_id), _) => format!(
            "tell application id \"com.googlecode.iterm2\" to repeat with w in windows\nrepeat with t in tabs of w\nrepeat with s in sessions of t\nif unique ID of s is \"{}\" then close s\nend repeat\nend repeat\nend repeat",
            applescript_escape(session_id),
        ),
        (Some("com.apple.Terminal"), _, Some(tty)) => format!(
            "tell application id \"com.apple.Terminal\" to repeat with w in windows\nrepeat with t in tabs of w\nif tty of t is \"{}\" then close t\nend repeat\nend repeat",
            applescript_escape(tty),
        ),
        _ => return Err("source terminal has no exact closable endpoint".into()),
    };
    let status = Command::new("/usr/bin/osascript")
        .args(["-e", &script])
        .status()
        .map_err(|e| e.to_string())?;
    status
        .success()
        .then_some(())
        .ok_or_else(|| format!("terminal cleanup exited with {status}"))
}

/// Safely launch one exact, user-authorized task in an already-prepared
/// directory. Isolation and task decomposition deliberately remain outside
/// the daemon; this only owns the managed process lifecycle.
#[cfg(unix)]
fn launch_orchestrated_session(
    provider: &str,
    model: &str,
    agent_type: &str,
    cursor_mode: Option<&str>,
    cwd: &str,
    task: &str,
    task_id: &str,
    title: &str,
    slot: Option<u8>,
    role: &str,
    manager_task_id: Option<&str>,
    channel_id: Option<&str>,
    workflow_id: Option<&str>,
    workflow_run_id: Option<&str>,
    workflow_phase: Option<&str>,
    workflow_gate: Option<&str>,
    workflow_fanout: bool,
    workflow_assignment: Option<&str>,
    workflow_assignments: Option<&[WorkflowAssignmentAuthorization]>,
) -> Result<serde_json::Value, String> {
    use std::os::unix::fs::{OpenOptionsExt, PermissionsExt};

    if !matches!(provider, "claude" | "codex" | "cursor") {
        return Err("provider must be 'claude', 'codex', or 'cursor'".into());
    }
    if !valid_orchestrator_task_id(task_id) {
        return Err("task_id must be 1-64 letters, digits, dots, underscores, or dashes".into());
    }
    if !matches!(role, "orchestrator" | "worker") {
        return Err("role must be 'orchestrator' or 'worker'".into());
    }
    let (agent_type, model) = required_launch_selection(Some(agent_type), Some(model))?;
    if task.trim().is_empty() || task.len() > 16_384 || task.contains('\0') {
        return Err("task must contain 1-16384 UTF-8 bytes".into());
    }
    let requested_cwd = Path::new(cwd);
    if !requested_cwd.is_absolute() || !requested_cwd.is_dir() {
        return Err("cwd must be an existing absolute directory".into());
    }
    let cwd =
        std::fs::canonicalize(requested_cwd).map_err(|e| format!("cannot resolve cwd: {e}"))?;
    if provider != "cursor" && cursor_mode.is_some() {
        return Err("cursor_mode is only valid with provider 'cursor'".into());
    }
    let cursor_mode = cursor_mode.unwrap_or("headless");
    if provider == "cursor" && !matches!(cursor_mode, "headless" | "attachable") {
        return Err("cursor_mode must be 'headless' or 'attachable'".into());
    }
    // `cursor-agent` is the CLI that can actually run `--print
    // --output-format stream-json`. Falling back to a bare `cursor` is only
    // valid when that binary is Cursor's agent entrypoint; on a normal install
    // `cursor` is the VS Code-derived editor launcher, which cannot run a
    // headless agent and exits immediately — leaving a stale tmux server, no
    // daemon row, and no error anywhere. Silent degradation to a binary that
    // cannot do the job is worse than refusing, so headless launches require
    // the real agent CLI and say so.
    let provider_bin = if provider == "cursor" {
        match executable_named("cursor-agent") {
            Some(path) => Some(path),
            None if cursor_mode == "attachable" => executable_named("cursor"),
            None => {
                return Err(
                    "cursor-agent is not installed; headless Cursor launches require it \
                     (a bare `cursor` is the editor launcher and cannot run a headless agent). \
                     Install cursor-agent, set CURSOR_AGENT, or use --cursor-mode attachable."
                        .into(),
                )
            }
        }
    } else {
        executable_named(provider)
    }
    .ok_or_else(|| format!("{provider} is not installed"))?
    .canonicalize()
    .map_err(|e| format!("cannot resolve provider executable: {e}"))?;
    let terminal_bundle_id = preferred_terminal_bundle_id();
    let home = dirs::home_dir().ok_or("cannot resolve home directory")?;
    let runner = home.join(".config/focalpoint/focalpoint-run.sh");
    if !runner.is_file() {
        return Err(format!(
            "managed-session launcher is not installed: {}",
            runner.display()
        ));
    }
    if runner
        .metadata()
        .map_err(|e| e.to_string())?
        .permissions()
        .mode()
        & 0o111
        == 0
    {
        return Err(format!(
            "managed-session launcher is not executable: {}",
            runner.display()
        ));
    }

    let state_dir = crate::paths::daemon_state_dir();
    let receipts_dir = state_dir.join("launches");
    let launchers_dir = state_dir.join("launchers");
    for directory in [&receipts_dir, &launchers_dir] {
        std::fs::create_dir_all(directory).map_err(|e| e.to_string())?;
        std::fs::set_permissions(directory, std::fs::Permissions::from_mode(0o700))
            .map_err(|e| e.to_string())?;
    }
    let receipt = receipts_dir.join(format!("{task_id}.json"));
    if receipt.exists() {
        let mut existing: Value = serde_json::from_slice(
            &std::fs::read(&receipt).map_err(|e| format!("cannot read launch receipt: {e}"))?,
        )
        .map_err(|e| format!("invalid launch receipt: {e}"))?;
        if existing.get("status").and_then(Value::as_str) == Some("failed") {
            return Err(existing
                .get("error")
                .and_then(Value::as_str)
                .unwrap_or("managed launch previously failed before registration; retry with a new task id")
                .to_string());
        }
        existing["ok"] = Value::Bool(true);
        return Ok(existing);
    }
    let launch_id = new_relaunch_id();
    let mut receipt_file = OpenOptions::new()
        .create_new(true)
        .write(true)
        .mode(0o600)
        .open(&receipt)
        .map_err(|error| {
            if error.kind() == std::io::ErrorKind::AlreadyExists {
                format!("task id was already launched: {task_id}")
            } else {
                format!("cannot claim task id: {error}")
            }
        })?;
    let mut receipt_value = serde_json::json!({
        "task_id": task_id,
        "launch_id": launch_id,
        "title": title,
        "slot": slot,
        "provider": provider,
        "agent_type": agent_type,
        "cursor_mode": (provider == "cursor").then_some(cursor_mode),
        "model": model,
        "cwd": cwd,
        "terminal_bundle_id": terminal_bundle_id.clone(),
        "role": role,
        "manager_task_id": manager_task_id,
        "channel_id": channel_id,
        "workflow_id": workflow_id,
        "workflow_run_id": workflow_run_id,
        "workflow_phase": workflow_phase,
        "workflow_gate": workflow_gate,
        "workflow_fanout": workflow_fanout,
        "workflow_assignment": workflow_assignment,
        "workflow_assignments": workflow_assignments.map(workflow_ledger_value),
        "workflow_approvals": workflow_assignments.map(|_| json!({})),
        "accepted_at_unix_ms": unix_ms_now(),
        "status": "opening",
    });
    if let Err(error) = serde_json::to_writer_pretty(&mut receipt_file, &receipt_value)
        .map_err(std::io::Error::other)
        .and_then(|_| writeln!(receipt_file))
        .and_then(|_| receipt_file.sync_all())
    {
        let _ = std::fs::remove_file(&receipt);
        return Err(format!("cannot persist launch claim: {error}"));
    }

    let launcher = launchers_dir.join(format!("{task_id}.command"));
    if launcher.exists() {
        let _ = std::fs::remove_file(&receipt);
        return Err(format!("task id already has a pending launcher: {task_id}"));
    }
    let numbered_identity = slot
        .map(|slot| format!("session #{slot}"))
        .unwrap_or_else(|| "an overflow session without a numbered key".to_string());
    let prompt = orchestrated_prompt(
        provider,
        cursor_mode,
        &numbered_identity,
        title,
        task_id,
        role,
        channel_id.is_some(),
        task,
    );
    let cursor_wrapper = home.join(".config/focalpoint/adapters/cursor-cli-focalpoint.sh");
    let provider_command = if provider == "cursor" {
        cursor_provider_command(
            &provider_bin,
            Some(model),
            &prompt,
            cursor_mode,
            (cursor_mode == "headless"
                && cursor_wrapper.is_file()
                && is_executable(&cursor_wrapper))
            .then_some(cursor_wrapper.as_path()),
        )?
    } else {
        orchestrated_provider_command(&provider_bin, Some(model), &prompt)
    };
    let manager_export = manager_task_id
        .map(|id| format!("export FOCALPOINT_MANAGER_TASK_ID={}\n", shell_quote(id)))
        .unwrap_or_default();
    let channel_export = channel_id
        .map(|id| format!("export FOCALPOINT_CHANNEL_ID={}\n", shell_quote(id)))
        .unwrap_or_default();
    let roadmap_exports = [
        ("FOCALPOINT_AGENT_TYPE", Some(agent_type)),
        ("FOCALPOINT_WORKFLOW_ID", workflow_id),
        ("FOCALPOINT_WORKFLOW_RUN_ID", workflow_run_id),
        ("FOCALPOINT_WORKFLOW_PHASE", workflow_phase),
        ("FOCALPOINT_WORKFLOW_GATE", workflow_gate),
        ("FOCALPOINT_WORKFLOW_ASSIGNMENT", workflow_assignment),
    ]
    .into_iter()
    .filter_map(|(key, value)| value.map(|value| format!("export {key}={}\n", shell_quote(value))))
    .collect::<String>();
    let slot_export = slot
        .map(|slot| {
            format!(
                "export FOCALPOINT_SESSION_SLOT={}\n",
                shell_quote(&slot.to_string())
            )
        })
        .unwrap_or_default();
    // Make the FocalPoint CLI reachable from the launched agent without
    // depending on the user's shell configuration at all.
    //
    // The adapter hooks resolve the CLI as `${FOCALPOINT_PATH:-focalpoint}`,
    // and adapters are *required* to no-op silently when it is missing — so a
    // PATH that lacks it produces a session that runs invisibly: no key, no
    // state, no channel eligibility, and no row to re-register from. A login
    // shell is not a reliable fix. `zsh -l` sources .zshenv/.zprofile/.zlogin
    // but NOT .zshrc, and a Homebrew install commonly initializes PATH from
    // .zshrc, which is interactive-only. Exporting the daemon's own directory
    // is deterministic instead: `focalpoint`, `fpctl-agent`, and `focalpointd`
    // are installed side by side, so this resolves the hooks' CLI *and* the
    // `fpctl-agent` that orchestrator agents invoke directly.
    let daemon_bin_dir = std::env::current_exe()
        .ok()
        .and_then(|exe| exe.canonicalize().ok())
        .and_then(|exe| exe.parent().map(std::path::Path::to_path_buf));
    let path_export = daemon_bin_dir
        .map(|dir| {
            format!(
                "export PATH={}:\"$PATH\"\nexport FOCALPOINT_PATH={}\n",
                shell_quote(&dir.display().to_string()),
                shell_quote(&dir.join("focalpoint").display().to_string()),
            )
        })
        .unwrap_or_default();
    let script = format!(
        "#!/bin/zsh -l\nset -e\nrm -f -- {}\ncd -- {}\n{}export FOCALPOINT_LAUNCH_ID={}\nexport FOCALPOINT_ORCHESTRATOR_TASK_ID={}\nexport FOCALPOINT_ORCHESTRATION_ROLE={}\nexport FOCALPOINT_SESSION_TITLE={}\n{}{}{}{}exec {} {}\n",
        shell_quote(&launcher.display().to_string()),
        shell_quote(&cwd.display().to_string()),
        path_export,
        shell_quote(&launch_id),
        shell_quote(task_id),
        shell_quote(role),
        shell_quote(title),
        slot_export,
        manager_export,
        channel_export,
        roadmap_exports,
        shell_quote(&runner.display().to_string()),
        provider_command,
    );
    let temporary = launchers_dir.join(format!(".{task_id}.{}.tmp", std::process::id()));
    let launch_result = (|| -> Result<(), String> {
        let mut file = OpenOptions::new()
            .create_new(true)
            .write(true)
            .mode(0o700)
            .open(&temporary)
            .map_err(|e| format!("cannot create launcher: {e}"))?;
        file.write_all(script.as_bytes())
            .and_then(|_| file.sync_all())
            .map_err(|e| format!("cannot write launcher: {e}"))?;
        std::fs::rename(&temporary, &launcher)
            .map_err(|e| format!("cannot publish launcher: {e}"))?;
        open_terminal_launcher(terminal_bundle_id.as_str(), &launcher)?;
        Ok(())
    })();
    if let Err(error) = launch_result {
        let _ = std::fs::remove_file(&temporary);
        let _ = std::fs::remove_file(&launcher);
        let _ = std::fs::remove_file(&receipt);
        return Err(error);
    }
    // Cursor needs a second, receipt-bound registration handshake. Claude and
    // Codex retain their existing terminal-open launch acknowledgement.
    let launch_status = if provider == "cursor" {
        "awaiting-registration"
    } else {
        "launched"
    };
    receipt_value["status"] = Value::String(launch_status.into());
    let receipt_update = receipt.with_extension(format!("json.{}.tmp", std::process::id()));
    if let Ok(data) = serde_json::to_vec_pretty(&receipt_value) {
        if std::fs::write(&receipt_update, data).is_ok() {
            let _ = std::fs::rename(&receipt_update, &receipt);
        }
    }
    Ok(serde_json::json!({
        "ok": true,
        "task_id": task_id,
        "launch_id": launch_id,
        "title": title,
        "slot": slot,
        "provider": provider,
        "agent_type": agent_type,
        "model": model,
        "cursor_mode": (provider == "cursor").then_some(cursor_mode),
        "cwd": cwd,
        "role": role,
        "manager_task_id": manager_task_id,
        "channel_id": channel_id,
        "workflow_id": workflow_id,
        "workflow_run_id": workflow_run_id,
        "workflow_phase": workflow_phase,
        "workflow_gate": workflow_gate,
        "workflow_fanout": workflow_fanout,
        "workflow_assignment": workflow_assignment,
        "terminal_bundle_id": terminal_bundle_id,
        "status": launch_status,
    }))
}

#[cfg(unix)]
fn resume_managed_session(
    provider: &str,
    cwd: &str,
    session: &str,
    title: Option<&str>,
) -> Result<Value, String> {
    use std::os::unix::fs::OpenOptionsExt;
    if !matches!(provider, "claude" | "codex") {
        return Err("provider must be 'claude' or 'codex'".into());
    }
    if session.is_empty() || session.len() > 256 || session.chars().any(char::is_control) {
        return Err("invalid provider session id".into());
    }
    let cwd =
        std::fs::canonicalize(cwd).map_err(|e| format!("working directory is unavailable: {e}"))?;
    if !cwd.is_dir() {
        return Err("working directory is not a directory".into());
    }
    let home = dirs::home_dir().ok_or("cannot resolve home directory")?;
    let runner = home.join(".config/focalpoint/focalpoint-run.sh");
    if !runner.is_file() || !is_executable(&runner) {
        return Err("managed-session launcher is not installed".into());
    }
    let state = crate::paths::daemon_state_dir();
    let receipts = state.join("resumes");
    let launchers = state.join("launchers");
    std::fs::create_dir_all(&receipts).map_err(|e| e.to_string())?;
    std::fs::create_dir_all(&launchers).map_err(|e| e.to_string())?;
    let key: String = session
        .chars()
        .map(|ch| {
            if ch.is_ascii_alphanumeric() || matches!(ch, '.' | '_' | '-') {
                ch
            } else {
                '_'
            }
        })
        .collect();
    let terminal_bundle_id = preferred_terminal_bundle_id();
    let launch_id = new_relaunch_id();
    // A resume click is a new user-authorized attempt. Keying receipts only
    // by provider/session made the first receipt permanent: every later click
    // returned the old `launched` JSON without starting a process. Keep each
    // attempt collision-free and auditable instead.
    let receipt = receipts.join(format!("{provider}-{key}-{launch_id}.json"));
    let mut value = serde_json::json!({"ok":true,"launch_id":launch_id,"provider":provider,"session":session,
        "title":title,"cwd":cwd,"terminal_bundle_id":terminal_bundle_id,"status":"opening"});
    let mut file = OpenOptions::new()
        .create_new(true)
        .write(true)
        .mode(0o600)
        .open(&receipt)
        .map_err(|e| e.to_string())?;
    serde_json::to_writer_pretty(&mut file, &value).map_err(|e| e.to_string())?;
    file.sync_all().map_err(|e| e.to_string())?;
    let launcher = launchers.join(format!("resume-{provider}-{key}.command"));
    let provider_command = if provider == "claude" {
        format!(
            "{} --resume {}",
            shell_quote(
                &executable_named("claude")
                    .ok_or("claude is not installed")?
                    .display()
                    .to_string()
            ),
            shell_quote(session)
        )
    } else {
        format!(
            "{} resume {}",
            shell_quote(
                &executable_named("codex")
                    .ok_or("codex is not installed")?
                    .display()
                    .to_string()
            ),
            shell_quote(session)
        )
    };
    let title_export = title
        .filter(|value| !value.is_empty())
        .map(|value| format!("export FOCALPOINT_SESSION_TITLE={}\n", shell_quote(value)))
        .unwrap_or_default();
    let script = format!("#!/bin/zsh -l\nset -e\nrm -f -- {}\ncd -- {}\nexport FOCALPOINT_LAUNCH_ID={}\nexport FOCALPOINT_RESUME_SESSION_ID={}\n{}exec {} {}\n",
        shell_quote(&launcher.display().to_string()), shell_quote(&cwd.display().to_string()), shell_quote(&launch_id), shell_quote(session), title_export,
        shell_quote(&runner.display().to_string()), provider_command);
    let temporary = launcher.with_extension(format!("command.{}.tmp", std::process::id()));
    let mut launcher_file = OpenOptions::new()
        .create_new(true)
        .write(true)
        .mode(0o700)
        .open(&temporary)
        .map_err(|e| e.to_string())?;
    launcher_file
        .write_all(script.as_bytes())
        .and_then(|_| launcher_file.sync_all())
        .map_err(|e| e.to_string())?;
    std::fs::rename(&temporary, &launcher).map_err(|e| e.to_string())?;
    open_terminal_launcher(&terminal_bundle_id, &launcher)?;
    value["status"] = "launched".into();
    let data = serde_json::to_vec_pretty(&value).map_err(|e| e.to_string())?;
    let update = receipt.with_extension(format!("json.{}.tmp", std::process::id()));
    std::fs::write(&update, data)
        .and_then(|_| std::fs::rename(update, &receipt))
        .map_err(|e| e.to_string())?;
    Ok(value)
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
    state_name: &str,
    rgb: &[u64],
    pattern_name: &str,
    period_ms: Option<u64>,
) -> Result<(State, Style), String> {
    let state =
        State::from_name(state_name).ok_or_else(|| format!("unknown state: {state_name:?}"))?;
    let pattern = Pattern::from_name(pattern_name).ok_or_else(|| {
        format!("unknown pattern {pattern_name:?}; expected solid|breathe|blink|strobe|off")
    })?;
    let period_ms = match period_ms {
        None => crate::styles::default_style(state).period_ms,
        Some(n) if n <= u16::MAX as u64 => n as u16,
        Some(_) => return Err("period_ms must be an integer 0..=65535".to_string()),
    };
    Ok((
        state,
        Style::new(parse_rgb_values(rgb)?, pattern, period_ms),
    ))
}

fn parse_inject_fields(
    kind: &str,
    control: Option<&str>,
    action: Option<&str>,
    delta: Option<i64>,
    gesture: Option<&str>,
) -> Result<Vec<DeviceEvent>, String> {
    match kind {
        "key" => {
            let control = control.ok_or_else(|| "inject key requires 'control'".to_string())?;
            let id = control_id(control).ok_or_else(|| format!("unknown control: {control:?}"))?;
            match action.unwrap_or("tap") {
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
            let delta = delta.ok_or_else(|| "inject dial requires integer 'delta'".to_string())?;
            if !(-128..=127).contains(&delta) {
                return Err(format!("delta {delta} out of range (-128..=127)"));
            }
            Ok(vec![DeviceEvent::Dial { delta: delta as i8 }])
        }
        "joy" => {
            let gesture = gesture.ok_or_else(|| "inject joy requires 'gesture'".to_string())?;
            let id = joy_id(gesture).ok_or_else(|| format!("unknown gesture: {gesture:?}"))?;
            Ok(vec![DeviceEvent::Joy { gesture: id }])
        }
        other => Err(format!(
            "unknown inject kind {other:?}; expected key|dial|joy"
        )),
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
    let state =
        State::from_name(state_name).ok_or_else(|| format!("unknown state: {state_name:?}"))?;
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
            let action = value
                .get("action")
                .and_then(|a| a.as_str())
                .unwrap_or("tap");
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
            Ok(vec![DeviceEvent::Dial { delta: delta as i8 }])
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
    /// Daemon-owned persisted mailboxes. Message bodies never leave this
    /// object through the wake transport.
    pub channels: Channels,
    /// Monotonic debounce timestamps are deliberately process-local.
    pub channel_wake_last: HashMap<String, Instant>,
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
    host_tx: tokio::sync::mpsc::UnboundedSender<HostCmd>,
    /// Serializes every registry mutation through its emitted effects and
    /// durable snapshot. `Shared` protects individual memory accesses; this
    /// lock protects the larger mutation -> device/events -> persistence
    /// transaction so concurrent hook connections cannot publish B before A
    /// after the registry itself committed A before B.
    transition: Arc<Mutex<()>>,
}

#[cfg(unix)]
impl EventCtx {
    fn broadcast(&self, line: &str) {
        // Err just means no subscribers; that's fine.
        let _ = self.evt_tx.send(line.to_string());
    }
}

#[cfg(unix)]
fn meta_truthy(value: Option<&serde_json::Value>) -> bool {
    value.is_some_and(|value| {
        value == &serde_json::Value::Bool(true)
            || matches!(value.as_str(), Some("true" | "1"))
            || value.as_i64().is_some_and(|number| number != 0)
    })
}

/// Resolve a session only when it is an orchestrator-owned managed process and
/// the caller supplies the matching stable task id. Transcript support is
/// narrowed separately because Cursor does not expose the same local format.
#[cfg(unix)]
fn orchestrated_session_target(
    registry: &Registry,
    session_id: &str,
    task_id: &str,
) -> Result<Session, String> {
    if !valid_orchestrator_task_id(task_id) {
        return Err("invalid orchestrator task id".into());
    }
    let session = registry
        .session_or_tombstone(session_id)
        .ok_or_else(|| format!("unknown session: {session_id}"))?;
    if !meta_truthy(session.meta.get("managed")) {
        return Err("session is not managed by FocalPoint".into());
    }
    let owned_task = session
        .meta
        .get("orchestrator_task_id")
        .and_then(serde_json::Value::as_str);
    if owned_task != Some(task_id) {
        return Err("session does not match that orchestrator task id".into());
    }
    if !matches!(
        session.kind.as_deref(),
        Some("claude" | "codex" | "cursor" | "cursor-cli")
    ) {
        return Err("managed stop supports only claude, codex, and cursor".into());
    }
    Ok(session)
}

#[cfg(unix)]
fn channel_actor(registry: &Registry, task_id: &str) -> Result<Session, String> {
    if !valid_orchestrator_task_id(task_id) {
        return Err("invalid channel task id".into());
    }
    let matches: Vec<Session> = registry
        .list()
        .into_iter()
        .filter(|session| {
            meta_truthy(session.meta.get("managed"))
                && session.has_authoritative_attachment()
                && matches!(
                    session.kind.as_deref(),
                    Some("claude" | "codex" | "cursor" | "cursor-cli")
                )
                && session
                    .meta
                    .get("orchestrator_task_id")
                    .and_then(serde_json::Value::as_str)
                    == Some(task_id)
        })
        .collect();
    match matches.len() {
        1 => Ok(matches.into_iter().next().unwrap()),
        0 => Err("no live managed session owns that channel task id".into()),
        _ => Err("multiple live sessions own that channel task id".into()),
    }
}

#[cfg(unix)]
const CHANNEL_WAKE_PING: &str = "FocalPoint: you have channel mail. Run fpctl-agent channel read --channel \"$FOCALPOINT_CHANNEL_ID\".";

/// The only inter-session injection. Its payload is a source constant; it
/// never contains a message body, kind, sender, or any other channel data.
#[cfg(unix)]
fn maybe_wake_channel_member(ctx: &EventCtx, channel: &str, recipient: &Session) {
    if recipient.state != State::Idle || recipient.state == State::Waiting {
        return;
    }
    // The degraded tier remains visible to a human for unmanaged sessions,
    // missing panes, and a deliberately disabled managed wake.
    if !ctx.config.channel.wake_managed() || !channel_wake_allowed(recipient) {
        ctx.broadcast(
            &serde_json::json!({"event":"channel-notify","channel":channel,"session":recipient.id})
                .to_string(),
        );
        return;
    }
    let Some((server, session, pane, tty)) = channel_wake_target(recipient) else {
        ctx.broadcast(
            &serde_json::json!({"event":"channel-notify","channel":channel,"session":recipient.id})
                .to_string(),
        );
        return;
    };
    let allowed = {
        let mut state = ctx.shared.lock().unwrap();
        let now = Instant::now();
        match state.channel_wake_last.get(&recipient.id) {
            Some(last) if now.duration_since(*last) < Duration::from_secs(3) => false,
            _ => {
                state.channel_wake_last.insert(recipient.id.clone(), now);
                true
            }
        }
    };
    if !allowed {
        return;
    }
    std::thread::spawn(move || {
        send_channel_wake(&server, &session, &pane, &tty);
    });
}

#[cfg(unix)]
fn channel_public(channel: &crate::channel::Channel) -> serde_json::Value {
    serde_json::json!({"channel_id": channel.id, "owner_session": channel.owner_session,
        "members": channel.members.keys().collect::<Vec<_>>(), "closed": false})
}

#[cfg(unix)]
fn join_managed_channel(
    channel: &mut crate::channel::Channel,
    session_id: &str,
    meta: &Map<String, Value>,
) -> Result<bool, String> {
    if !meta_truthy(meta.get("managed")) {
        return Err("channel registration requires a managed session".into());
    }
    let task_id = meta
        .get("orchestrator_task_id")
        .and_then(Value::as_str)
        .ok_or("channel registration requires a managed task id")?;
    let role = meta
        .get("orchestration_role")
        .and_then(Value::as_str)
        .ok_or("channel registration requires an orchestration role")?;
    let was_member = channel.members.contains_key(session_id);
    match role {
        "orchestrator" if channel.owner_task_id == task_id => {
            channel.bind_owner(session_id.to_string())?;
        }
        "worker"
            if meta.get("manager_task_id").and_then(Value::as_str)
                == Some(channel.owner_task_id.as_str()) =>
        {
            channel.join_at_tail(session_id.to_string());
        }
        _ => return Err("managed session identity does not authorize this channel".into()),
    }
    Ok(!was_member)
}

#[cfg(unix)]
fn managed_channel_identity(registry: &Registry, session_id: &str) -> Option<Session> {
    registry.list().into_iter().find(|session| {
        session.id == session_id
            && session.has_authoritative_attachment()
            && meta_truthy(session.meta.get("managed"))
            && matches!(
                session.kind.as_deref(),
                Some("claude" | "codex" | "cursor" | "cursor-cli")
            )
    })
}

#[cfg(unix)]
fn post_managed_channel_lifecycle(
    channel: &mut crate::channel::Channel,
    session_id: &str,
    meta: &Map<String, Value>,
    state: State,
    joined: bool,
) {
    let role = meta
        .get("orchestration_role")
        .and_then(Value::as_str)
        .unwrap_or("worker");
    let title = meta
        .get("session_title")
        .and_then(Value::as_str)
        .unwrap_or(session_id);
    let assignment = meta
        .get("workflow_assignment")
        .and_then(Value::as_str)
        .map(|value| format!(" assignment={value}"))
        .unwrap_or_default();
    let (kind, body) = if joined {
        (
            "progress",
            format!("{title} joined workflow coordination as {role}.{assignment}"),
        )
    } else {
        match state {
            State::Done => ("progress", format!("{title} completed.{assignment}")),
            State::Error => (
                "blocker",
                format!("{title} entered an error state.{assignment}"),
            ),
            State::Approval => (
                "question",
                format!("{title} is waiting for approval.{assignment}"),
            ),
            _ => return,
        }
    };
    // Provider hooks can repeat terminal state events. Keep the automatic
    // control-plane projection idempotent without suppressing model-authored
    // messages that happen to have the same text.
    if channel.messages.last().is_some_and(|message| {
        message.from_session == "focalpoint"
            && message.kind == kind
            && message.body == body
            && message.to
                == if role == "orchestrator" {
                    "channel"
                } else {
                    channel.owner_session.as_str()
                }
    }) {
        return;
    }
    let to = if role == "orchestrator" {
        "channel".to_string()
    } else {
        channel.owner_session.clone()
    };
    channel.post("focalpoint".into(), to, kind.into(), body, unix_ms_now());
}

#[cfg(unix)]
fn channel_post_target(
    channel: &crate::channel::Channel,
    actor: &str,
    requested_to: &str,
) -> Result<String, String> {
    if !channel.members.contains_key(actor) {
        return Err("session is not a channel member".into());
    }
    if actor == channel.owner_session {
        if requested_to != "channel" && !channel.members.contains_key(requested_to) {
            return Err("recipient is not a channel member".into());
        }
        Ok(requested_to.to_string())
    } else {
        if requested_to != "channel" && requested_to != channel.owner_session {
            return Err("workers may post only to their channel owner".into());
        }
        Ok(channel.owner_session.clone())
    }
}

#[cfg(unix)]
fn channel_wake_allowed(recipient: &Session) -> bool {
    channel_wake_target(recipient).is_some()
}

#[cfg(unix)]
fn orchestrated_transcript_path(session: &Session) -> Result<PathBuf, String> {
    let raw = session
        .meta
        .get("transcript_path")
        .and_then(serde_json::Value::as_str)
        .ok_or("session has not reported a transcript path yet")?;
    let path = Path::new(raw)
        .canonicalize()
        .map_err(|error| format!("cannot resolve transcript path: {error}"))?;
    let home = dirs::home_dir().ok_or("cannot resolve home directory")?;
    let root = match session.kind.as_deref() {
        Some("claude") => home.join(".claude/projects"),
        Some("codex") => home.join(".codex/sessions"),
        _ => return Err("transcripts are supported only for claude and codex".into()),
    }
    .canonicalize()
    .map_err(|error| format!("cannot resolve transcript root: {error}"))?;
    if !path.starts_with(&root) || path.extension().and_then(|ext| ext.to_str()) != Some("jsonl") {
        return Err("reported transcript is outside the provider transcript directory".into());
    }
    Ok(path)
}

#[cfg(unix)]
fn gracefully_end_session(
    id: &str,
    pid: Option<i32>,
    ctx: &EventCtx,
    host_tx: &tokio::sync::mpsc::UnboundedSender<HostCmd>,
) {
    if let Some(pid) = pid {
        let ctx = ctx.clone();
        let host_tx = host_tx.clone();
        let id = id.to_string();
        std::thread::spawn(move || {
            quit_agent_process(pid);
            let _transition = ctx.transition.lock().unwrap();
            let effects = ctx.shared.lock().unwrap().registry.end_session(&id);
            apply_effects(effects, &ctx, &host_tx);
        });
    } else {
        let _transition = ctx.transition.lock().unwrap();
        let effects = ctx.shared.lock().unwrap().registry.end_session(id);
        apply_effects(effects, ctx, host_tx);
    }
}

/// JSON line for a `state` event (PROTOCOL.md §3): the aggregate state.
#[cfg(unix)]
fn state_event_line(state: State) -> String {
    event_line(Event::State {
        state: state.name().to_string(),
    })
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
            session: id.to_string(),
            kind: kind.clone(),
            label: label.clone(),
            name: name.clone(),
            slot,
            state: state.name().to_string(),
            backlogged: meta
                .get(crate::session::BACKLOGGED_META_KEY)
                .and_then(Value::as_bool)
                .unwrap_or(false),
            meta: external_meta(meta),
            connected: None,
            health: "unknown".into(),
            health_reason: None,
            attachment_id: None,
            attachment_type: None,
            last_activity_unix_ms: unix_ms_now(),
            last_verified_unix_ms: None,
            terminal_host: None,
        },
    })
}

/// JSON line for a `session-ended` event.
#[cfg(unix)]
fn session_ended_line(id: &str, slot: Option<u8>) -> String {
    event_line(Event::SessionEnded {
        session: id.to_string(),
        slot,
    })
}

/// JSON line for a `session-disconnected` event (PROTOCOL.md §3): a session
/// was reaped by a sweep rather than explicitly ended. Subscribers keep the
/// row but mark it disconnected (`connected: false`) rather than removing it
/// (as `session-ended` means) — it's still recoverable and shown until it's
/// explicitly ended, dismissed, recovered, or its tombstone TTL expires.
#[cfg(unix)]
fn session_disconnected_line(id: &str, slot: Option<u8>) -> String {
    event_line(Event::SessionDisconnected {
        session: id.to_string(),
        slot,
    })
}

/// JSON line for a `session-rekeyed` event (PROTOCOL.md §3): a `Compacting`
/// session was reunited with its post-compaction continuation under a new
/// id. Subscribers should relabel their existing record for `old_session`
/// in place (preserving name/history/stats) rather than treat it as an end
/// followed by a new registration.
#[cfg(unix)]
fn session_rekeyed_line(old_id: &str, new_id: &str) -> String {
    event_line(Event::SessionRekeyed {
        old_session: old_id.to_string(),
        new_session: new_id.to_string(),
    })
}

#[cfg(unix)]
fn managed_relaunch_event_line(
    session: &str,
    launch_id: &str,
    status: &str,
    tmux_server: Option<&str>,
    tmux_session: Option<&str>,
    error: Option<&str>,
) -> String {
    serde_json::json!({
        "event": "managed-relaunch",
        "session": session,
        "launch_id": launch_id,
        "status": status,
        "tmux_server": tmux_server,
        "tmux_session": tmux_session,
        "error": error,
    })
    .to_string()
}

#[cfg(unix)]
fn attention_order_event_line(sessions: &[String]) -> String {
    serde_json::json!({ "event": "attention-order", "sessions": sessions }).to_string()
}

/// JSON line for a provider-wide quota snapshot.
#[cfg(unix)]
fn usage_event_line(provider: &str, usage: &serde_json::Map<String, serde_json::Value>) -> String {
    event_line(Event::Usage {
        provider: provider.to_string(),
        usage: usage.clone(),
    })
}

/// JSON line for a `style` event (PROTOCOL.md §3).
#[cfg(unix)]
fn style_event_line(state: State, style: &Style) -> String {
    event_line(Event::Style {
        state: state.name().to_string(),
        rgb: style.rgb,
        pattern: style.pattern.name().to_string(),
        period_ms: style.period_ms,
    })
}

/// JSON object of all six styles, keyed by state name in id order (for the
/// `get-styles` response).
#[cfg(unix)]
fn styles_json(table: &StyleTable) -> StyleMap {
    let mut styles = Vec::new();
    for (state, style) in table.iter() {
        styles.push((
            state.name().to_string(),
            StyleDto {
                rgb: style.rgb,
                pattern: style.pattern.name().to_string(),
                period_ms: style.period_ms,
            },
        ));
    }
    StyleMap(styles)
}

/// The full set of device commands to (re)send on connect: all styles, the
/// aggregate `SET_STATE`, then all twelve slot states. Sending explicit empty
/// values is essential: firmware RAM survives a daemon reconnect, so replaying
/// occupied slots alone leaves any previously occupied key illuminated.
#[cfg(unix)]
fn replay_state_cmds(shared: &Mutex<Shared>) -> Vec<HostCmd> {
    let s = shared.lock().unwrap();
    let mut cmds = Vec::new();
    for (state, style) in s.styles.iter() {
        cmds.push(style.to_host_cmd(state));
    }
    cmds.push(HostCmd::SetState(s.registry.aggregate()));
    let slot_states: HashMap<u8, State> = s.registry.slot_states().into_iter().collect();
    for key in 1..=12 {
        cmds.push(HostCmd::SetKeyState {
            key,
            state: slot_states.get(&key).copied(),
        });
    }
    cmds.push(HostCmd::SetNavState(s.registry.navigation_states()));
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
) -> bool {
    let mut session_effect = false;
    for effect in effects {
        match effect {
            Effect::SlotCleared { slot } => {
                eprintln!("[session] clear vacated slot={slot}");
                let _ = host_tx.send(HostCmd::SetKeyState {
                    key: slot,
                    state: None,
                });
            }
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
                eprintln!(
                    "[session] upsert id={} slot={} state={} kind={} title={} task_id={} role={} pid={} tty={} mux_server={} mux_session={} mux_pane={} managed={} relaunch={}",
                    diagnostic_text(&id),
                    slot.map(|v| v.to_string()).unwrap_or_else(|| "-".into()),
                    state.name(),
                    kind.as_deref().map(diagnostic_text).unwrap_or_else(|| "-".into()),
                    label.as_deref().map(diagnostic_text).unwrap_or_else(|| "-".into()),
                    diagnostic_meta(&meta, "orchestrator_task_id"),
                    diagnostic_meta(&meta, "orchestration_role"),
                    diagnostic_meta(&meta, "pid"), diagnostic_meta(&meta, "tty"),
                    diagnostic_meta(&meta, "mux_server"), diagnostic_meta(&meta, "mux_session"),
                    diagnostic_meta(&meta, "mux_pane"), diagnostic_meta(&meta, "managed"),
                    diagnostic_meta(&meta, "relaunch_id"),
                );
                if let Some(key) = slot {
                    let _ = host_tx.send(HostCmd::SetKeyState {
                        key,
                        state: Some(state),
                    });
                }
                let authoritative = ctx
                    .shared
                    .lock()
                    .unwrap()
                    .registry
                    .session_or_tombstone(&id);
                if let Some(session) = authoritative {
                    ctx.broadcast(&event_line(Event::Session {
                        session: session_to_dto(&session, None),
                    }));
                } else {
                    ctx.broadcast(&session_event_line(
                        &id, &kind, &label, &name, &meta, slot, state,
                    ));
                }
            }
            Effect::SessionEnded { id, slot } => {
                session_effect = true;
                eprintln!(
                    "[session] end id={} slot={}",
                    diagnostic_text(&id),
                    slot.map(|v| v.to_string()).unwrap_or_else(|| "-".into())
                );
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
                eprintln!(
                    "[session] disconnect id={} slot={}",
                    diagnostic_text(&id),
                    slot.map(|v| v.to_string()).unwrap_or_else(|| "-".into())
                );
                if let Some(key) = slot {
                    let _ = host_tx.send(HostCmd::SetKeyState { key, state: None });
                }
                ctx.broadcast(&session_disconnected_line(&id, slot));
            }
            Effect::SessionHealthChanged { id, health, reason } => {
                session_effect = true;
                eprintln!(
                    "[probe] session={} health={} reason={}",
                    diagnostic_text(&id),
                    health.name(),
                    reason
                        .as_deref()
                        .map(diagnostic_text)
                        .unwrap_or_else(|| "-".into())
                );
                ctx.broadcast(&event_line(Event::SessionHealthChanged {
                    session: id,
                    health: health.name().to_string(),
                    reason,
                }));
            }
            Effect::SessionRekeyed { old_id, new_id } => {
                // No device command: the slot/state don't change here — the
                // SessionUpsert that immediately follows (Registry::set_state
                // always emits both together) carries those.
                session_effect = true;
                eprintln!(
                    "[session] rekey old={} new={}",
                    diagnostic_text(&old_id),
                    diagnostic_text(&new_id)
                );
                ctx.broadcast(&session_rekeyed_line(&old_id, &new_id));
            }
            Effect::ManagedRelaunchCompleted {
                old_id,
                new_id,
                launch_id,
                source_terminal,
            } => {
                session_effect = true;
                eprintln!("[managed-relaunch] complete session={new_id} launch_id={launch_id}");
                ctx.broadcast(&managed_relaunch_event_line(
                    &new_id, &launch_id, "complete", None, None, None,
                ));
                if let Some(endpoint) = source_terminal {
                    std::thread::spawn(move || {
                        match close_exact_terminal_endpoint(&endpoint) {
                        Ok(()) => eprintln!("[managed-relaunch] source-cleanup old_session={} result=closed", diagnostic_text(&old_id)),
                        Err(reason) => eprintln!("[managed-relaunch] source-cleanup old_session={} result=left-open reason={}", diagnostic_text(&old_id), diagnostic_text(&reason)),
                    }
                    });
                }
            }
            Effect::AttentionOrderChanged { sessions } => {
                session_effect = true;
                eprintln!("[attention] order={}", sessions.join(","));
                ctx.broadcast(&attention_order_event_line(&sessions));
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
    let _ = host_tx.send(HostCmd::SetNavState(
        ctx.shared.lock().unwrap().registry.navigation_states(),
    ));
    session_effect
}

/// `Session` -> the JSON shape both `"list-sessions"` and the persisted
/// snapshot use (PROTOCOL.md §3) — one place so they can't drift apart.
/// External-facing session shape (`list-sessions`, `session` events): strips
/// both carry-forward bookkeeping and the daemon-private transcript path.
#[cfg(unix)]
fn session_to_dto(s: &Session, connected: Option<bool>) -> SessionDto {
    let meta = external_meta(&s.meta);
    let now = Instant::now();
    let wall = unix_ms_now();
    let instant_to_unix_ms = |instant: Instant| {
        wall.saturating_sub(now.saturating_duration_since(instant).as_millis() as u64)
    };
    let endpoint: Option<&TerminalEndpoint> = match s.attachment.as_ref() {
        Some(Attachment::Process { terminal, .. } | Attachment::Managed { terminal, .. }) => {
            Some(terminal)
        }
        _ => None,
    };
    SessionDto {
        session: s.id.clone(),
        kind: s.kind.clone(),
        label: s.label.clone(),
        name: s.name.clone(),
        // A numbered slot represents a currently authoritative runtime.
        // Tombstones retain their previous slot privately in `slot_history`
        // for exact re-registration, but disconnected/unverified DTOs must
        // render slotless so clients cannot route focus to stale endpoints.
        slot: if connected == Some(false) || !s.has_authoritative_attachment() {
            None
        } else {
            s.slot
        },
        state: s.state.name().to_string(),
        backlogged: s.is_backlogged(),
        meta,
        connected: connected.or(Some(s.health != SessionHealth::Detached)),
        health: s.health.name().to_string(),
        health_reason: s.health_reason.clone(),
        attachment_id: s.attachment_id().map(str::to_string),
        attachment_type: s.attachment_type().map(str::to_string),
        last_activity_unix_ms: instant_to_unix_ms(s.last_update),
        last_verified_unix_ms: s.last_verified.map(instant_to_unix_ms),
        terminal_host: endpoint.map(|value| TerminalHostDto {
            bundle_id: value.bundle_id.clone(),
            application_pid: value.application_pid,
            window_id: value.window_id.clone(),
            session_id: value.session_id.clone(),
            host_tty: value.host_tty.clone(),
        }),
    }
}

fn public_meta(meta: &Map<String, Value>) -> Map<String, Value> {
    meta.iter()
        .filter(|(key, _)| {
            !key.starts_with('_')
                && key.as_str() != crate::session::BACKLOGGED_META_KEY
                && !key.starts_with("terminal_")
                && key.as_str() != "mux_client_tty"
                && key.as_str() != "mux_socket"
                && !matches!(
                    key.as_str(),
                    "attachment_registration"
                        | "process_boot_time"
                        | "process_start_time"
                        | "provider_executable"
                        | "terminal_application_pid"
                )
        })
        .map(|(key, value)| (key.clone(), value.clone()))
        .collect()
}

/// `public_meta` plus stripping `transcript_path`, which stays out of every
/// client-visible shape (events, `list-sessions`) even though it persists in
/// the internal snapshot for restart-safe bounded transcript reads.
fn external_meta(meta: &Map<String, Value>) -> Map<String, Value> {
    let mut meta = public_meta(meta);
    meta.remove("transcript_path");
    meta
}

/// `Session` -> the JSON shape the persisted snapshot uses (PROTOCOL.md §3
/// plus the daemon-private `transcript_path`, which the snapshot must keep so
/// a restart doesn't break `read-session-transcript`). Not used for any
/// client-visible shape — those go through `session_to_dto`/`external_meta`.
#[cfg(unix)]
fn session_to_json(s: &Session) -> Value {
    serde_json::json!({
        "session": s.id,
        "kind": s.kind,
        "label": s.label,
        "name": s.name,
        "slot": s.slot,
        "state": s.state.name(),
        "backlogged": s.is_backlogged(),
        "meta": public_meta(&s.meta),
        "carry": s.carry,
        "health": s.health.name(),
        "health_reason": s.health_reason,
        "attachment": s.attachment,
        "slot_history": s.slot_history,
        "last_verified_elapsed_ms": s.last_verified.map(|instant| Instant::now().saturating_duration_since(instant).as_millis() as u64),
    })
}

/// The inverse of `session_to_json`, given the `Instant` to use for
/// `last_update`/`reaped_at` (reconstructed by the caller — see
/// `restore_instant`). `None` on any malformed/missing required field.
#[cfg(unix)]
fn session_from_json(v: &serde_json::Value, last_update: Instant, live: bool) -> Option<Session> {
    let id = v.get("session")?.as_str()?.to_string();
    let state = crate::protocol::State::from_name(v.get("state")?.as_str()?)?;
    let mut meta = v
        .get("meta")
        .and_then(|m| m.as_object())
        .cloned()
        .unwrap_or_default();
    let backlogged = v
        .get("backlogged")
        .and_then(Value::as_bool)
        .unwrap_or(false);
    if backlogged {
        meta.insert(
            crate::session::BACKLOGGED_META_KEY.into(),
            Value::Bool(true),
        );
    }
    // Read snapshots written before carry-forward data was made internal, but
    // never expose those legacy keys again.
    let mut carry = v
        .get("carry")
        .and_then(|c| c.as_object())
        .cloned()
        .unwrap_or_default();
    for key in [
        "turns",
        "tool_calls",
        "subagents",
        "tokens_in",
        "tokens_out",
        "cost_usd",
    ] {
        if let Some(value) = meta.remove(&format!("_carry_{key}")) {
            carry.entry(key.to_string()).or_insert(value);
        }
    }
    let persisted_attachment: Option<Attachment> = v
        .get("attachment")
        .cloned()
        .and_then(|value| serde_json::from_value(value).ok());
    let persisted_health = v
        .get("health")
        .and_then(Value::as_str)
        .and_then(|value| match value {
            "healthy" => Some(SessionHealth::Healthy),
            "suspect" => Some(SessionHealth::Suspect),
            "unknown" => Some(SessionHealth::Unknown),
            "detached" => Some(SessionHealth::Detached),
            _ => None,
        });
    // Snapshot migration: pre-attachment live rows had `attachment: null`.
    // Represent them explicitly as unverified; Registry::restore immediately
    // releases their stale numbered slots while retaining slot history.
    // Tombstones stay detached with no attachment.
    let migrated_unverified =
        live && persisted_attachment.is_none() && persisted_health != Some(SessionHealth::Detached);
    let attachment = persisted_attachment.or_else(|| {
        migrated_unverified.then(|| Attachment::Unverified {
            id: format!(
                "unverified:restored:{}",
                id.chars()
                    .filter(|ch| !ch.is_control())
                    .take(160)
                    .collect::<String>()
            ),
        })
    });
    let health = persisted_health.unwrap_or(if attachment.is_some() {
        SessionHealth::Suspect
    } else {
        SessionHealth::Unknown
    });
    Some(Session {
        id,
        kind: v.get("kind").and_then(|x| x.as_str()).map(str::to_string),
        label: v.get("label").and_then(|x| x.as_str()).map(str::to_string),
        name: v.get("name").and_then(|x| x.as_str()).map(str::to_string),
        meta,
        carry,
        slot: if backlogged {
            None
        } else {
            v.get("slot").and_then(|x| x.as_u64()).map(|n| n as u8)
        },
        state,
        last_update,
        attachment,
        health,
        health_reason: v
            .get("health_reason")
            .and_then(Value::as_str)
            .map(str::to_string)
            .or_else(|| {
                migrated_unverified
                    .then(|| "restored integration awaiting authoritative ownership".into())
            }),
        last_verified: v
            .get("last_verified_elapsed_ms")
            .and_then(Value::as_u64)
            .and_then(|elapsed| Instant::now().checked_sub(Duration::from_millis(elapsed))),
        failed_probes: 0,
        first_probe_failure: None,
        slot_history: v
            .get("slot_history")
            .and_then(Value::as_array)
            .map(|values| {
                values
                    .iter()
                    .filter_map(Value::as_u64)
                    .filter_map(|v| u8::try_from(v).ok())
                    .collect()
            })
            .unwrap_or_default(),
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

#[cfg(unix)]
fn reconcile_opening_launch_receipts() {
    let directory = crate::paths::daemon_state_dir().join("launches");
    let Ok(entries) = std::fs::read_dir(directory) else {
        return;
    };
    for entry in entries.flatten() {
        let path = entry.path();
        let Ok(data) = std::fs::read(&path) else {
            continue;
        };
        let Ok(mut receipt) = serde_json::from_slice::<Value>(&data) else {
            continue;
        };
        if receipt.get("status").and_then(Value::as_str) != Some("opening") {
            continue;
        }
        receipt["status"] = Value::String("needs-user-retry".into());
        if let Ok(data) = serde_json::to_vec_pretty(&receipt) {
            let temporary = path.with_extension(format!("json.{}.tmp", std::process::id()));
            if std::fs::write(&temporary, data).is_ok() {
                let _ = std::fs::rename(temporary, path);
            }
        }
    }
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
    Instant::now()
        .checked_sub(total)
        .unwrap_or_else(Instant::now)
}

/// Persist the full current session/tombstone/usage state (Part 4) —
/// called after any session-affecting `Effect` (`apply_effects`) and after
/// a successful `set-usage`. The sibling-temp + rename replacement keeps the
/// last complete document intact if serialization or writing fails. Failure
/// is non-fatal (live in-memory state remains authoritative) but is logged.
#[cfg(unix)]
fn save_snapshot(shared: &Mutex<Shared>) {
    let now = Instant::now();
    let (sessions, tombstones, usage, attention_order, channels) = {
        let s = shared.lock().unwrap();
        let sessions: Vec<serde_json::Value> = s
            .registry
            .list()
            .iter()
            .map(|sess| {
                let mut v = session_to_json(sess);
                v["carry"] = serde_json::json!(sess.carry);
                v["elapsed_ms_since_update"] = serde_json::json!(now
                    .saturating_duration_since(sess.last_update)
                    .as_millis()
                    as u64);
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
                v["elapsed_ms_since_reaped"] =
                    serde_json::json!(now.saturating_duration_since(*reaped_at).as_millis() as u64);
                v
            })
            .collect();
        (
            sessions,
            tombstones,
            s.usage.clone(),
            s.registry.attention_order_override(),
            s.channels.clone(),
        )
    };
    let snapshot = serde_json::json!({
        "saved_at_unix_ms": unix_ms_now(),
        "sessions": sessions,
        "tombstones": tombstones,
        "usage": usage,
        "attention_order": attention_order,
        "channels": channels,
    });
    let path = crate::paths::daemon_state_path();
    if let Some(parent) = path.parent() {
        let _ = std::fs::create_dir_all(parent);
    }
    let Ok(data) = serde_json::to_vec(&snapshot) else {
        return;
    };
    let tmp = path.with_extension(format!("json.tmp.{}", std::process::id()));
    let result = (|| -> std::io::Result<()> {
        let mut file = OpenOptions::new()
            .create(true)
            .truncate(true)
            .write(true)
            .open(&tmp)?;
        file.write_all(&data)?;
        drop(file);
        std::fs::rename(&tmp, &path)?;
        Ok(())
    })();
    if let Err(error) = result {
        let _ = std::fs::remove_file(&tmp);
        eprintln!("[snapshot] failed to persist {}: {error}", path.display());
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
    Channels,
) {
    let empty = || {
        (
            Registry::new(ttl).with_tombstone_ttl(tombstone_ttl),
            HashMap::new(),
            Channels::default(),
        )
    };
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
            session_from_json(v, restore_instant(saved_at_unix_ms, elapsed), true)
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
            let sess = session_from_json(v, reaped_at, false)?;
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

    let attention_order = root
        .get("attention_order")
        .and_then(|value| value.as_array())
        .map(|values| {
            values
                .iter()
                .filter_map(|value| value.as_str().map(str::to_string))
                .collect::<Vec<_>>()
        });
    let mut registry = Registry::restore(ttl, tombstone_ttl, sessions, tombstones);
    registry.restore_attention_order(attention_order);
    let channels = root
        .get("channels")
        .cloned()
        .and_then(|value| serde_json::from_value(value).ok())
        .unwrap_or_default();
    (registry, usage, channels)
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
fn reconcile_on_startup(shared: &Mutex<Shared>, attachment_probe_grace: Duration) {
    let now = Instant::now();
    let sessions = shared.lock().unwrap().registry.list();
    let probes = probe_runtime_attachments(&sessions);
    let mut s = shared.lock().unwrap();
    for (id, verified, reason, immediate) in probes {
        // Startup must reconcile before clients can observe the snapshot. A
        // definitive mismatch detaches immediately; a transient miss begins
        // the normal debounce and remains suspect.
        s.registry.note_attachment_probe(
            &id,
            verified,
            reason,
            immediate,
            attachment_probe_grace,
            now,
        );
    }
}

#[cfg(unix)]
fn probe_runtime_attachments(sessions: &[Session]) -> Vec<(String, bool, Option<String>, bool)> {
    let mut managed: HashMap<(String, Option<String>), Vec<(String, String, String, String)>> =
        HashMap::new();
    let mut results = Vec::new();
    for session in sessions {
        match session.attachment.as_ref() {
            Some(Attachment::Process {
                boot_time,
                pid,
                process_start_time,
                executable,
                pane_tty,
                ..
            }) => {
                let current_boot = sysinfo::System::boot_time();
                if current_boot != *boot_time {
                    results.push((
                        session.id.clone(),
                        false,
                        Some("system boot identity changed".into()),
                        true,
                    ));
                    continue;
                }
                let sys_pid = sysinfo::Pid::from_u32(*pid as u32);
                let mut system = sysinfo::System::new();
                system.refresh_processes(sysinfo::ProcessesToUpdate::Some(&[sys_pid]), true);
                let Some(process) = system.process(sys_pid) else {
                    results.push((
                        session.id.clone(),
                        false,
                        Some("provider process is absent".into()),
                        false,
                    ));
                    continue;
                };
                if process.start_time() != *process_start_time {
                    results.push((
                        session.id.clone(),
                        false,
                        Some("provider PID birth time changed".into()),
                        true,
                    ));
                    continue;
                }
                // macOS can temporarily withhold an executable path from a
                // launchd process (notably on managed/corporate laptops).
                // Absence is inconclusive; only a concrete different path
                // proves this PID fingerprint belongs to another runtime.
                if process
                    .exe()
                    .is_some_and(|path| path.to_string_lossy() != executable.as_str())
                {
                    results.push((
                        session.id.clone(),
                        false,
                        Some("provider executable changed".into()),
                        true,
                    ));
                    continue;
                }
                if let Some(expected_tty) = pane_tty {
                    // The same permission boundary can make `ps` return no
                    // tty. Treat that as inconclusive after the exact
                    // boot/PID-birth checks above; only a concrete mismatch
                    // counts as a failed ownership probe.
                    if crate::identity::tty_for_pid(*pid)
                        .is_some_and(|observed| observed != *expected_tty)
                    {
                        results.push((
                            session.id.clone(),
                            false,
                            Some("provider controlling tty changed".into()),
                            false,
                        ));
                        continue;
                    }
                }
                results.push((session.id.clone(), true, None, false));
            }
            Some(Attachment::Managed {
                mux_server,
                mux_socket,
                mux_session,
                mux_pane,
                pane_tty,
                ..
            }) => {
                managed
                    .entry((mux_server.clone(), mux_socket.clone()))
                    .or_default()
                    .push((
                        session.id.clone(),
                        mux_session.clone(),
                        mux_pane.clone(),
                        pane_tty.clone(),
                    ));
            }
            Some(Attachment::Unverified { .. }) | None => {}
        }
    }
    for ((server, socket), expected) in managed {
        let output = executable_named("tmux").and_then(|tmux| {
            let mut command = Command::new(tmux);
            if let Some(socket) = socket.as_deref().filter(|value| !value.is_empty()) {
                command.args(["-S", socket]);
            } else {
                command.args(["-L", &server]);
            }
            command
                .args([
                    "list-panes",
                    "-a",
                    "-F",
                    "#{session_name}|#{pane_id}|#{pane_tty}",
                ])
                .output()
                .ok()
        });
        let observed = output
            .filter(|output| output.status.success())
            .and_then(|output| String::from_utf8(output.stdout).ok())
            .unwrap_or_default();
        for (id, session, pane, tty) in expected {
            let exact = observed
                .lines()
                .any(|line| line == format!("{session}|{pane}|{tty}"));
            results.push((
                id,
                exact,
                (!exact).then(|| "managed tmux pane ownership is unavailable".into()),
                false,
            ));
        }
    }
    results
}

/// Run the focus action for `session` (PROTOCOL.md §3 Focus), exposing the
/// session via `FOCALPOINT_SESSION_*` env vars (empty string for missing values).
#[cfg(unix)]
fn focus_environment(session: &crate::session::Session, slot: u8) -> Vec<(&'static str, String)> {
    let meta_text = |key: &str| {
        session
            .meta
            .get(key)
            .and_then(serde_json::Value::as_str)
            .unwrap_or_default()
            .to_string()
    };
    vec![
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
        ("FOCALPOINT_SESSION_MUX_SERVER", meta_text("mux_server")),
        ("FOCALPOINT_SESSION_MUX_SESSION", meta_text("mux_session")),
        ("FOCALPOINT_SESSION_MUX_PANE", meta_text("mux_pane")),
        (
            "FOCALPOINT_TERMINAL_BUNDLE_ID",
            meta_text("terminal_bundle_id"),
        ),
        (
            "FOCALPOINT_TERMINAL_APPLICATION_PID",
            session
                .meta
                .get("terminal_application_pid")
                .and_then(Value::as_i64)
                .map(|value| value.to_string())
                .unwrap_or_default(),
        ),
        (
            "FOCALPOINT_TERMINAL_WINDOW_ID",
            meta_text("terminal_window_id"),
        ),
        (
            "FOCALPOINT_TERMINAL_SESSION_ID",
            meta_text("terminal_session_id"),
        ),
        (
            "FOCALPOINT_TERMINAL_HOST_TTY",
            meta_text("terminal_host_tty"),
        ),
        ("FOCALPOINT_SLOT", slot.to_string()),
    ]
}

#[cfg(unix)]
fn run_focus(ctx: &EventCtx, session: &crate::session::Session, slot: u8) {
    let focus = ctx.config.session.focus.clone().unwrap_or(Action::None);
    eprintln!(
        "[focus] id={} slot={} state={} pid={} tty={} mux_server={} mux_session={} mux_pane={} managed={}",
        diagnostic_text(&session.id),
        slot,
        session.state.name(),
        diagnostic_meta(&session.meta, "pid"),
        diagnostic_meta(&session.meta, "tty"),
        diagnostic_meta(&session.meta, "mux_server"),
        diagnostic_meta(&session.meta, "mux_session"),
        diagnostic_meta(&session.meta, "mux_pane"),
        diagnostic_meta(&session.meta, "managed"),
    );
    let (terminal_pid, terminal_session_id) = match session.attachment.as_ref() {
        Some(Attachment::Process { terminal, .. } | Attachment::Managed { terminal, .. }) => {
            (terminal.application_pid, terminal.session_id.clone())
        }
        _ => (None, None),
    };
    let strategy = match session.attachment.as_ref() {
        Some(Attachment::Managed { .. }) => "managed-tmux",
        Some(Attachment::Process { terminal, .. }) if terminal.session_id.is_some() => {
            "terminal-session-id"
        }
        Some(Attachment::Process { .. }) => "terminal-tty",
        _ => "none",
    }
    .to_string();
    let attachment_id = session.attachment_id().map(str::to_string);
    let preflight_reason = if session.attachment.is_none() {
        Some("session has no runtime attachment".to_string())
    } else if session.health == SessionHealth::Detached {
        Some("runtime attachment is stale".to_string())
    } else {
        None
    };
    let outcome = if let Some(reason) = preflight_reason {
        Err(reason)
    } else {
        let env = focus_environment(session, slot);
        crate::actions::run_with_env_status(&focus, &env)
    };
    let (result, reason) = match outcome {
        Ok(()) => {
            ctx.broadcast(&event_line(Event::Focus {
                session: session.id.clone(),
            }));
            ("focused".to_string(), None)
        }
        Err(reason) if session.health == SessionHealth::Detached => {
            ("attachment-stale".to_string(), Some(reason))
        }
        Err(reason) => ("endpoint-missing".to_string(), Some(reason)),
    };
    ctx.broadcast(&event_line(Event::FocusResult {
        session: session.id.clone(),
        slot: (slot != 0).then_some(slot),
        attachment_id,
        strategy,
        result,
        terminal_pid,
        terminal_session_id,
        reason,
    }));
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
            let line = event_line(Event::Key {
                control: name.clone(),
                pressed,
            });
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
                        Some(session) => {
                            let ctx = ctx.clone();
                            std::thread::spawn(move || run_focus(&ctx, &session, slot));
                        }
                        None => crate::actions::run(&ctx.config.action_for(&name)),
                    }
                } else if (17..=20).contains(&control) {
                    let (session, navigation_states) = {
                        let _transition = ctx.transition.lock().unwrap();
                        let mut shared = ctx.shared.lock().unwrap();
                        let session = match control {
                            17 => shared.registry.next_attention(),
                            18 => shared.registry.previous_attention(),
                            19 => shared.registry.next_session(),
                            20 => shared.registry.previous_session(),
                            _ => unreachable!(),
                        };
                        let navigation = shared.registry.navigation_states();
                        (session, navigation)
                    };
                    if let Some(session) = session {
                        let ctx = ctx.clone();
                        let slot = session.slot.unwrap_or(0);
                        std::thread::spawn(move || run_focus(&ctx, &session, slot));
                    }
                    let _ = ctx.host_tx.send(HostCmd::SetNavState(navigation_states));
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
            let line = event_line(Event::Joy {
                gesture: name.to_string(),
            });
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
                // state — all styles, the aggregate, and all twelve slots
                // (including explicit empty values).
                let _ = hid_write(&device, HostCmd::SetHostMode(true).encode());
                let replay = replay_state_cmds(&ctx.shared);
                let occupied = replay
                    .iter()
                    .filter(|cmd| matches!(cmd, HostCmd::SetKeyState { state: Some(_), .. }))
                    .count();
                eprintln!(
                    "[device] replaying {} commands; key_slots=12 occupied={} empty={}",
                    replay.len(),
                    occupied,
                    12 - occupied
                );
                for cmd in replay {
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
        Ok(written) if written == framed.len() => Ok(()),
        Ok(written) => {
            eprintln!(
                "[device] short write: wrote {written} of {} report bytes",
                framed.len()
            );
            Err(())
        }
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
    // all styles, aggregate, and all twelve slots including explicit empties).
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
        HostCmd::SetNavState(states) => eprintln!(
            "[mock] LED <- SET_NAV_STATE attention_next={} attention_previous={} session_next={} session_previous={}",
            states.attention_next.map(State::name).unwrap_or("empty"),
            states.attention_previous.map(State::name).unwrap_or("empty"),
            states.session_next.map(State::name).unwrap_or("empty"),
            states.session_previous.map(State::name).unwrap_or("empty"),
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
    reconcile_opening_launch_receipts();
    let tombstone_ttl = config.session.tombstone_ttl();
    let unverified_ttl = config.session.unverified_ttl();
    let attachment_probe_grace = config.session.attachment_probe_grace();
    // Restore sessions/tombstones/usage from the last run (Part 4) instead
    // of always starting fresh — a daemon restart shouldn't blank
    // `focalpoint sessions`/`focalpoint usage` until adapters naturally
    // re-report. Missing/corrupt snapshot: silently empty, same as before
    // this feature existed.
    let (registry, usage, channels) = load_snapshot(None, tombstone_ttl);
    let shared = Arc::new(Mutex::new(Shared {
        registry,
        usage,
        styles: config.style_table(),
        channels,
        channel_wake_last: HashMap::new(),
        device_present: false,
    }));
    // One-shot reconciliation against live OS facts, before anything else
    // can see the restored state: a session that actually died while the
    // daemon was down must not resurrect as a zombie, just become a
    // recoverable tombstone like any other non-explicit disappearance.
    reconcile_on_startup(&shared, attachment_probe_grace);
    let (evt_tx, _keep) = tokio::sync::broadcast::channel::<String>(256);
    let (host_tx, host_rx) = tokio::sync::mpsc::unbounded_channel::<HostCmd>();

    // Shared event/action context, used by both the device thread and the
    // socket handlers (so injected events take the same dispatch path).
    let ctx = EventCtx {
        evt_tx: evt_tx.clone(),
        config: config.clone(),
        shared: shared.clone(),
        host_tx: host_tx.clone(),
        transition: Arc::new(Mutex::new(())),
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
                let _transition = ctx.transition.lock().unwrap();
                let (effects, expired_launches) = {
                    let mut shared = ctx.shared.lock().unwrap();
                    let now = Instant::now();
                    (
                        shared.registry.expire_tombstones(now),
                        shared
                            .registry
                            .expire_managed_launches(now, Duration::from_secs(120)),
                    )
                };
                for (task_id, slot) in expired_launches {
                    eprintln!(
                        "[managed-launch] registration-timeout task_id={} slot={} reservation_released=true",
                        diagnostic_text(&task_id),
                        slot.map(|value| value.to_string()).unwrap_or_else(|| "overflow".into()),
                    );
                }
                if !effects.is_empty() {
                    apply_effects(effects, &ctx, &host_tx);
                }
            }
        });
    }

    // Attachment health is probed independently of adapter activity. Process
    // fingerprints and private tmux ownership are authoritative; ordinary
    // failures require two observations spanning the configured grace.
    {
        let ctx = ctx.clone();
        let host_tx = host_tx.clone();
        tokio::spawn(async move {
            let mut tick = tokio::time::interval(std::time::Duration::from_secs(15));
            loop {
                tick.tick().await;
                let sessions = ctx.shared.lock().unwrap().registry.list();
                let probes = probe_runtime_attachments(&sessions);
                let _transition = ctx.transition.lock().unwrap();
                let effects: Vec<Effect> = {
                    let mut shared = ctx.shared.lock().unwrap();
                    let now = Instant::now();
                    let mut effects: Vec<Effect> = probes
                        .into_iter()
                        .flat_map(|(id, ok, reason, immediate)| {
                            shared.registry.note_attachment_probe(
                                &id,
                                ok,
                                reason,
                                immediate,
                                attachment_probe_grace,
                                now,
                            )
                        })
                        .collect();
                    effects.extend(
                        shared
                            .registry
                            .expire_unverified_attachments(now, unverified_ttl),
                    );
                    effects
                };
                if !effects.is_empty() {
                    apply_effects(effects, &ctx, &host_tx);
                }
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
    let listener =
        UnixListener::bind(&path).map_err(|e| format!("failed to bind {}: {e}", path.display()))?;
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
                // change can slip between the two. Begin/end markers make this
                // an authoritative replacement snapshot for clients, including
                // disconnected tombstones that used to require a racing
                // `list-sessions` side request.
                let mut rx = ctx.evt_tx.subscribe();
                let generation = SNAPSHOT_SEQUENCE.fetch_add(1, Ordering::Relaxed);
                let (aggregate, sessions, tombstones, attention_order, usage, styles) = {
                    let s = shared.lock().unwrap();
                    (
                        s.registry.aggregate(),
                        s.registry.list(),
                        s.registry.tombstones_snapshot(),
                        s.registry.attention_order(),
                        s.usage.clone(),
                        s.styles,
                    )
                };
                let mut snapshot = event_line(Event::SnapshotBegin { generation });
                snapshot.push('\n');
                snapshot.push_str(&state_event_line(aggregate));
                for sess in &sessions {
                    snapshot.push('\n');
                    snapshot.push_str(&event_line(Event::Session {
                        session: session_to_dto(sess, Some(true)),
                    }));
                }
                for (_, sess, _) in &tombstones {
                    snapshot.push('\n');
                    snapshot.push_str(&event_line(Event::Session {
                        session: session_to_dto(sess, Some(false)),
                    }));
                }
                snapshot.push('\n');
                snapshot.push_str(&attention_order_event_line(&attention_order));
                for (provider, usage_snapshot) in usage {
                    snapshot.push('\n');
                    snapshot.push_str(&usage_event_line(&provider, &usage_snapshot));
                }
                for (state, style) in styles.iter() {
                    snapshot.push('\n');
                    snapshot.push_str(&style_event_line(state, &style));
                }
                snapshot.push('\n');
                snapshot.push_str(&event_line(Event::SnapshotEnd { generation }));
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
                        Err(tokio::sync::broadcast::error::RecvError::Lagged(missed)) => {
                            // Continuing would leave the client permanently
                            // inconsistent: there is no way to reconstruct the
                            // missed mutations from later deltas. Closing makes
                            // auto-reconnecting clients consume a fresh,
                            // authoritative snapshot.
                            eprintln!("[subscribe] receiver lagged by {missed} events; resyncing");
                            return;
                        }
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
        Request::SetState {
            state: name,
            session,
            kind,
            mut label,
            mut meta,
        } => {
            let _transition = ctx.transition.lock().unwrap();
            if session.is_some()
                && matches!(
                    kind.as_deref(),
                    Some("claude" | "codex" | "cursor" | "cursor-cli")
                )
            {
                let fields = meta.get_or_insert_with(Map::new);
                correlate_pending_managed_launch(
                    &shared.lock().unwrap().registry,
                    kind.as_deref(),
                    fields,
                );
                if let Some(authoritative_title) =
                    fields.get("session_title").and_then(Value::as_str)
                {
                    label = Some(authoritative_title.to_string());
                }
            }
            let state = match State::from_name(&name) {
                Some(s) => s,
                None => return err(&format!("unknown state: {name:?}")),
            };
            if let Some(id) = session.as_deref() {
                let empty = serde_json::Map::new();
                let fields = meta.as_ref().unwrap_or(&empty);
                eprintln!(
                    "[session-input] cmd=set-state id={} state={} task_id={} requested_slot={} pid={} tty={} mux_server={} mux_session={} mux_pane={} managed={} relaunch={} reregistered={}",
                    diagnostic_text(id), state.name(),
                    diagnostic_meta(fields, "orchestrator_task_id"),
                    diagnostic_meta(fields, "requested_slot"),
                    diagnostic_meta(fields, "pid"), diagnostic_meta(fields, "tty"),
                    diagnostic_meta(fields, "mux_server"), diagnostic_meta(fields, "mux_session"),
                    diagnostic_meta(fields, "mux_pane"), diagnostic_meta(fields, "managed"),
                    diagnostic_meta(fields, "relaunch_id"), diagnostic_meta(fields, "reregistered"),
                );
            }
            let (effects, channel_changed) = {
                let mut shared = shared.lock().unwrap();
                let effects = shared.registry.set_state(
                    session.as_deref(),
                    state,
                    kind,
                    label,
                    meta.clone(),
                    Instant::now(),
                );
                // Use the registry's merged, authoritatively attached
                // identity, never the request's self-asserted metadata.
                let identity = session
                    .as_deref()
                    .and_then(|id| managed_channel_identity(&shared.registry, id));
                let mut channel_changed = false;
                if let Some(identity) = identity {
                    if let Some(channel_id) = identity
                        .meta
                        .get("channel_id")
                        .and_then(serde_json::Value::as_str)
                    {
                        channel_changed = true;
                        if let Some(channel) = shared.channels.channels.get_mut(channel_id) {
                            match join_managed_channel(channel, &identity.id, &identity.meta) {
                                Ok(joined) => {
                                    post_managed_channel_lifecycle(
                                        channel,
                                        &identity.id,
                                        &identity.meta,
                                        state,
                                        joined,
                                    );
                                }
                                Err(message) => eprintln!(
                                    "[channel] registration-rejected channel={} session={} error={}",
                                    diagnostic_text(channel_id), diagnostic_text(&identity.id),
                                    diagnostic_text(&message),
                                ),
                            }
                        }
                    }
                }
                (effects, channel_changed)
            };
            if !apply_effects(effects, ctx, host_tx) && channel_changed {
                save_snapshot(shared);
            }
            ok()
        }
        Request::SetMeta {
            session,
            kind,
            label,
            meta,
        } => {
            let _transition = ctx.transition.lock().unwrap();
            let joining_channel = meta
                .get("channel_id")
                .and_then(serde_json::Value::as_str)
                .map(str::to_string);
            eprintln!(
                "[session-input] cmd=set-meta id={} task_id={} requested_slot={} pid={} tty={} mux_server={} mux_session={} mux_pane={} managed={} relaunch={} reregistered={}",
                diagnostic_text(&session),
                diagnostic_meta(&meta, "orchestrator_task_id"),
                diagnostic_meta(&meta, "requested_slot"),
                diagnostic_meta(&meta, "pid"),
                diagnostic_meta(&meta, "tty"),
                diagnostic_meta(&meta, "mux_server"),
                diagnostic_meta(&meta, "mux_session"),
                diagnostic_meta(&meta, "mux_pane"),
                diagnostic_meta(&meta, "managed"),
                diagnostic_meta(&meta, "relaunch_id"),
                diagnostic_meta(&meta, "reregistered"),
            );
            // Unknown sessions are a silent no-op (never registers one) —
            // see `Registry::merge_meta`.
            let (effects, channel_changed) = {
                let mut shared = shared.lock().unwrap();
                let effects =
                    shared
                        .registry
                        .merge_meta(&session, kind, label, meta.clone(), Instant::now());
                let identity = managed_channel_identity(&shared.registry, &session);
                let mut channel_changed = false;
                if let (Some(channel_id), Some(identity)) =
                    (joining_channel.as_deref(), identity)
                {
                    channel_changed = true;
                    if let Some(channel) = shared.channels.channels.get_mut(channel_id) {
                        match join_managed_channel(channel, &session, &identity.meta) {
                            Ok(joined) => {
                                if joined {
                                    post_managed_channel_lifecycle(
                                        channel,
                                        &session,
                                        &identity.meta,
                                        identity.state,
                                        true,
                                    );
                                }
                            }
                            Err(message) => eprintln!(
                                "[channel] registration-rejected channel={} session={} error={}",
                                diagnostic_text(channel_id), diagnostic_text(&session),
                                diagnostic_text(&message),
                            ),
                        }
                    }
                }
                (effects, channel_changed)
            };
            if !apply_effects(effects, ctx, host_tx) && channel_changed {
                save_snapshot(shared);
            }
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
            let mut arr: Vec<SessionDto> = sessions
                .iter()
                .map(|s| session_to_dto(s, Some(true)))
                .collect();
            for (_id, sess, _reaped_at) in &tombstones {
                arr.push(session_to_dto(sess, Some(false)));
            }
            Dispatch::Reply(Response::Sessions {
                ok: true,
                sessions: arr,
            })
        }
        Request::GetCapabilities => Dispatch::Reply(Response::Json(serde_json::json!({
            "ok": true,
            "protocol": {"major": crate::protocol::PROTO_MAJOR, "minor": crate::protocol::PROTO_MINOR},
            "features": {
                "managed_launch": true,
                "explicit_launch_identity": true,
                "confirmed_stop": true,
                "workflow_observation": true,
                "workflow_assignment_ledger": true,
                "workflow_gate_approval": true,
                "history_storage": "client",
                "diagnostics": true,
                "triage_metadata": true
            }
        }))),
        Request::GetDiagnostics => {
            let state = shared.lock().unwrap();
            let live = state.registry.list();
            let disconnected = state.registry.tombstones_snapshot();
            let suspect = live
                .iter()
                .filter(|session| session.health != SessionHealth::Healthy)
                .count();
            Dispatch::Reply(Response::Json(serde_json::json!({
                "ok": true,
                "daemon": "reachable",
                "device_present": state.device_present,
                "live_sessions": live.len(),
                "disconnected_sessions": disconnected.len(),
                "sessions_needing_diagnostics": suspect,
                "provider_usage_sources": state.usage.len(),
                "open_channels": state.channels.channels.len(),
                "checked_at_unix_ms": unix_ms_now()
            })))
        }
        Request::ListWorkflowRuns => {
            let state = shared.lock().unwrap();
            let mut runs: serde_json::Map<String, Value> = serde_json::Map::new();
            for (session, connected) in state
                .registry
                .list()
                .into_iter()
                .map(|session| (session, true))
                .chain(
                    state
                        .registry
                        .tombstones_snapshot()
                        .into_iter()
                        .map(|(_, session, _)| (session, false)),
                )
            {
                let Some(run_id) = session.meta.get("workflow_run_id").and_then(Value::as_str)
                else {
                    continue;
                };
                let entry = runs.entry(run_id.to_string()).or_insert_with(|| {
                    serde_json::json!({
                        "run_id": run_id,
                        "workflow_id": session.meta.get("workflow_id"),
                        "sessions": []
                    })
                });
                if let Some(sessions) = entry.get_mut("sessions").and_then(Value::as_array_mut) {
                    sessions.push(serde_json::json!({
                        "session": session.id,
                        "task_id": session.meta.get("orchestrator_task_id"),
                        "agent_type": session.meta.get("agent_type"),
                        "provider": session.meta.get("provider").cloned()
                            .or_else(|| session.kind.clone().map(Value::String)),
                        "model": session.meta.get("model"),
                        "phase": session.meta.get("workflow_phase"),
                        "gate": session.meta.get("workflow_gate"),
                        "assignment": session.meta.get("workflow_assignment"),
                        "fanout": session.meta.get("workflow_fanout").and_then(Value::as_bool).unwrap_or(false),
                        "state": session.state.name(),
                        "connected": connected
                    }));
                }
            }
            Dispatch::Reply(Response::Json(serde_json::json!({
                "ok": true,
                "runs": runs.into_values().collect::<Vec<_>>()
            })))
        }
        Request::SetUsage { provider, usage } => {
            let _transition = ctx.transition.lock().unwrap();
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
            let _transition = ctx.transition.lock().unwrap();
            // A missing/null `name`, or an empty one, clears the rename so
            // the session falls back to the adapter's label.
            let effects = shared.lock().unwrap().registry.rename(&id, name.as_deref());
            let Some(effects) = effects else {
                return err(&format!("unknown session: {id}"));
            };
            apply_effects(effects, ctx, host_tx);
            ok()
        }
        Request::SetSessionBacklogged {
            session: id,
            backlogged,
        } => {
            let _transition = ctx.transition.lock().unwrap();
            let effects = match shared
                .lock()
                .unwrap()
                .registry
                .set_backlogged(&id, backlogged)
            {
                Ok(effects) => effects,
                Err(message) => return err(&message),
            };
            apply_effects(effects, ctx, host_tx);
            ok()
        }
        Request::SwapSlots {
            session1: id1,
            session2: id2,
        } => {
            let _transition = ctx.transition.lock().unwrap();
            let result = shared.lock().unwrap().registry.swap_slots(&id1, &id2);
            match result {
                Ok(effects) => {
                    apply_effects(effects, ctx, host_tx);
                    ok()
                }
                Err(message) => err(&message),
            }
        }
        Request::MoveSlot { session: id, slot } => {
            let _transition = ctx.transition.lock().unwrap();
            let effects = match shared.lock().unwrap().registry.move_slot(&id, slot) {
                Ok(effects) => effects,
                Err(message) => return err(&message),
            };
            apply_effects(effects, ctx, host_tx);
            ok()
        }
        Request::EndSession { session: id } => {
            let _transition = ctx.transition.lock().unwrap();
            let (current, effects) = {
                let mut state = shared.lock().unwrap();
                let current = state.registry.session_or_tombstone(&id);
                let effects = state.registry.end_session(&id);
                (current, effects)
            };
            if let Some(session) = current {
                eprintln!(
                    "[session] end-request id={} current_pid={} current_tty={} current_mux={} current_managed={}",
                    diagnostic_text(&id), diagnostic_meta(&session.meta, "pid"),
                    diagnostic_meta(&session.meta, "tty"), diagnostic_meta(&session.meta, "mux_pane"),
                    diagnostic_meta(&session.meta, "managed"),
                );
            } else {
                eprintln!(
                    "[session] end-request id={} current=-",
                    diagnostic_text(&id)
                );
            }
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
            let target = shared.lock().unwrap().registry.session_or_tombstone(&id);
            let pid = target.as_ref().and_then(Session::pid);
            let terminal = target
                .as_ref()
                .and_then(|session| match session.attachment.as_ref() {
                    Some(
                        Attachment::Process { terminal, .. } | Attachment::Managed { terminal, .. },
                    ) => Some(terminal.clone()),
                    _ => None,
                });
            match pid {
                Some(pid) => {
                    let ctx = ctx.clone();
                    let host_tx = host_tx.clone();
                    let id = id.clone();
                    std::thread::spawn(move || {
                        quit_agent_process(pid);
                        if let Some(endpoint) = terminal {
                            match close_exact_terminal_endpoint(&endpoint) {
                                Ok(()) => eprintln!(
                                    "[session] quit-terminal id={} result=closed",
                                    diagnostic_text(&id)
                                ),
                                Err(reason) => eprintln!(
                                    "[session] quit-terminal id={} result=left-open reason={}",
                                    diagnostic_text(&id),
                                    diagnostic_text(&reason)
                                ),
                            }
                        }
                        let _transition = ctx.transition.lock().unwrap();
                        let effects = ctx.shared.lock().unwrap().registry.end_session(&id);
                        apply_effects(effects, &ctx, &host_tx);
                    });
                }
                None => {
                    // A disconnected session can lose its provider pid while
                    // retaining an exact terminal endpoint. Close that endpoint
                    // before removing the durable row.
                    if let Some(endpoint) = terminal {
                        let ctx = ctx.clone();
                        let host_tx = host_tx.clone();
                        let id = id.clone();
                        std::thread::spawn(move || {
                            match close_exact_terminal_endpoint(&endpoint) {
                                Ok(()) => eprintln!(
                                    "[session] quit-terminal id={} result=closed",
                                    diagnostic_text(&id)
                                ),
                                Err(reason) => eprintln!(
                                    "[session] quit-terminal id={} result=left-open reason={}",
                                    diagnostic_text(&id),
                                    diagnostic_text(&reason)
                                ),
                            }
                            let _transition = ctx.transition.lock().unwrap();
                            let effects = ctx.shared.lock().unwrap().registry.end_session(&id);
                            apply_effects(effects, &ctx, &host_tx);
                        });
                    } else {
                        let _transition = ctx.transition.lock().unwrap();
                        let effects = shared.lock().unwrap().registry.end_session(&id);
                        apply_effects(effects, ctx, host_tx);
                    }
                }
            }
            ok()
        }
        Request::StopManagedSession {
            session: id,
            task_id,
            confirmation,
        } => {
            if confirmation != "user-confirmed" {
                return err("stop-managed-session requires confirmation='user-confirmed'");
            }
            let session = match orchestrated_session_target(
                &shared.lock().unwrap().registry,
                &id,
                &task_id,
            ) {
                Ok(session) => session,
                Err(message) => return err(&message),
            };
            gracefully_end_session(&id, session.pid(), ctx, host_tx);
            Dispatch::Reply(Response::Json(serde_json::json!({
                "ok": true, "session": id, "task_id": task_id,
                "status": "stopping", "confirmation": "accepted"
            })))
        }
        Request::StopOrchestratedSession {
            session: _,
            task_id: _,
        } => {
            err("stop-orchestrated-session is disabled; use stop-managed-session with explicit confirmation")
        }
        Request::ReadSessionTranscript {
            session: id,
            task_id,
            tail,
            search,
        } => {
            let tail = tail.unwrap_or(20);
            if !(1..=8_000).contains(&tail) {
                return err("read-session-transcript 'tail' must be 1-8000");
            }
            let search = match search.as_deref() {
                None => None,
                Some(search)
                    if !search.is_empty()
                        && search.chars().count() <= 256
                        && !search.chars().any(char::is_control) =>
                {
                    Some(search)
                }
                Some(_) => return err("transcript search must be 1-256 printable characters"),
            };
            let session = match orchestrated_session_target(
                &shared.lock().unwrap().registry,
                &id,
                &task_id,
            ) {
                Ok(session) => session,
                Err(message) => return err(&message),
            };
            let path = match orchestrated_transcript_path(&session) {
                Ok(path) => path,
                Err(message) => return err(&message),
            };
            let provider = session.kind.as_deref().expect("validated provider");
            let messages =
                match crate::transcript::read_transcript(&path, provider, tail as usize, search) {
                    Ok(messages) => messages,
                    Err(message) => return err(&message),
                };
            Dispatch::Reply(Response::Json(serde_json::json!({
                "ok": true,
                "session": id,
                "task_id": task_id,
                "provider": provider,
                "count": messages.len(),
                "messages": messages,
            })))
        }
        Request::ChannelCreate { task_id } => {
            let _transition = ctx.transition.lock().unwrap();
            let actor = match channel_actor(&shared.lock().unwrap().registry, &task_id) {
                Ok(actor) => actor,
                Err(message) => return err(&message),
            };
            if actor
                .meta
                .get("orchestration_role")
                .and_then(serde_json::Value::as_str)
                != Some("orchestrator")
            {
                return err("only an orchestrator may create a channel");
            }
            let channel = shared.lock().unwrap().channels.create(actor.id, task_id);
            save_snapshot(shared);
            Dispatch::Reply(Response::Json(
                serde_json::json!({"ok": true, "channel_id": channel.id}),
            ))
        }
        Request::ChannelClose {
            task_id,
            channel: channel_id,
        } => {
            let _transition = ctx.transition.lock().unwrap();
            let actor = match channel_actor(&shared.lock().unwrap().registry, &task_id) {
                Ok(actor) => actor,
                Err(message) => return err(&message),
            };
            let mut state = shared.lock().unwrap();
            let Some(channel) = state.channels.channels.get(&channel_id) else {
                return err("unknown channel");
            };
            if channel.owner_session != actor.id {
                return err("only the creating orchestrator may close this channel");
            }
            state.channels.channels.remove(&channel_id);
            drop(state);
            save_snapshot(shared);
            Dispatch::Reply(Response::Json(
                serde_json::json!({"ok": true, "channel_id": channel_id, "closed": true}),
            ))
        }
        Request::ChannelMembers {
            task_id,
            channel: channel_id,
        } => {
            let actor = match channel_actor(&shared.lock().unwrap().registry, &task_id) {
                Ok(actor) => actor,
                Err(message) => return err(&message),
            };
            let state = shared.lock().unwrap();
            let Some(channel) = state.channels.channels.get(&channel_id) else {
                return err("unknown channel");
            };
            if !channel.members.contains_key(&actor.id) {
                return err("session is not a channel member");
            }
            Dispatch::Reply(Response::Json(
                serde_json::json!({"ok": true, "channel": channel_public(channel)}),
            ))
        }
        Request::ChannelRead {
            task_id,
            channel: channel_id,
            since,
            tail,
            ack,
        } => {
            let _transition = ctx.transition.lock().unwrap();
            let actor = match channel_actor(&shared.lock().unwrap().registry, &task_id) {
                Ok(actor) => actor,
                Err(message) => return err(&message),
            };
            let tail = tail.unwrap_or(20);
            if !(1..=100).contains(&tail) {
                return err("channel read tail must be 1-100");
            }
            let mut state = shared.lock().unwrap();
            let Some(channel) = state.channels.channels.get_mut(&channel_id) else {
                return err("unknown channel");
            };
            let (messages, next, available_through) = match channel.read(&actor.id, since, tail as usize) {
                Ok(value) => value,
                Err(message) => return err(&message),
            };
            let acknowledged_through = if ack.unwrap_or(false) {
                match channel.ack(&actor.id, next) {
                    Ok(cursor) => cursor,
                    Err(message) => return err(&message),
                }
            } else {
                channel.members.get(&actor.id).copied().unwrap_or(0)
            };
            drop(state);
            if ack.unwrap_or(false) {
                save_snapshot(shared);
            }
            Dispatch::Reply(Response::Json(
                serde_json::json!({"ok":true,"channel_id":channel_id,"messages":messages,
                    "next_cursor":next,"available_through":available_through,
                    "acknowledged_through":acknowledged_through}),
            ))
        }
        Request::ChannelAck {
            task_id,
            channel: channel_id,
            through,
        } => {
            let _transition = ctx.transition.lock().unwrap();
            let actor = match channel_actor(&shared.lock().unwrap().registry, &task_id) {
                Ok(actor) => actor,
                Err(message) => return err(&message),
            };
            let acknowledged_through = {
                let mut state = shared.lock().unwrap();
                let Some(channel) = state.channels.channels.get_mut(&channel_id) else {
                    return err("unknown channel");
                };
                match channel.ack(&actor.id, through) {
                    Ok(cursor) => cursor,
                    Err(message) => return err(&message),
                }
            };
            save_snapshot(shared);
            Dispatch::Reply(Response::Json(serde_json::json!({
                "ok": true, "channel_id": channel_id,
                "acknowledged_through": acknowledged_through,
            })))
        }
        Request::ChannelPost {
            task_id,
            channel: channel_id,
            body,
            kind,
            to,
        } => {
            let _transition = ctx.transition.lock().unwrap();
            let actor = match channel_actor(&shared.lock().unwrap().registry, &task_id) {
                Ok(actor) => actor,
                Err(message) => return err(&message),
            };
            let kind = kind.unwrap_or_else(|| "note".to_string());
            if !valid_kind(&kind) {
                return err("invalid channel message kind");
            }
            if body.chars().count() > BODY_MAX_CHARS {
                return err("channel body exceeds 4096 characters");
            }
            let requested_to = to.as_deref().unwrap_or("channel");
            let (message, recipients) = {
                let mut state = shared.lock().unwrap();
                let Some(channel) = state.channels.channels.get_mut(&channel_id) else {
                    return err("unknown channel");
                };
                let recipient = match channel_post_target(channel, &actor.id, requested_to) {
                    Ok(to) => to,
                    Err(message) => return err(&message),
                };
                let message = channel.post(
                    actor.id.clone(),
                    recipient.clone(),
                    kind,
                    body,
                    unix_ms_now(),
                );
                let recipient_ids: Vec<String> = if recipient == "channel" {
                    channel
                        .members
                        .keys()
                        .filter(|id| **id != actor.id)
                        .cloned()
                        .collect()
                } else {
                    vec![recipient]
                };
                (message, recipient_ids)
            };
            let recipient_sessions: Vec<Session> = {
                let state = shared.lock().unwrap();
                recipients
                    .iter()
                    .filter_map(|id| state.registry.session_or_tombstone(id))
                    .collect()
            };
            for recipient in recipient_sessions {
                maybe_wake_channel_member(ctx, &channel_id, &recipient);
            }
            save_snapshot(shared);
            Dispatch::Reply(Response::Json(
                serde_json::json!({"ok":true,"message":message}),
            ))
        }
        Request::RelaunchManagedSession { session: id } => {
            let _transition = ctx.transition.lock().unwrap();
            let launch_id = new_relaunch_id();
            let begun = shared.lock().unwrap().registry.begin_managed_relaunch(
                &id,
                &launch_id,
                Instant::now(),
            );
            let (source, effects) = match begun {
                Ok(value) => value,
                Err(message) => {
                    eprintln!("[managed-relaunch] rejected session={id}: {message}");
                    return err(&message);
                }
            };
            let prepared = match prepare_managed_resume(&source, &launch_id) {
                Ok(prepared) => prepared,
                Err(message) => {
                    eprintln!("[managed-relaunch] preflight failed session={id}: {message}");
                    let effects = shared
                        .lock()
                        .unwrap()
                        .registry
                        .cancel_managed_relaunch(&id, &launch_id);
                    apply_effects(effects, ctx, host_tx);
                    return err(&message);
                }
            };
            let Some(pid) = source.pid() else {
                let effects = shared
                    .lock()
                    .unwrap()
                    .registry
                    .cancel_managed_relaunch(&id, &launch_id);
                apply_effects(effects, ctx, host_tx);
                return err("session has no provider pid");
            };
            apply_effects(effects, ctx, host_tx);
            eprintln!("[managed-relaunch] accepted session={id} launch_id={launch_id} pid={pid}");
            ctx.broadcast(&managed_relaunch_event_line(
                &id, &launch_id, "quitting", None, None, None,
            ));

            let ctx = ctx.clone();
            let host_tx = host_tx.clone();
            let id = id.clone();
            let thread_launch_id = launch_id.clone();
            std::thread::spawn(move || {
                if !quit_agent_process(pid) {
                    let message = "old provider did not exit; managed relaunch cancelled";
                    eprintln!("[managed-relaunch] quit failed session={id} launch_id={thread_launch_id} pid={pid}");
                    let _transition = ctx.transition.lock().unwrap();
                    let effects = ctx
                        .shared
                        .lock()
                        .unwrap()
                        .registry
                        .cancel_managed_relaunch(&id, &thread_launch_id);
                    apply_effects(effects, &ctx, &host_tx);
                    ctx.broadcast(&managed_relaunch_event_line(
                        &id,
                        &thread_launch_id,
                        "failed",
                        None,
                        None,
                        Some(message),
                    ));
                    return;
                }
                if let Err(message) = launch_managed_resume(&prepared) {
                    eprintln!("[managed-relaunch] tmux launch failed session={id} launch_id={thread_launch_id}: {message}");
                    let _transition = ctx.transition.lock().unwrap();
                    let effects = ctx.shared.lock().unwrap().registry.fail_managed_relaunch(
                        &id,
                        &thread_launch_id,
                        Instant::now(),
                    );
                    apply_effects(effects, &ctx, &host_tx);
                    ctx.broadcast(&managed_relaunch_event_line(
                        &id,
                        &thread_launch_id,
                        "failed",
                        None,
                        None,
                        Some(&message),
                    ));
                    return;
                }
                if let Err(message) = open_managed_tmux_terminal(&prepared) {
                    eprintln!("[managed-relaunch] terminal open failed session={id} launch_id={thread_launch_id}: {message}");
                    kill_managed_resume(&prepared);
                    let _transition = ctx.transition.lock().unwrap();
                    let effects = ctx.shared.lock().unwrap().registry.fail_managed_relaunch(
                        &id,
                        &thread_launch_id,
                        Instant::now(),
                    );
                    apply_effects(effects, &ctx, &host_tx);
                    ctx.broadcast(&managed_relaunch_event_line(
                        &id,
                        &thread_launch_id,
                        "failed",
                        None,
                        None,
                        Some(&message),
                    ));
                    return;
                }
                ctx.broadcast(&managed_relaunch_event_line(
                    &id,
                    &thread_launch_id,
                    "launched",
                    Some(&prepared.tmux_server),
                    Some(&prepared.tmux_session),
                    None,
                ));
                eprintln!("[managed-relaunch] launched session={id} launch_id={thread_launch_id} tmux_server={} tmux_session={}", prepared.tmux_server, prepared.tmux_session);

                std::thread::sleep(Duration::from_secs(20));
                let still_pending = ctx
                    .shared
                    .lock()
                    .unwrap()
                    .registry
                    .is_managed_relaunch_pending(&id, &thread_launch_id);
                if still_pending {
                    eprintln!("[managed-relaunch] registration timeout session={id} launch_id={thread_launch_id}");
                    kill_managed_resume(&prepared);
                    let _transition = ctx.transition.lock().unwrap();
                    let effects = ctx.shared.lock().unwrap().registry.fail_managed_relaunch(
                        &id,
                        &thread_launch_id,
                        Instant::now(),
                    );
                    apply_effects(effects, &ctx, &host_tx);
                    ctx.broadcast(&managed_relaunch_event_line(
                        &id,
                        &thread_launch_id,
                        "failed",
                        None,
                        None,
                        Some("replacement provider did not register"),
                    ));
                }
            });
            Dispatch::Reply(Response::Json(serde_json::json!({
                "ok": true,
                "launch_id": launch_id,
            })))
        }
        Request::GetAttentionOrder => {
            let sessions = shared.lock().unwrap().registry.attention_order();
            Dispatch::Reply(Response::Json(
                serde_json::json!({ "ok": true, "sessions": sessions }),
            ))
        }
        Request::SetAttentionOrder { sessions } => {
            let _transition = ctx.transition.lock().unwrap();
            let effects = match shared
                .lock()
                .unwrap()
                .registry
                .set_attention_order(sessions)
            {
                Ok(effects) => effects,
                Err(message) => return err(&message),
            };
            apply_effects(effects, ctx, host_tx);
            ok()
        }
        Request::FocusNextAttention => {
            let _transition = ctx.transition.lock().unwrap();
            let (session, navigation_states) = {
                let mut shared = shared.lock().unwrap();
                let session = shared.registry.next_attention();
                let navigation_states = shared.registry.navigation_states();
                (session, navigation_states)
            };
            let _ = host_tx.send(HostCmd::SetNavState(navigation_states));
            let selected = session.as_ref().map(|session| session.id.clone());
            if let Some(session) = session {
                let ctx = ctx.clone();
                let slot = session.slot.unwrap_or(0);
                std::thread::spawn(move || run_focus(&ctx, &session, slot));
            }
            Dispatch::Reply(Response::Json(
                serde_json::json!({ "ok": true, "session": selected }),
            ))
        }
        Request::FocusPrevAttention => {
            let _transition = ctx.transition.lock().unwrap();
            let (session, navigation_states) = {
                let mut shared = shared.lock().unwrap();
                let session = shared.registry.previous_attention();
                let navigation_states = shared.registry.navigation_states();
                (session, navigation_states)
            };
            let _ = host_tx.send(HostCmd::SetNavState(navigation_states));
            let selected = session.as_ref().map(|session| session.id.clone());
            if let Some(session) = session {
                let ctx = ctx.clone();
                let slot = session.slot.unwrap_or(0);
                std::thread::spawn(move || run_focus(&ctx, &session, slot));
            }
            Dispatch::Reply(Response::Json(
                serde_json::json!({ "ok": true, "session": selected }),
            ))
        }
        Request::LaunchSession {
            provider,
            cwd,
            model,
            agent_type,
            cursor_mode,
            task,
            task_id,
            title,
            role,
            manager_task_id,
            channel_id,
            workflow_id,
            workflow_run_id,
            workflow_phase,
            workflow_gate,
            workflow_fanout,
            workflow_assignment,
            workflow_assignments,
            transition_confirmation,
        } => {
            let mut channel_id = channel_id;
            let (agent_type, selected_model) =
                match required_launch_selection(agent_type.as_deref(), model.as_deref()) {
                    Ok(selection) => selection,
                    Err(message) => return err(&message),
                };
            let role = role.as_deref().unwrap_or("worker");
            if role == "worker" {
                if let Some(manager) = manager_task_id.as_deref() {
                    if let Some(run_id) = manager_workflow_run_id(manager) {
                        if workflow_run_id.as_deref() != Some(run_id.as_str()) {
                            return err("workers managed by a workflow orchestrator must claim that workflow run and an authorized assignment");
                        }
                    }
                }
            }
            if let Err(message) = validate_workflow_launch_metadata(
                role,
                workflow_id.as_deref(),
                workflow_run_id.as_deref(),
                workflow_phase.as_deref(),
                workflow_gate.as_deref(),
                workflow_fanout.unwrap_or(false),
                workflow_assignment.as_deref(),
                workflow_assignments.as_deref(),
                transition_confirmation.as_deref(),
            ) {
                return err(&message);
            }
            // Workflow workers inherit the run's daemon-owned channel. A
            // caller may repeat that exact id for compatibility, but cannot
            // substitute or omit coordination by choosing another channel.
            if role == "worker" {
                if let Some(run_id) = workflow_run_id.as_deref() {
                    let receipt: Value = match std::fs::read(workflow_receipt_path(run_id))
                        .ok()
                        .and_then(|data| serde_json::from_slice(&data).ok())
                    {
                        Some(receipt) => receipt,
                        None => return err("unknown workflow run"),
                    };
                    let Some(run_channel) = receipt.get("channel_id").and_then(Value::as_str) else {
                        return err("workflow run has no coordination channel");
                    };
                    if channel_id.as_deref().is_some_and(|id| id != run_channel) {
                        return err("workflow worker channel does not match the workflow run");
                    }
                    channel_id = Some(run_channel.to_string());
                }
            }
            let title = match orchestrator_session_title(title.as_deref(), &task_id) {
                Ok(title) => title,
                Err(message) => return err(&message),
            };
            let receipt_path = crate::paths::daemon_state_dir()
                .join("launches")
                .join(format!("{task_id}.json"));
            if let Ok(data) = std::fs::read(&receipt_path) {
                let Ok(mut receipt) = serde_json::from_slice::<Value>(&data) else {
                    return err("managed task id has an invalid launch receipt");
                };
                // The initial workflow request intentionally has no channel
                // argument: the daemon created and persisted it atomically.
                if role == "orchestrator"
                    && workflow_assignments.is_some()
                    && channel_id.is_none()
                {
                    channel_id = receipt
                        .get("channel_id")
                        .and_then(Value::as_str)
                        .map(str::to_string);
                }
                let exact_strings = [
                    ("provider", Some(provider.as_str())),
                    ("model", Some(selected_model)),
                    ("agent_type", Some(agent_type)),
                    ("cwd", Some(cwd.as_str())),
                    ("role", Some(role)),
                    ("manager_task_id", manager_task_id.as_deref()),
                    ("channel_id", channel_id.as_deref()),
                    ("workflow_id", workflow_id.as_deref()),
                    ("workflow_run_id", workflow_run_id.as_deref()),
                    ("workflow_phase", workflow_phase.as_deref()),
                    ("workflow_gate", workflow_gate.as_deref()),
                    ("workflow_assignment", workflow_assignment.as_deref()),
                ];
                let mismatch = exact_strings.into_iter().any(|(field, requested)| {
                    let stored = receipt.get(field).filter(|value| !value.is_null()).and_then(Value::as_str);
                    stored != requested
                }) || receipt.get("workflow_fanout").and_then(Value::as_bool)
                    != Some(workflow_fanout.unwrap_or(false))
                    || !receipt_workflow_manifest_matches(
                        &receipt,
                        workflow_assignments.as_deref(),
                    );
                if mismatch {
                    return err(&format!(
                        "managed task id {task_id} is already active with a different request; use a new task id"
                    ));
                }
                receipt["ok"] = true.into();
                return Dispatch::Reply(Response::Json(receipt));
            }
            let (slot, workflow_claim, created_channel_id) = {
                let _transition = ctx.transition.lock().unwrap();
                let mut state = shared.lock().unwrap();
                if let Err(message) = validate_orchestration_relationship(
                    &state.registry,
                    role,
                    &task_id,
                    manager_task_id.as_deref(),
                ) {
                    return err(&message);
                }
                if let Some(channel_id) = channel_id.as_deref() {
                    let Some(channel) = state.channels.channels.get(channel_id) else {
                        return err("unknown channel");
                    };
                    if role == "worker" {
                        let Some(manager) = manager_task_id.as_deref() else {
                            return err("launch --channel requires manager_task_id");
                        };
                        if channel.owner_task_id != manager {
                            return err("channel is not owned by that orchestrator task");
                        }
                    } else {
                        return err("top-level orchestrator channels are daemon-created");
                    }
                }
                let slot = match state
                    .registry
                    .reserve_managed_launch(&task_id, Instant::now())
                {
                    Ok(slot) => slot,
                    Err(message) => {
                        let existing = std::fs::read(
                            crate::paths::daemon_state_dir()
                                .join("launches")
                                .join(format!("{task_id}.json")),
                        )
                        .ok()
                        .and_then(|data| serde_json::from_slice::<Value>(&data).ok());
                        if let Some(mut receipt) = existing {
                            if receipt.get("status").and_then(Value::as_str) == Some("failed") {
                                return err(receipt
                                    .get("error")
                                    .and_then(Value::as_str)
                                    .unwrap_or("managed launch previously failed before registration; retry with a new task id"));
                            }
                            if role == "orchestrator"
                                && workflow_assignments.is_some()
                                && channel_id.is_none()
                            {
                                channel_id = receipt
                                    .get("channel_id")
                                    .and_then(Value::as_str)
                                    .map(str::to_string);
                            }
                            // Replaying the stored receipt is what makes
                            // re-running a partially expanded formation safe.
                            // It is only safe when the repeat is the *same*
                            // request, though: replaying it for a different
                            // provider/model/cwd silently ignores what the
                            // caller asked for while reporting `ok: true,
                            // status: launched`, which reads as success and is
                            // not. Idempotency requires matching the request,
                            // not just the task id.
                            let mismatched = [
                                ("provider", Some(provider.as_str())),
                                ("model", Some(selected_model)),
                                ("agent_type", Some(agent_type)),
                                ("cwd", Some(cwd.as_str())),
                                ("role", Some(role)),
                                ("manager_task_id", manager_task_id.as_deref()),
                                ("channel_id", channel_id.as_deref()),
                                ("workflow_id", workflow_id.as_deref()),
                                ("workflow_run_id", workflow_run_id.as_deref()),
                                ("workflow_phase", workflow_phase.as_deref()),
                                ("workflow_gate", workflow_gate.as_deref()),
                                ("workflow_assignment", workflow_assignment.as_deref()),
                            ]
                            .into_iter()
                            .filter(|(field, requested)| {
                                receipt
                                    .get(*field)
                                    .filter(|value| !value.is_null())
                                    .and_then(Value::as_str)
                                    != *requested
                            })
                            .map(|(field, _)| field)
                            .collect::<Vec<_>>();
                            if !mismatched.is_empty()
                                || receipt.get("workflow_fanout").and_then(Value::as_bool)
                                    != Some(workflow_fanout.unwrap_or(false))
                                || !receipt_workflow_manifest_matches(
                                    &receipt,
                                    workflow_assignments.as_deref(),
                                )
                            {
                                let mismatched = if mismatched.is_empty() {
                                    "workflow metadata".to_string()
                                } else {
                                    mismatched.join(", ")
                                };
                                return err(&format!(
                                    "managed task id {task_id} is already active with a different \
                                     request ({} differ); use a new task id",
                                    mismatched
                                ));
                            }
                            receipt["ok"] = true.into();
                            return Dispatch::Reply(Response::Json(receipt));
                        }
                        return err(&message);
                    }
                };
                let claim = if role == "worker" && workflow_run_id.is_some() {
                    match consume_workflow_assignment(
                        workflow_id.as_deref().expect("validated workflow id"),
                        workflow_run_id.as_deref().expect("validated workflow run"),
                        workflow_phase.as_deref().expect("validated workflow phase"),
                        workflow_gate.as_deref().expect("validated workflow gate"),
                        workflow_fanout.unwrap_or(false),
                        workflow_assignment
                            .as_deref()
                            .expect("validated workflow assignment"),
                        agent_type,
                        &provider,
                        selected_model,
                        manager_task_id.as_deref(),
                        &task_id,
                    ) {
                        Ok(claim) => Some(claim),
                        Err(message) => {
                            state.registry.cancel_managed_launch(&task_id);
                            return err(&message);
                        }
                    }
                } else {
                    None
                };
                let created_channel_id = if role == "orchestrator"
                    && workflow_assignments.is_some()
                    && channel_id.is_none()
                {
                    let channel = state.channels.create_pending(task_id.clone());
                    channel_id = Some(channel.id.clone());
                    Some(channel.id)
                } else {
                    None
                };
                (slot, claim, created_channel_id)
            };
            if created_channel_id.is_some() {
                save_snapshot(shared);
            }
            eprintln!(
                "[managed-launch] reserved task_id={} title={} slot={} provider={} role={} cwd={} terminal=new-window",
                diagnostic_text(&task_id), diagnostic_text(&title),
                slot.map(|value| value.to_string()).unwrap_or_else(|| "overflow".into()),
                diagnostic_text(&provider), diagnostic_text(role), diagnostic_text(&cwd),
            );
            match launch_orchestrated_session(
                &provider,
                selected_model,
                agent_type,
                cursor_mode.as_deref(),
                &cwd,
                &task,
                &task_id,
                &title,
                slot,
                role,
                manager_task_id.as_deref(),
                channel_id.as_deref(),
                workflow_id.as_deref(),
                workflow_run_id.as_deref(),
                workflow_phase.as_deref(),
                workflow_gate.as_deref(),
                workflow_fanout.unwrap_or(false),
                workflow_assignment.as_deref(),
                workflow_assignments.as_deref(),
            ) {
                Ok(mut response) => {
                    if provider == "cursor" {
                        let receipt = crate::paths::daemon_state_dir()
                            .join("launches")
                            .join(format!("{task_id}.json"));
                        if let Err(message) = await_cursor_launch_registration(
                            &receipt,
                            CURSOR_LAUNCH_REGISTRATION_TIMEOUT,
                        ) {
                            update_launch_receipt_status(&receipt, "failed", Some(&message));
                            let _transition = ctx.transition.lock().unwrap();
                            {
                                let mut state = shared.lock().unwrap();
                                state.registry.cancel_managed_launch(&task_id);
                                if let Some(channel_id) = created_channel_id.as_deref() {
                                    state.channels.channels.remove(channel_id);
                                }
                            }
                            if created_channel_id.is_some() {
                                save_snapshot(shared);
                            }
                            if let Some(claim) = &workflow_claim {
                                rollback_workflow_assignment(claim);
                            }
                            eprintln!(
                                "[managed-launch] registration-failed task_id={} provider=cursor error={}",
                                diagnostic_text(&task_id),
                                diagnostic_text(&message),
                            );
                            return err(&message);
                        }
                        response["status"] = "launched".into();
                    }
                    eprintln!(
                        "[managed-launch] confirmed task_id={} title={} slot={} provider={}",
                        diagnostic_text(&task_id),
                        diagnostic_text(&title),
                        slot.map(|value| value.to_string())
                            .unwrap_or_else(|| "overflow".into()),
                        diagnostic_text(&provider),
                    );
                    Dispatch::Reply(Response::Json(response))
                }
                Err(message) => {
                    let _transition = ctx.transition.lock().unwrap();
                    {
                        let mut state = shared.lock().unwrap();
                        state.registry.cancel_managed_launch(&task_id);
                        if let Some(channel_id) = created_channel_id.as_deref() {
                            state.channels.channels.remove(channel_id);
                        }
                    }
                    if created_channel_id.is_some() {
                        save_snapshot(shared);
                    }
                    if let Some(claim) = &workflow_claim {
                        rollback_workflow_assignment(claim);
                    }
                    eprintln!(
                        "[managed-launch] failed task_id={} title={} slot={} provider={} error={}",
                        diagnostic_text(&task_id),
                        diagnostic_text(&title),
                        slot.map(|value| value.to_string())
                            .unwrap_or_else(|| "overflow".into()),
                        diagnostic_text(&provider),
                        diagnostic_text(&message),
                    );
                    err(&message)
                }
            }
        }
        Request::ApproveWorkflowTransition {
            workflow_run_id,
            workflow_phase,
        } => {
            let _transition = ctx.transition.lock().unwrap();
            match approve_workflow_transition(&workflow_run_id, &workflow_phase) {
                Ok(response) => Dispatch::Reply(Response::Json(response)),
                Err(message) => err(&message),
            }
        }
        Request::ResumeSession {
            provider,
            cwd,
            session,
            title,
        } => match resume_managed_session(&provider, &cwd, &session, title.as_deref()) {
            Ok(response) => Dispatch::Reply(Response::Json(response)),
            Err(message) => err(&message),
        },
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
        Request::Inject {
            kind,
            control,
            action,
            delta,
            gesture,
        } => match parse_inject_fields(
            &kind,
            control.as_deref(),
            action.as_deref(),
            delta,
            gesture.as_deref(),
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
            Dispatch::Reply(Response::State {
                ok: true,
                state: state.name().to_string(),
            })
        }
        Request::SetLed { index, rgb } => {
            let index = match u8::try_from(index) {
                Ok(index) => index,
                Err(_) => return err("set-led requires integer 'index' in 0..=255 (255 = all)"),
            };
            let c = match parse_rgb_values(&rgb) {
                Ok(rgb) => rgb,
                Err(message) => return err(&message),
            };
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
            Dispatch::Reply(Response::Styles {
                ok: true,
                styles: styles_json(&styles),
            })
        }
        Request::SetStyle {
            state: state_name,
            rgb,
            pattern,
            period_ms,
        } => {
            let _transition = ctx.transition.lock().unwrap();
            let (state, style) =
                match parse_set_style_fields(&state_name, &rgb, &pattern, period_ms) {
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
            Dispatch::Reply(Response::Ping {
                ok: true,
                device: present,
            })
        }
    }
}

#[cfg(unix)]
fn err(msg: &str) -> Dispatch {
    Dispatch::Reply(Response::Error {
        ok: false,
        error: msg.to_string(),
    })
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
    Err(
        "Windows named pipe (\\\\.\\pipe\\focalpoint) is not yet implemented; \
         FocalPoint currently supports macOS and Linux."
            .to_string(),
    )
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn replay_includes_all_navigation_states() {
        let mut registry = Registry::new(None);
        registry.set_state(
            Some("needs-input"),
            State::Waiting,
            None,
            None,
            None,
            Instant::now(),
        );
        let shared = Mutex::new(Shared {
            registry,
            usage: HashMap::new(),
            styles: StyleTable::default(),
            channels: Channels::default(),
            channel_wake_last: HashMap::new(),
            device_present: false,
        });
        assert!(replay_state_cmds(&shared).iter().any(|cmd| matches!(
            cmd,
            HostCmd::SetNavState(states)
                if states.attention_next == Some(State::Waiting)
                    && states.attention_previous == Some(State::Waiting)
                    && states.session_next == Some(State::Waiting)
                    && states.session_previous == Some(State::Waiting)
        )));
    }

    #[test]
    fn replay_explicitly_clears_every_unoccupied_key() {
        let mut registry = Registry::new(None);
        let meta = Map::from_iter([
            ("pid".into(), json!(4242)),
            ("process_boot_time".into(), json!(7)),
            ("process_start_time".into(), json!(11)),
            ("provider_executable".into(), json!("/usr/local/bin/codex")),
        ]);
        registry.set_state(
            Some("only-session"),
            State::Running,
            None,
            None,
            Some(meta),
            Instant::now(),
        );
        let shared = Mutex::new(Shared {
            registry,
            usage: HashMap::new(),
            styles: StyleTable::default(),
            channels: Channels::default(),
            channel_wake_last: HashMap::new(),
            device_present: false,
        });

        let key_cmds: Vec<HostCmd> = replay_state_cmds(&shared)
            .into_iter()
            .filter(|cmd| matches!(cmd, HostCmd::SetKeyState { .. }))
            .collect();
        assert_eq!(key_cmds.len(), 12);
        assert_eq!(
            key_cmds[0],
            HostCmd::SetKeyState {
                key: 1,
                state: Some(State::Running),
            }
        );
        for (index, cmd) in key_cmds.iter().enumerate().skip(1) {
            assert_eq!(
                *cmd,
                HostCmd::SetKeyState {
                    key: index as u8 + 1,
                    state: None,
                }
            );
        }
    }

    #[cfg(unix)]
    #[test]
    fn focus_environment_exports_exact_managed_tmux_identity() {
        let mut meta = serde_json::Map::new();
        meta.insert("tty".into(), serde_json::json!("/dev/ttys-stale"));
        meta.insert("mux_server".into(), serde_json::json!("fp-worker-42"));
        meta.insert("mux_session".into(), serde_json::json!("worker-42"));
        meta.insert("mux_pane".into(), serde_json::json!("%7"));
        let session = Session {
            id: "claude-session".into(),
            kind: Some("claude".into()),
            label: Some("Parser implementation".into()),
            name: None,
            meta,
            carry: serde_json::Map::new(),
            slot: Some(4),
            state: State::Thinking,
            last_update: Instant::now(),
            attachment: None,
            health: SessionHealth::Unknown,
            health_reason: None,
            last_verified: None,
            failed_probes: 0,
            first_probe_failure: None,
            slot_history: vec![4],
        };
        let env: std::collections::HashMap<_, _> =
            focus_environment(&session, 4).into_iter().collect();

        assert_eq!(env["FOCALPOINT_SESSION_TTY"], "/dev/ttys-stale");
        assert_eq!(env["FOCALPOINT_SESSION_MUX_SERVER"], "fp-worker-42");
        assert_eq!(env["FOCALPOINT_SESSION_MUX_SESSION"], "worker-42");
        assert_eq!(env["FOCALPOINT_SESSION_MUX_PANE"], "%7");
        assert_eq!(env["FOCALPOINT_SLOT"], "4");
    }

    #[test]
    fn channel_rejects_non_member_and_worker_to_worker_posts() {
        let mut channel =
            crate::channel::Channel::new("ch-1".into(), "owner".into(), "task".into());
        channel.join_at_tail("worker-a".into());
        channel.join_at_tail("worker-b".into());
        assert!(channel_post_target(&channel, "outsider", "channel").is_err());
        assert!(channel_post_target(&channel, "worker-a", "worker-b").is_err());
        assert_eq!(
            channel_post_target(&channel, "worker-a", "channel").unwrap(),
            "owner"
        );
    }

    #[cfg(unix)]
    #[test]
    fn managed_workflow_channel_binds_owner_and_authorized_worker() {
        let mut channels = crate::channel::Channels::default();
        let channel_id = channels
            .create_pending("run-orchestrator".into())
            .id
            .clone();
        let channel = channels.channels.get_mut(&channel_id).unwrap();

        let owner = Map::from_iter([
            ("managed".into(), json!(true)),
            ("orchestrator_task_id".into(), json!("run-orchestrator")),
            ("orchestration_role".into(), json!("orchestrator")),
        ]);
        assert!(join_managed_channel(channel, "owner-session", &owner).unwrap());
        assert_eq!(channel.owner_session, "owner-session");

        let worker = Map::from_iter([
            ("managed".into(), json!(true)),
            ("orchestrator_task_id".into(), json!("worker-task")),
            ("orchestration_role".into(), json!("worker")),
            ("manager_task_id".into(), json!("run-orchestrator")),
        ]);
        assert!(join_managed_channel(channel, "worker-session", &worker).unwrap());
        assert!(channel.members.contains_key("worker-session"));
    }

    #[cfg(unix)]
    #[test]
    fn managed_workflow_channel_rejects_identity_mismatch() {
        let mut channels = crate::channel::Channels::default();
        let channel_id = channels.create_pending("expected-owner".into()).id.clone();
        let channel = channels.channels.get_mut(&channel_id).unwrap();
        let impostor = Map::from_iter([
            ("managed".into(), json!(true)),
            ("orchestrator_task_id".into(), json!("wrong-owner")),
            ("orchestration_role".into(), json!("orchestrator")),
        ]);
        assert!(join_managed_channel(channel, "impostor", &impostor).is_err());
        assert!(channel.owner_session.is_empty());
        assert!(channel.members.is_empty());
    }

    #[test]
    fn channel_wake_requires_a_private_owned_tmux_target() {
        let mut meta = serde_json::Map::new();
        meta.insert("managed".into(), serde_json::json!(true));
        meta.insert("mux_pane".into(), serde_json::json!("%12"));
        let session = Session {
            id: "s".into(),
            kind: Some("claude".into()),
            label: None,
            name: None,
            meta,
            carry: serde_json::Map::new(),
            slot: Some(1),
            state: State::Idle,
            last_update: Instant::now(),
            attachment: None,
            health: SessionHealth::Unknown,
            health_reason: None,
            last_verified: None,
            failed_probes: 0,
            first_probe_failure: None,
            slot_history: vec![1],
        };
        // A legacy/default-server pane is never enough to wake.
        assert!(!channel_wake_allowed(&session));

        let mut owned = session.clone();
        owned
            .meta
            .insert("mux_server".into(), serde_json::json!("fp-worker-42"));
        owned
            .meta
            .insert("mux_session".into(), serde_json::json!("fp-claude-42"));
        owned
            .meta
            .insert("tty".into(), serde_json::json!("/dev/ttys042"));
        assert!(channel_wake_allowed(&owned));

        owned.state = State::Waiting;
        assert!(!channel_wake_allowed(&owned));
    }
    use serde_json::json;

    #[test]
    fn process_is_alive_matches_reality() {
        assert!(process_is_alive(std::process::id() as i32));
        // Not a real pid on any sane system (max_pid ceilings are far below
        // this on macOS/Linux) — exercises the ESRCH -> false path.
        assert!(!process_is_alive(999_999_999));
    }

    #[test]
    fn managed_tmux_config_uses_focalpoint_xdg_convention() {
        assert_eq!(
            managed_tmux_config_from(
                Some(PathBuf::from("/tmp/xdg-config")),
                Some(PathBuf::from("/Users/example")),
            ),
            PathBuf::from("/tmp/xdg-config/focalpoint/tmux.conf"),
        );
        assert_eq!(
            managed_tmux_config_from(None, Some(PathBuf::from("/Users/example"))),
            PathBuf::from("/Users/example/.config/focalpoint/tmux.conf"),
        );
    }

    #[test]
    fn managed_launch_never_forces_a_second_terminal_application_instance() {
        assert_eq!(
            terminal_open_args("com.apple.Terminal"),
            ["-b", "com.apple.Terminal"],
        );
    }

    #[test]
    fn managed_relaunch_event_carries_private_tmux_server_and_session() {
        let event: Value = serde_json::from_str(&managed_relaunch_event_line(
            "provider-session",
            "launch-1",
            "launched",
            Some("fp-relaunch-1"),
            Some("fp-relaunch-1"),
            None,
        ))
        .unwrap();
        assert_eq!(event["tmux_server"], "fp-relaunch-1");
        assert_eq!(event["tmux_session"], "fp-relaunch-1");
    }

    #[test]
    fn orchestrator_titles_are_bounded_printable_and_default_to_task_id() {
        assert_eq!(
            orchestrator_session_title(None, "worker-1").unwrap(),
            "worker-1"
        );
        assert_eq!(
            orchestrator_session_title(Some(" Parser implementation "), "worker-1").unwrap(),
            "Parser implementation",
        );
        assert!(orchestrator_session_title(Some("bad\ntitle"), "worker-1").is_err());
        assert!(orchestrator_session_title(Some(""), "worker-1").is_err());
    }

    #[test]
    fn orchestrator_task_ids_are_narrow() {
        assert!(valid_orchestrator_task_id("board-design_3.v2"));
        assert!(!valid_orchestrator_task_id("../escape"));
        assert!(!valid_orchestrator_task_id("has space"));
        assert!(!valid_orchestrator_task_id(""));
        assert!(!valid_orchestrator_task_id(&"x".repeat(65)));
    }

    #[test]
    fn orchestrator_model_ids_are_narrow() {
        for model in [
            "sonnet",
            "claude-opus-4-1",
            "gpt-5.6-sol",
            "openai/gpt-oss:20b",
            "model@latest",
        ] {
            assert!(valid_orchestrator_model_id(model), "{model}");
        }
        for model in [
            "",
            " has-space",
            "has space",
            "--model",
            "model;touch",
            "model\nnext",
        ] {
            assert!(!valid_orchestrator_model_id(model), "{model}");
        }
        assert!(!valid_orchestrator_model_id(&"x".repeat(129)));
    }

    #[test]
    fn orchestration_relationship_requires_one_live_managed_orchestrator() {
        let mut registry = Registry::new(None);
        assert!(validate_orchestration_relationship(
            &registry,
            "worker",
            "worker-1",
            Some("orchestrator-1")
        )
        .unwrap_err()
        .contains("no live managed orchestrator"));

        let mut meta = serde_json::Map::new();
        meta.insert("managed".into(), serde_json::Value::Bool(true));
        meta.insert(
            "orchestration_role".into(),
            serde_json::Value::String("orchestrator".into()),
        );
        meta.insert(
            "orchestrator_task_id".into(),
            serde_json::Value::String("orchestrator-1".into()),
        );
        registry.set_state(
            Some("manager"),
            State::Running,
            Some("claude".into()),
            None,
            Some(meta),
            Instant::now(),
        );
        assert!(validate_orchestration_relationship(
            &registry,
            "worker",
            "worker-1",
            Some("orchestrator-1")
        )
        .is_ok());
        assert!(validate_orchestration_relationship(
            &registry,
            "orchestrator",
            "nested",
            Some("orchestrator-1")
        )
        .unwrap_err()
        .contains("cannot also declare a manager"));
    }

    #[test]
    fn orchestrated_launch_passes_model_before_prompt() {
        assert_eq!(
            orchestrated_provider_command(
                Path::new("/opt/homebrew/bin/claude"),
                Some("sonnet"),
                "Task:\nInspect it."
            ),
            "'/opt/homebrew/bin/claude' '--model' 'sonnet' 'Task:\nInspect it.'"
        );
        assert_eq!(
            orchestrated_provider_command(
                Path::new("/opt/homebrew/bin/codex"),
                None,
                "Task:\nInspect it."
            ),
            "'/opt/homebrew/bin/codex' 'Task:\nInspect it.'"
        );
    }

    #[test]
    fn cursor_launch_modes_use_the_right_entrypoint() {
        assert_eq!(
            cursor_provider_command(
                Path::new("/opt/homebrew/bin/cursor-agent"),
                Some("gpt-5"),
                "Task:\nInspect it.",
                "attachable",
                None,
            )
            .unwrap(),
            "'/opt/homebrew/bin/cursor-agent' '--model' 'gpt-5' 'Task:\nInspect it.'"
        );
        assert_eq!(
            cursor_provider_command(
                Path::new("/opt/homebrew/bin/cursor"),
                None,
                "Task:\nInspect it.",
                "attachable",
                None,
            )
            .unwrap(),
            "'/opt/homebrew/bin/cursor' 'agent' 'Task:\nInspect it.'"
        );
        assert_eq!(
            cursor_provider_command(
                Path::new("/opt/homebrew/bin/cursor-agent"),
                None,
                "Task:\nInspect it.",
                "headless",
                Some(Path::new(
                    "/Users/me/.config/focalpoint/adapters/cursor-cli-focalpoint.sh"
                )),
            )
            .unwrap(),
            "'/Users/me/.config/focalpoint/adapters/cursor-cli-focalpoint.sh' 'Task:\nInspect it.'"
        );
        assert!(cursor_provider_command(
            Path::new("/opt/homebrew/bin/cursor-agent"),
            None,
            "Task",
            "headless",
            None,
        )
        .unwrap_err()
        .contains("headless adapter is not installed"));
    }

    #[test]
    fn attachable_cursor_prompt_requires_pane_local_registration() {
        let attachable = orchestrated_prompt(
            "cursor",
            "attachable",
            "session #4",
            "Cursor audit",
            "cursor-audit-1",
            "worker",
            true,
            "Inspect it.",
        );
        assert!(attachable.contains("Before any other work"));
        assert!(attachable.contains("run exactly: focalpoint register"));
        assert!(attachable.contains("focalpoint register --state done"));

        let headless = orchestrated_prompt(
            "cursor",
            "headless",
            "session #4",
            "Cursor audit",
            "cursor-audit-1",
            "worker",
            false,
            "Inspect it.",
        );
        assert!(!headless.contains("focalpoint register"));
        assert!(!headless.contains("focalpoint_claim_assignment"));
        assert!(attachable.contains("focalpoint_claim_assignment"));
    }

    #[test]
    fn cursor_headless_kind_correlates_to_cursor_launch_receipt() {
        assert_eq!(
            managed_launch_provider_kind(Some("cursor-cli")),
            Some("cursor")
        );
        assert_eq!(managed_launch_provider_kind(Some("cursor")), Some("cursor"));
        assert_eq!(managed_launch_provider_kind(Some("codex")), Some("codex"));
    }

    #[test]
    fn cursor_launch_receipt_requires_registration_before_success() {
        let receipt = std::env::temp_dir().join(format!(
            "focalpoint-cursor-launch-receipt-{}-{}.json",
            std::process::id(),
            unix_ms_now()
        ));
        std::fs::write(&receipt, r#"{"status":"awaiting-registration"}"#).unwrap();
        let error = await_cursor_launch_registration(&receipt, Duration::ZERO).unwrap_err();
        assert!(error.contains("did not register"));

        update_launch_receipt_status(&receipt, "registered", None);
        assert!(await_cursor_launch_registration(&receipt, Duration::ZERO).is_ok());
        let _ = std::fs::remove_file(receipt);
    }

    #[test]
    fn orchestrated_session_controls_require_matching_managed_task() {
        let mut registry = Registry::new(None);
        let mut meta = serde_json::Map::new();
        meta.insert("managed".into(), serde_json::Value::Bool(true));
        meta.insert(
            "orchestrator_task_id".into(),
            serde_json::Value::String("task-1".into()),
        );
        registry.set_state(
            Some("owned"),
            State::Running,
            Some("claude".into()),
            None,
            Some(meta),
            Instant::now(),
        );
        assert_eq!(
            orchestrated_session_target(&registry, "owned", "task-1")
                .unwrap()
                .id,
            "owned"
        );
        assert!(orchestrated_session_target(&registry, "owned", "task-2")
            .unwrap_err()
            .contains("does not match"));
        assert!(orchestrated_session_target(&registry, "missing", "task-1")
            .unwrap_err()
            .contains("unknown session"));

        let mut cursor_meta = serde_json::Map::new();
        cursor_meta.insert("managed".into(), serde_json::Value::Bool(true));
        cursor_meta.insert(
            "orchestrator_task_id".into(),
            serde_json::Value::String("cursor-task".into()),
        );
        registry.set_state(
            Some("cursor-owned"),
            State::Done,
            Some("cursor".into()),
            None,
            Some(cursor_meta),
            Instant::now(),
        );
        assert_eq!(
            orchestrated_session_target(&registry, "cursor-owned", "cursor-task")
                .unwrap()
                .id,
            "cursor-owned"
        );
    }

    #[test]
    fn preferred_terminal_bundle_ids_are_narrow() {
        assert_eq!(
            parse_terminal_bundle_id("com.googlecode.iterm2\n").as_deref(),
            Some("com.googlecode.iterm2")
        );
        assert_eq!(
            parse_terminal_bundle_id("dev.warp.Warp-Stable").as_deref(),
            Some("dev.warp.Warp-Stable")
        );
        assert_eq!(parse_terminal_bundle_id(""), None);
        assert_eq!(parse_terminal_bundle_id("--args"), None);
        assert_eq!(parse_terminal_bundle_id("bad bundle;open /tmp"), None);
        assert_eq!(parse_terminal_bundle_id(&"x".repeat(256)), None);
    }

    #[cfg(unix)]
    #[test]
    fn attention_order_event_matches_protocol() {
        assert_eq!(
            attention_order_event_line(&["a".into(), "b".into()]),
            r#"{"event":"attention-order","sessions":["a","b"]}"#
        );
    }

    #[test]
    fn quit_agent_process_waits_until_target_exits() {
        let mut child = Command::new("/bin/sleep")
            .arg("60")
            .spawn()
            .expect("spawn sleep");
        let pid = child.id() as i32;
        assert!(process_is_alive(pid));
        assert!(quit_agent_process(pid));
        let _ = child.wait();
        assert!(!process_is_alive(pid));
    }

    #[cfg(unix)]
    #[test]
    fn terminal_cleanup_passes_exact_iterm_session_and_application_pid() {
        use std::os::unix::fs::PermissionsExt;

        let dir = std::env::temp_dir().join(format!(
            "focalpoint-close-test-{}-{}",
            std::process::id(),
            SNAPSHOT_SEQUENCE.fetch_add(1, Ordering::Relaxed)
        ));
        std::fs::create_dir(&dir).unwrap();
        let calls = dir.join("calls");
        let helper = dir.join("helper");
        std::fs::write(
            &helper,
            format!("#!/bin/sh\nprintf '%s\\n' \"$*\" > '{}'\n", calls.display()),
        )
        .unwrap();
        std::fs::set_permissions(&helper, std::fs::Permissions::from_mode(0o700)).unwrap();
        let endpoint = TerminalEndpoint {
            bundle_id: Some("com.googlecode.iterm2".into()),
            application_pid: Some(26748),
            window_id: None,
            session_id: Some("exact-session-id".into()),
            host_tty: Some("/dev/ttys002".into()),
        };

        close_exact_terminal_endpoint_with_helper(&endpoint, Some(&helper)).unwrap();
        assert_eq!(
            std::fs::read_to_string(&calls).unwrap().trim(),
            "--close --session-id exact-session-id --application-pid 26748"
        );
        std::fs::remove_dir_all(dir).unwrap();
    }

    #[test]
    fn session_to_json_and_back_round_trips() {
        let mut meta = serde_json::Map::new();
        meta.insert("turns".into(), json!(7));
        meta.insert("tty".into(), json!("/dev/ttys004"));
        meta.insert("transcript_path".into(), json!("/private/transcript.jsonl"));
        meta.insert(crate::session::BACKLOGGED_META_KEY.into(), json!(true));
        let original = Session {
            id: "abc".into(),
            kind: Some("claude".into()),
            label: Some("My Chat".into()),
            name: Some("Renamed".into()),
            meta,
            carry: serde_json::Map::new(),
            slot: None,
            state: State::Thinking,
            last_update: Instant::now(),
            attachment: None,
            health: SessionHealth::Unknown,
            health_reason: None,
            last_verified: None,
            failed_probes: 0,
            first_probe_failure: None,
            slot_history: Vec::new(),
        };
        let v = session_to_json(&original);
        let restored = session_from_json(&v, original.last_update, true).expect("parses");
        assert_eq!(restored.id, original.id);
        assert_eq!(restored.kind, original.kind);
        assert_eq!(restored.label, original.label);
        assert_eq!(restored.name, original.name);
        assert_eq!(restored.slot, original.slot);
        assert_eq!(restored.state, original.state);
        assert_eq!(restored.meta, original.meta);
        assert!(restored.is_backlogged());
        let external = session_to_dto(&original, None);
        assert!(external.backlogged);
        assert!(external.meta.get("transcript_path").is_none());
        assert!(external
            .meta
            .get(crate::session::BACKLOGGED_META_KEY)
            .is_none());
        assert_eq!(external.meta["turns"], json!(7));
    }

    #[test]
    fn disconnected_dto_hides_last_held_slot() {
        let session = Session {
            id: "detached".into(),
            kind: Some("codex".into()),
            label: None,
            name: None,
            meta: Map::new(),
            carry: Map::new(),
            slot: Some(6),
            state: State::Idle,
            last_update: Instant::now(),
            attachment: Some(Attachment::Process {
                id: "process:7:42:11:codex".into(),
                boot_time: 7,
                pid: 42,
                process_start_time: 11,
                executable: "/usr/local/bin/codex".into(),
                pane_tty: None,
                terminal: TerminalEndpoint::default(),
            }),
            health: SessionHealth::Detached,
            health_reason: Some("provider process exited".into()),
            last_verified: None,
            failed_probes: 0,
            first_probe_failure: None,
            slot_history: vec![6],
        };

        assert_eq!(session_to_dto(&session, Some(false)).slot, None);
        assert_eq!(session.slot, Some(6), "durable history stays private");
    }

    #[test]
    fn request_dto_decodes_protocol_commands() {
        let request: Request = serde_json::from_value(json!({
            "cmd": "set-state", "state": "running", "session": "s1",
            "kind": "claude", "meta": {"cwd": "/repo"}
        }))
        .expect("typed request decodes");
        assert!(
            matches!(request, Request::SetState { state, session: Some(session), .. }
            if state == "running" && session == "s1")
        );

        let request: Request = serde_json::from_value(json!({
            "cmd": "inject", "kind": "dial", "delta": -1
        }))
        .expect("typed inject decodes");
        assert!(matches!(request, Request::Inject { kind, delta: Some(-1), .. } if kind == "dial"));

        let request: Request = serde_json::from_value(json!({
            "cmd": "set-session-backlogged", "session": "s1", "backlogged": true
        }))
        .expect("typed backlog request decodes");
        assert!(
            matches!(request, Request::SetSessionBacklogged { session, backlogged: true }
            if session == "s1")
        );

        let request: Request = serde_json::from_value(json!({
            "cmd": "channel-read", "task_id": "worker", "channel": "ch-1",
            "tail": 25, "ack": true
        }))
        .expect("typed channel read decodes");
        assert!(matches!(
            request,
            Request::ChannelRead {
                ack: Some(true),
                ..
            }
        ));

        let request: Request = serde_json::from_value(json!({
            "cmd": "channel-ack", "task_id": "worker", "channel": "ch-1",
            "through": 42
        }))
        .expect("typed channel acknowledgement decodes");
        assert!(matches!(request, Request::ChannelAck { through: 42, .. }));
    }

    #[test]
    fn dto_session_payload_never_exposes_carry_bookkeeping() {
        let session = Session {
            id: "s1".into(),
            kind: Some("claude".into()),
            label: None,
            name: None,
            meta: Map::from_iter([
                ("turns".into(), json!(8)),
                ("_carry_turns".into(), json!(5)),
            ]),
            carry: Map::from_iter([("turns".into(), json!(5))]),
            slot: Some(1),
            state: State::Running,
            last_update: Instant::now(),
            attachment: None,
            health: SessionHealth::Unknown,
            health_reason: None,
            last_verified: None,
            failed_probes: 0,
            first_probe_failure: None,
            slot_history: vec![1],
        };
        let payload = session_to_json(&session);
        assert_eq!(payload["backlogged"], json!(false));
        assert!(payload["meta"].get("_carry_turns").is_none());
        assert_eq!(payload["carry"]["turns"], json!(5));
        let event = session_event_line(
            &session.id,
            &session.kind,
            &session.label,
            &session.name,
            &session.meta,
            session.slot,
            session.state,
        );
        assert!(!event.contains("_carry_"));
    }

    #[test]
    fn session_from_json_rejects_malformed_input() {
        assert!(session_from_json(&json!({"kind": "claude"}), Instant::now(), true).is_none());
        assert!(session_from_json(
            &json!({"session": "x", "state": "not-a-real-state"}),
            Instant::now(),
            true
        )
        .is_none());
    }

    #[test]
    fn legacy_live_snapshot_without_attachment_migrates_to_unverified() {
        let legacy = json!({
            "session": "legacy-codex",
            "state": "running",
            "kind": "codex",
            "slot": 6,
            "health": "unknown",
            "meta": {}
        });

        let live = session_from_json(&legacy, Instant::now(), true).expect("live session parses");
        assert!(matches!(
            live.attachment,
            Some(Attachment::Unverified { .. })
        ));
        assert_eq!(live.health, SessionHealth::Unknown);
        assert_eq!(
            live.health_reason.as_deref(),
            Some("restored integration awaiting authoritative ownership")
        );

        let tombstone =
            session_from_json(&legacy, Instant::now(), false).expect("tombstone parses");
        assert!(tombstone.attachment.is_none());
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
                DeviceEvent::Key {
                    control: 0,
                    pressed: true
                },
                DeviceEvent::Key {
                    control: 0,
                    pressed: false
                },
            ]
        );
    }

    #[test]
    fn inject_key_press_and_release() {
        let press =
            parse_inject(&json!({"kind":"key","control":"reject","action":"press"})).unwrap();
        assert_eq!(
            press,
            vec![DeviceEvent::Key {
                control: 1,
                pressed: true
            }]
        );
        let release =
            parse_inject(&json!({"kind":"key","control":"reject","action":"release"})).unwrap();
        assert_eq!(
            release,
            vec![DeviceEvent::Key {
                control: 1,
                pressed: false
            }]
        );
    }

    #[test]
    fn inject_key_defaults_to_tap_when_action_missing() {
        let events = parse_inject(&json!({"kind":"key","control":"key1"})).unwrap();
        assert_eq!(events.len(), 2);
        assert_eq!(
            events[0],
            DeviceEvent::Key {
                control: 4,
                pressed: true
            }
        );
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

    #[test]
    fn snapshot_markers_match_protocol() {
        assert_eq!(
            event_line(Event::SnapshotBegin { generation: 42 }),
            r#"{"event":"snapshot-begin","generation":42}"#
        );
        assert_eq!(
            event_line(Event::SnapshotEnd { generation: 42 }),
            r#"{"event":"snapshot-end","generation":42}"#
        );
    }

    #[test]
    fn focus_event_matches_protocol() {
        assert_eq!(
            event_line(Event::Focus {
                session: "session-123".into()
            }),
            r#"{"event":"focus","session":"session-123"}"#
        );
    }

    #[test]
    fn focus_result_carries_exact_failure_diagnostics() {
        let value: Value = serde_json::from_str(&event_line(Event::FocusResult {
            session: "slot-1".into(),
            slot: Some(1),
            attachment_id: Some("process:1:2:3:codex".into()),
            strategy: "terminal-session-id".into(),
            result: "endpoint-missing".into(),
            terminal_pid: Some(42),
            terminal_session_id: Some("unique-session".into()),
            reason: Some("no exact terminal endpoint".into()),
        }))
        .unwrap();
        assert_eq!(value["event"], "focus-result");
        assert_eq!(value["session"], "slot-1");
        assert_eq!(value["result"], "endpoint-missing");
        assert_eq!(value["terminal_session_id"], "unique-session");
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
        let (_, hi) = parse_set_style(
            &json!({"state":"idle","rgb":[0,0,0],"pattern":"off","period_ms":9000}),
        )
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
        assert!(
            parse_set_style(&json!({"state":"waiting","rgb":[0,0,0],"pattern":"sparkle"})).is_err()
        );
        // bad state
        assert!(parse_set_style(&json!({"state":"nope","rgb":[0,0,0],"pattern":"solid"})).is_err());
        // rgb wrong length
        assert!(parse_set_style(&json!({"state":"idle","rgb":[0,0],"pattern":"solid"})).is_err());
        // rgb out of range
        assert!(
            parse_set_style(&json!({"state":"idle","rgb":[0,0,300],"pattern":"solid"})).is_err()
        );
        // missing fields
        assert!(parse_set_style(&json!({"state":"idle"})).is_err());
        assert!(parse_set_style(&json!({"rgb":[0,0,0],"pattern":"solid"})).is_err());
    }

    #[cfg(unix)]
    #[test]
    fn launch_selection_is_required_and_never_defaults() {
        let legacy = serde_json::from_value::<Request>(json!({
            "cmd":"launch-session", "provider":"codex", "cwd":"/tmp",
            "task":"Inspect it", "task_id":"inspect-1"
        }));
        assert!(
            legacy.is_ok(),
            "omissions decode so the daemon can return an actionable error"
        );
        assert!(required_launch_selection(None, None).is_err());
        assert!(required_launch_selection(Some("general"), Some("gpt-5.6-terra")).is_err());
        assert!(required_launch_selection(Some("reviewer"), Some("provider-default")).is_err());
        assert_eq!(
            required_launch_selection(Some("correctness-reviewer"), Some("gpt-5.6-terra")),
            Ok(("correctness-reviewer", "gpt-5.6-terra"))
        );

        let self_asserted = serde_json::from_value::<Request>(json!({
            "cmd":"launch-session", "agent_type":"reviewer", "provider":"codex",
            "model":"gpt-5.6-sol", "cwd":"/tmp", "task":"Review it",
            "task_id":"review-1", "workflow_id":"review",
            "workflow_run_id":"review-run-1", "workflow_phase":"review",
            "workflow_gate":"confirm", "transition_confirmation":"user-confirmed"
        }))
        .expect("legacy field decodes for an actionable daemon rejection");
        let Request::LaunchSession {
            transition_confirmation,
            ..
        } = self_asserted
        else {
            panic!("launch request");
        };
        assert!(validate_workflow_launch_metadata(
            "worker",
            Some("review"),
            Some("review-run-1"),
            Some("review"),
            Some("confirm"),
            false,
            Some("reviewer"),
            None,
            transition_confirmation.as_deref()
        )
        .unwrap_err()
        .contains("not accepted"));
    }

    #[cfg(unix)]
    #[test]
    fn workflow_manifest_validation_fails_closed_and_accepts_exact_structure() {
        let assignments = vec![WorkflowAssignmentAuthorization {
            assignment_id: "review:reviewer:0".into(),
            phase: "review".into(),
            agent_type: "reviewer".into(),
            provider: "codex".into(),
            model: "gpt-5.6-sol".into(),
            gate: "confirm".into(),
            fanout: false,
            fanout_limit: 1,
        }];
        assert!(validate_workflow_launch_metadata(
            "orchestrator",
            Some("review"),
            Some("run-1"),
            Some("orchestration"),
            Some("authorized"),
            false,
            None,
            Some(&assignments),
            None
        )
        .is_ok());
        assert!(validate_workflow_launch_metadata(
            "orchestrator",
            Some("review"),
            Some("run-1"),
            Some("orchestration"),
            Some("authorized"),
            false,
            None,
            None,
            None
        )
        .is_err());
        assert!(validate_workflow_launch_metadata(
            "worker",
            Some("review"),
            Some("run-1"),
            Some("review"),
            Some("confirm"),
            false,
            None,
            None,
            None
        )
        .is_err());
        assert!(validate_workflow_launch_metadata(
            "worker", None, None, None, None, false, None, None, None
        )
        .is_ok());

        let mut duplicate = assignments.clone();
        duplicate.push(assignments[0].clone());
        assert!(validate_workflow_assignment_manifest(&duplicate).is_err());
        let mut implicit = assignments.clone();
        implicit[0].model = "provider-default".into();
        assert!(validate_workflow_assignment_manifest(&implicit).is_err());
        let mut unsafe_fanout = assignments;
        unsafe_fanout[0].gate = "auto".into();
        unsafe_fanout[0].fanout = true;
        unsafe_fanout[0].fanout_limit = 2;
        assert!(validate_workflow_assignment_manifest(&unsafe_fanout).is_err());
        let too_many = vec![workflow_test_assignment("authorized", 1); WORKFLOW_ASSIGNMENT_MAX + 1];
        assert!(validate_workflow_assignment_manifest(&too_many).is_err());
    }

    #[cfg(unix)]
    #[test]
    fn workflow_receipt_replay_requires_the_exact_static_manifest() {
        let requested = vec![workflow_test_assignment("authorized", 1)];
        let receipt = json!({"workflow_assignments": workflow_ledger_value(&requested)});
        assert!(receipt_workflow_manifest_matches(
            &receipt,
            Some(&requested)
        ));
        let mut changed = requested.clone();
        changed[0].model = "different".into();
        assert!(!receipt_workflow_manifest_matches(&receipt, Some(&changed)));
        assert!(!receipt_workflow_manifest_matches(&receipt, None));
    }

    #[cfg(unix)]
    fn workflow_test_receipt(assignments: &[WorkflowAssignmentAuthorization]) -> PathBuf {
        let path = std::env::temp_dir().join(format!(
            "focalpoint-workflow-test-{}.json",
            new_relaunch_id()
        ));
        std::fs::write(
            &path,
            serde_json::to_vec(&json!({
                "task_id":"run-1", "workflow_run_id":"run-1", "workflow_id":"review",
                "role":"orchestrator", "workflow_assignments": workflow_ledger_value(assignments),
                "workflow_approvals": {}
            }))
            .unwrap(),
        )
        .unwrap();
        path
    }

    #[cfg(unix)]
    fn workflow_test_assignment(gate: &str, limit: u16) -> WorkflowAssignmentAuthorization {
        WorkflowAssignmentAuthorization {
            assignment_id: "review:reviewer:0".into(),
            phase: "review".into(),
            agent_type: "reviewer".into(),
            provider: "codex".into(),
            model: "gpt-5.6-sol".into(),
            gate: gate.into(),
            fanout_limit: limit,
            fanout: limit > 1,
        }
    }

    #[cfg(unix)]
    #[test]
    fn workflow_ledger_accepts_exact_assignment_and_rejects_mismatches() {
        let assignment = workflow_test_assignment("authorized", 1);
        let path = workflow_test_receipt(&[assignment]);
        let exact = consume_workflow_assignment_at(
            &path,
            "review",
            "run-1",
            "review",
            "authorized",
            false,
            "review:reviewer:0",
            "reviewer",
            "codex",
            "gpt-5.6-sol",
            Some("run-1"),
            "worker-1",
        );
        assert!(exact.is_ok());
        assert!(consume_workflow_assignment_at(
            &path,
            "review",
            "run-1",
            "review",
            "authorized",
            false,
            "review:reviewer:0",
            "reviewer",
            "codex",
            "gpt-5.6-sol",
            Some("run-1"),
            "worker-replay"
        )
        .unwrap_err()
        .contains("exhausted"));
        let _ = std::fs::remove_file(&path);

        let cases = [
            (
                "other",
                "review",
                "authorized",
                "reviewer",
                "codex",
                "gpt-5.6-sol",
                Some("run-1"),
                false,
            ),
            (
                "review:reviewer:0",
                "other",
                "authorized",
                "reviewer",
                "codex",
                "gpt-5.6-sol",
                Some("run-1"),
                false,
            ),
            (
                "review:reviewer:0",
                "review",
                "auto",
                "reviewer",
                "codex",
                "gpt-5.6-sol",
                Some("run-1"),
                false,
            ),
            (
                "review:reviewer:0",
                "review",
                "authorized",
                "other",
                "codex",
                "gpt-5.6-sol",
                Some("run-1"),
                false,
            ),
            (
                "review:reviewer:0",
                "review",
                "authorized",
                "reviewer",
                "claude",
                "gpt-5.6-sol",
                Some("run-1"),
                false,
            ),
            (
                "review:reviewer:0",
                "review",
                "authorized",
                "reviewer",
                "codex",
                "other",
                Some("run-1"),
                false,
            ),
            (
                "review:reviewer:0",
                "review",
                "authorized",
                "reviewer",
                "codex",
                "gpt-5.6-sol",
                Some("other"),
                false,
            ),
            (
                "review:reviewer:0",
                "review",
                "authorized",
                "reviewer",
                "codex",
                "gpt-5.6-sol",
                Some("run-1"),
                true,
            ),
        ];
        for (id, phase, gate, agent_type, provider, model, manager, fanout) in cases {
            let path = workflow_test_receipt(&[workflow_test_assignment("authorized", 1)]);
            assert!(consume_workflow_assignment_at(
                &path, "review", "run-1", phase, gate, fanout, id, agent_type, provider, model,
                manager, "worker-x"
            )
            .is_err());
            let receipt: Value = serde_json::from_slice(&std::fs::read(&path).unwrap()).unwrap();
            assert_eq!(
                receipt["workflow_assignments"][0]["launches_consumed"],
                json!(0)
            );
            let _ = std::fs::remove_file(path);
        }
    }

    #[cfg(unix)]
    #[test]
    fn workflow_fanout_cap_and_one_shot_approval_are_daemon_owned() {
        let path = workflow_test_receipt(&[workflow_test_assignment("confirm", 2)]);
        let launch = |task: &str| {
            consume_workflow_assignment_at(
                &path,
                "review",
                "run-1",
                "review",
                "confirm",
                true,
                "review:reviewer:0",
                "reviewer",
                "codex",
                "gpt-5.6-sol",
                Some("run-1"),
                task,
            )
        };
        assert!(launch("worker-1")
            .unwrap_err()
            .contains("no daemon-recorded"));
        approve_workflow_transition_at(&path, "run-1", "review").unwrap();
        assert!(approve_workflow_transition_at(&path, "run-1", "review").is_err());
        assert!(launch("worker-1").is_ok());
        assert!(launch("worker-replay")
            .unwrap_err()
            .contains("already consumed"));
        approve_workflow_transition_at(&path, "run-1", "review").unwrap();
        assert!(launch("worker-2").is_ok());
        assert!(approve_workflow_transition_at(&path, "run-1", "review")
            .unwrap_err()
            .contains("exhausted"));
        let _ = std::fs::remove_file(path);
    }

    #[test]
    fn confirmed_stop_request_requires_confirmation_field_at_decode() {
        assert!(serde_json::from_value::<Request>(json!({
            "cmd":"stop-managed-session", "session":"s1", "task_id":"task-1"
        }))
        .is_err());
        assert!(serde_json::from_value::<Request>(json!({
            "cmd":"stop-managed-session", "session":"s1", "task_id":"task-1",
            "confirmation":"user-confirmed"
        }))
        .is_ok());
    }
}
