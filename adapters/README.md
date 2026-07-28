# FocalPoint Adapters

FocalPoint is agent-agnostic — it speaks a simple protocol. **Adapters** are lightweight integrations that wire specific tools (Claude Code, Codex CLI, or your own script) to FocalPoint's state machine.

This directory contains four reference adapters and a template for building your own.

## Adapter Overview

| Adapter | Status | Type | Setup Effort | Integration | Sessions |
|---------|--------|------|--------------|-------------|----------|
| **claude-code** | Production | Hooks | ~1 min | Automatic via `~/.claude/settings.json` | Auto-registers per Claude session (`session_id`/`cwd` from hook JSON); `end-session` on `SessionEnd`; ships the default `[session] focus` action |
| **cursor** | Production | Hooks | ~1 min | Automatic via `~/.cursor/hooks.json` | Auto-registers per conversation (`conversation_id`/workspace root); `end-session` on `sessionEnd`; no `waiting` state and no token stats ([why](cursor/README.md)) |
| **codex-cli** | Production | Lifecycle hooks | ~1 min | Automatic via `~/.codex/hooks.json` | Auto-registers at `SessionStart`; full thinking/running/waiting/done states; `end-session` on `SessionEnd` |
| **generic** | Production | Wrapper | ~1 min | Call `wrap.sh` in your scripts/CI | Opt-in via `--session`/`--kind`/`--label`; sessionless by default |

## Quick Start

### Claude Code (Recommended)

The easiest and most complete integration. FocalPoint automatically tracks your coding session:

```bash
cd adapters/claude-code
./install.sh
# Follow the printed instructions to merge the hooks config
```

Then use Claude Code normally — your keys will light up with agent state.

### Cursor

Installs at the user level, so every workspace is covered at once:

```bash
cd adapters/cursor
./install.sh
# Follow the printed instructions to merge the block into ~/.cursor/hooks.json
```

Each Cursor chat then claims its own key. See
[cursor/README.md](cursor/README.md) for the event mapping and the three
things Cursor can't report (no `waiting`, no tokens, workspace-level focus).

### Generic (Any Tool)

Wrap any command with state tracking:

```bash
~/.config/focalpoint/adapters/wrap.sh npm test
~/.config/focalpoint/adapters/wrap.sh ./deploy.sh
```

## State Machine

All adapters map tool events to these canonical states (defined in `PROTOCOL.md` §1):

| State | Meaning | LED Effect |
|-------|---------|-----------|
| `idle` | No agent session active | dim white breathing |
| `thinking` | Model reasoning or processing | purple pulse |
| `running` | Tool/command executing | amber chase |
| `waiting` | Blocked on user (approval, input) | blue slow blink |
| `done` | Turn/task finished | green solid |
| `error` | Failure needing attention | red blink |

## Session Model

FocalPoint supports more than one live agent at a time. Any `set-state` call
that carries a `--session ID` registers (or updates) a session on the
daemon, tagged with a free-form `--kind` (`claude`, `codex`, `openrouter`,
…) and an optional human-readable `--label`. Sessions **register in the
order the daemon first sees them**, and each claims the lowest-numbered free
key (1–12) at that moment — slots never shift once assigned, so a session
keeps its key for its whole lifetime, even as other sessions come and go.
Sessions beyond 12 still work; they just don't get a dedicated key.

A session ends via `focalpoint end-session <ID>`, or automatically after
`session_ttl_minutes` (config §5, default 60) of no updates. `set-state`
calls with no `--session` drive the **sessionless default session** instead
— the original, pre-multi-session behavior — which occupies no key but still
counts toward the aggregate.

Single-channel displays (the daemon's own `SET_STATE`, a menu-bar dot, a
keyboard backlight) can't show 12 states at once, so they show the
**aggregate**: the worst state across every live session, ranked `error >
waiting > running > thinking > done > idle`. Displays that *can* show
per-key state (the numbered keys themselves) show each session's own state
on its own slot instead, via `SET_KEY_STATE`. Pressing a numbered key with a
live session runs the `[session] focus` action (config §5) rather than that
key's normal `[actions]` mapping, so keys double as a session switcher — see
`claude-code/focus-session.sh` for the reference implementation on macOS.

