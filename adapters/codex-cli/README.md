# FocalPoint adapter: OpenAI Codex CLI

Maps [Codex CLI](https://github.com/openai/codex) notification events to
FocalPoint states via Codex's `notify` config option.

## How it works

Codex CLI can invoke an external program on certain events, passing a JSON
payload as a single command-line argument, e.g.:

```json
{"type":"agent-turn-complete","thread-id":"...","turn-id":"...","cwd":"...","last-assistant-message":"..."}
```

`notify.sh` parses the payload's `type` field and calls `focalpoint set-state`:

| Codex event | FocalPoint state |
|---|---|
| `agent-turn-complete` | `done` |
| `approval-requested` | `waiting` |

### Multi-session tracking

The payload also carries `thread-id` and `cwd`. When present, `notify.sh`
attaches them to `set-state` as `--session "$thread_id" --kind codex --cwd
"$cwd" --label "$(basename "$cwd")"`, so each Codex thread registers as its
own numbered-key session (PROTOCOL.md §3) instead of just driving the
sessionless aggregate. If `thread-id` is missing, the adapter falls back to
plain sessionless calls.

**No `end-session` event, but real end-session behavior anyway:** Codex's
`notify` hook has no session-end event type — there's nothing to fire
`end-session` on directly. But `notify` is invoked as a direct child of the
`codex` process itself (no intermediate shell), so `notify.sh` backgrounds a
tiny watcher on the first event for a given thread that polls Codex's PID and
calls `end-session` itself the moment that process exits. No shell-profile
wrapper or other install step needed — it's entirely self-contained in this
script. `session_ttl_minutes` (config §5, default 60) is still the fallback
if the script gets removed/reinstalled mid-session.

## Install

1. Copy the script somewhere stable:

   ```sh
   mkdir -p ~/.config/focalpoint/adapters
   cp notify.sh ~/.config/focalpoint/adapters/codex-notify.sh
   chmod +x ~/.config/focalpoint/adapters/codex-notify.sh
   ```

2. Add to `~/.codex/config.toml` (top level, not under a section):

   ```toml
   notify = ["bash", "/Users/you/.config/focalpoint/adapters/codex-notify.sh"]
   ```

   Use an absolute path — Codex does not expand `~` here.

## Honest limitations

Codex CLI's `notify` hook fires on only two event types (turn complete and
approval requested), so this adapter can show **waiting** and **done**, but not
live **thinking**/**running** transitions the way the Claude Code adapter can
(Claude Code exposes a much richer hook lifecycle). Two workarounds:

- Wrap your `codex` invocation with the generic adapter to at least get
  `running` while a non-interactive `codex exec` runs:
  `../generic/wrap.sh codex exec "..."`
- If Codex gains richer lifecycle hooks (see
  [openai/codex#2150](https://github.com/openai/codex/discussions/2150)),
  extend the `case` block in `notify.sh` — one line per new event type.

The `[tui]` notifications option in Codex config controls terminal-native
desktop notifications and is independent of (and compatible with) this adapter.

MIT License — see `adapters/README.md`.
