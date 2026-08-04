//! Integration tests (Part 5 of SESSION-IDENTITY-PERSISTENCE-PLAN.md), built
//! last, on top of the focused unit tests for each mechanism in
//! `session.rs`/`daemon.rs`/`config.rs`/`identity.rs`. Spawns a real
//! `focalpointd --mock-device` per test and drives it through the real
//! `focalpoint` CLI over the actual Unix-socket protocol — the same
//! `--mock-device` + CLI pattern already documented as the no-hardware
//! smoke test in `daemon/README.md`, just automated and isolated per test.
//!
//! Isolation: each test gets its own `XDG_RUNTIME_DIR`/`XDG_STATE_HOME`/
//! `XDG_CONFIG_HOME` under a short-path scratch dir. Deliberately NOT
//! `std::env::temp_dir()` — on macOS that resolves to a long
//! `/private/var/folders/.../T/` path that overflows a Unix socket's
//! `SUN_LEN` once `focalpoint.sock` is appended (hit this for real while
//! manually smoke-testing Part 4's persistence). `/tmp/fp-test-<pid>-<n>`
//! stays short and always exists.
//!
//! Deterministic matching: tests that exercise the pooled recovery matcher
//! (Part 3) always pass explicit `--meta tty=...`/`--meta pid=...` rather
//! than relying on `--kind claude|codex` auto-resolution (Part 1) — the
//! test process's own real ancestry/terminal is irrelevant noise here, and
//! multiple tests run in parallel from the same `cargo test` runner.

use serde_json::Value;
use std::io::{BufRead, BufReader, Write};
use std::os::unix::net::UnixStream;
use std::path::PathBuf;
use std::process::{Child, Command, Stdio};
use std::sync::atomic::{AtomicU32, Ordering};
use std::time::{Duration, Instant};

fn short_tmp_dir() -> PathBuf {
    static COUNTER: AtomicU32 = AtomicU32::new(0);
    let n = COUNTER.fetch_add(1, Ordering::Relaxed);
    let dir = PathBuf::from(format!("/tmp/fp-test-{}-{}", std::process::id(), n));
    std::fs::create_dir_all(&dir).expect("create scratch dir");
    dir
}

struct CliOutput {
    status_ok: bool,
    stdout: String,
}

struct TestDaemon {
    child: Child,
    dir: PathBuf,
    daemon_bin: &'static str,
    cli_bin: &'static str,
}

impl TestDaemon {
    fn start() -> Self {
        Self::start_with(None, None)
    }

    /// `state_json`, if given, is written to `state.json` *before* the
    /// daemon's first launch — for tests that need to seed a specific
    /// persisted snapshot (e.g. an artificially-aged tombstone) rather than
    /// building it up through a live reap.
    fn start_with(config_toml: Option<&str>, state_json: Option<&Value>) -> Self {
        let dir = short_tmp_dir();
        std::fs::create_dir_all(dir.join("runtime")).unwrap();
        std::fs::create_dir_all(dir.join("state").join("focalpoint")).unwrap();
        if let Some(cfg) = config_toml {
            let cfg_dir = dir.join("config").join("focalpoint");
            std::fs::create_dir_all(&cfg_dir).unwrap();
            std::fs::write(cfg_dir.join("config.toml"), cfg).unwrap();
        }
        if let Some(snapshot) = state_json {
            std::fs::write(
                dir.join("state").join("focalpoint").join("state.json"),
                snapshot.to_string(),
            )
            .unwrap();
        }
        let daemon_bin = env!("CARGO_BIN_EXE_focalpointd");
        let cli_bin = env!("CARGO_BIN_EXE_focalpoint");
        let child = Self::spawn(daemon_bin, &dir);
        let daemon = TestDaemon {
            child,
            dir,
            daemon_bin,
            cli_bin,
        };
        daemon.wait_ready();
        daemon
    }

    fn spawn(daemon_bin: &str, dir: &std::path::Path) -> Child {
        Command::new(daemon_bin)
            .arg("--mock-device")
            .env("XDG_RUNTIME_DIR", dir.join("runtime"))
            .env("XDG_STATE_HOME", dir.join("state"))
            .env("XDG_CONFIG_HOME", dir.join("config"))
            .stdin(Stdio::null())
            .stdout(Stdio::null())
            .stderr(Stdio::null())
            .spawn()
            .expect("spawn focalpointd")
    }

