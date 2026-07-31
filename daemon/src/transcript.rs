//! Bounded normalization of local Claude Code and Codex JSONL transcripts.

use serde::Serialize;
use serde_json::Value;
use std::collections::VecDeque;
use std::path::Path;

const MAX_TRANSCRIPT_BYTES: u64 = 64 * 1024 * 1024;
const MAX_MESSAGE_CHARS: usize = 4_096;

#[derive(Debug, Clone, PartialEq, Eq, Serialize)]
pub struct TranscriptMessage {
    pub timestamp: Option<String>,
    pub role: String,
    pub kind: String,
    pub text: String,
}

fn bounded_text(text: &str) -> String {
    text.chars()
        .filter(|ch| !ch.is_control() || matches!(ch, '\n' | '\t'))
        .take(MAX_MESSAGE_CHARS)
        .collect::<String>()
        .trim()
        .to_string()
}

fn content_text(content: &Value) -> String {
    match content {
        Value::String(text) => bounded_text(text),
        Value::Array(items) => {
            let mut parts = Vec::new();
            for item in items {
                let item_type = item.get("type").and_then(Value::as_str).unwrap_or("");
                let part = match item_type {
                    "text" | "input_text" | "output_text" | "tool_result" => item
                        .get("text")
                        .or_else(|| item.get("content"))
                        .map(content_text)
                        .unwrap_or_default(),
                    "tool_use" | "function_call" | "custom_tool_call" => item
                        .get("name")
                        .and_then(Value::as_str)
                        .map(|name| format!("[tool: {name}]"))
                        .unwrap_or_else(|| "[tool call]".into()),
                    _ => item.get("text").map(content_text).unwrap_or_default(),
                };
                if !part.is_empty() {
                    parts.push(part);
                }
            }
            bounded_text(&parts.join("\n"))
        }
        Value::Object(_) => content
            .get("text")
            .or_else(|| content.get("content"))
            .map(content_text)
            .unwrap_or_default(),
        _ => String::new(),
    }
}

fn normalize_claude(value: &Value) -> Option<TranscriptMessage> {
    let event_type = value.get("type")?.as_str()?;
    if !matches!(event_type, "user" | "assistant") {
        return None;
    }
    let message = value.get("message")?;
    let role = message
        .get("role")
        .and_then(Value::as_str)
        .unwrap_or(event_type);
    let text = content_text(message.get("content").unwrap_or(&Value::Null));
    (!text.is_empty()).then(|| TranscriptMessage {
        timestamp: value
            .get("timestamp")
            .and_then(Value::as_str)
            .map(str::to_string),
        role: role.to_string(),
        kind: "message".into(),
        text,
    })
}

fn normalize_codex(value: &Value) -> Option<TranscriptMessage> {
    if value.get("type").and_then(Value::as_str) != Some("response_item") {
        return None;
    }
    let payload = value.get("payload")?;
    let payload_type = payload.get("type")?.as_str()?;
    let (role, kind, text) = match payload_type {
        "message" => (
            payload
                .get("role")
                .and_then(Value::as_str)
                .unwrap_or("assistant")
                .to_string(),
            "message".to_string(),
            content_text(payload.get("content").unwrap_or(&Value::Null)),
        ),
        "function_call" | "custom_tool_call" => (
            "tool".into(),
            "tool_call".into(),
            payload
                .get("name")
                .and_then(Value::as_str)
                .map(|name| format!("[tool: {name}]"))
                .unwrap_or_else(|| "[tool call]".into()),
        ),
        "function_call_output" | "custom_tool_call_output" => (
            "tool".into(),
            "tool_result".into(),
            content_text(payload.get("output").unwrap_or(&Value::Null)),
        ),
        _ => return None,
    };
    (!text.is_empty()).then(|| TranscriptMessage {
        timestamp: value
            .get("timestamp")
            .and_then(Value::as_str)
            .map(str::to_string),
        role,
        kind,
        text,
    })
}

pub fn read_transcript(
    path: &Path,
    provider: &str,
    tail: usize,
    search: Option<&str>,
) -> Result<Vec<TranscriptMessage>, String> {
    let metadata = path
        .metadata()
        .map_err(|error| format!("cannot inspect transcript: {error}"))?;
    if !metadata.is_file() {
        return Err("transcript path is not a file".into());
    }
    if metadata.len() > MAX_TRANSCRIPT_BYTES {
        return Err(format!(
            "transcript exceeds the {} MiB read limit",
            MAX_TRANSCRIPT_BYTES / 1024 / 1024
        ));
    }
    let bytes = std::fs::read(path).map_err(|error| format!("cannot read transcript: {error}"))?;
    let needle = search.map(str::to_lowercase);
    let mut messages = VecDeque::with_capacity(tail);
    for line in bytes.split(|byte| *byte == b'\n') {
        let Ok(value) = serde_json::from_slice::<Value>(line) else {
            continue;
        };
        let normalized = match provider {
            "claude" => normalize_claude(&value),
            "codex" => normalize_codex(&value),
            _ => return Err("transcripts are supported only for claude and codex".into()),
        };
        let Some(message) = normalized else { continue };
        if needle
            .as_ref()
            .is_some_and(|needle| !message.text.to_lowercase().contains(needle))
        {
            continue;
        }
        if messages.len() == tail {
            messages.pop_front();
        }
        messages.push_back(message);
    }
    Ok(messages.into())
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn normalizes_claude_messages_without_thinking_or_metadata() {
        let user = serde_json::json!({
            "type":"user", "timestamp":"t1",
            "message":{"role":"user", "content":"please inspect"}
        });
        let assistant = serde_json::json!({
            "type":"assistant", "timestamp":"t2", "message":{"role":"assistant","content":[
                {"type":"thinking","thinking":"private chain"},
                {"type":"text","text":"working on it"},
                {"type":"tool_use","name":"Read","input":{"secret":"x"}}
            ]}
        });
        assert_eq!(normalize_claude(&user).unwrap().text, "please inspect");
        assert_eq!(
            normalize_claude(&assistant).unwrap().text,
            "working on it\n[tool: Read]"
        );
    }

    #[test]
    fn normalizes_codex_messages_and_bounded_tool_results() {
        let message = serde_json::json!({"type":"response_item","timestamp":"t",
            "payload":{"type":"message","role":"assistant","content":[
                {"type":"output_text","text":"done"}]}});
        assert_eq!(normalize_codex(&message).unwrap().text, "done");
        let tool = serde_json::json!({"type":"response_item",
            "payload":{"type":"function_call","name":"exec_command"}});
        assert_eq!(normalize_codex(&tool).unwrap().text, "[tool: exec_command]");
    }
}
