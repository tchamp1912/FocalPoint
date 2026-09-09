# Cursor Adapter

Tracks each Cursor agent conversation as its own FocalPoint session, so every
chat claims its own numbered key and drives the pad's colors as it thinks,
runs tools, and finishes.

Uses [Cursor hooks](https://cursor.com/docs/agent/hooks) — small commands
Cursor runs at fixed points in the agent loop. They're installed at the user
level (`~/.cursor/hooks.json`), so every workspace is covered without
per-project setup.

## Install

The repo-root installer does everything, including merging the hooks block:

```bash
./install.sh
```

Or install just this adapter and merge the block yourself:

```bash
cd adapters/cursor
./install.sh          # prints the hooks.json block to merge
```

Cursor reloads `hooks.json` on save. Confirm the hooks are live under
**Cursor Settings → Hooks**; restart Cursor if they don't appear.

## Event mapping

| Cursor hook | FocalPoint state |
|---|---|
| `sessionStart` | `thinking` + fresh Cursor process registration |
| `beforeSubmitPrompt` | `thinking` |
| `afterAgentThought` | `thinking` |
| `preToolUse` | `running` |
| `postToolUse` | `thinking` |
| `postToolUseFailure` | `error` |
| `stop` (status `completed`) | `done` |
| `stop` (status `aborted` / `error`) | `error` |
| `sessionEnd` | `end-session` — frees the key slot immediately |

Every call carries `--session <conversation_id> --kind cursor --cwd
<workspace> --label <workspace basename>`. Two chats in the same repo
therefore start with the same label; rename either one from the FocalPoint
app (or `focalpoint rename-session <id> "<name>"`) and the name sticks — the
adapter only ever writes `label`, which never clobbers a user-set name.
`sessionStart` also asks the CLI to resolve the outer Cursor application
process. The process birth fingerprint is scoped to the conversation id, so
each chat can safely claim a different numbered slot even though all of them
share one Electron app. If startup resolution loses a race, the next hook
retries automatically.

Note that `aborted` — you pressed Cursor's stop button — reports `error`, not
`done`. The distinction FocalPoint cares about is "finished cleanly" vs.
"stopped short and may need you", and an aborted turn is the latter.

## Stats

Recomputed from the conversation transcript on `stop` only (once per turn,
never per tool call) and sent as `--meta`:

- `turns` — count of `turn_ended` markers in the transcript
- `tool_calls` — count of `tool_use` blocks
- `subagents` — count of `Task` tool calls, i.e. subagents launched this
  session, not how many are running now

Requires `jq`; silently skipped without it.

## Three honest limitations

**No `waiting` state.** Cursor has no equivalent of Claude Code's
permission-prompt notification hook, so there's no signal for "the agent is
blocked on you." A Cursor session will never show `waiting`. Watch for `done`
instead.

Cursor 3.13+ reports per-generation input/output usage on the `stop` hook; the
adapter accumulates it once per generation and reports token badges. Older
Cursor versions omit those fields and continue to show turns, tool calls, and
subagents only. Cursor does not currently report context occupancy or cost.

Cursor does not expose its generated chat title to hooks. The adapter preserves
the first submitted prompt as its stable label; before that arrives it uses
`Cursor · <directory>` rather than an ambiguous bare directory name.

**Focus is workspace-level, not chat-level.** Pressing a Cursor session's
numbered key raises the Cursor window for that session's workspace folder.
Cursor's hooks expose no window or composer handle — only `conversation_id`,
which nothing outside Cursor can address — so two chats open on the same repo
both land on that repo's window. Focusing an individual chat isn't possible
today at any level of effort.

## Focus setup

Focus goes through the shared router the Claude adapter ships, which
dispatches to `focus-cursor.sh` when the session's kind is `cursor`. That
means `[session] focus` in `~/.config/focalpoint/config.toml` stays pointed
at one script for all agents:

```toml
[session]
focus = { type = "shell", run = "~/.config/focalpoint/adapters/focus-session.sh" }
```

`focus-cursor.sh` only targets an already-running Cursor. It opens the
workspace with `cursor <workspace>`, resolving the bundled CLI when the
GUI's PATH lacks the shell shim. It avoids `--reuse-window`, which can replace
the last active window's workspace. The fallback sends the folder through
`open -a Cursor <workspace>`; with no folder it activates the app. Failed
routing is reported to the daemon. Every external call has a hard timeout
(`FOCALPOINT_FOCUS_TIMEOUT`, default 3s). No Accessibility permission is required.

Child composers (`task-*` ids, explicit parent ids, or subagent transcript
paths) do not register independent sessions. Separate top-level chats remain
separate, even when they share a workspace and Cursor application process.

## Performance

Cursor hook definitions have no `async` option (Claude Code's do), so these
run inline in the agent loop — `preToolUse` and `postToolUse` fire on every
single tool call. The script is deliberately lean and only touches the
transcript on `stop`. Each entry sets `"timeout": 5`; Cursor moves on if that
elapses.

## Two rules this adapter must never break

Both are Cursor-specific and easy to violate when editing `hooks.sh`:

1. **Never exit 2.** Cursor reads exit code 2 from a command hook as "deny"
   and blocks the tool call the user was trying to run. A status adapter must
   never be able to interfere with the agent, so every path ends in `exit 0`
   and the `focalpoint` calls are `|| true`.
2. **Never write to stdout.** Cursor parses a hook's stdout as its JSON
   response. All output is redirected; emitting nothing is a valid "no
   opinion" response.

## Troubleshooting

Nothing lights up:

```bash
focalpoint ping                    # daemon alive?
focalpoint watch                   # live events while you run a Cursor turn
```

Test the hook directly, without Cursor:

```bash
echo '{"hook_event_name":"beforeSubmitPrompt","conversation_id":"test-1",
       "workspace_roots":["'"$PWD"'"]}' \
  | ~/.config/focalpoint/adapters/cursor-hooks.sh
focalpoint sessions                # should list a `cursor` session
focalpoint end-session test-1      # clean up
```

If the session appears but never changes state, check that all eight events
are present in `~/.cursor/hooks.json` and that the command path there is
absolute and executable.

For attachment and hook-delivery failures, inspect the bounded local log at
`~/.local/state/focalpoint/logs/cursor-hooks.log` and the daemon log at
`~/Library/Logs/focalpoint/focalpointd.err.log`. The FocalPoint Setup
Diagnostics window can collect, redact, copy, and place a bounded excerpt of
these lifecycle-only logs into a prefilled GitHub issue. It excludes prompts,
transcripts, tool content, labels, and working directories.

## Uninstall

`./uninstall.sh` at the repo root removes only FocalPoint's entries from
`~/.cursor/hooks.json`, leaving any hooks of your own intact, and backs the
file up first. Use `--dry-run` to preview.

## License

MIT — see [adapters/README.md](../README.md).
