//! Thin socket client used by the `focalpoint` CLI (PROTOCOL.md §3 & §4).

#[cfg(unix)]
use crate::paths::socket_path;
#[cfg(unix)]
use crate::protocol::State;

/// Error type carrying a message and the process exit code the CLI should use.
#[derive(Debug)]
pub struct CliError {
    pub message: String,
    pub code: i32,
}

impl CliError {
    fn new(message: impl Into<String>, code: i32) -> Self {
        CliError {
            message: message.into(),
            code,
        }
    }
}

#[cfg(unix)]
fn connect() -> Result<std::os::unix::net::UnixStream, CliError> {
    let path = socket_path();
    std::os::unix::net::UnixStream::connect(&path).map_err(|e| {
        CliError::new(
            format!(
                "cannot connect to daemon at {} ({e}). Is focalpointd running?",
                path.display()
            ),
            1,
        )
    })
}

/// Send one request line and read exactly one response line.
#[cfg(unix)]
fn request(req: serde_json::Value) -> Result<serde_json::Value, CliError> {
    use std::io::{BufRead, BufReader, Write};

    let stream = connect()?;
    let mut writer = stream
        .try_clone()
        .map_err(|e| CliError::new(format!("socket error: {e}"), 1))?;
    let mut line = req.to_string();
    line.push('\n');
    writer
        .write_all(line.as_bytes())
        .map_err(|e| CliError::new(format!("write error: {e}"), 1))?;

    let mut reader = BufReader::new(stream);
    let mut resp = String::new();
    reader
        .read_line(&mut resp)
        .map_err(|e| CliError::new(format!("read error: {e}"), 1))?;
    if resp.trim().is_empty() {
        return Err(CliError::new("daemon closed the connection", 1));
    }
    serde_json::from_str(&resp).map_err(|e| CliError::new(format!("bad response: {e}"), 1))
}

/// Assert the response has `ok: true`, else surface its error.
#[cfg(unix)]
fn expect_ok(resp: &serde_json::Value) -> Result<(), CliError> {
    if resp.get("ok").and_then(|v| v.as_bool()) == Some(true) {
        Ok(())
    } else {
        let msg = resp
            .get("error")
            .and_then(|v| v.as_str())
            .unwrap_or("request failed");
        Err(CliError::new(msg.to_string(), 1))
    }
}

/// Auto-resolve tty/pid identity for `session`/`kind` and merge into
/// `meta_obj`, unless the caller already supplied an explicit tty/pid meta
/// value. Only applies to kinds whose adapter wants ancestry-derived
/// identity (`claude`, `codex`) — skipped for everything else (`cursor`,
/// `generic`, unknown), matching the reasoning bash used before this moved
/// into Rust (SESSION-IDENTITY-PERSISTENCE-PLAN.md Part 1). A fully empty
/// resolution is not cached, so subsequent hooks for the same instance
/// automatically retry and self-heal.
#[cfg(unix)]
fn apply_identity(
    meta_obj: &mut serde_json::Map<String, serde_json::Value>,
    session: Option<&str>,
    kind: Option<&str>,
    refresh_identity: bool,
) {
    let (Some(session), Some(kind)) = (session, kind) else {
        return;
    };
    if !matches!(kind, "claude" | "codex") {
        return;
    }
    let identity = crate::identity::resolve_identity(session, kind, refresh_identity);
    if !meta_obj.contains_key("tty") {
        if let Some(tty) = identity.tty {
            meta_obj.insert("tty".to_string(), serde_json::Value::from(tty));
        }
    }
    if !meta_obj.contains_key("pid") {
        if let Some(pid) = identity.pid {
            meta_obj.insert("pid".to_string(), serde_json::Value::from(pid));
        }
    }
}

