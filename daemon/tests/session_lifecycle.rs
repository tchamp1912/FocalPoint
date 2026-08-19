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
//! Deterministic matching: tests that exercise attachment recovery pass a
//! complete boot/PID/start-time/executable fingerprint rather than relying
//! on provider ancestry auto-resolution. Tests that simulate history resume
//! use the exact `resume_session_id` marker.

use serde_json::Value;
use std::io::{BufRead, BufReader, Write};
use std::os::unix::net::UnixStream;
use std::path::PathBuf;
use std::process::{Child, Command, Stdio};
use std::sync::atomic::{AtomicU32, Ordering};
use std::time::{Duration, Instant};

fn current_process_attachment_meta() -> [String; 4] {
    let pid = sysinfo::Pid::from_u32(std::process::id());
    let system = sysinfo::System::new_all();
    let process = system.process(pid).expect("current test process");
    [
        format!("pid={}", pid.as_u32()),
        format!("process_boot_time={}", sysinfo::System::boot_time()),
        format!("process_start_time={}", process.start_time()),
        format!(
            "provider_executable={}",
            process
                .exe()
                .expect("current test executable")
                .to_string_lossy()
        ),
    ]
}

fn missing_process_attachment_meta(pid: u32, start_time: u64) -> [String; 4] {
    [
        format!("pid={pid}"),
        format!("process_boot_time={}", sysinfo::System::boot_time()),
        format!("process_start_time={start_time}"),
        "provider_executable=/definitely/missing/focalpoint-provider".into(),
    ]
}

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
        self.cli_with_env(args, &[])
    }

    fn cli_with_env(&self, args: &[&str], env: &[(&str, &str)]) -> CliOutput {
        let output = Command::new(self.cli_bin)
            .args(args)
            .env("XDG_RUNTIME_DIR", self.dir.join("runtime"))
            .env("XDG_STATE_HOME", self.dir.join("state"))
            .env("XDG_CONFIG_HOME", self.dir.join("config"))
            .envs(env.iter().copied())
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

    fn subscription_snapshot(&self) -> Vec<Value> {
        let socket = self.dir.join("runtime/focalpoint.sock");
        let mut stream = UnixStream::connect(socket).expect("connect daemon socket");
        writeln!(stream, "{{\"cmd\":\"subscribe\"}}").expect("write subscribe");
        let mut reader = BufReader::new(stream);
        let mut events = Vec::new();
        loop {
            let mut line = String::new();
            reader.read_line(&mut line).expect("read subscription event");
            assert!(!line.is_empty(), "subscription closed before snapshot-end");
            let event: Value = serde_json::from_str(line.trim()).expect("valid event JSON");
            let complete = event["event"] == "snapshot-end";
            events.push(event);
            if complete {
                return events;
            }
        }
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
fn subscription_snapshot_is_framed_and_includes_disconnected_sessions() {
    let now_ms = std::time::SystemTime::now()
        .duration_since(std::time::UNIX_EPOCH)
        .unwrap()
        .as_millis() as u64;
    let snapshot = serde_json::json!({
        "saved_at_unix_ms": now_ms,
        "sessions": [{
            "session": "live", "kind": "generic", "label": "Live", "name": null,
            "slot": 1, "state": "running", "meta": {}, "elapsed_ms_since_update": 0
        }],
        "tombstones": [{
            "session": "gone", "kind": "generic", "label": "Gone", "name": null,
            "slot": 2, "state": "done", "meta": {}, "elapsed_ms_since_reaped": 0
        }],
        "usage": {},
    });
    let d = TestDaemon::start_with(None, Some(&snapshot));
    let events = d.subscription_snapshot();
    assert_eq!(events.first().unwrap()["event"], "snapshot-begin");
    assert_eq!(events.last().unwrap()["event"], "snapshot-end");
    assert_eq!(
        events.first().unwrap()["generation"],
        events.last().unwrap()["generation"]
    );
    let live = events.iter().find(|event| event["session"] == "live").unwrap();
    let gone = events.iter().find(|event| event["session"] == "gone").unwrap();
    assert_eq!(live["connected"], true);
    assert_eq!(gone["connected"], false);
}

#[test]
fn pane_local_reregister_reconstructs_managed_identity() {
    use std::os::unix::fs::PermissionsExt;

    let d = TestDaemon::start();
    let fake_tmux = d.dir.join("fake-tmux");
    std::fs::write(
        &fake_tmux,
        "#!/bin/bash\nprintf 'fp-codex-42|%%4|/dev/ttys042\\n'\n",
    )
    .unwrap();
    std::fs::set_permissions(&fake_tmux, std::fs::Permissions::from_mode(0o700)).unwrap();
    let fake_tmux_text = fake_tmux.to_string_lossy().to_string();
    let output = d.cli_with_env(
        &[
            "re-register", "--session", "provider-session", "--kind", "codex",
            "--title", "Parser implementation", "--task-id", "worker-1",
            "--role", "worker", "--manager-task-id", "orchestrator-1",
            "--slot", "4", "--state", "thinking",
        ],
        &[
            ("TMUX", "/tmp/tmux-501/fp-worker-42,123,0"),
            ("TMUX_PANE", "%4"),
            ("FOCALPOINT_TMUX_SERVER", "fp-worker-42"),
            ("FOCALPOINT_TMUX_BIN", &fake_tmux_text),
        ],
    );
    assert!(output.status_ok, "re-register failed: {}", output.stdout);

    let sessions = d.cli_json(&["sessions", "--json"]);
    let session = &sessions.as_array().unwrap()[0];
    assert_eq!(session["session"], "provider-session");
    assert_eq!(session["label"], "Parser implementation");
    // The pane proof is sufficient to reconstruct the managed attachment,
    // but a caller-provided slot is not authoritative. Without the matching
    // daemon launch receipt/reservation it receives the normal free slot.
    assert_eq!(session["slot"], 1);
    assert_eq!(session["meta"]["managed"], "true");
    assert_eq!(session["meta"]["mux_server"], "fp-worker-42");
    assert_eq!(session["meta"]["mux_session"], "fp-codex-42");
    assert_eq!(session["meta"]["mux_pane"], "%4");
    assert_eq!(session["meta"]["orchestrator_task_id"], "worker-1");
    assert_eq!(session["meta"]["reregistered"], "true");
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
    let attachment = current_process_attachment_meta();

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
        "--meta",
        &attachment[0],
        "--meta",
        &attachment[1],
        "--meta",
        &attachment[2],
        "--meta",
        &attachment[3],
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
        "--meta",
        &attachment[0],
        "--meta",
        &attachment[1],
        "--meta",
        &attachment[2],
        "--meta",
        &attachment[3],
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
        "--meta",
        &attachment[0],
        "--meta",
        &attachment[1],
        "--meta",
        &attachment[2],
        "--meta",
        &attachment[3],
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
    let attachment = missing_process_attachment_meta(999_999_999, 101);

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
        &attachment[0], // not a real process on any sane system
        "--meta",
        "tty=/dev/test-tty-dead",
        "--meta",
        &attachment[1],
        "--meta",
        &attachment[2],
        "--meta",
        &attachment[3],
    ]);
    assert_eq!(
        d.cli_json(&["sessions", "--json"])
            .as_array()
            .unwrap()
            .len(),
        1
    );

    // The real attachment probe runs every 15 seconds and requires failures
    // spanning 30 seconds before detaching an absent process. This proves the
    // debounce and durable disconnected row end to end in a live daemon.
    d.wait_until(Duration::from_secs(70), || {
        d.cli_json(&["sessions", "--json"])
            .as_array()
            .unwrap()
            .iter()
            .any(|s| s["session"] == "old" && s["connected"] == serde_json::json!(false))
    });

    // Once detached, the obsolete runtime attachment is gone. A new logical
    // id can recover the durable record only through the exact provider
    // resume id; tty, cwd, and the former fingerprint are not fallbacks.
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
        "resume_session_id=old",
        "--meta",
        &attachment[0],
        "--meta",
        "tty=/dev/test-tty-other",
        "--meta",
        &attachment[1],
        "--meta",
        &attachment[2],
        "--meta",
        &attachment[3],
    ]);
    let sessions = d.cli_json(&["sessions", "--json"]);
    let arr = sessions.as_array().unwrap();
    assert_eq!(arr.len(), 1);
    assert_eq!(arr[0]["session"], "new");
}