Full details: `PROTOCOL.md` §3 ("Sessions" and "Focus").

## CLI Interface

All adapters use a single CLI, provided by the `focalpointd` daemon:

```bash
focalpoint set-state <idle|thinking|running|waiting|done|error>
        [--session ID] [--kind KIND] [--label LABEL] [--cwd PATH]
        [--meta KEY=VALUE]...
focalpoint get-state        # aggregate across all live sessions
focalpoint sessions         # list live sessions in slot order
focalpoint end-session <ID>
focalpoint set-led <index|all> <r> <g> <b>
focalpoint watch            # Stream state/session/key/dial/joystick events as JSON
focalpoint ping             # Check daemon + device connectivity
```

## Writing Your Own Adapter

It's simple: call `focalpoint set-state <state>` on your tool's lifecycle events.
If your tool has a natural notion of "a session" (a conversation, a job, a
thread id) that can outlive a single command, add `--session`/`--kind`
/`--label` so it gets its own numbered key instead of just driving the
sessionless aggregate — see "Session Model" above.

If your tool can cheaply report usage numbers (tokens, tool/turn counts),
attach them with repeated `--meta key=value` flags — `tokens_in`, `tokens_out`,
`tool_calls`, and `turns` are shown as optional badges next to a session's
elapsed time in the menu bar app (Settings → Claude & Codex). Entirely
opt-in: report whichever you have, or none at all.

### Template (Shell Script)

```bash
#!/bin/bash
set -u
FOCALPOINT="${FOCALPOINT_PATH:-focalpoint}"

# Sessionless: fine for a one-shot script with no ongoing session concept.
"$FOCALPOINT" set-state running 2>/dev/null || true

# Do work...

"$FOCALPOINT" set-state done 2>/dev/null || true   # on success
"$FOCALPOINT" set-state error 2>/dev/null || true  # on error
```

```bash
#!/bin/bash
# With a session: each run/thread/conversation gets its own key. Pass a
# stable id ($$ , a thread id, a conversation id — whatever your tool has)
# and a --kind identifying your tool.
set -u
FOCALPOINT="${FOCALPOINT_PATH:-focalpoint}"
SESSION_ID="mytool-$$"
KIND="mytool"
CWD="$(pwd)"

"$FOCALPOINT" set-state running --session "$SESSION_ID" --kind "$KIND" \
  --cwd "$CWD" --label "$(basename "$CWD")" 2>/dev/null || true

# Do work...

"$FOCALPOINT" set-state done --session "$SESSION_ID" --kind "$KIND" 2>/dev/null || true

# When the session is truly over (not just this one command):
"$FOCALPOINT" end-session "$SESSION_ID" 2>/dev/null || true
```

### Template (Python)

```python
#!/usr/bin/env python3
import os
import subprocess
import sys

def set_state(state, session=None, kind=None, label=None, cwd=None):
    cmd = ["focalpoint", "set-state", state]
    if session:
        cmd += ["--session", session, "--kind", kind or "generic"]
        if label:
            cmd += ["--label", label]
        if cwd:
            cmd += ["--cwd", cwd]
    try:
        subprocess.run(cmd, check=False)
    except FileNotFoundError:
        pass  # Daemon not running; silently no-op

# Sessionless
set_state("running")
try:
    # Do work...
    set_state("done")
except Exception as e:
    set_state("error")
    raise

# With a session
session_id = f"mytool-{os.getpid()}"
set_state("running", session=session_id, kind="mytool", label="my job")
try:
    # Do work...
    set_state("done", session=session_id, kind="mytool")
finally:
    subprocess.run(["focalpoint", "end-session", session_id], check=False)
```

### Template (Node.js)

```javascript
const { execSync } = require('child_process');

function setState(state, { session, kind, label, cwd } = {}) {
  const args = ['set-state', state];
  if (session) {
    args.push('--session', session, '--kind', kind || 'generic');
    if (label) args.push('--label', label);
    if (cwd) args.push('--cwd', cwd);
  }
  try {
    execSync(`focalpoint ${args.map(a => `"${a}"`).join(' ')}`, { stdio: 'ignore' });
  } catch {
    // Daemon not running; silently no-op
  }
}

// Sessionless
setState("running");
try {
  // Do work...
  setState("done");
} catch (e) {
  setState("error");
  throw e;
}

// With a session
const sessionId = `mytool-${process.pid}`;
setState("running", { session: sessionId, kind: "mytool", label: "my job" });
try {
  // Do work...
  setState("done", { session: sessionId, kind: "mytool" });
} finally {
  try { execSync(`focalpoint end-session "${sessionId}"`, { stdio: 'ignore' }); } catch {}
}
```