/// `focalpoint set-state <name> [--session] [--kind] [--label] [--cwd] [--meta k=v]... [--refresh-identity]`
#[cfg(unix)]
pub fn set_state(
    name: &str,
    session: Option<&str>,
    kind: Option<&str>,
    label: Option<&str>,
    cwd: Option<&str>,
    meta: &[String],
    refresh_identity: bool,
) -> Result<(), CliError> {
    if State::from_name(name).is_none() {
        return Err(CliError::new(
            format!(
                "unknown state {name:?}; expected one of idle|thinking|running|waiting|approval|done|error|compacting"
            ),
            2,
        ));
    }
    let mut req = serde_json::json!({ "cmd": "set-state", "state": name });
    if let Some(s) = session {
        req["session"] = s.into();
    }
    if let Some(k) = kind {
        req["kind"] = k.into();
    }
    if let Some(l) = label {
        req["label"] = l.into();
    }
    let mut meta_obj = serde_json::Map::new();
    if let Some(c) = cwd {
        meta_obj.insert("cwd".to_string(), c.into());
    }
    for kv in meta {
        let Some((k, v)) = kv.split_once('=') else {
            return Err(CliError::new(
                format!("invalid --meta {kv:?}; expected key=value"),
                2,
            ));
        };
        let value = if let Ok(i) = v.parse::<i64>() {
            serde_json::Value::from(i)
        } else if let Ok(f) = v.parse::<f64>() {
            serde_json::Value::from(f)
        } else {
            serde_json::Value::from(v)
        };
        meta_obj.insert(k.to_string(), value);
    }
    apply_identity(&mut meta_obj, session, kind, refresh_identity);
    if !meta_obj.is_empty() {
        req["meta"] = serde_json::Value::Object(meta_obj);
    }
    let resp = request(req)?;
    expect_ok(&resp)?;
    println!("ok");
    Ok(())
}

/// `focalpoint set-meta --session <ID> [--kind] [--label] [--meta k=v]... [--refresh-identity]`
/// Meta-only: merges into an existing session's `meta` without touching its
/// live state (unlike `set-state`, which requires one). Unknown session ids
/// are a no-op on the daemon side, not registered.
#[cfg(unix)]
pub fn set_meta(
    session: &str,
    kind: Option<&str>,
    label: Option<&str>,
    meta: &[String],
    refresh_identity: bool,
) -> Result<(), CliError> {
    if session.is_empty() {
        return Err(CliError::new("--session must not be empty", 2));
    }
    let mut req = serde_json::json!({ "cmd": "set-meta", "session": session });
    if let Some(k) = kind {
        req["kind"] = k.into();
    }
    if let Some(l) = label {
        req["label"] = l.into();
    }
    let mut meta_obj = serde_json::Map::new();
    for kv in meta {
        let Some((k, v)) = kv.split_once('=') else {
            return Err(CliError::new(
                format!("invalid --meta {kv:?}; expected key=value"),
                2,
            ));
        };
        let value = if let Ok(i) = v.parse::<i64>() {
            serde_json::Value::from(i)
        } else if let Ok(f) = v.parse::<f64>() {
            serde_json::Value::from(f)
        } else {
            serde_json::Value::from(v)
        };
        meta_obj.insert(k.to_string(), value);
    }
    apply_identity(&mut meta_obj, Some(session), kind, refresh_identity);
    if !meta_obj.is_empty() {
        req["meta"] = serde_json::Value::Object(meta_obj);
    }
    let resp = request(req)?;
    expect_ok(&resp)?;
    println!("ok");
    Ok(())
}

/// `focalpoint set-usage <provider> --meta key=value...`
#[cfg(unix)]
pub fn set_usage(provider: &str, meta: &[String]) -> Result<(), CliError> {
    if provider.is_empty() {
        return Err(CliError::new("provider must not be empty", 2));
    }
    let mut usage = serde_json::Map::new();
    for kv in meta {
        let Some((key, raw)) = kv.split_once('=') else {
            return Err(CliError::new(
                format!("invalid --meta {kv:?}; expected key=value"),
                2,
            ));
        };
        let value = raw
            .parse::<f64>()
            .map_err(|_| CliError::new(format!("usage value for {key:?} must be numeric"), 2))?;
        if !value.is_finite() {
            return Err(CliError::new(
                format!("usage value for {key:?} must be finite"),
                2,
            ));
        }
        usage.insert(key.to_string(), serde_json::Value::from(value));
    }
    if usage.is_empty() {
        return Err(CliError::new("set-usage requires at least one --meta", 2));
    }
    let resp = request(serde_json::json!({
        "cmd": "set-usage", "provider": provider, "usage": usage,
    }))?;
    expect_ok(&resp)?;
    println!("ok");
    Ok(())
}

