//! Socket and state-file path resolution (PROTOCOL.md §3).

use std::path::PathBuf;

/// Resolve the daemon socket path.
///
/// `$XDG_RUNTIME_DIR/focalpoint.sock`, falling back to
/// `~/.local/state/focalpoint/focalpoint.sock`.
pub fn socket_path() -> PathBuf {
    if let Some(dir) = std::env::var_os("XDG_RUNTIME_DIR") {
        if !dir.is_empty() {
            return PathBuf::from(dir).join("focalpoint.sock");
        }
    }
    let base = dirs::home_dir()
        .map(|h| h.join(".local").join("state"))
        .unwrap_or_else(|| PathBuf::from("/tmp"));
    base.join("focalpoint").join("focalpoint.sock")
}

/// Resolve the daemon's persisted session/tombstone/usage snapshot path
/// (`daemon.rs`'s `save_snapshot`/`load_snapshot`,
/// SESSION-IDENTITY-PERSISTENCE-PLAN.md Part 4).
///
/// `$XDG_STATE_HOME/focalpoint/state.json`, falling back to
/// `~/.local/state/focalpoint/state.json` — the same base directory
/// convention every adapter's own cache files already use
/// (`adapters/claude-code/hooks.sh`'s identity cache, etc.), just a path the
/// daemon itself now also owns. Deliberately *not* `$XDG_RUNTIME_DIR` (which
/// `socket_path` prefers): that's commonly a tmpfs wiped on reboot, and a
/// session "left through a reboot" (a real, explicitly-requested use case —
/// see `tombstone_ttl_minutes = 0`) needs this to actually survive one.
pub fn daemon_state_path() -> PathBuf {
    let base = std::env::var_os("XDG_STATE_HOME")
        .filter(|v| !v.is_empty())
        .map(PathBuf::from)
        .or_else(|| dirs::home_dir().map(|h| h.join(".local").join("state")))
        .unwrap_or_else(|| PathBuf::from("/tmp"));
    base.join("focalpoint").join("state.json")
}