    fn wait_ready(&self) {
        let deadline = Instant::now() + Duration::from_secs(10);
        loop {
            if self.cli(&["get-state"]).status_ok {
                return;
            }
            assert!(Instant::now() < deadline, "daemon never became ready");
            std::thread::sleep(Duration::from_millis(100));
        }
    }

    fn cli(&self, args: &[&str]) -> CliOutput {
        let output = Command::new(self.cli_bin)
            .args(args)
            .env("XDG_RUNTIME_DIR", self.dir.join("runtime"))
            .env("XDG_STATE_HOME", self.dir.join("state"))
            .env("XDG_CONFIG_HOME", self.dir.join("config"))
            .output()
            .expect("run focalpoint CLI");
        CliOutput {
            status_ok: output.status.success(),
            stdout: String::from_utf8_lossy(&output.stdout).into_owned(),
        }
    }

    fn cli_ok(&self, args: &[&str]) {
        let out = self.cli(args);
        assert!(
            out.status_ok,
            "`focalpoint {}` failed: {}",
            args.join(" "),
            out.stdout
        );
    }

    fn cli_json(&self, args: &[&str]) -> Value {
        let out = self.cli(args);
        serde_json::from_str(out.stdout.trim()).unwrap_or_else(|e| {
            panic!(
                "bad JSON from `focalpoint {}`: {e}\nstdout: {:?}",
                args.join(" "),
                out.stdout
            )
        })
    }

    fn socket_json(&self, request: Value) -> Value {
        let socket = self.dir.join("runtime/focalpoint.sock");
        let mut stream = UnixStream::connect(socket).expect("connect daemon socket");
        writeln!(stream, "{request}").expect("write daemon request");
        let mut response = String::new();
        BufReader::new(stream)
            .read_line(&mut response)
            .expect("read daemon response");
        serde_json::from_str(response.trim()).expect("valid daemon JSON")
    }

    /// Kill and respawn against the *same* state/runtime dirs — the actual
    /// scenario Part 4 exists for.
    fn restart(&mut self) {
        let _ = self.child.kill();
        let _ = self.child.wait();
        self.child = Self::spawn(self.daemon_bin, &self.dir);
        self.wait_ready();
    }

    fn wait_until<F>(&self, timeout: Duration, mut pred: F)
    where
        F: FnMut() -> bool,
    {
        let deadline = Instant::now() + timeout;
        while !pred() {
            assert!(Instant::now() < deadline, "condition never became true");
            std::thread::sleep(Duration::from_secs(2));
        }
    }
}

impl Drop for TestDaemon {
    fn drop(&mut self) {
        let _ = self.child.kill();
        let _ = self.child.wait();
        let _ = std::fs::remove_dir_all(&self.dir);
    }
}

#[test]
fn daemon_owns_attention_order_cycles_and_persists_it() {
    let mut d = TestDaemon::start();
    for (id, state) in [("a", "waiting"), ("b", "error"), ("c", "running")] {
        d.cli_ok(&["set-state", state, "--session", id, "--kind", "generic"]);
    }

    assert_eq!(
        d.socket_json(serde_json::json!({"cmd": "get-attention-order"})),
        serde_json::json!({"ok": true, "sessions": ["b", "a", "c"]})
    );
    let rejected = d.socket_json(serde_json::json!({
        "cmd": "set-attention-order", "sessions": ["a", "b"]
    }));
    assert_eq!(rejected["ok"], false);

    assert_eq!(
        d.socket_json(serde_json::json!({
            "cmd": "set-attention-order", "sessions": ["a", "c", "b"]
        })),
        serde_json::json!({"ok": true})
    );
    assert_eq!(
        d.socket_json(serde_json::json!({"cmd": "focus-next-attention"})),
        serde_json::json!({"ok": true, "session": "a"})
    );
    assert_eq!(
        d.socket_json(serde_json::json!({"cmd": "focus-next-attention"})),
        serde_json::json!({"ok": true, "session": "b"})
    );
    assert_eq!(
        d.socket_json(serde_json::json!({"cmd": "focus-prev-attention"})),
        serde_json::json!({"ok": true, "session": "a"})
    );

    d.restart();
    assert_eq!(
        d.socket_json(serde_json::json!({"cmd": "get-attention-order"})),
        serde_json::json!({"ok": true, "sessions": ["a", "c", "b"]})
    );
}

