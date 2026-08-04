# FocalPoint Claude Code Adapter

Claude Code integration for FocalPoint via built-in hooks. This is the most complete and easiest adapter — no configuration needed beyond the initial setup.

## Installation

```bash
cd adapters/claude-code
./install.sh
```

This will:
1. Copy `hooks.sh` to `~/.config/focalpoint/adapters/hooks.sh`
2. Copy `focus-session.sh` to `~/.config/focalpoint/adapters/focus-session.sh`
3. Copy `statusline-usage.sh` to `~/.config/focalpoint/adapters/statusline-usage.sh`
4. Print a `hooks` configuration block to merge into `~/.claude/settings.json`
4. Print a `[session]` config snippet for `~/.config/focalpoint/config.toml`

## Setup

After running `install.sh`, merge the printed configuration into `~/.claude/settings.json`:

```bash
mkdir -p ~/.claude
echo '{}' > ~/.claude/settings.json  # if starting fresh
# Then manually add the hooks block (or use your editor's JSON merge tooling)
```

The hooks block wires five Claude Code events to the dispatcher:

| Claude Code Event | FocalPoint State | Meaning |
|---|---|---|
| `UserPromptSubmit` | `thinking` | You've submitted a prompt; Claude is processing |
| `PreToolUse` | `running` | Claude is about to execute a tool (Bash, Write, etc.) |
| `PostToolUse` | `thinking` | Tool execution finished; Claude is reasoning about results |
| `Stop` | `done` | Claude's response is complete |
| `Notification` (`idle_prompt`) | `waiting` | Claude finished and awaits your next prompt |
| `Notification` (`permission_prompt`) | `approval` | A tool use awaits your approval |
| `SessionEnd` | `end-session` | Session ended; its numbered-key slot is freed |

After each `PostToolUse`, the asynchronous hook also publishes a fresh
transcript-derived stats snapshot. This lets token, tool-call, turn, subagent,
model, and context badges update during a long tool loop; `Stop` still sends
the final authoritative snapshot. A transcript that is still being flushed can
lag by one hook, but the next tool event or `Stop` corrects it.

### Subscription usage monitor (optional)

For Claude.ai Pro/Max subscriptions, Claude Code's documented status-line JSON
includes 5-hour and 7-day percentage/reset fields after the first response.
Configure the reporter as your status-line command:

```json
{
  "statusLine": {
    "type": "command",
    "command": "bash ~/.config/focalpoint/adapters/statusline-usage.sh"
  }
}
```

The script sends only those four numeric values to the local FocalPoint daemon.
It never reads or forwards prompts, tools, or transcripts. Claude Code supports
one status-line command; if you already use one, wrap both commands in your
own script rather than replacing it. API-key accounts and sessions before
their first response simply report no quota.

## How It Works

`hooks.sh` reads a JSON object from stdin (Claude Code's hook protocol), extracts the event type, maps it to a FocalPoint state, and calls:

```bash
focalpoint set-state <state>
```

The script always exits 0 — if the daemon is down or `focalpoint` is missing, it silently succeeds rather than blocking Claude Code.

### Multi-session tracking

Claude Code's hook JSON also carries `session_id` and `cwd` (standard fields
on every hook payload). When present, `hooks.sh` attaches them to every
`set-state` call:

```bash
focalpoint set-state thinking --session "$session_id" --kind claude \
  --cwd "$cwd" --label "$(basename "$cwd")"
```

This registers/updates the session on the daemon (PROTOCOL.md §3), which
claims it a numbered key so each concurrent Claude Code session gets its own
LED. On `SessionEnd`, the adapter calls `focalpoint end-session "$session_id"`
instead of `set-state idle`, so the slot frees immediately rather than
waiting on the TTL.

Permission notifications use a two-second cancelable grace period. If Claude
auto-approves and proceeds to `PreToolUse`, `approval` is never published;
idle/input prompts remain immediate as `waiting`. `FOCALPOINT_APPROVAL_GRACE_SECS` can
override the grace period for testing.

If `session_id` can't be extracted for any reason, the adapter falls back to
plain sessionless `set-state` calls — exactly the old behavior — so nothing
breaks on older Claude Code versions or malformed hook payloads.

### Bringing a session's terminal to the front

Pressing a numbered key whose slot has a live session runs the daemon's
`[session] focus` action instead of that key's normal `[actions]` mapping
(PROTOCOL.md §3 "Focus"). `focus-session.sh` is the default focus action for
macOS: it asks iTerm2, then Terminal.app, for a window/tab whose title or
tty contains the session's cwd basename, and brings it to the front.

**This is a heuristic, not a real lookup** — see the comments at the top of
`focus-session.sh` for its known failure modes (wrong window on cwd-basename
collisions, no match on other terminal apps or overridden titles). Wire it
up in `~/.config/focalpoint/config.toml`:

```toml
[session]
focus = { type = "shell", run = "~/.config/focalpoint/adapters/focus-session.sh" }
```

`install.sh` prints this snippet with the resolved path after copying the
script.

## Requirements

- `focalpointd` daemon running (provides `focalpoint` CLI)
- Bash or sh
- `grep`, `cut` (POSIX utilities)

## Testing

Manually call the adapter to verify it works:

```bash
echo '{"hook_event_name":"UserPromptSubmit","session_id":"abc123","cwd":"/Users/you/project"}' \
  | ~/.config/focalpoint/adapters/hooks.sh
echo '{"hook_event_name":"PreToolUse","session_id":"abc123","cwd":"/Users/you/project"}' \
  | ~/.config/focalpoint/adapters/hooks.sh
echo '{"hook_event_name":"Notification","notificationType":"permission_prompt","session_id":"abc123","cwd":"/Users/you/project"}' \
  | ~/.config/focalpoint/adapters/hooks.sh
echo '{"hook_event_name":"SessionEnd","session_id":"abc123","cwd":"/Users/you/project"}' \
  | ~/.config/focalpoint/adapters/hooks.sh
```

(The field is `hook_event_name`, not `event` — see
https://code.claude.com/docs/en/hooks.)

Use `focalpoint watch` to observe state changes in real time.

## Troubleshooting

**Hooks not firing?**
- Verify `~/.claude/settings.json` contains the hooks block
- Check that Claude Code recognizes the settings: `claude /config` should show the hooks
- Ensure `focalpointd` is running: `focalpoint ping`

**Daemon connection error?**
- This is normal if `focalpointd` isn't installed yet. The adapter will silently no-op.
- Install the daemon and it will work automatically once it's running.

## Architecture

```
Claude Code (hook event)
  ↓
  hooks.sh (reads JSON, maps event → state)
  ↓
  focalpoint set-state (CLI)
  ↓
  focalpointd (daemon)
  ↓
  FocalPoint device (LED update)
```

The hooks fire asynchronously (set `"async": true`) so they never block Claude Code's event loop.

## MIT License

See `adapters/README.md`.
