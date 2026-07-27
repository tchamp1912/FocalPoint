//! Execution of configured [`Action`]s (PROTOCOL.md §5).
//!
//! `shell` runs everywhere via `sh -c`. `keystroke` and `paste` synthesize
//! input; on macOS this is done via `osascript`/System Events. On other
//! platforms those two degrade to a logged warning (the socket event is still
//! delivered — only the synthesized input is skipped).

use crate::config::Action;

/// Run an action. Non-blocking for `shell` (spawns and detaches); the
/// osascript-based actions are short and run to completion.
pub fn run(action: &Action) {
    run_with_env(action, &[]);
}

/// Run an action with extra environment variables (used by the focus action,
/// PROTOCOL.md §3). The env only applies to `shell`; `keystroke`/`paste` ignore
/// it (osascript doesn't consume it meaningfully).
pub fn run_with_env(action: &Action, env: &[(&str, String)]) {
    match action {
        Action::None => {}
        Action::Shell { run } => run_shell(run, env),
        Action::Keystroke { keys } => run_keystroke(keys),
        Action::Paste { text } => run_paste(text),
    }
}

fn run_shell(cmd: &str, env: &[(&str, String)]) {
    let mut command = std::process::Command::new("sh");
    command.arg("-c").arg(cmd);
    for (k, v) in env {
        command.env(k, v);
    }
    match command.spawn() {
        Ok(_) => {}
        Err(e) => eprintln!("[action] shell spawn failed: {e}"),
    }
}

/// Run a short osascript program to completion (macOS only).
#[cfg(target_os = "macos")]
fn osascript(script: &str) {
    match std::process::Command::new("osascript")
        .arg("-e")
        .arg(script)
        .status()
    {
        Ok(s) if s.success() => {}
        Ok(s) => eprintln!("[action] osascript exited with {s}"),
        Err(e) => eprintln!("[action] osascript failed: {e}"),
    }
}

/// Escape a string for embedding inside an AppleScript double-quoted literal.
#[cfg(target_os = "macos")]
fn as_escape(s: &str) -> String {
    s.replace('\\', "\\\\").replace('"', "\\\"")
}

/// Well-known key names -> macOS virtual key codes for System Events.
#[cfg(target_os = "macos")]
fn key_code(name: &str) -> Option<u16> {
    Some(match name {
        "enter" | "return" => 36,
        "escape" | "esc" => 53,
        "tab" => 48,
        "space" => 49,
        "delete" | "backspace" => 51,
        "up" => 126,
        "down" => 125,
        "left" => 123,
        "right" => 124,
        _ => return None,
    })
}

#[cfg(target_os = "macos")]
fn run_keystroke(keys: &str) {
    if let Some(code) = key_code(keys) {
        osascript(&format!(
            "tell application \"System Events\" to key code {code}"
        ));
    } else {
        // Fall back to typing the literal string.
        osascript(&format!(
            "tell application \"System Events\" to keystroke \"{}\"",
            as_escape(keys)
        ));
    }
}

#[cfg(target_os = "macos")]
fn run_paste(text: &str) {
    // Put the text on the clipboard, then Cmd-V into the focused app. This is
    // more reliable for long text than synthesizing each character.
    let escaped = as_escape(text);
    osascript(&format!("set the clipboard to \"{escaped}\""));
    osascript("tell application \"System Events\" to keystroke \"v\" using command down");
}

#[cfg(not(target_os = "macos"))]
fn run_keystroke(keys: &str) {
    eprintln!("[action] keystroke '{keys}' not supported on this platform (macOS only); skipping");
}

#[cfg(not(target_os = "macos"))]
fn run_paste(_text: &str) {
    eprintln!("[action] paste not supported on this platform (macOS only); skipping");
}