#[test]
fn orchestrator_controls_require_matching_task_and_hide_transcript_path() {
    let d = TestDaemon::start();
    d.cli_ok(&[
        "set-state",
        "running",
        "--session",
        "owned",
        "--kind",
        "claude",
        "--meta",
        "managed=true",
        "--meta",
        "orchestrator_task_id=task-1",
        "--meta",
        "transcript_path=/tmp/private.jsonl",
    ]);
    let listed = d.socket_json(serde_json::json!({"cmd": "list-sessions"}));
    assert!(listed["sessions"][0]["meta"]
        .get("transcript_path")
        .is_none());

    let rejected = d.socket_json(serde_json::json!({
        "cmd": "stop-orchestrated-session", "session": "owned", "task_id": "task-2"
    }));
    assert_eq!(rejected["ok"], false);
    assert_eq!(
        d.socket_json(serde_json::json!({
            "cmd": "read-session-transcript", "session": "owned", "task_id": "task-2"
        }))["ok"],
        false
    );
    let stopped = d.socket_json(serde_json::json!({
        "cmd": "stop-orchestrated-session", "session": "owned", "task_id": "task-1"
    }));
    assert_eq!(stopped["ok"], true);
    assert_eq!(stopped["status"], "stopping");
    assert!(d
        .cli_json(&["sessions", "--json"])
        .as_array()
        .unwrap()
        .is_empty());
}

#[test]
fn basic_lifecycle_and_explicit_end_session_leaves_no_tombstone() {
    let d = TestDaemon::start();

    d.cli_ok(&[
        "set-state",
        "running",
        "--session",
        "s1",
        "--kind",
        "generic",
        "--cwd",
        "/tmp/proj",
        "--label",
        "First",
    ]);
    d.cli_ok(&[
        "set-state",
        "waiting",
        "--session",
        "s1",
        "--kind",
        "generic",
        "--cwd",
        "/tmp/proj",
        "--label",
        "First",
    ]);
    let sessions = d.cli_json(&["sessions", "--json"]);
    let arr = sessions.as_array().unwrap();
    assert_eq!(arr.len(), 1);
    assert_eq!(arr[0]["session"], "s1");
    assert_eq!(arr[0]["state"], "waiting");

    d.cli_ok(&["end-session", "s1"]);
    assert_eq!(
        d.cli_json(&["sessions", "--json"])
            .as_array()
            .unwrap()
            .len(),
        0
    );

    // A brand-new registration with the exact same signals must NOT recover
    // s1's history — end-session must have cleared any tombstone-eligible
    // trace outright, not just hidden it.
    d.cli_ok(&[
        "set-state",
        "thinking",
        "--session",
        "s2",
        "--kind",
        "generic",
        "--cwd",
        "/tmp/proj",
        "--label",
        "First",
    ]);
    let sessions = d.cli_json(&["sessions", "--json"]);
    let arr = sessions.as_array().unwrap();
    assert_eq!(arr.len(), 1);
    assert_eq!(arr[0]["session"], "s2");
    assert!(arr[0]["meta"].get("turns").is_none());
}

#[test]
fn compaction_continuation_carries_stats_and_resets_context() {
    let d = TestDaemon::start();

    d.cli_ok(&[
        "set-state",
        "running",
        "--session",
        "old",
        "--kind",
        "claude",
        "--cwd",
        "/tmp/proj",
        "--label",
        "My Chat",
        "--meta",
        "tty=/dev/test-tty-1",
        "--meta",
        "turns=30",
        "--meta",
        "tool_calls=550",
        "--meta",
        "cost_usd=1.5",
        "--meta",
        "context_tokens=116821",
    ]);
    d.cli_ok(&[
        "set-state",
        "compacting",
        "--session",
        "old",
        "--kind",
        "claude",
        "--cwd",
        "/tmp/proj",
        "--meta",
        "tty=/dev/test-tty-1",
    ]);
    d.cli_ok(&[
        "set-state",
        "thinking",
        "--session",
        "new",
        "--kind",
        "claude",
        "--cwd",
        "/tmp/proj",
        "--label",
        "My Chat",
        "--meta",
        "tty=/dev/test-tty-1",
        "--meta",
        "turns=3",
        "--meta",
        "tool_calls=12",
        "--meta",
        "cost_usd=0.2",
        "--meta",
        "context_tokens=4000",
    ]);

    let sessions = d.cli_json(&["sessions", "--json"]);
    let arr = sessions.as_array().unwrap();
    assert_eq!(
        arr.len(),
        1,
        "old must have been rekeyed into new, not left as a duplicate"
    );
    let s = &arr[0];
    assert_eq!(s["session"], "new");
    assert_eq!(s["meta"]["turns"], 33); // 30 + 3
    assert_eq!(s["meta"]["tool_calls"], 562); // 550 + 12
    assert!((s["meta"]["cost_usd"].as_f64().unwrap() - 1.7).abs() < 1e-9); // 1.5 + 0.2
    assert_eq!(
        s["meta"]["context_tokens"], 4000,
        "instantaneous key: plain overwrite, not carried"
    );
    assert_eq!(s["meta"]["compactions"], 1);
    assert!(
        s["meta"].get("_carry_turns").is_none(),
        "internal carry-forward bookkeeping must never cross the socket API"
    );
}