/// `focalpoint usage [--json]`
#[cfg(unix)]
pub fn usage(json: bool) -> Result<(), CliError> {
    let resp = request(serde_json::json!({ "cmd": "get-usage" }))?;
    expect_ok(&resp)?;
    let usage = resp
        .get("usage")
        .cloned()
        .unwrap_or_else(|| serde_json::json!({}));
    if json {
        println!("{usage}");
    } else {
        println!("{usage:#}");
    }
    Ok(())
}

/// `focalpoint get-state` (aggregate)
#[cfg(unix)]
pub fn get_state() -> Result<(), CliError> {
    let resp = request(serde_json::json!({ "cmd": "get-state" }))?;
    expect_ok(&resp)?;
    let state = resp
        .get("state")
        .and_then(|v| v.as_str())
        .ok_or_else(|| CliError::new("response missing state", 1))?;
    println!("{state}");
    Ok(())
}

/// `focalpoint sessions [--json]`
#[cfg(unix)]
pub fn sessions(json: bool) -> Result<(), CliError> {
    let resp = request(serde_json::json!({ "cmd": "list-sessions" }))?;
    expect_ok(&resp)?;
    let list = resp
        .get("sessions")
        .and_then(|v| v.as_array())
        .cloned()
        .unwrap_or_default();
    if json {
        println!("{}", serde_json::Value::Array(list));
        return Ok(());
    }
    if list.is_empty() {
        println!("(no live sessions)");
        return Ok(());
    }
    // Human-readable table.
    println!(
        "{:<5} {:<10} {:<9} {:<16} {:<20} CWD",
        "SLOT", "KIND", "STATE", "NAME", "SESSION"
    );
    for s in &list {
        let slot = s
            .get("slot")
            .and_then(|v| v.as_u64())
            .map(|n| n.to_string())
            .unwrap_or_else(|| "-".into());
        let field = |k: &str| s.get(k).and_then(|v| v.as_str()).unwrap_or("").to_string();
        let cwd = s
            .get("meta")
            .and_then(|m| m.get("cwd"))
            .and_then(|v| v.as_str())
            .unwrap_or("");
        // The user's rename wins over the adapter's label, matching what
        // every other front-end shows for this session.
        let display = [field("name"), field("label"), field("kind")]
            .into_iter()
            .find(|v| !v.is_empty())
            .unwrap_or_default();
        println!(
            "{:<5} {:<10} {:<9} {:<16} {:<20} {}",
            slot,
            field("kind"),
            field("state"),
            display,
            field("session"),
            cwd
        );
    }
    Ok(())
}

/// `focalpoint rename-session <ID> [NAME]` — omit NAME (or pass an empty one)
/// to clear the rename and fall back to the adapter's label.
#[cfg(unix)]
pub fn rename_session(id: &str, name: Option<&str>) -> Result<(), CliError> {
    let resp = request(serde_json::json!({
        "cmd": "rename-session",
        "session": id,
        "name": name,
    }))?;
    expect_ok(&resp)?;
    println!("ok");
    Ok(())
}

/// Move a live session into or out of the daemon-owned backlog.
#[cfg(unix)]
pub fn set_session_backlogged(id: &str, backlogged: bool) -> Result<(), CliError> {
    let resp = request(serde_json::json!({
        "cmd": "set-session-backlogged",
        "session": id,
        "backlogged": backlogged,
    }))?;
    expect_ok(&resp)?;
    println!("ok");
    Ok(())
}

