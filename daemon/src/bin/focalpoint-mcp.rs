//! Provider-neutral MCP façade for FocalPoint workflow coordination.
//!
//! Identity is derived exclusively from the managed launch environment. Tool
//! arguments never accept task, session, or channel ids, so an agent cannot
//! use this server to impersonate another workflow member.

use serde_json::{json, Map, Value};
use std::io::{BufRead, BufReader, Write};
use std::os::unix::net::UnixStream;
use std::path::PathBuf;
use std::time::Duration;

const SERVER_NAME: &str = "focalpoint-coordination";
const SERVER_VERSION: &str = env!("CARGO_PKG_VERSION");
const DEFAULT_PROTOCOL: &str = "2025-11-25";
const SUPPORTED_PROTOCOLS: &[&str] = &["2025-11-25", "2025-06-18", "2025-03-26", "2024-11-05"];

#[derive(Debug, Clone)]
struct Identity {
    task_id: String,
    channel_id: String,
    assignment: Option<String>,
    phase: Option<String>,
    role: Option<String>,
}

impl Identity {
    fn from_env() -> Result<Self, String> {
        let task_id = std::env::var("FOCALPOINT_ORCHESTRATOR_TASK_ID")
            .map_err(|_| "FocalPoint MCP tools require a managed workflow session".to_string())?;
        let channel_id = std::env::var("FOCALPOINT_CHANNEL_ID")
            .map_err(|_| "this managed session has no workflow coordination channel".to_string())?;
        Ok(Self {
            task_id,
            channel_id,
            assignment: std::env::var("FOCALPOINT_WORKFLOW_ASSIGNMENT").ok(),
            phase: std::env::var("FOCALPOINT_WORKFLOW_PHASE").ok(),
            role: std::env::var("FOCALPOINT_ORCHESTRATION_ROLE").ok(),
        })
    }