#[test]
fn dead_pid_sweep_reaps_and_tombstone_is_recoverable() {
    let d = TestDaemon::start();

    d.cli_ok(&[
        "set-state",
        "running",
        "--session",
        "old",
        "--kind",
        "generic",
        "--cwd",
        "/tmp/proj",
        "--meta",
        "pid=999999999", // not a real process on any sane system
        "--meta",
        "tty=/dev/test-tty-dead",
    ]);
    assert_eq!(
        d.cli_json(&["sessions", "--json"])
            .as_array()
            .unwrap()
            .len(),
        1
    );

    // The real dead-pid sweep (daemon.rs) runs on a 30s cadence — wait for
    // it to actually reap this session, rather than asserting the mechanism
    // in isolation. This is the one test in this file that genuinely proves
    // the periodic sweep is wired to `reap_session` end to end in a live
    // running daemon. A reaped session is no longer dropped from the list —
    // it stays visible as `connected: false` (disconnected) until ended,
    // dismissed, recovered, or its tombstone TTL expires.
    d.wait_until(Duration::from_secs(45), || {
        d.cli_json(&["sessions", "--json"])
            .as_array()
            .unwrap()
            .iter()
            .any(|s| s["session"] == "old" && s["connected"] == serde_json::json!(false))
    });

    // Recover via pid+cwd (2 signals) — a different tty, as if reattached
    // in a new terminal. Recovery consumes the tombstone, so only the
    // reconnected session remains.
    d.cli_ok(&[
        "set-state",
        "thinking",
        "--session",
        "new",
        "--kind",
        "generic",
        "--cwd",
        "/tmp/proj",
        "--meta",
        "pid=999999999",
        "--meta",
        "tty=/dev/test-tty-other",
    ]);
    let sessions = d.cli_json(&["sessions", "--json"]);
    let arr = sessions.as_array().unwrap();
    assert_eq!(arr.len(), 1);
    assert_eq!(arr[0]["session"], "new");
}

#[test]
fn shared_label_and_cwd_do_not_recover_a_dead_tty_tombstone() {
    let d = TestDaemon::start();

    d.cli_ok(&[
        "set-state",
        "running",
        "--session",
        "old",
        "--kind",
        "claude",
        "--cwd",
        "/tmp/proj",
        "--label",
        "Resumed Chat",
        "--meta",
        "tty=/dev/fp-test-nonexistent-1",
        "--meta",
        "pid=111111",
        "--meta",
        "turns=7",
    ]);
    assert_eq!(
        d.cli_json(&["sessions", "--json"])
            .as_array()
            .unwrap()
            .len(),
        1
    );

    // Dead-tty sweep: the pty device never existed, so reap is deterministic
    // once the 30s interval fires — same cadence as the dead-pid test above.
    // The reaped session stays visible as `connected: false`.
    d.wait_until(Duration::from_secs(45), || {
        d.cli_json(&["sessions", "--json"])
            .as_array()
            .unwrap()
            .iter()
            .any(|s| s["session"] == "old" && s["connected"] == serde_json::json!(false))
    });

    // Different pid *and* tty. A title plus cwd is shared by unrelated fresh
    // sessions, so it must not consume the disconnected tombstone.
    d.cli_ok(&[
        "set-state",
        "thinking",
        "--session",
        "new",
        "--kind",
        "claude",
        "--cwd",
        "/tmp/proj",
        "--label",
        "Resumed Chat",
        "--meta",
        "tty=/dev/fp-test-nonexistent-2",
        "--meta",
        "pid=222222",
        "--meta",
        "turns=1",
    ]);
    let sessions = d.cli_json(&["sessions", "--json"]);
    let arr = sessions.as_array().unwrap();
    assert_eq!(arr.len(), 2);
    let new = arr.iter().find(|session| session["session"] == "new").unwrap();
    assert_eq!(new["connected"], serde_json::json!(true));
    assert_eq!(new["meta"]["turns"], 1, "fresh session must not inherit old totals");
    let old = arr.iter().find(|session| session["session"] == "old").unwrap();
    assert_eq!(old["connected"], serde_json::json!(false));
}

