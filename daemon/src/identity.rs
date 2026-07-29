//! Session identity resolution (tty/pid) for the Claude Code and Codex
//! adapters — moved here from bash `ps`-walking (see
//! SESSION-IDENTITY-PERSISTENCE-PLAN.md Part 1) so there's exactly one
//! implementation instead of two drifting copies. Invoked by the `focalpoint`
//! CLI itself, in the same process the adapter's hook script already shells
//! out to for `set-state`/`set-meta` — so "my own ancestry" *is* the hook's
//! ancestry, no extra hop needed.
//!
//! `pid` resolution needs an ancestor walk (the hook's own process is a
//! shell/node/etc., not the agent process); `tty` does not — a process's
//! controlling terminal is independent of what its stdio fds are redirected
//! to (stdin here is the hook-JSON pipe), so checking it directly via
//! `/dev/tty` is both simpler and more correct than climbing ancestors
//! looking for the first one with a resolvable tty.

use serde::{Deserialize, Serialize};
use std::path::PathBuf;

/// Everything the resolver needs to know about one process. Abstracted
/// behind a trait so the walk logic (`resolve_pid`) is unit-testable against
/// a fixed fake process tree, without spawning real processes.
pub trait ProcessSource {
    fn ppid(&self, pid: i32) -> Option<i32>;
    /// Process name only (`ps -o comm=`), not the full path.
    fn comm(&self, pid: i32) -> Option<String>;
    /// Full argv, used only to reject known transient-helper signatures
    /// (e.g. Claude Code's own `claude daemon run --origin transient ...`).
    fn cmd(&self, pid: i32) -> Option<Vec<String>>;
}

/// Real process ancestry via `sysinfo`.
pub struct SysinfoProcessSource(sysinfo::System);

impl SysinfoProcessSource {
    pub fn new() -> Self {
        let mut sys = sysinfo::System::new();
        sys.refresh_processes(sysinfo::ProcessesToUpdate::All, true);
        SysinfoProcessSource(sys)
    }
}

impl Default for SysinfoProcessSource {
    fn default() -> Self {
        Self::new()
    }
}

impl ProcessSource for SysinfoProcessSource {
    fn ppid(&self, pid: i32) -> Option<i32> {
        self.0
            .process(sysinfo::Pid::from_u32(pid as u32))
            .and_then(|p| p.parent())
            .map(|p| p.as_u32() as i32)
    }

    fn comm(&self, pid: i32) -> Option<String> {
        self.0
            .process(sysinfo::Pid::from_u32(pid as u32))
            .map(|p| p.name().to_string_lossy().into_owned())
    }

    fn cmd(&self, pid: i32) -> Option<Vec<String>> {
        self.0.process(sysinfo::Pid::from_u32(pid as u32)).map(|p| {
            p.cmd()
                .iter()
                .map(|s| s.to_string_lossy().into_owned())
                .collect()
        })
    }
}

/// Walk from `start_pid` up through parents, remembering the OUTERMOST
/// (nearest-to-terminal/login) ancestor whose comm matches `target_comm` —
/// not the first hit climbing up — since transient helpers (Claude Code's
/// own `claude daemon run --origin transient --spawned-by ...`) nest
/// *below* the real interactive process, closer to the hook. The argv-based
/// rejection of "daemon run" stays as defense-in-depth on top of this
/// structural rule, not a replacement for it.
pub fn resolve_pid(source: &impl ProcessSource, start_pid: i32, target_comm: &str) -> Option<i32> {
    let mut found = None;
    let mut pid = start_pid;
    let mut guard = 0;
    loop {
        guard += 1;
        if guard > 4096 {
            break; // pathological ancestry loop guard; should never trigger
        }
        if let Some(comm) = source.comm(pid) {
            let base = comm.rsplit('/').next().unwrap_or(&comm);
            if base == target_comm {
                let is_transient = source
                    .cmd(pid)
                    .map(|args| args.join(" ").contains("daemon run"))
                    .unwrap_or(false);
                if !is_transient {
                    found = Some(pid);
                }
            }
        }
        match source.ppid(pid) {
            Some(parent) if parent > 1 && parent != pid => pid = parent,
            _ => break,
        }
    }
    found
}

