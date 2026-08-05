//! Narrow socket controller for supervising agents.
//!
//! This binary intentionally exposes no approval answers, arbitrary input,
//! session termination, slot mutation, shell execution, or local policy-file
//! writes. Session priority and managed launching are owned by focalpointd.

#[cfg(test)]
use clap::CommandFactory;
use clap::{Parser, Subcommand, ValueEnum};
use serde_json::{json, Value};
use std::io::{BufRead, BufReader, Write};
use std::os::unix::net::UnixStream;
use std::path::PathBuf;
use std::time::Duration;

#[derive(Parser, Debug)]
#[command(
    name = "fpctl-agent",
    about = "Safe FocalPoint orchestration controller"
)]
struct Cli {
    #[command(subcommand)]
    command: AgentCommand,
}

#[derive(Subcommand, Debug)]
enum AgentCommand {
    /// Read live sessions, provider usage, and daemon-owned attention order.
    Status,
    /// Read recoverable disconnected sessions retained by the daemon.
    History,
    /// Read the daemon-owned attention order.
    Order,
    /// Focus one exact session id.
    Focus { session: String },
    /// Promote one eligible unmanaged Claude/Codex session into the managed launcher.
    Relaunch { session: String },
    /// Focus the next waiting/error session in daemon priority order.
    Next,
    /// Focus the previous waiting/error session in daemon priority order.
    Previous,
    /// Replace the complete live-session priority order.
    Prioritize {
        /// Every live session id, highest priority first.
        #[arg(required = true)]
        sessions: Vec<String>,
    },
    /// Ask the daemon to open one managed agent for an authorized task.
    Launch {
        #[arg(long)]
        provider: Provider,
        /// Provider model id or alias. Omit to use that provider's default.
        #[arg(long)]
        model: Option<String>,
        #[arg(long)]
        cwd: PathBuf,
        #[arg(long)]
        task: String,
        #[arg(long)]
        task_id: String,
        /// Relationship shown by FocalPoint. Defaults to a normal worker.
        #[arg(long, value_enum, default_value_t = OrchestrationRole::Worker)]
        role: OrchestrationRole,
        /// Stable task id of the orchestrator supervising this worker.
        #[arg(long, requires = "task_id")]
        manager_task_id: Option<String>,
        /// Join the launched worker to this channel at its current tail.
        #[arg(long)]
        channel: Option<String>,
        /// Cursor only: headless streams structured lifecycle events; attachable
        /// opens Cursor's normal interactive terminal UI.
        #[arg(long, value_enum, default_value_t = CursorLaunchMode::Headless)]
        cursor_mode: CursorLaunchMode,
    },
    /// Pull-first mailbox operations for the current managed agent task.
    Channel { #[command(subcommand)] command: ChannelCommand },
    /// Gracefully stop a FocalPoint-launched session with matching ownership.
    Stop {
        #[arg(long)]
        session: String,
        #[arg(long)]
        task_id: String,
    },
    /// Read normalized, bounded messages from an owned session transcript.
    Transcript {
        #[arg(long)]
        session: String,
        #[arg(long)]
        task_id: String,
        /// Number of matching messages to return (1-8000).
        #[arg(long, default_value_t = 20, value_parser = clap::value_parser!(u16).range(1..=8_000))]
        tail: u16,
        /// Optional case-insensitive text filter.
        #[arg(long)]
        search: Option<String>,
    },
}

#[derive(Subcommand, Debug)]
enum ChannelCommand {
    Create,
    Post { #[arg(long)] channel: String, #[arg(long)] body: String, #[arg(long, default_value = "note")] kind: String, #[arg(long)] to: Option<String> },
    Read { #[arg(long)] channel: String, #[arg(long)] since: Option<u64>, #[arg(long, default_value_t = 20)] tail: u16 },
    Members { #[arg(long)] channel: String },
    Close { #[arg(long)] channel: String },
}

#[derive(Copy, Clone, Debug, ValueEnum)]
enum Provider {
    Claude,
    Codex,
    Cursor,
}

#[derive(Copy, Clone, Debug, Default, ValueEnum)]
enum CursorLaunchMode {
    /// Run Cursor in print/stream-json mode, tracked by FocalPoint's wrapper.
    #[default]
    Headless,
    /// Open Cursor's interactive terminal UI in the managed tmux pane.
    Attachable,
}

impl CursorLaunchMode {
    fn name(self) -> &'static str {
        match self {
            Self::Headless => "headless",
            Self::Attachable => "attachable",
        }
    }
}

#[derive(Copy, Clone, Debug, Default, ValueEnum)]
enum OrchestrationRole {
    Orchestrator,
    #[default]
    Worker,
}

impl OrchestrationRole {
    fn name(self) -> &'static str {
        match self {
            Self::Orchestrator => "orchestrator",
            Self::Worker => "worker",
        }
    }
}

impl Provider {
    fn name(self) -> &'static str {
        match self {
            Self::Claude => "claude",
            Self::Codex => "codex",
            Self::Cursor => "cursor",
        }
    }
}

fn home_dir() -> Result<PathBuf, String> {
    std::env::var_os("HOME")
        .map(PathBuf::from)
        .ok_or_else(|| "HOME is not set".into())
}

fn socket_path() -> Result<PathBuf, String> {
    if let Some(runtime) = std::env::var_os("XDG_RUNTIME_DIR") {
        Ok(PathBuf::from(runtime).join("focalpoint.sock"))
    } else {
        Ok(home_dir()?.join(".local/state/focalpoint/focalpoint.sock"))
    }
}

fn request(command: Value) -> Result<Value, String> {
    let path = socket_path()?;
    let mut stream = UnixStream::connect(&path)
        .map_err(|e| format!("cannot connect to daemon at {} ({e})", path.display()))?;
    let timeout = Some(Duration::from_secs(5));
    stream
        .set_read_timeout(timeout)
        .map_err(|e| e.to_string())?;
    stream
        .set_write_timeout(timeout)
        .map_err(|e| e.to_string())?;
    writeln!(stream, "{command}").map_err(|e| format!("socket write failed: {e}"))?;
    let mut response = String::new();
    BufReader::new(stream)
        .read_line(&mut response)
        .map_err(|e| format!("socket read failed: {e}"))?;
    if response.trim().is_empty() {
        return Err("daemon returned no response".into());
    }
    let value: Value = serde_json::from_str(&response)
        .map_err(|e| format!("daemon returned invalid JSON: {e}"))?;
    if value.get("ok").and_then(Value::as_bool) == Some(false) {
        return Err(value
            .get("error")
            .and_then(Value::as_str)
            .unwrap_or("daemon command failed")
            .to_string());
    }
    Ok(value)
}

fn bounded_string(value: &Value) -> Option<Value> {
    value
        .as_str()
        .map(|text| Value::String(text.chars().take(4_096).collect()))
}

/// Strip extensible daemon metadata down to the fixed fields an orchestrator
/// needs. Prompts, transcripts, and unknown keys never cross this boundary.
fn sanitized_sessions(response: &Value) -> Result<Value, String> {
    let rows = response
        .get("sessions")
        .and_then(Value::as_array)
        .ok_or_else(|| "daemon returned an invalid session list".to_string())?;
    let mut safe_rows = Vec::new();
    for row in rows.iter().take(100) {
        let mut safe = serde_json::Map::new();
        for key in ["session", "kind", "label", "name", "state"] {
            if let Some(value) = row.get(key).and_then(bounded_string) {
                safe.insert(key.into(), value);
            }
        }
        for key in ["slot", "connected", "backlogged"] {
            if let Some(value) = row
                .get(key)
                .filter(|v| v.is_number() || v.is_boolean() || v.is_null())
            {
                safe.insert(key.into(), value.clone());
            }
        }
        let mut meta = serde_json::Map::new();
        if let Some(source) = row.get("meta").and_then(Value::as_object) {
            for key in [
                "cwd",
                "model",
                "tty",
                "mux_pane",
                "orchestrator_task_id",
                "orchestration_role",
                "manager_task_id",
            ] {
                if let Some(value) = source.get(key).and_then(bounded_string) {
                    meta.insert(key.into(), value);
                }
            }
            for key in ["managed", "pid"] {
                if let Some(value) = source
                    .get(key)
                    .filter(|v| v.is_string() || v.is_number() || v.is_boolean())
                {
                    meta.insert(
                        key.into(),
                        bounded_string(value).unwrap_or_else(|| value.clone()),
                    );
                }
            }
        }
        safe.insert("meta".into(), Value::Object(meta));
        safe_rows.push(Value::Object(safe));
    }
    Ok(json!({"ok": true, "sessions": safe_rows}))
}

/// The daemon retains disconnected tombstones only while they are eligible for
/// recovery. Keep the same deliberately small session representation as
/// `status`, and never expose transcript, prompt, or arbitrary metadata.
fn sanitized_history(response: &Value) -> Result<Value, String> {
    let mut history = sanitized_sessions(response)?;
    let sessions = history
        .get_mut("sessions")
        .and_then(Value::as_array_mut)
        .ok_or_else(|| "internal invalid sanitized session list".to_string())?;
    sessions.retain(|session| session.get("connected").and_then(Value::as_bool) == Some(false));
    Ok(history)
}

fn sanitized_usage(response: &Value) -> Result<Value, String> {
    let providers = response
        .get("usage")
        .and_then(Value::as_object)
        .ok_or_else(|| "daemon returned invalid usage".to_string())?;
    let mut safe = serde_json::Map::new();
    for (provider, snapshot) in providers.iter().take(32) {
        let Some(values) = snapshot.as_object() else {
            continue;
        };
        let numeric = values
            .iter()
            .take(64)
            .filter(|(_, value)| value.is_number())
            .map(|(key, value)| (key.chars().take(128).collect(), value.clone()))
            .collect();
        safe.insert(provider.chars().take(128).collect(), Value::Object(numeric));
    }
    Ok(json!({"ok": true, "usage": safe}))
}

fn run(command: AgentCommand) -> Result<(), String> {
    let response = match command {
        AgentCommand::Status => {
            let sessions = request(json!({"cmd": "list-sessions"}))?;
            let usage = request(json!({"cmd": "get-usage"}))?;
            let order = request(json!({"cmd": "get-attention-order"}))?;
            json!({"sessions": sanitized_sessions(&sessions)?,
                   "usage": sanitized_usage(&usage)?, "attention_order": order})
        }
        AgentCommand::History => {
            let sessions = request(json!({"cmd": "list-sessions"}))?;
            sanitized_history(&sessions)?
        }
        AgentCommand::Order => request(json!({"cmd": "get-attention-order"}))?,
        AgentCommand::Focus { session } => {
            request(json!({"cmd": "focus-session", "session": session}))?
        }
        AgentCommand::Relaunch { session } => {
            request(json!({"cmd": "relaunch-managed-session", "session": session}))?
        }
        AgentCommand::Next => request(json!({"cmd": "focus-next-attention"}))?,
        AgentCommand::Previous => request(json!({"cmd": "focus-prev-attention"}))?,
        AgentCommand::Prioritize { sessions } => request(json!({
            "cmd": "set-attention-order", "sessions": sessions
        }))?,
        AgentCommand::Launch {
            provider,
            model,
            cwd,
            task,
            task_id,
            role,
            manager_task_id,
            channel,
            cursor_mode,
        } => request(json!({
            "cmd": "launch-session", "provider": provider.name(), "cwd": cwd,
            "model": model, "task": task, "task_id": task_id,
            "role": role.name(), "manager_task_id": manager_task_id, "channel_id": channel,
            "cursor_mode": matches!(provider, Provider::Cursor).then(|| cursor_mode.name()),
        }))?,
        AgentCommand::Channel { command } => {
            let task_id = std::env::var("FOCALPOINT_ORCHESTRATOR_TASK_ID")
                .map_err(|_| "channel commands require a FocalPoint-managed session".to_string())?;
            match command {
                ChannelCommand::Create => request(json!({"cmd":"channel-create","task_id":task_id}))?,
                ChannelCommand::Post { channel, body, kind, to } => request(json!({"cmd":"channel-post","task_id":task_id,"channel":channel,"body":body,"kind":kind,"to":to}))?,
                ChannelCommand::Read { channel, since, tail } => request(json!({"cmd":"channel-read","task_id":task_id,"channel":channel,"since":since,"tail":tail}))?,
                ChannelCommand::Members { channel } => request(json!({"cmd":"channel-members","task_id":task_id,"channel":channel}))?,
                ChannelCommand::Close { channel } => request(json!({"cmd":"channel-close","task_id":task_id,"channel":channel}))?,
            }
        }
        AgentCommand::Stop { session, task_id } => request(json!({
            "cmd": "stop-orchestrated-session", "session": session, "task_id": task_id,
        }))?,
        AgentCommand::Transcript {
            session,
            task_id,
            tail,
            search,
        } => request(json!({
            "cmd": "read-session-transcript", "session": session,
            "task_id": task_id, "tail": tail, "search": search,
        }))?,
    };
    println!(
        "{}",
        serde_json::to_string_pretty(&response).map_err(|e| e.to_string())?
    );
    Ok(())
}

fn main() {
    if let Err(error) = run(Cli::parse().command) {
        eprintln!("fpctl-agent: {error}");
        std::process::exit(1);
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn command_surface_has_no_dangerous_or_obsolete_verbs() {
        let help = Cli::command().render_long_help().to_string();
        for allowed in [
            "status",
            "history",
            "order",
            "focus",
            "relaunch",
            "next",
            "previous",
            "prioritize",
            "launch",
            "stop",
            "transcript",
        ] {
            assert!(help.contains(allowed));
        }
        for forbidden in [
            "inject",
            "accept",
            "reject",
            "end-session",
            "quit-session",
            "refresh",
            "policy",
        ] {
            assert!(!help.contains(forbidden));
        }
    }

    #[test]
    fn launch_accepts_an_explicit_model() {
        let parsed = Cli::try_parse_from([
            "fpctl-agent",
            "launch",
            "--provider",
            "claude",
            "--model",
            "sonnet",
            "--cwd",
            "/tmp",
            "--task",
            "Inspect it.",
            "--task-id",
            "inspect-1",
        ])
        .unwrap();
        match parsed.command {
            AgentCommand::Launch {
                model,
                role,
                manager_task_id,
                ..
            } => {
                assert_eq!(model.as_deref(), Some("sonnet"));
                assert!(matches!(role, OrchestrationRole::Worker));
                assert!(manager_task_id.is_none());
            }
            _ => panic!("expected launch"),
        }
    }

    #[test]
    fn launch_accepts_cursor_mode() {
        let parsed = Cli::try_parse_from([
            "fpctl-agent", "launch", "--provider", "cursor", "--cursor-mode",
            "attachable", "--cwd", "/tmp", "--task", "Inspect it.", "--task-id",
            "cursor-1",
        ])
        .unwrap();
        match parsed.command {
            AgentCommand::Launch { cursor_mode, .. } => {
                assert!(matches!(cursor_mode, CursorLaunchMode::Attachable));
            }
            _ => panic!("expected launch"),
        }
    }

    #[test]
    fn history_keeps_only_disconnected_rows_and_sanitizes_metadata() {
        let response = json!({"sessions": [
            {"session":"live", "kind":"codex", "connected":true, "meta":{"cwd":"/work", "secret":"nope"}},
            {"session":"old", "kind":"claude", "state":"done", "connected":false,
             "meta":{"cwd":"/history", "managed":true, "transcript_path":"private"}}
        ]});
        let history = sanitized_history(&response).unwrap();
        assert_eq!(history["sessions"].as_array().unwrap().len(), 1);
        let entry = &history["sessions"][0];
        assert_eq!(entry["session"], "old");
        assert_eq!(entry["meta"]["cwd"], "/history");
        assert!(entry["meta"].get("transcript_path").is_none());
    }

    #[test]
    fn relaunch_command_parses_only_an_exact_session_id() {
        let parsed = Cli::try_parse_from(["fpctl-agent", "relaunch", "session-123"]).unwrap();
        assert!(matches!(parsed.command, AgentCommand::Relaunch { session } if session == "session-123"));
    }

    #[test]
    fn launch_accepts_orchestration_relationship() {
        let parsed = Cli::try_parse_from([
            "fpctl-agent",
            "launch",
            "--provider",
            "codex",
            "--cwd",
            "/tmp",
            "--task",
            "Inspect it.",
            "--task-id",
            "worker-1",
            "--role",
            "worker",
            "--manager-task-id",
            "orchestrator-1",
        ])
        .unwrap();
        match parsed.command {
            AgentCommand::Launch {
                role,
                manager_task_id,
                ..
            } => {
                assert!(matches!(role, OrchestrationRole::Worker));
                assert_eq!(manager_task_id.as_deref(), Some("orchestrator-1"));
            }
            _ => panic!("expected launch"),
        }
    }

    #[test]
    fn stop_and_transcript_require_ownership_fields() {
        assert!(Cli::try_parse_from([
            "fpctl-agent",
            "stop",
            "--session",
            "s1",
            "--task-id",
            "task-1"
        ])
        .is_ok());
        assert!(Cli::try_parse_from(["fpctl-agent", "stop", "--session", "s1"]).is_err());
        let parsed = Cli::try_parse_from([
            "fpctl-agent",
            "transcript",
            "--session",
            "s1",
            "--task-id",
            "task-1",
            "--tail",
            "8000",
            "--search",
            "failed",
        ])
        .unwrap();
        match parsed.command {
            AgentCommand::Transcript { tail, search, .. } => {
                assert_eq!(tail, 8_000);
                assert_eq!(search.as_deref(), Some("failed"));
            }
            _ => panic!("expected transcript"),
        }
        assert!(Cli::try_parse_from([
            "fpctl-agent",
            "transcript",
            "--session",
            "s1",
            "--task-id",
            "task-1",
            "--tail",
            "8001",
        ])
        .is_err());
    }

    #[test]
    fn status_drops_unbounded_metadata_and_transcripts() {
        let input = json!({"sessions": [{
            "session": "s1", "kind": "codex", "state": "waiting", "slot": 2,
            "backlogged": true,
            "meta": {"pid": 42, "tty": "/dev/ttys003", "mux_pane": "%4",
                     "prompt": "secret", "transcript": "secret", "unknown": "secret"}
        }]});
        let output = sanitized_sessions(&input).unwrap();
        let meta = output["sessions"][0]["meta"].as_object().unwrap();
        assert_eq!(meta.get("pid"), Some(&json!(42)));
        assert_eq!(meta.get("mux_pane"), Some(&json!("%4")));
        assert_eq!(output["sessions"][0]["backlogged"], json!(true));
        assert!(!meta.contains_key("prompt"));
        assert!(!meta.contains_key("transcript"));
        assert!(!meta.contains_key("unknown"));
    }
}