#[test]
fn restart_persists_session_and_usage() {
    let mut d = TestDaemon::start();

    d.cli_ok(&[
        "set-state",
        "running",
        "--session",
        "s1",
        "--kind",
        "generic",
        "--cwd",
        "/tmp/proj",
        "--label",
        "Persisted",
        "--meta",
        "turns=5",
    ]);
    d.cli_ok(&["set-usage", "claude", "--meta", "five_hour_used=42"]);

    d.restart();

    // No new hook event fired — this must already be correct.
    let sessions = d.cli_json(&["sessions", "--json"]);
    let arr = sessions.as_array().unwrap();
    assert_eq!(arr.len(), 1);
    assert_eq!(arr[0]["session"], "s1");
    assert_eq!(arr[0]["meta"]["turns"], 5);

    let usage = d.cli_json(&["usage", "--json"]);
    assert_eq!(usage["claude"]["five_hour_used"], 42.0);
}

#[test]
fn restart_preserves_tombstone_for_recovery() {
    let mut d = TestDaemon::start();

    d.cli_ok(&[
        "set-state",
        "running",
        "--session",
        "old",
        "--kind",
        "generic",
        "--cwd",
        "/tmp/proj",
        "--label",
        "Survives Restart",
        "--meta",
        "pid=999999998",
        "--meta",
        "turns=12",
    ]);

    // Restart while the session is still "live" on disk — startup
    // reconciliation reaps the dead pid into a tombstone immediately (no
    // 30s sweep wait), and Part 4 must persist that tombstone across the
    // same load path a real reboot uses. The reaped session stays visible
    // as a disconnected (`connected: false`) row rather than vanishing.
    d.restart();
    let after = d.cli_json(&["sessions", "--json"]);
    let after = after.as_array().unwrap();
    assert_eq!(after.len(), 1);
    assert_eq!(after[0]["session"], "old");
    assert_eq!(after[0]["connected"], serde_json::json!(false));

    d.cli_ok(&[
        "set-state",
        "thinking",
        "--session",
        "new",
        "--kind",
        "generic",
        "--cwd",
        "/tmp/proj",
        "--label",
        "Survives Restart",
        "--meta",
        "pid=999999998",
        "--meta",
        "tty=/dev/fp-test-other",
    ]);
    let sessions = d.cli_json(&["sessions", "--json"]);
    let arr = sessions.as_array().unwrap();
    assert_eq!(arr.len(), 1);
    assert_eq!(arr[0]["session"], "new");
    assert_eq!(arr[0]["meta"]["turns"], 12);
}

#[test]
fn tombstone_infinite_ttl_recovers_after_simulated_long_gap() {
    // A default (30min) tombstone_ttl would never accept a 60-day-old
    // tombstone — hand-author a snapshot containing one and boot straight
    // into it, proving `tombstone_ttl_minutes = 0` means what it says, end
    // to end, through the same load path a real restart uses (Part 4).
    let sixty_days_ms = 60u64 * 24 * 60 * 60 * 1000;
    let now_ms = std::time::SystemTime::now()
        .duration_since(std::time::UNIX_EPOCH)
        .unwrap()
        .as_millis() as u64;
    let snapshot = serde_json::json!({
        "saved_at_unix_ms": now_ms,
        "sessions": [],
        "tombstones": [{
            "session": "ancient",
            "kind": "generic",
            "label": "Old Chat",
            "name": null,
            "slot": 1,
            "state": "done",
            "meta": {"cwd": "/tmp/proj", "tty": "/dev/test-tty-ancient", "turns": 11},
            "elapsed_ms_since_reaped": sixty_days_ms,
        }],
        "usage": {},
    });

    let d = TestDaemon::start_with(
        Some("[session]\ntombstone_ttl_minutes = 0\n"),
        Some(&snapshot),
    );

    d.cli_ok(&[
        "set-state",
        "thinking",
        "--session",
        "new",
        "--kind",
        "generic",
        "--cwd",
        "/tmp/proj",
        "--label",
        "Old Chat",
        "--meta",
        "resume_session_id=ancient",
        "--meta",
        "tty=/dev/test-tty-different",
    ]);
    let sessions = d.cli_json(&["sessions", "--json"]);
    let arr = sessions.as_array().unwrap();
    assert_eq!(arr.len(), 1);
    assert_eq!(arr[0]["session"], "new");
    assert_eq!(
        arr[0]["meta"]["turns"], 11,
        "must have recovered ancient's carried stats"
    );
}
