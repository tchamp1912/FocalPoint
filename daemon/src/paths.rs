//! Socket path resolution (PROTOCOL.md §3).

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
