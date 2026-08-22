//! Session identity resolution (tty/pid) for the Claude Code and Codex
//! adapters — moved here from bash `ps`-walking (see
//! SESSION-IDENTITY-PERSISTENCE-PLAN.md Part 1) so there's exactly one
//! implementation instead of two drifting copies. Invoked by the `focalpoint`
//! CLI itself, in the same process the adapter's hook script already shells
//! out to for `set-state`/`set-meta` — so "my own ancestry" *is* the hook's
//! ancestry, no extra hop needed.
//!
//! `pid` resolution needs an ancestor walk (the hook's own process is a
//! shell/node/etc., not the agent process). `tty` comes from that agent
//! pid's controlling terminal (`ps -o tty=`) when available — *not* from
//! `own_tty()` alone, which on macOS often resolves to the useless generic
//! path `/dev/tty` (every session then collides and focus can't switch).

use serde::{Deserialize, Serialize};
use std::path::PathBuf;
use std::process::Command;

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

/// Prefer sysinfo's structured argv, but let callers recover it from the OS
/// when sysinfo observes the narrow post-exec window where `comm` is already
/// the new binary name and `cmd()` is still empty.
fn process_args_or_fallback(
    args: Vec<String>,
    fallback: impl FnOnce() -> Option<Vec<String>>,
) -> Option<Vec<String>> {
    if args.iter().any(|arg| !arg.trim().is_empty()) {
        Some(args)
    } else {
        fallback().filter(|fallback_args| fallback_args.iter().any(|arg| !arg.trim().is_empty()))
    }
}

/// Read one process's command line directly from `ps`. We keep the returned
/// line intact rather than shell-splitting it: identity matching only needs
/// to prove the executable path contains `claude` and reject `daemon run`,
/// both of which are safer and more accurate against the unmodified text.
fn ps_args_for_pid(pid: i32) -> Option<Vec<String>> {
    let output = Command::new("ps")
        .args(["-o", "args=", "-p", &pid.to_string()])
        .output()
        .ok()?;
    if !output.status.success() {
        return None;
    }
    let command_line = String::from_utf8_lossy(&output.stdout).trim().to_string();
    (!command_line.is_empty()).then(|| vec![command_line])
}

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
        let sysinfo_args = self
            .0
            .process(sysinfo::Pid::from_u32(pid as u32))
            .map(|process| {
                process
                    .cmd()
                    .iter()
                    .map(|arg| arg.to_string_lossy().into_owned())
                    .collect()
            })
            .unwrap_or_default();
        process_args_or_fallback(sysinfo_args, || ps_args_for_pid(pid))
    }
}