/// This process's own controlling terminal, independent of what fd 0/1/2
/// are redirected to. `None` if there is none (e.g. a detached/background
/// job) or it can't be resolved.
pub fn own_tty() -> Option<String> {
    unsafe {
        let fd = libc::open(
            b"/dev/tty\0".as_ptr() as *const libc::c_char,
            libc::O_RDONLY | libc::O_NOCTTY,
        );
        if fd < 0 {
            return None;
        }
        let mut buf = [0i8; 256];
        let rc = libc::ttyname_r(fd, buf.as_mut_ptr(), buf.len());
        libc::close(fd);
        if rc != 0 {
            return None;
        }
        std::ffi::CStr::from_ptr(buf.as_ptr())
            .to_str()
            .ok()
            .map(|s| s.to_string())
    }
}

#[derive(Debug, Clone, Default, PartialEq, Serialize, Deserialize)]
pub struct Identity {
    pub tty: Option<String>,
    pub pid: Option<i32>,
}

fn identity_dir() -> PathBuf {
    let base = std::env::var_os("XDG_STATE_HOME")
        .filter(|v| !v.is_empty())
        .map(PathBuf::from)
        .or_else(|| dirs::home_dir().map(|h| h.join(".local").join("state")))
        .unwrap_or_else(|| PathBuf::from("/tmp"));
    base.join("focalpoint").join("sessions")
}

fn identity_path(session_id: &str) -> PathBuf {
    identity_dir().join(format!("{session_id}.json"))
}

/// Read a previously-cached identity for `session_id`, if any.
pub fn load_identity(session_id: &str) -> Option<Identity> {
    let data = std::fs::read_to_string(identity_path(session_id)).ok()?;
    serde_json::from_str(&data).ok()
}

fn save_identity(session_id: &str, identity: &Identity) {
    let dir = identity_dir();
    let _ = std::fs::create_dir_all(&dir);
    if let Ok(data) = serde_json::to_string(identity) {
        let _ = std::fs::write(identity_path(session_id), data);
    }
}

/// Remove a session's cached identity — called on `end-session` (the one
/// chokepoint every adapter's `SessionEnd` already goes through), so a
/// reused session_id (shouldn't happen, but) never inherits a stale cache.
pub fn remove_identity(session_id: &str) {
    let _ = std::fs::remove_file(identity_path(session_id));
}

/// Resolve (or load the cached) identity for `session_id`. `target_comm` is
/// the process name to search for (`"claude"`, `"codex"`); `refresh` forces
/// a fresh walk + cache overwrite instead of trusting an existing cache —
/// callers pass this on `SessionStart`, the one point a process instance for
/// this session_id is known to have just begun.
pub fn resolve_identity(session_id: &str, target_comm: &str, refresh: bool) -> Identity {
    if !refresh {
        if let Some(identity) = load_identity(session_id) {
            return identity;
        }
    }
    let source = SysinfoProcessSource::new();
    let pid = resolve_pid(&source, std::process::id() as i32, target_comm);
    let identity = Identity {
        tty: own_tty(),
        pid,
    };
    save_identity(session_id, &identity);
    identity
}

#[cfg(test)]
mod tests {
    use super::*;
    use std::collections::HashMap;

    /// A fixed, fake process tree for deterministic walk tests — no real
    /// process spawning required.
    struct FakeProcess {
        ppid: Option<i32>,
        comm: &'static str,
        cmd: Vec<&'static str>,
    }

    #[derive(Default)]
    struct FakeProcessSource(HashMap<i32, FakeProcess>);