    fn context(&self) -> Value {
        json!({
            "task_id": self.task_id,
            "channel_id": self.channel_id,
            "assignment": self.assignment,
            "phase": self.phase,
            "role": self.role,
        })
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

fn daemon_request(command: Value) -> Result<Value, String> {
    let path = socket_path()?;
    let mut stream = UnixStream::connect(&path).map_err(|error| {
        format!(
            "cannot connect to FocalPoint daemon at {} ({error})",
            path.display()
        )
    })?;
    let timeout = Some(Duration::from_secs(5));
    stream
        .set_read_timeout(timeout)
        .map_err(|error| error.to_string())?;
    stream
        .set_write_timeout(timeout)
        .map_err(|error| error.to_string())?;
    writeln!(stream, "{command}").map_err(|error| format!("daemon write failed: {error}"))?;
    let mut response = String::new();
    BufReader::new(stream)
        .read_line(&mut response)
        .map_err(|error| format!("daemon read failed: {error}"))?;
    let value: Value = serde_json::from_str(&response)
        .map_err(|error| format!("invalid daemon response: {error}"))?;
    if value.get("ok").and_then(Value::as_bool) == Some(true) {
        Ok(value)
    } else {
        Err(value
            .get("error")
            .and_then(Value::as_str)
            .unwrap_or("FocalPoint coordination request failed")
            .to_string())
    }
}

fn string_argument(
    arguments: &Map<String, Value>,
    key: &str,
    max: usize,
) -> Result<String, String> {
    let value = arguments
        .get(key)
        .and_then(Value::as_str)
        .map(str::trim)
        .filter(|value| !value.is_empty())
        .ok_or_else(|| format!("{key} must be a non-empty string"))?;
    if value.chars().count() > max || value.contains('\0') {
        return Err(format!(
            "{key} exceeds its safe length or contains a null character"
        ));
    }
    Ok(value.to_string())
}

fn post(identity: &Identity, kind: &str, body: String) -> Result<Value, String> {
    daemon_request(json!({
        "cmd": "channel-post",
        "task_id": identity.task_id,
        "channel": identity.channel_id,
        "kind": kind,
        "body": body,
    }))
}

fn read(identity: &Identity, limit: u64, acknowledge: bool) -> Result<Value, String> {
    daemon_request(json!({
        "cmd": "channel-read",
        "task_id": identity.task_id,
        "channel": identity.channel_id,
        "tail": limit.clamp(1, 100),
        "ack": acknowledge,
    }))
}

fn call_tool(name: &str, arguments: &Map<String, Value>) -> Result<Value, String> {
    let identity = Identity::from_env()?;
    match name {
        "focalpoint_claim_assignment" => {
            let unread = read(&identity, 50, false)?;
            let assignment = identity.assignment.as_deref().unwrap_or("orchestration");
            post(
                &identity,
                "progress",
                format!("Claimed workflow assignment {assignment}."),
            )?;
            Ok(json!({"identity": identity.context(), "coordination": unread}))
        }
        "focalpoint_read_coordination" => {
            let limit = arguments.get("limit").and_then(Value::as_u64).unwrap_or(20);
            let acknowledge = arguments
                .get("acknowledge")
                .and_then(Value::as_bool)
                .unwrap_or(false);
            read(&identity, limit, acknowledge)
        }
        "focalpoint_ack_coordination" => {
            let through = arguments
                .get("through")
                .and_then(Value::as_u64)
                .ok_or_else(|| "through must be a message id".to_string())?;
            daemon_request(json!({
                "cmd": "channel-ack",
                "task_id": identity.task_id,
                "channel": identity.channel_id,
                "through": through,
            }))
        }
        "focalpoint_ask" => post(
            &identity,
            "question",
            string_argument(arguments, "body", 4_096)?,
        ),
        "focalpoint_report_progress" => post(
            &identity,
            "progress",
            string_argument(arguments, "body", 4_096)?,
        ),
        "focalpoint_report_blocker" => post(
            &identity,
            "blocker",
            string_argument(arguments, "body", 4_096)?,
        ),
        "focalpoint_complete" => post(
            &identity,
            "progress",
            format!(
                "Completed: {}",
                string_argument(arguments, "summary", 4_080)?
            ),
        ),
        _ => Err(format!("unknown FocalPoint coordination tool: {name}")),
    }
}

fn text_tool(name: &str, description: &str, property: &str) -> Value {
    json!({
        "name": name,
        "description": description,
        "inputSchema": {
            "type": "object",
            "properties": {property: {"type": "string"}},
            "required": [property],
            "additionalProperties": false,
        }
    })
}

fn tools() -> Vec<Value> {
    vec![
        json!({
            "name": "focalpoint_claim_assignment",
            "description": "Claim the current managed workflow assignment and read pending coordination without acknowledging it.",
            "inputSchema": {"type":"object","properties":{},"additionalProperties":false}
        }),
        json!({
            "name": "focalpoint_read_coordination",
            "description": "Read pending workflow coordination. Reads are non-destructive unless acknowledge is true.",
            "inputSchema": {
                "type":"object",
                "properties": {
                    "limit":{"type":"integer","minimum":1,"maximum":100,"default":20},
                    "acknowledge":{"type":"boolean","default":false}
                },
                "additionalProperties":false
            }
        }),
        json!({
            "name": "focalpoint_ack_coordination",
            "description": "Acknowledge workflow messages through an id after processing them successfully.",
            "inputSchema": {
                "type":"object",
                "properties":{"through":{"type":"integer","minimum":0}},
                "required":["through"],"additionalProperties":false
            }
        }),
        text_tool(
            "focalpoint_ask",
            "Ask the workflow orchestrator a bounded question.",
            "body",
        ),
        text_tool(
            "focalpoint_report_progress",
            "Report meaningful workflow progress.",
            "body",
        ),
        text_tool(
            "focalpoint_report_blocker",
            "Report a blocker to the workflow orchestrator.",
            "body",
        ),
        text_tool(
            "focalpoint_complete",
            "Report the assignment's completion summary.",
            "summary",
        ),
    ]
}

fn success(id: Value, result: Value) -> Value {
    json!({"jsonrpc":"2.0","id":id,"result":result})
}

fn protocol_error(id: Value, code: i64, message: impl Into<String>) -> Value {
    json!({"jsonrpc":"2.0","id":id,"error":{"code":code,"message":message.into()}})
}

fn tool_result(result: Result<Value, String>) -> Value {
    match result {
        Ok(value) => json!({
            "content":[{"type":"text","text":serde_json::to_string_pretty(&value).unwrap_or_default()}],
            "structuredContent":value,
            "isError":false
        }),
        Err(message) => json!({
            "content":[{"type":"text","text":message}],
            "isError":true
        }),
    }
}

fn handle(request: Value) -> Option<Value> {
    let id = request.get("id").cloned();
    let method = request.get("method").and_then(Value::as_str).unwrap_or("");
    if id.is_none() {
        // MCP notifications are intentionally acknowledged by silence.
        return None;
    }
    let id = id.unwrap_or(Value::Null);
    match method {
        "initialize" => {
            let requested_protocol = request
                .pointer("/params/protocolVersion")
                .and_then(Value::as_str)
                .unwrap_or(DEFAULT_PROTOCOL);
            let protocol = SUPPORTED_PROTOCOLS
                .contains(&requested_protocol)
                .then_some(requested_protocol)
                .unwrap_or(DEFAULT_PROTOCOL);
            Some(success(
                id,
                json!({
                    "protocolVersion":protocol,
                    "capabilities":{"tools":{"listChanged":false}},
                    "serverInfo":{"name":SERVER_NAME,"version":SERVER_VERSION},
                    "instructions":"Workflow coordination is identity-bound. Claim the assignment first; report blockers and completion through these tools."
                }),
            ))
        }
        "ping" => Some(success(id, json!({}))),
        "tools/list" => Some(success(id, json!({"tools":tools()}))),
        "tools/call" => {
            let Some(name) = request.pointer("/params/name").and_then(Value::as_str) else {
                return Some(protocol_error(
                    id,
                    -32602,
                    "tools/call requires a tool name",
                ));
            };
            let empty = Map::new();
            let arguments = request
                .pointer("/params/arguments")
                .and_then(Value::as_object)
                .unwrap_or(&empty);
            Some(success(id, tool_result(call_tool(name, arguments))))
        }
        _ => Some(protocol_error(
            id,
            -32601,
            format!("method not found: {method}"),
        )),
    }
}

fn main() {
    let stdin = std::io::stdin();
    let mut stdout = std::io::stdout().lock();
    for line in stdin.lock().lines() {
        let Ok(line) = line else { break };
        if line.trim().is_empty() {
            continue;
        }
        let response = match serde_json::from_str::<Value>(&line) {
            Ok(request) => handle(request),
            Err(error) => Some(protocol_error(
                Value::Null,
                -32700,
                format!("parse error: {error}"),
            )),
        };
        if let Some(response) = response {
            if writeln!(stdout, "{response}")
                .and_then(|_| stdout.flush())
                .is_err()
            {
                break;
            }
        }
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn tool_catalog_exposes_structured_coordination_contract() {
        let catalog = tools();
        let names = catalog
            .iter()
            .filter_map(|tool| tool.get("name").and_then(Value::as_str).map(str::to_string))
            .collect::<Vec<_>>();
        assert_eq!(names.len(), 7);
        assert!(names.contains(&"focalpoint_claim_assignment".into()));
        assert!(names.contains(&"focalpoint_complete".into()));
        let ask = catalog
            .iter()
            .find(|tool| tool["name"] == "focalpoint_ask")
            .unwrap();
        assert!(ask["inputSchema"]["properties"].get("body").is_some());
        assert_eq!(ask["inputSchema"]["required"], json!(["body"]));
    }

    #[test]
    fn initialize_negotiates_supported_protocol_and_rejects_unknown_future_version() {
        let response = handle(json!({
            "jsonrpc":"2.0","id":1,"method":"initialize",
            "params":{"protocolVersion":"2025-06-18"}
        }))
        .unwrap();
        assert_eq!(response["result"]["protocolVersion"], "2025-06-18");
        assert_eq!(response["result"]["serverInfo"]["name"], SERVER_NAME);

        let response = handle(json!({
            "jsonrpc":"2.0","id":2,"method":"initialize",
            "params":{"protocolVersion":"2099-01-01"}
        }))
        .unwrap();
        assert_eq!(response["result"]["protocolVersion"], DEFAULT_PROTOCOL);
    }

    #[test]
    fn notifications_produce_no_stdout_response() {
        assert!(handle(json!({"jsonrpc":"2.0","method":"notifications/initialized"})).is_none());
    }
}