/// Claude Code 2.1.222+ execs a versioned self-update binary. On macOS its
/// process `comm` is the version itself (for example `2.1.222`), rather than
/// `claude`. Accept that form only when argv still identifies Claude Code; a
/// bare version-looking ancestor is never sufficient.
fn is_versioned_claude_binary(base: &str, args: &[String]) -> bool {
    let versioned_name = base.split('.').count() >= 3
        && base
            .split('.')
            .all(|part| !part.is_empty() && part.bytes().all(|byte| byte.is_ascii_digit()));
    versioned_name
        && args.iter().any(|arg| {
            let normalized = arg.replace('\\', "/").to_ascii_lowercase();
            normalized.contains("claude")
        })
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
            let args = source.cmd(pid).unwrap_or_default();
            let target_matches = base == target_comm
                || (target_comm == "claude" && is_versioned_claude_binary(base, &args));
            if target_matches {
                let is_transient = args.join(" ").contains("daemon run");
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

/// Normalize a tty name from `ps` or `ttyname_r` into a usable device path.
/// Rejects the generic `/dev/tty` alias — it is not unique per terminal.
fn usable_tty(raw: &str) -> Option<String> {
    let tty = raw.trim();
    if tty.is_empty() || tty == "?" || tty == "??" || tty == "/dev/tty" || tty == "tty" {
        return None;
    }
    if tty.starts_with("/dev/") {
        Some(tty.to_string())
    } else {
        Some(format!("/dev/{tty}"))
    }
}

/// Controlling terminal for `pid`, via `ps -o tty=`. Used for focus matching
/// (iTerm/Terminal compare against `/dev/ttys00N`).
pub(crate) fn tty_for_pid(pid: i32) -> Option<String> {
    let output = Command::new("ps")
        .args(["-o", "tty=", "-p", &pid.to_string()])
        .output()
        .ok()?;
    if !output.status.success() {
        return None;
    }
    usable_tty(&String::from_utf8_lossy(&output.stdout))
}

fn resolve_tty(pid: Option<i32>) -> Option<String> {
    pid.and_then(tty_for_pid)
        .or_else(|| own_tty().and_then(|t| usable_tty(&t)))
}

fn select_resolved_pid(
    walked_pid: Option<i32>,
    cached_pid: Option<i32>,
    refresh: bool,
) -> Option<i32> {
    if refresh {
        walked_pid
    } else {
        walked_pid.or(cached_pid)
    }
}

fn repair_cached_identity(session_id: &str, mut identity: Identity) -> Identity {
    let mut changed = false;
    let tty_bad = identity
        .tty
        .as_deref()
        .map(|t| t == "/dev/tty")
        .unwrap_or(true);
    if tty_bad {
        if let Some(pid) = identity.pid {
            if let Some(tty) = tty_for_pid(pid) {
                identity.tty = Some(tty);
                changed = true;
            }
        }
    }
    if identity.pid.is_some()
        && (identity.boot_time.is_none()
            || identity.process_start_time.is_none()
            || identity.executable.is_none())
    {
        let (boot_time, process_start_time, executable) = process_fingerprint(identity.pid);
        identity.boot_time = boot_time;
        identity.process_start_time = process_start_time;
        identity.executable = executable;
        changed = true;
    }
    changed |= refresh_terminal_endpoint(&mut identity);
    if changed {
        save_identity(session_id, &identity);
    }
    identity
}

#[derive(Debug, Clone, Default, PartialEq, Serialize, Deserialize)]
pub struct Identity {
    pub tty: Option<String>,
    pub pid: Option<i32>,
    /// System boot epoch (seconds) and process birth time are part of the
    /// attachment fingerprint.  A PID or tty on its own is reusable and is
    /// therefore never authoritative session identity.
    #[serde(default)]
    pub boot_time: Option<u64>,
    #[serde(default)]
    pub process_start_time: Option<u64>,
    #[serde(default)]
    pub executable: Option<String>,
    /// Terminal-host identity is cached beside (but never folded into) the
    /// provider fingerprint. It is used only to address the exact iTerm
    /// application process that owns this session when multiple instances
    /// share the same bundle identifier.
    #[serde(default)]
    pub terminal_application_pid: Option<i32>,
    #[serde(default)]
    pub terminal_session_id: Option<String>,
}

fn normalized_iterm_session_id(value: &str) -> Option<String> {
    let normalized = value
        .rsplit_once(':')
        .map(|(_, id)| id)
        .unwrap_or(value)
        .trim();
    (!normalized.is_empty()).then(|| normalized.to_string())
}

fn current_iterm_session_id() -> Option<String> {
    std::env::var("ITERM_SESSION_ID")
        .ok()
        .and_then(|value| normalized_iterm_session_id(&value))
}

fn iterm_focus_helper_path() -> PathBuf {
    if let Some(path) = std::env::var_os("FOCALPOINT_ITERM_FOCUS_HELPER")
        .filter(|value| !value.is_empty())
    {
        return PathBuf::from(path);
    }
    let config = std::env::var_os("XDG_CONFIG_HOME")
        .filter(|value| !value.is_empty())
        .map(PathBuf::from)
        .or_else(|| dirs::home_dir().map(|home| home.join(".config")))
        .unwrap_or_else(|| PathBuf::from("/tmp"));
    config
        .join("focalpoint")
        .join("adapters")
        .join("focalpoint-iterm-focus")
}

fn lookup_iterm_application_pid(session_id: &str) -> Option<i32> {
    if !matches!(std::env::var("TERM_PROGRAM").ok().as_deref(), Some("iTerm.app" | "iTerm2")) {
        return None;
    }
    let helper = iterm_focus_helper_path();
    if !helper.is_file() {
        return None;
    }
    let output = Command::new(helper)
        .args(["--lookup", "--session-id", session_id])
        .output()
        .ok()?;
    if !output.status.success() {
        return None;
    }
    String::from_utf8(output.stdout)
        .ok()?
        .split('|')
        .next()?
        .trim()
        .parse::<i32>()
        .ok()
        .filter(|pid| *pid > 1)
}

fn refresh_terminal_endpoint(identity: &mut Identity) -> bool {
    let Some(session_id) = current_iterm_session_id() else {
        return false;
    };
    if identity.terminal_session_id.as_deref() == Some(session_id.as_str())
        && identity.terminal_application_pid.is_some()
    {
        return false;
    }
    let application_pid = lookup_iterm_application_pid(&session_id);
    let changed = identity.terminal_session_id.as_deref() != Some(session_id.as_str())
        || identity.terminal_application_pid != application_pid;
    identity.terminal_session_id = Some(session_id);
    identity.terminal_application_pid = application_pid;
    changed
}

fn process_fingerprint(pid: Option<i32>) -> (Option<u64>, Option<u64>, Option<String>) {
    let Some(pid) = pid else {
        return (None, None, None);
    };
    let sys_pid = sysinfo::Pid::from_u32(pid as u32);
    let mut system = sysinfo::System::new();
    system.refresh_processes(sysinfo::ProcessesToUpdate::Some(&[sys_pid]), true);
    let Some(process) = system.process(sys_pid) else {
        return (None, None, None);
    };
    (
        Some(sysinfo::System::boot_time()),
        Some(process.start_time()),
        process
            .exe()
            .map(|path| path.to_string_lossy().into_owned()),
    )
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

/// Cache a usable resolution. A completely empty result is deliberately not
/// cached: absence of an identity is usually a startup race, not a stable
/// fact. Leaving the per-session cache absent re-arms every later hook call
/// for this same process instance, allowing it to self-heal as soon as the
/// agent appears in the process table.
fn save_identity_or_rearm(session_id: &str, identity: &Identity) {
    if identity.pid.is_none() && identity.tty.is_none() {
        remove_identity(session_id);
    } else {
        save_identity(session_id, identity);
    }
}

/// Remove a session's cached identity — called on `end-session` (the one
/// chokepoint every adapter's `SessionEnd` already goes through), so a
/// reused session_id (shouldn't happen, but) never inherits a stale cache.
pub fn remove_identity(session_id: &str) {
    let _ = std::fs::remove_file(identity_path(session_id));
}

/// Resolve (or load the cached) identity for `session_id`. `target_comm` is
/// the process name to search for (`"claude"`, `"codex"`). Claude's versioned
/// self-update binaries are recognized from their Claude-identifying argv;
/// `refresh` forces
/// a fresh walk + cache overwrite instead of trusting an existing cache —
/// callers pass this on `SessionStart`, the one point a process instance for
/// this session_id is known to have just begun.
pub fn resolve_identity(session_id: &str, target_comm: &str, refresh: bool) -> Identity {
    let cached = load_identity(session_id);
    let cached_pid = cached.as_ref().and_then(|i| i.pid);
    if !refresh {
        if let Some(identity) = cached {
            let identity = repair_cached_identity(session_id, identity);
            // Only trust a cache that actually resolved *something*: a pid, or
            // a usable (non-generic) tty. A `{pid: None, tty: None}` (or
            // `/dev/tty`) entry is a poisoned negative result — the ancestry
            // walk lost a race at `SessionStart` (e.g. the agent process
            // wasn't in the table yet) and cached the failure. Returning it
            // here would lock the session into "no identity" for its whole
            // life, since nothing but `--refresh-identity` (SessionStart only)
            // ever re-walks. Falling through instead re-walks on the next
            // hook, which runs from within the now-established agent ancestry
            // and normally succeeds. See identity resolution in
            // SESSION-IDENTITY-PERSISTENCE-PLAN.md Part 1.
            let tty_usable = identity
                .tty
                .as_deref()
                .map(|t| t != "/dev/tty")
                .unwrap_or(false);
            if identity.pid.is_some() || tty_usable {
                return identity;
            }
        }
    }
    let source = SysinfoProcessSource::new();
    let walked_pid = resolve_pid(&source, std::process::id() as i32, target_comm);
    // `refresh` means a new process instance is known to have started. Never
    // fall back to the previous instance's cached PID in that case: if the
    // fresh walk loses a startup race, return empty and remain re-armed for
    // the next hook. Non-refresh calls may retain a prior usable PID while
    // repairing its tty.
    let pid = select_resolved_pid(walked_pid, cached_pid, refresh);
    let (boot_time, process_start_time, executable) = process_fingerprint(pid);
    let identity = Identity {
        tty: resolve_tty(pid),
        pid,
        boot_time,
        process_start_time,
        executable,
        terminal_application_pid: None,
        terminal_session_id: None,
    };
    let mut identity = identity;
    refresh_terminal_endpoint(&mut identity);
    save_identity_or_rearm(session_id, &identity);
    identity
}

#[cfg(test)]
mod tests {
    use super::*;
    use std::collections::HashMap;
    use std::sync::Mutex;

    static IDENTITY_ENV_LOCK: Mutex<()> = Mutex::new(());

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
        fn insert(
            &mut self,
            pid: i32,
            ppid: Option<i32>,
            comm: &'static str,
            cmd: &[&'static str],
        ) {
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
    fn claude_versioned_self_update_binary_resolves_from_argv() {
        // Claude Code 2.1.222+ may exec its self-update binary directly, so
        // macOS reports `comm` as the version string instead of `claude`.
        let mut src = FakeProcessSource::default();
        src.insert(300, Some(200), "focalpoint", &["focalpoint", "set-state"]);
        src.insert(200, Some(100), "bash", &["bash", "hooks.sh"]);
        src.insert(
            100,
            Some(2),
            "2.1.222",
            &["/Users/example/.local/share/claude/versions/2.1.222"],
        );
        src.insert(2, Some(1), "zsh", &["-zsh"]);

        assert_eq!(resolve_pid(&src, 300, "claude"), Some(100));
    }

    #[test]
    fn empty_sysinfo_argv_uses_ps_fallback_for_versioned_claude() {
        let recovered = process_args_or_fallback(Vec::new(), || {
            Some(vec![
                "/Users/example/.local/share/claude/versions/2.1.222".into()
            ])
        })
        .unwrap();
        assert!(is_versioned_claude_binary("2.1.222", &recovered));

        let structured = process_args_or_fallback(vec!["claude".into()], || {
            panic!("ps fallback must not run when sysinfo argv is populated")
        });
        assert_eq!(structured, Some(vec!["claude".into()]));
    }

    #[test]
    fn version_looking_non_claude_process_is_not_matched() {
        let mut src = FakeProcessSource::default();
        src.insert(200, Some(100), "bash", &["bash"]);
        src.insert(100, Some(2), "2.1.222", &["/opt/example/versions/2.1.222"]);
        src.insert(2, Some(1), "zsh", &["-zsh"]);

        assert_eq!(resolve_pid(&src, 200, "claude"), None);
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
            &[
                "claude",
                "daemon",
                "run",
                "--origin",
                "transient",
                "--spawned-by",
                "{}",
            ],
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
    fn fresh_instance_never_reuses_previous_cached_pid() {
        assert_eq!(select_resolved_pid(None, Some(42), true), None);
        assert_eq!(select_resolved_pid(Some(84), Some(42), true), Some(84));
        assert_eq!(select_resolved_pid(None, Some(42), false), Some(42));
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
    fn usable_tty_rejects_generic_dev_tty() {
        assert_eq!(usable_tty("/dev/tty"), None);
        assert_eq!(usable_tty("??"), None);
        assert_eq!(usable_tty("ttys003"), Some("/dev/ttys003".to_string()));
        assert_eq!(usable_tty("/dev/ttys024"), Some("/dev/ttys024".to_string()));
    }

    #[test]
    fn iterm_session_id_normalization_strips_only_the_instance_prefix() {
        assert_eq!(
            normalized_iterm_session_id("w0t0p0:ABC-123"),
            Some("ABC-123".into())
        );
        assert_eq!(
            normalized_iterm_session_id("ABC-123"),
            Some("ABC-123".into())
        );
        assert_eq!(normalized_iterm_session_id(""), None);
    }

    #[test]
    fn empty_negative_cache_is_not_trusted_and_rewalks() {
        let _environment_guard = IDENTITY_ENV_LOCK.lock().unwrap();
        // Isolate from other tests / the real user's state dir.
        let tmp =
            std::env::temp_dir().join(format!("focalpoint-identity-poison-{}", std::process::id()));
        std::env::set_var("XDG_STATE_HOME", &tmp);

        let id = "poisoned-session";
        // A prior SessionStart lost the walk race and cached a fully-empty
        // identity. Without the trust guard this would be returned verbatim
        // forever; with it, resolve_identity re-walks instead.
        save_identity(
            id,
            &Identity {
                tty: None,
                pid: None,
                ..Identity::default()
            },
        );

        let resolved = resolve_identity(id, "definitely-not-a-real-comm", false);
        // The re-walk finds no such agent (so pid stays None here), but the
        // point is it *attempted* a fresh resolution rather than blindly
        // trusting the poisoned cache — proven by resolving a tty from this
        // test process's own controlling terminal when it has one. Under CI /
        // a detached test runner there may be none, so only assert the guard
        // did not short-circuit on the cached pid: it must remain None (a
        // trusted cache path never re-walks, but also never changes it), and
        // must not panic.
        assert_eq!(resolved.pid, None);
        if resolved.tty.is_none() {
            assert!(
                load_identity(id).is_none(),
                "a none/none result must leave identity resolution re-armed"
            );
        }

        let _ = std::fs::remove_dir_all(&tmp);
        std::env::remove_var("XDG_STATE_HOME");
    }

    #[test]
    fn identity_cache_round_trips() {
        let _environment_guard = IDENTITY_ENV_LOCK.lock().unwrap();
        // Isolate from other tests / the real user's state dir.
        let tmp =
            std::env::temp_dir().join(format!("focalpoint-identity-test-{}", std::process::id()));
        std::env::set_var("XDG_STATE_HOME", &tmp);

        let id = "test-session-abc";
        assert!(load_identity(id).is_none());

        let identity = Identity {
            tty: Some("/dev/ttys003".to_string()),
            pid: Some(4242),
            ..Identity::default()
        };
        save_identity(id, &identity);
        assert_eq!(load_identity(id), Some(identity));

        save_identity_or_rearm(id, &Identity::default());
        assert!(load_identity(id).is_none());

        let _ = std::fs::remove_dir_all(&tmp);
        std::env::remove_var("XDG_STATE_HOME");
    }
}
