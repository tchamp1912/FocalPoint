# FocalPoint adapter: OpenAI Codex CLI

Uses Codex's native lifecycle hooks to register sessions immediately and keep
their FocalPoint state current.

| Codex hook | FocalPoint state |
|---|---|
| `SessionStart`, `UserPromptSubmit`, `PostToolUse` | `thinking` |
| `PreToolUse` | `running` |
| `PermissionRequest` | `waiting` |
| `Stop` | `done` and refresh session stats |
| `SessionEnd` | End the FocalPoint session |

`PermissionRequest` uses a two-second cancelable grace period. If Codex
auto-approves and reaches `PreToolUse`, `waiting` is never published; only a
request that remains blocked lights the keyboard and widget.
`FOCALPOINT_APPROVAL_GRACE_SECS` can override the grace period for testing.

Every hook payload includes `session_id`, `cwd`, and a rollout transcript path.
On `Stop`, the adapter derives completed turns, tool calls, subagent launches,
input/output tokens, model, and current context usage from that local rollout.
Codex documents the transcript as a convenience rather than a stable hook API,
so parsing is defensive and falls back to a persistent turn counter.

Codex does not expose a generated chat title through hooks. The adapter keeps
the first submitted prompt as a stable label; before that prompt arrives it
uses `Codex · <directory>` so provider sessions sharing a workspace remain
distinguishable.

## Install

The repository installer copies `hooks.sh` to
`~/.config/focalpoint/adapters/codex-hooks.sh` and merges
`hooks-fragment.json` into `~/.codex/hooks.json`:

```sh
./install.sh
```

Restart Codex after installation, run `/hooks`, and trust the FocalPoint hook
definition. Codex hashes hook definitions and skips new or changed user hooks
until they are reviewed.

`notify.sh` is retained only as a fallback for older Codex releases without
native hooks. Do not configure both integrations: both completion callbacks
would increment the same session's turn count.

MIT License — see `adapters/README.md`.