    impl FakeProcessSource {
        fn insert(&mut self, pid: i32, ppid: Option<i32>, comm: &'static str, cmd: &[&'static str]) {
            self.0.insert(
                pid,
                FakeProcess {
                    ppid,
                    comm,
                    cmd: cmd.to_vec(),
                },
            );
        }
    }

    impl ProcessSource for FakeProcessSource {
        fn ppid(&self, pid: i32) -> Option<i32> {
            self.0.get(&pid).and_then(|p| p.ppid)
        }
        fn comm(&self, pid: i32) -> Option<String> {
            self.0.get(&pid).map(|p| p.comm.to_string())
        }
        fn cmd(&self, pid: i32) -> Option<Vec<String>> {
            self.0
                .get(&pid)
                .map(|p| p.cmd.iter().map(|s| s.to_string()).collect())
        }
    }

    #[test]
    fn plain_nested_shell_finds_the_one_real_match() {
        // hook(300) -> bash(200) -> claude(100) -> zsh(2) -> launchd(1)
        let mut src = FakeProcessSource::default();
        src.insert(300, Some(200), "focalpoint", &["focalpoint", "set-state"]);
        src.insert(200, Some(100), "bash", &["bash", "hooks.sh"]);
        src.insert(100, Some(2), "claude", &["claude"]);
        src.insert(2, Some(1), "zsh", &["-zsh"]);

        assert_eq!(resolve_pid(&src, 300, "claude"), Some(100));
    }

    #[test]
    fn rejects_transient_daemon_run_helper() {
        // Reproduces the real bug this walk was fixed for: a
        // `claude daemon run --origin transient` helper shares comm with
        // the real interactive session but must never be matched.
        // helper(400, comm=claude, "daemon run") -> real(100, comm=claude) -> zsh(2)
        let mut src = FakeProcessSource::default();
        src.insert(
            400,
            Some(100),
            "claude",
            &["claude", "daemon", "run", "--origin", "transient", "--spawned-by", "{}"],
        );
        src.insert(100, Some(2), "claude", &["claude"]);
        src.insert(2, Some(1), "zsh", &["-zsh"]);

        assert_eq!(resolve_pid(&src, 400, "claude"), Some(100));
    }

    #[test]
    fn no_match_returns_none() {
        let mut src = FakeProcessSource::default();
        src.insert(200, Some(2), "bash", &["bash"]);
        src.insert(2, Some(1), "zsh", &["-zsh"]);

        assert_eq!(resolve_pid(&src, 200, "claude"), None);
    }

    #[test]
    fn multiple_matches_keeps_climbing_to_outermost() {
        // inner(300, claude) -> mid(200, claude) -> outer(100, claude) -> zsh(2)
        // The real interactive process is the outermost one, nearest the
        // terminal/login shell — not the first hit walking up from $$.
        let mut src = FakeProcessSource::default();
        src.insert(300, Some(200), "claude", &["claude"]);
        src.insert(200, Some(100), "claude", &["claude"]);
        src.insert(100, Some(2), "claude", &["claude"]);
        src.insert(2, Some(1), "zsh", &["-zsh"]);

        assert_eq!(resolve_pid(&src, 300, "claude"), Some(100));
    }

    #[test]
    fn identity_cache_round_trips() {
        // Isolate from other tests / the real user's state dir.
        let tmp = std::env::temp_dir().join(format!("focalpoint-identity-test-{}", std::process::id()));
        std::env::set_var("XDG_STATE_HOME", &tmp);

        let id = "test-session-abc";
        assert!(load_identity(id).is_none());

        let identity = Identity {
            tty: Some("/dev/ttys003".to_string()),
            pid: Some(4242),
        };
        save_identity(id, &identity);
        assert_eq!(load_identity(id), Some(identity));

        remove_identity(id);
        assert!(load_identity(id).is_none());

        let _ = std::fs::remove_dir_all(&tmp);
        std::env::remove_var("XDG_STATE_HOME");
    }
}