### Best Practices

1. **Always use `stderr` → `/dev/null`** — silent failure is correct; `focalpoint` should never block your tool
2. **Map your tool's lifecycle to states** — if you have reasoning + execution phases, think about which maps to `thinking` vs `running`
3. **Never hold the state** — set state at event time, not in a loop
4. **Handle daemon absence gracefully** — the device might not be plugged in; your tool should work anyway
5. **Only pass `--session` if you have a stable id for the whole session** — a bare `--kind`/`--label` without `--session` has nothing to attach to and is ignored; reuse the *same* `--session` id across all calls for one session, and call `end-session` when it's truly done (or let `session_ttl_minutes` reap it)

## Protocol Reference

- **State names & IDs:** `PROTOCOL.md` § 1
- **HID device transport:** `PROTOCOL.md` § 2 (firmware ↔ daemon)
- **Daemon socket API:** `PROTOCOL.md` § 3 (JSON-RPC over Unix socket)
- **CLI interface:** `PROTOCOL.md` § 4 (documented above)
- **Control actions:** `PROTOCOL.md` § 5 (how FocalPoint keys send actions back to your tool)

## Daemon Installation

Adapters expect `focalpointd` (the host daemon) to be running. Depending on your platform:

```bash
# macOS (Homebrew)
brew install focalpoint

# Linux / compile from source
# See ../daemon/README.md

# Or build from this repo:
# cd ../daemon && cargo build --release
# ./target/release/focalpointd
```

Once running, verify with:

```bash
focalpoint ping
```

If it says "ok: device found", you're ready. If "ok: daemon running (no device)", the daemon is up but FocalPoint isn't plugged in yet.

## Troubleshooting

**Adapters not working?**

1. Is `focalpointd` running? → `focalpoint ping`
2. Is FocalPoint plugged in? → Check USB cable, device manager
3. Are states being set? → `focalpoint watch` in one terminal, then trigger the adapter in another

**My tool doesn't work with adapters?**

You don't need an adapter — just call `focalpoint set-state` directly in your tool or shell script. See "Writing Your Own Adapter" above.

## Licensing

**Adapters: MIT License**

All code in this directory is MIT-licensed to maximize adoption. Copy, modify, and distribute freely for any purpose (commercial or otherwise).

```
Copyright (c) 2025 FocalPoint Contributors

Permission is hereby granted, free of charge, to any person obtaining a copy
of this software and associated documentation files (the "Software"), to deal
in the Software without restriction, including without limitation the rights
to use, copy, modify, merge, publish, distribute, sublicense, and/or sell
copies of the Software, and to permit persons to whom the Software is
furnished to do so, subject to the following conditions:

The above copyright notice and this permission notice shall be included in all
copies or substantial portions of the Software.

THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND, EXPRESS OR
IMPLIED, INCLUDING BUT NOT LIMITED TO THE WARRANTIES OF MERCHANTABILITY,
FITNESS FOR A PARTICULAR PURPOSE AND NONINFRINGEMENT. IN NO EVENT SHALL THE
AUTHORS OR COPYRIGHT HOLDERS BE LIABLE FOR ANY CLAIM, DAMAGES OR OTHER
LIABILITY, WHETHER IN AN ACTION OF CONTRACT, TORT OR OTHERWISE, ARISING FROM,
OUT OF OR IN CONNECTION WITH THE SOFTWARE OR THE USE OR OTHER DEALINGS IN THE
SOFTWARE.
```

## See Also

- `PLAN.md` — Project overview and roadmap
- `PROTOCOL.md` — Protocol specification (device transport, state names, CLI)
- `daemon/` — Host daemon source code (Rust)
- `firmware/` — QMK keyboard firmware
