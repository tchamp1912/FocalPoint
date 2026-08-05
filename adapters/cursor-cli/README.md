# FocalPoint adapter: Cursor CLI headless agent

This is a separate adapter for the terminal coding agent invoked as
`cursor-agent` (or the current `cursor agent` entrypoint). It is **not** the
Cursor IDE-hooks adapter in [`../cursor`](../cursor/README.md).

## Research findings (August 1, 2026)

Cursor CLI has no documented lifecycle-hook or notify callback API comparable
to Codex CLI's hooks. Cursor's own CLI reference documents headless mode as
`--print` plus `--output-format stream-json`: it emits NDJSON in real time,
begins with a `system`/`init` event containing `session_id`, `cwd`, and model,
emits `tool_call` events with `started`/`completed` subtypes, and ends with a
`result` event on success. The CLI documentation says that an error exits
non-zero, writes an error to stderr, and can end without a terminal JSON
result. It explicitly says thinking events are suppressed in print mode.

Cursor's `cursor agent` is now the primary CLI command and `cursor-agent`
remains a compatible alias. It supports `--resume [chatId]` and `ls`, but the
documented stream is the useful stable source of an active session id; the
adapter does not infer one from a transcript, PID, or working directory.

CLI hook support is currently only partial: Cursor staff state that only
`beforeShellExecution` and `afterShellExecution` fire for `cursor-agent`, with
full lifecycle-hook parity still planned. Those two events cannot represent
prompt, model-thinking, completion, or session-end reliably. This adapter
therefore deliberately does **not** install `~/.cursor/hooks.json` entries or
invent event names; it wraps supported stream output instead.

Sources: [Cursor output format](https://docs.cursor.com/en/cli/reference/output-format),
[headless mode](https://docs.cursor.com/en/cli/headless),
[parameters](https://docs.cursor.com/en/cli/reference/parameters), and
[Cursor staff on partial CLI hooks](https://forum.cursor.com/t/cursor-cli-doesnt-send-all-events-defined-in-hooks/148316).

## Setup

Run the repository installer to copy the wrapper to the shared adapter
directory, then invoke that wrapper instead of `cursor-agent` for headless
runs:

```bash
./install.sh
~/.config/focalpoint/adapters/cursor-cli-focalpoint.sh --force "Refactor authentication"
```

Or run it directly from this checkout:

```bash
adapters/cursor-cli/wrap.sh "Review the current changes"
```

The wrapper chooses `cursor-agent` when installed, otherwise `cursor agent`.
Set `CURSOR_AGENT=/path/to/cursor-agent` to select a non-standard executable.
It owns `--print --output-format stream-json`; do not pass either flag through
the wrapper. Its stdout is Cursor's unchanged NDJSON stream, so it remains
suitable for a pipeline or CI log. Diagnostic messages only go to stderr.

`jq` is required to decode the stream. Without it, the agent still runs and
its output is relayed unchanged, but FocalPoint safely receives no lifecycle
updates.

## Lifecycle mapping and capabilities

| Cursor CLI stream event | FocalPoint action |
|---|---|
| `system` / `init` | Register supplied `session_id` as kind `cursor-cli`; `thinking` |
| `tool_call` / `started` | `running` |
| `tool_call` / `completed`, `assistant` | `thinking` |
| `result` / `success` | `done`, then `end-session` |
| terminal result other than success, or process exit without one | `error`, then `end-session` |

The first `system/init` event supplies the real Cursor CLI session id, `cwd`,
and model. Passing that id to `focalpoint set-state` registers the session and
claims the daemon's lowest free numbered key. The wrapper always talks to
FocalPoint through the `focalpoint` CLI, redirects those calls completely, and
silently continues if either the CLI or daemon is unavailable.

## Honest limitations

- **No `waiting`.** Headless stream JSON provides no approval/input lifecycle
  event, and the available shell hooks are insufficient to infer one.
- **No reliable model-thinking signal.** Cursor suppresses thinking events in
  print mode. `thinking` is an approximation between tool events and on init.
- **No token, cost, context, or transcript stats.** The documented terminal
  result has durations and text, not usage or a transcript path.
- **Only wrapped headless runs are tracked.** Interactive Cursor CLI has no
  documented event feed suitable for this integration.
- **The `done`/`error` state is immediately followed by `end-session`.** This
  frees the numbered key at process end, but a terminal state may be brief.

## Managed launches

`fpctl-agent launch --provider cursor` supports two Cursor CLI modes:

```bash
# Default: stream-tracked, non-interactive Cursor agent.
fpctl-agent launch --provider cursor --cursor-mode headless --cwd /absolute/path \
  --task 'Implement the authorized change.' --task-id cursor-task-1

# Normal interactive Cursor terminal UI in FocalPoint's managed tmux pane.
fpctl-agent launch --provider cursor --cursor-mode attachable --cwd /absolute/path \
  --task 'Implement this with my approvals.' --task-id cursor-task-2
```

`headless` is the default and requires the installed wrapper named above. It
uses `--print --output-format stream-json`, registers the real Cursor chat id,
and propagates managed-launch/channel metadata. `attachable` invokes Cursor's
normal chat mode in the terminal so a person can type follow-ups and approve
commands; Cursor does not expose lifecycle events in that mode, therefore it
cannot be tracked or joined to a FocalPoint channel.

## Verification

```bash
bash -n adapters/cursor-cli/wrap.sh
focalpoint watch
adapters/cursor-cli/wrap.sh --force "Reply with a short summary of this repo"
```

With a daemon running, the watch stream should show a `cursor-cli` session
register, transition through the mapping above, and end when Cursor exits.

MIT License — see [adapters/README.md](../README.md).
