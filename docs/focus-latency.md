# Focus latency

This note maps the path from a FocalPoint selection to exact terminal focus,
records the August 22, 2026 macOS measurements, and documents the bounded
timing probes. Focus identities and command text are deliberately absent from
timing logs.

## End-to-end path

1. A menu row or desktop widget calls `AppModel.focusSession`. A live slotted
   session sends an injected numbered-key tap; a disconnected or overflow
   session sends `focus-session` by stable session ID. Global numbered hotkeys
   send the same injected tap directly. Physical keys enter as the same
   `DeviceEvent::Key` used by injection.
2. `DaemonClient.send` schedules a user-initiated one-shot Unix-socket request.
   Connect, encode, and write have no retry or sleep on the successful path.
   The subscriber's two-second delay is reconnect-only and is not in focus
   dispatch.
3. `focalpointd` resolves a numbered slot or stable ID to a cloned session and
   spawns `run_focus` on a detached thread. Attention navigation first resolves
   its exact session under the registry lock. The socket handler does not wait
   for terminal activation.
4. `run_focus` rejects missing/detached attachments, constructs bounded
   `FOCALPOINT_SESSION_*` identity variables, and calls the configured focus
   action through `actions::run_with_env_status`. That synchronous action hop
   now logs only `result` and `elapsed_ms`.
5. `focus-session.sh` dispatches Cursor sessions to `focus-cursor.sh`. Managed
   terminal sessions first validate the exact private tmux server/session/pane,
   select its window, enumerate attached clients, switch each client, and raise
   the terminal endpoint matching the client tty. Unmanaged sessions use the
   captured iTerm application PID/session ID, then exact tty. No cwd, title, or
   generic terminal activation fallback is permitted.
6. The native iTerm helper enumerates the selected iTerm process (or every
   process when no PID was captured), selects the exact session/tab/window, and
   calls AppKit activation. AppleScript tty matching remains the fallback when
   the helper is unavailable. Cursor reuses the exact workspace window where
   possible, then activates Cursor; Cursor exposes no per-chat window handle.
7. A successful action broadcasts `focus` and `focus-result`; a failure reports
   `endpoint-missing` or `attachment-stale`. `focus-result` means the exact
   adapter completed successfully, not that WindowServer has painted the
   target. AppKit activation is asynchronous, so final presentation latency is
   OS-controlled.

## Sleeps, retries, and timeouts

- The daemon adds no retry or sleep to focus dispatch.
- The iTerm helper tries the captured application PID first, then all iTerm
  PIDs. These are exact fallbacks, not timed retries. Each ScriptingBridge
  application has a 60-tick (one second) Apple Event timeout so an unresponsive
  legacy iTerm process is bounded.
- AppleScript and Cursor external calls retain the three-second hard timeout.
  Completion polling changed from 100 ms to 10 ms. This bounds post-completion
  detection overhead at 10 ms instead of 100 ms without changing kill or
  fallback semantics.
- The app subscriber retries a lost daemon connection after two seconds, but a
  connected focus request does not pass through that retry loop.

## Reproduction and results

Measurements used macOS 26.5.2 with six running iTerm processes. Samples used
`CLOCK_MONOTONIC`, exact captured endpoints, and alternating before/after runs
to reduce drift. The managed sample used an exact private tmux pane and client;
the unmanaged sample used an exact iTerm process/session. Values are process
completion proxies because non-invasive code cannot observe the exact frame in
which WindowServer presents a tab or pane.

| Path | Sample | Before p50 / p95 | After p50 / p95 | Result |
|---|---:|---:|---:|---:|
| Unmanaged native iTerm focus | 40 + 40 | 120.3 / 138.4 ms | 121.0 / 139.7 ms | unchanged; OS Apple Events dominate |
| Full managed tmux + native helper | 30 + 30 | 193.4 / 272.6 ms | 184.0 / 316.0 ms | no reliable change; variance dominates |
| Unmanaged exact-tty AppleScript fallback | 20 + 20 | 258.0 / 270.1 ms | 199.5 / 255.4 ms | p50 -58.5 ms (-22.7%) |

The native helper's opt-in phase probe observed total times of 119.7–186.1 ms
for the same endpoint. Application discovery was 1.0–1.4 ms and the AppKit
activation call was 1.3–26.8 ms; the synchronous ScriptingBridge hierarchy
and identity reads account for the remaining dominant time. An attempted
property-read reduction did not improve an interleaved sample and was not
kept.

To capture bounded production timings, set `FOCALPOINT_FOCUS_TIMING=1` in the
focus action environment. The daemon emits:

```text
[focus-timing] hop=action result=ok elapsed_ms=...
[focus-timing] adapter=iterm-helper result=matched total_ms=... applications_ms=... activation_ms=... applications=... windows=... tabs=... sessions=...
```

The helper line contains counts and durations only. Its normal stdout and all
session identifiers remain suppressed by the adapter. `test_focus_guard_poll.sh`
uses deterministic fake 30 ms commands and fails if either guarded adapter
returns to 100 ms ticks.

Remaining latency in the common native path is largely ScriptingBridge/Apple
Event startup and WindowServer/iTerm presentation. Removing it safely would
require a persistent, exact-endpoint host service or a terminal-supported focus
primitive; shortening Apple Event timeouts or activating a generic iTerm
instance would trade away correctness and was intentionally rejected.

## Destructive session cleanup

The app's destructive **End Session** action sends `quit-session` (the separate
**Remove Session** action remains non-destructive). After the provider exits,
the daemon now closes the terminal endpoint captured on the session attachment:
iTerm uses the native helper's `--close` operation with exact session ID and,
when available, exact application PID; Terminal uses exact tty. A disconnected
session with no provider PID still closes its captured endpoint. Missing or
unverified endpoint identity is logged and left open rather than risking an
unrelated terminal. This required a narrow shared change in `daemon/src/daemon.rs`.