/// `focalpoint swap-slots <ID1> <ID2>` — manual reorder: exchange the
/// numbered-key slots of two live sessions.
#[cfg(unix)]
pub fn swap_slots(id1: &str, id2: &str) -> Result<(), CliError> {
    let resp = request(serde_json::json!({
        "cmd": "swap-slots",
        "session1": id1,
        "session2": id2,
    }))?;
    expect_ok(&resp)?;
    println!("ok");
    Ok(())
}

/// `focalpoint move-slot <ID> <N>` — manual sparse placement: move a live
/// session onto free numbered slot N (1-12), leaving a gap. Companion to
/// `swap-slots`, which exchanges two occupied slots.
#[cfg(unix)]
pub fn move_slot(id: &str, slot: u64) -> Result<(), CliError> {
    let resp = request(serde_json::json!({
        "cmd": "move-slot",
        "session": id,
        "slot": slot,
    }))?;
    expect_ok(&resp)?;
    println!("ok");
    Ok(())
}

/// `focalpoint end-session <ID>` — also clears the cached identity for `id`
/// (Part 1's `identity.rs`), the one chokepoint every adapter's `SessionEnd`
/// already calls through, so a reused session_id never inherits a stale
/// tty/pid.
#[cfg(unix)]
pub fn end_session(id: &str) -> Result<(), CliError> {
    let resp = request(serde_json::json!({ "cmd": "end-session", "session": id }))?;
    crate::identity::remove_identity(id);
    expect_ok(&resp)?;
    println!("ok");
    Ok(())
}

/// `focalpoint set-led <index|all> <r> <g> <b>`
#[cfg(unix)]
pub fn set_led(index: &str, r: u8, g: u8, b: u8) -> Result<(), CliError> {
    let idx: u8 = if index.eq_ignore_ascii_case("all") {
        0xFF
    } else {
        index.parse().map_err(|_| {
            CliError::new(format!("invalid index {index:?}; use 0..=255 or 'all'"), 2)
        })?
    };
    let resp = request(serde_json::json!({
        "cmd": "set-led",
        "index": idx,
        "rgb": [r, g, b],
    }))?;
    expect_ok(&resp)?;
    println!("ok");
    Ok(())
}

/// `focalpoint watch` — subscribe and stream NDJSON events to stdout.
#[cfg(unix)]
pub fn watch() -> Result<(), CliError> {
    use std::io::{BufRead, BufReader, Write};

    let stream = connect()?;
    let mut writer = stream
        .try_clone()
        .map_err(|e| CliError::new(format!("socket error: {e}"), 1))?;
    writer
        .write_all(b"{\"cmd\":\"subscribe\"}\n")
        .map_err(|e| CliError::new(format!("write error: {e}"), 1))?;

    let reader = BufReader::new(stream);
    for line in reader.lines() {
        match line {
            Ok(l) => {
                println!("{l}");
                let _ = std::io::stdout().flush();
            }
            Err(_) => break,
        }
    }
    Ok(())
}

/// `focalpoint ping` — exit 0 only if the daemon is reachable AND a device is up.
#[cfg(unix)]
pub fn ping() -> Result<(), CliError> {
    let resp = request(serde_json::json!({ "cmd": "ping" }))?;
    expect_ok(&resp)?;
    let device = resp
        .get("device")
        .and_then(|v| v.as_bool())
        .unwrap_or(false);
    if device {
        println!("ok: daemon up, device present");
        Ok(())
    } else {
        Err(CliError::new("daemon up but no device attached", 1))
    }
}