#[test]
fn shared_label_and_cwd_do_not_recover_a_dead_tty_tombstone() {
    let d = TestDaemon::start();
    let old_attachment = missing_process_attachment_meta(111_111, 201);
    let new_attachment = missing_process_attachment_meta(222_222, 202);

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
        &old_attachment[0],
        "--meta",
        &old_attachment[1],
        "--meta",
        &old_attachment[2],
        "--meta",
        &old_attachment[3],
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

    // The authoritative process is absent (and the pty never existed), so
    // the debounced attachment probe eventually leaves a disconnected row.
    d.wait_until(Duration::from_secs(70), || {
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
        &new_attachment[0],
        "--meta",
        &new_attachment[1],
        "--meta",
        &new_attachment[2],
        "--meta",
        &new_attachment[3],
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
    let resumed_attachment = current_process_attachment_meta();

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
        "process_boot_time=0",
        "--meta",
        "process_start_time=1",
        "--meta",
        "provider_executable=/definitely/missing/focalpoint-provider",
        "--meta",
        "turns=12",
    ]);

    // Restart while the session is still "live" on disk — startup
    // reconciliation sees a definitive boot-identity mismatch and detaches
    // immediately (no debounce), and the snapshot must preserve history on
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
        "resume_session_id=old",
        "--meta",
        "tty=/dev/fp-test-other",
        "--meta",
        &resumed_attachment[0],
        "--meta",
        &resumed_attachment[1],
        "--meta",
        &resumed_attachment[2],
        "--meta",
        &resumed_attachment[3],
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
