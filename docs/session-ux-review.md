# Session UX fixes — September 9, 2026

## Findings and changes

| Reported behavior | Cause | Change |
| --- | --- | --- |
| Context count repeatedly drops and rebounds | Codex helper hooks can carry the parent session ID with a child rollout path. The adapter accepted the child's usage as the parent's. | Ignore helper rollouts before any lifecycle, counters, or telemetry writes. Regression fixtures include inherited parent IDs and child SessionEnd hooks. |
| Claude selection returns to Codex or proposes GPT | Automatic task routing overwrote explicit provider selection; recommendations ignored it. | Represent Automatic separately, preserve explicit selection, clear stale models on provider changes, and resolve suggestions within the selected provider. |
| Ending a managed session leaves its terminal | Managed stop and UI quit used different cleanup paths. | Share shutdown, capture the exact terminal endpoint before provider teardown removes the row, support iTerm host TTY fallback, and retain the session if the process refuses to exit. |
| Cursor focus targets the wrong window | `--reuse-window` selects the last active window; GUI PATH may omit the Cursor CLI. | Open the recorded workspace through the CLI, discover its bundled executable, and use a document-open fallback. |
| Helper agents appear as independent sessions | Cursor child composer events and Codex helper rollouts entered ordinary registration. | Filter explicit child identities at the adapter boundary. |
| Forks leave two live entries for one terminal | The registry distinguished conversations but did not hand off an exclusive terminal attachment. | On verified Codex registration, move the prior conversation to history and transfer the freed slot. Persist an internal superseded marker to reject late hooks without showing a duplicate after reconnects or restarts. Independent processes and hosts without a terminal remain separate. |

The main window now opens on Live Sessions. Session rows expose readable state badges, disable Focus for disconnected windows, and place End Session in a secondary menu. The launcher keeps optional fields under Options and launches directly with inline validation. Row focus uses the session ID rather than a potentially reassigned slot. Rejected end requests now show the daemon's error.

## Architectural assessment

The most consequential issues were inconsistent ownership boundaries: conversation identity, helper identity, provider process, terminal attachment, and keyboard slot were treated as interchangeable in some paths. The fixes preserve those distinctions without replacing the daemon/socket architecture.

The launcher now uses the shared model catalog and installed agent personas. One path still merits follow-up:

- Shutdown acknowledges an accepted request before asynchronous process exit and terminal closure. Failed exits retain their row and are logged, but a completion event would let every UI show explicit stopping/succeeded/failed states.

Cursor focus is at workspace-window granularity. The available adapter does not address individual chats in the same workspace. Ending a GUI Cursor conversation must happen in Cursor; FocalPoint rejects termination of its shared editor process.

## Validation and deployment

- Full Rust unit and integration suite passed: 207 tests, including isolated daemon lifecycle tests. After the final history-visibility correction, focused unit and two snapshot integration tests also passed, including repeated daemon restarts.
- Launcher model regression tests, full Swift app typecheck, optimized app build, and signature verification passed.
- Codex child isolation and Cursor lifecycle/child/focus shell regressions passed.
- The installed Codex hook was backed up and updated immediately. Before the update, the live stream alternated parent and helper counts within a second. A 35-second observation afterward showed normal advancing parent counts with no oscillation.
- Actual Terminal/iTerm window closure and Cursor window selection still require interactive verification; automated tests exercise endpoint dispatch and CLI/fallback behavior.

The app, daemon binaries, wrapper, and adapters are installed together; updates preserve existing session state and custom tmux settings.

## Launcher and terminal follow-up

The launch form now puts project, task, provider, installed agent type, and
catalog model on one screen. Optional title, task-size override, and terminal
accent live under Options. Launch is a single explicit action with a busy state;
success closes the form and failure retains the draft. Unchanged retries reuse
the daemon receipt identity. The launch timeout now accommodates Cursor's
registration window instead of declaring failure at five seconds.

The chosen persona is included in the task, with bounded file and prompt reads.
Unsupported enforced agent constraints remain unavailable in this launch path.
The old preset manager and task-ID controls are absent from the quick form;
existing saved presets are preserved on disk.

Terminal color is available at launch and in the managed session menus. It
changes tmux status and borders, not output background. Mouse scrollback is
retained; macOS drag-copy and copy-mode Enter/y use the clipboard. See the
orchestrator README for keyboard shortcuts and existing-session configuration.

Follow-up validation: the full Rust suite passed 209 tests; the final runtime
color helper also passed its focused exact-pane regression. Ten wrapper tests,
launcher model tests, catalog tests, and the full Swift typecheck passed. A
read-only smoke check against the installed configuration found five valid
agent types and confirmed model options for Codex, Claude, and Cursor. Copy
bindings were inspected on a disposable real tmux server.

## Saved folders, models, and custom scripts

The launcher remembers recent project folders and supports pinned favorites.
The model catalog includes GPT-6 Astra and Claude Fable 5.1 without changing
existing task recommendations. Under Claude, select Custom script, choose an
executable wrapper, and enter the gateway model ID. The wrapper receives normal
Claude arguments and must forward them. Its path is preserved through session
recovery; a missing script fails rather than falling back to standard Claude.

Further improvements worth prioritizing are completion events for session stop,
an explicit reconnect/recovery status, and a launch health check that explains
missing executables or hook setup before opening a terminal.