/// `focalpoint styles [--json]`
#[cfg(unix)]
pub fn styles(json: bool) -> Result<(), CliError> {
    let resp = request(serde_json::json!({ "cmd": "get-styles" }))?;
    expect_ok(&resp)?;
    let styles = resp
        .get("styles")
        .and_then(|v| v.as_object())
        .cloned()
        .unwrap_or_default();
    if json {
        println!("{}", serde_json::Value::Object(styles));
        return Ok(());
    }
    println!("{:<9} {:<15} {:<9} PERIOD_MS", "STATE", "RGB", "PATTERN");
    // Emit in the canonical state order.
    for state in [
        "idle",
        "thinking",
        "running",
        "waiting", "approval",
        "done",
        "error",
        "compacting",
    ] {
        let Some(s) = styles.get(state) else { continue };
        let rgb = s
            .get("rgb")
            .and_then(|v| v.as_array())
            .map(|a| {
                a.iter()
                    .filter_map(|n| n.as_u64())
                    .map(|n| n.to_string())
                    .collect::<Vec<_>>()
                    .join(",")
            })
            .unwrap_or_default();
        let pattern = s.get("pattern").and_then(|v| v.as_str()).unwrap_or("");
        let period = s
            .get("period_ms")
            .and_then(|v| v.as_u64())
            .map(|n| n.to_string())
            .unwrap_or_default();
        println!(
            "{state:<9} {:<15} {pattern:<9} {period}",
            format!("[{rgb}]")
        );
    }
    Ok(())
}

/// `focalpoint set-style <state> <r> <g> <b> <pattern> [period_ms]`
#[cfg(unix)]
pub fn set_style(
    state: &str,
    r: u8,
    g: u8,
    b: u8,
    pattern: &str,
    period_ms: Option<u16>,
) -> Result<(), CliError> {
    let mut req = serde_json::json!({
        "cmd": "set-style", "state": state, "rgb": [r, g, b], "pattern": pattern,
    });
    if let Some(p) = period_ms {
        req["period_ms"] = p.into();
    }
    let resp = request(req)?;
    expect_ok(&resp)?;
    println!("ok");
    Ok(())
}

/// `focalpoint inject key <control> <press|release|tap>`
#[cfg(unix)]
pub fn inject_key(control: &str, action: &str) -> Result<(), CliError> {
    if !matches!(action, "press" | "release" | "tap") {
        return Err(CliError::new(
            format!("invalid action {action:?}; expected press|release|tap"),
            2,
        ));
    }
    let resp = request(serde_json::json!({
        "cmd": "inject", "kind": "key", "control": control, "action": action,
    }))?;
    expect_ok(&resp)?;
    println!("ok");
    Ok(())
}

/// `focalpoint inject dial <delta>`
#[cfg(unix)]
pub fn inject_dial(delta: i64) -> Result<(), CliError> {
    let resp = request(serde_json::json!({ "cmd": "inject", "kind": "dial", "delta": delta }))?;
    expect_ok(&resp)?;
    println!("ok");
    Ok(())
}

/// `focalpoint inject joy <gesture>`
#[cfg(unix)]
pub fn inject_joy(gesture: &str) -> Result<(), CliError> {
    let resp = request(serde_json::json!({ "cmd": "inject", "kind": "joy", "gesture": gesture }))?;
    expect_ok(&resp)?;
    println!("ok");
    Ok(())
}

// Non-unix stubs so the CLI still compiles (and fails clearly).
#[cfg(not(unix))]
macro_rules! win_stub {
    ($($name:ident($($arg:ident : $ty:ty),*)),* $(,)?) => {$(
        pub fn $name($(_ : $ty),*) -> Result<(), CliError> {
            Err(CliError::new(
                "the focalpoint client requires a Unix domain socket; Windows named pipes are not yet implemented",
                1,
            ))
        }
    )*};
}
#[cfg(not(unix))]
win_stub!(
    set_state(name: &str, session: Option<&str>, kind: Option<&str>, label: Option<&str>, cwd: Option<&str>, meta: &[String]),
    set_meta(session: &str, kind: Option<&str>, label: Option<&str>, meta: &[String]),
    set_usage(provider: &str, meta: &[String]),
    usage(json: bool),
    get_state(),
    sessions(json: bool),
    end_session(id: &str),
    swap_slots(id1: &str, id2: &str),
    move_slot(id: &str, slot: u64),
    set_led(index: &str, r: u8, g: u8, b: u8),
    styles(json: bool),
    set_style(state: &str, r: u8, g: u8, b: u8, pattern: &str, period_ms: Option<u16>),
    watch(),
    ping(),
    inject_key(control: &str, action: &str),
    inject_dial(delta: i64),
    inject_joy(gesture: &str),
);
