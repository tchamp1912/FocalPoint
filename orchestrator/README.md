# Orchestrated attention

FocalPoint uses one simple model: **an orchestrator sets session priority; the
daemon owns and follows that order**. There is no background watcher, scheduled
ranker, policy file, or separate attention service.

```text
orchestrator agent -> fpctl-agent -> focalpointd -> app/widget + attention key
                                      |
                                      +-> managed Claude/Codex sessions
```

The orchestrator prepares environments and decides priority. `fpctl-agent`
sends those decisions through the daemon socket. The daemon remains the single
source of truth for live session identity, the attention order, launching, and
focus. The app renders daemon state, and the attention key asks the daemon for
the next session.

## Inspect and prioritize

```sh
fpctl-agent status
fpctl-agent history
fpctl-agent order
fpctl-agent prioritize SESSION_ID ...
```

`prioritize` replaces the complete live-session order. Pass every live session
exactly once, highest priority first. The daemon removes ended sessions and
appends newly registered sessions deterministically until the orchestrator
replaces the order. Stable numbered slots do not move when priority changes.

Focus is always explicit:

```sh
fpctl-agent focus SESSION_ID
```

`history` lists only the daemon's recoverable disconnected-session tombstones;
they are not part of the live attention order and cannot be passed to
`prioritize`. An orchestrator can promote an eligible live, unmanaged,
idle/waiting/done Claude or Codex session to managed tmux transport:

```sh
fpctl-agent relaunch SESSION_ID
```

The daemon validates the session and performs the clean quit-and-resume
handoff. It rejects disconnected history entries, already-managed sessions,
and in-flight work.

The menu-bar app and desktop widget highlight live states directly from the
daemon. FocalPoint does not post system notifications.

## Launching orchestrated work

FocalPoint exposes one deliberately narrow launch primitive:

```sh
fpctl-agent launch \
  --provider codex \
  --model gpt-5.6-sol \
  --cwd /absolute/path/already/prepared/by/the/orchestrator \
  --task 'Implement and test the assigned task.' \
  --task-id stable-task-id \
  --title 'Parser implementation'
```

It opens the literal task in Claude, Codex, or Cursor at that exact directory and tags
the resulting session for correlation. Before opening the terminal, the daemon
reserves its numbered slot and tells the agent both that number and `--title`
in its initial task. The visible managed session opens in a new application
instance/window of
the terminal selected under FocalPoint Settings; changing the preference takes
effect on the next launch. It does not create worktrees, install
dependencies, run setup commands, choose sandbox or approval settings,
decompose tasks, retry failed launches, answer approvals, or read transcripts.
Those decisions belong to the supervising orchestrator before `launch`.

`--model` accepts a concrete provider model id or alias and is required. The
launcher rejects omitted values and default/auto sentinels.

Cursor adds a launch-mode choice. The default is `headless`, which invokes the
installed Cursor stream wrapper and is therefore visible to FocalPoint with
lifecycle updates. Use `--cursor-mode attachable` to open Cursor's normal
interactive terminal UI in the managed tmux pane, where prompts and command
approvals can be handled directly. Cursor does not publish lifecycle events or
its current chat id in interactive mode, so FocalPoint prepends an instruction
requiring the agent's first terminal tool call to be `focalpoint register`.
That command uses a launch-scoped id and verifies the exact private tmux pane
before consuming the reserved slot. It runs again as
`focalpoint register --state done` before completion. This provides managed
health, exact focus, and channel membership; granular intermediate lifecycle
telemetry remains available only in headless mode.

```sh
fpctl-agent launch --provider cursor --cursor-mode headless --cwd /absolute/path \
  --task 'Run the authorized task.' --task-id cursor-headless-1 --title 'Cursor audit'
fpctl-agent launch --provider cursor --cursor-mode attachable --cwd /absolute/path \
  --task 'Run the authorized task interactively.' --task-id cursor-interactive-1 \
  --title 'Interactive Cursor audit'
```

The pane-local bootstrap can also be run manually in a launched attachable
Cursor terminal:

```sh
focalpoint register                    # defaults to thinking
focalpoint register --state done       # same launch-scoped session
```

It intentionally accepts no task, title, slot, or session-id arguments. Those
values come from the daemon-owned receipt and managed pane environment.

The native `fpctl-agent` controller communicates with `focalpointd` over the
same Unix-socket JSON API used by the app and adapters. Its guarded interface
does not expose approval answers, arbitrary input injection, raw termination,
or slot mutation.

## Workflow coordination

Every workflow run gets a daemon-owned channel automatically. The initial
orchestrator launch reserves it, registration binds its owner, and authorized
worker launches inherit membership from the workflow receipt. Callers do not
need to copy channel ids between launches, and a mismatched supplied id fails
closed.

The installed `focalpoint-mcp` stdio server exposes the same control plane to
Claude, Codex, and Cursor as structured tools: claim assignment, read,
acknowledge, ask, report progress, report a blocker, and complete. It derives
task and channel identity only from the managed launch environment. Agents
should acknowledge messages after processing them; reads are otherwise
non-destructive. `fpctl-agent channel` remains the guarded fallback when a
provider cannot connect to MCP.

## Read and stop owned work

Managed sessions launched with a stable task id can be inspected through a
bounded normalized transcript view:

```sh
fpctl-agent transcript --session SESSION_ID --task-id stable-task-id --tail 20
fpctl-agent transcript --session SESSION_ID --task-id stable-task-id --search failed
```

The reader returns at most 100 user/assistant/tool messages, bounds each text
field, omits thinking blocks and raw tool inputs, and accepts transcript paths
only inside the provider's local transcript directory. Ordinary `status`
remains transcript-free.

An orchestrator can gracefully stop only a managed session carrying the same
stable task id:

```sh
fpctl-agent stop --session SESSION_ID --task-id stable-task-id
```

This uses the agent's normal SIGINT-to-SIGTERM teardown and never exposes a
general process-kill primitive.

## Managed sessions (optional tmux transport)

`focalpoint-run.sh` launches an agent inside a private tmux session so
FocalPoint can focus the exact pane. tmux is optional: if it is absent, the
wrapper runs the command normally as an unmanaged session.

Install tmux on macOS:

```sh
brew install tmux
```

From a checkout:

```sh
orchestrator/focalpoint-run.sh claude
orchestrator/focalpoint-run.sh codex
```

After running the installer:

```sh
~/.config/focalpoint/focalpoint-run.sh claude
~/.config/focalpoint/focalpoint-run.sh codex
```

The installer refreshes the launcher but creates
`~/.config/focalpoint/tmux.conf` only when missing, preserving user changes.
That config applies only to FocalPoint-managed sessions and does not replace
the user's normal tmux configuration.

Managed terminals keep mouse scrollback with 100,000 lines of history. Drag to
select text and release to copy it to the macOS clipboard. In tmux copy mode,
Enter also copies (or `y` with vi keys); Escape leaves copy mode. The wrapper
installs these bindings on each new private server, including installations
with an older preserved `tmux.conf`.

Choose a terminal accent in the launcher, or set
`FOCALPOINT_TERMINAL_COLOR='#6C8CFF'` when invoking the wrapper. It colors a
small tmux status bar and pane borders, leaving agent output colors unchanged.
The app can also recolor an existing managed terminal; the daemon verifies its
exact private pane before changing it. Colors must use six-digit `#RRGGBB`.

Set `FOCALPOINT_TMUX_LAYOUT=cockpit` to put managed agents into one tmux session
as separate windows. The default, `per-agent`, creates one tmux session per
launcher invocation.

An unmanaged Claude or Codex conversation can be promoted from the app with
**Relaunch as Managed Session** while it is idle, waiting, or done. The daemon
reserves the identity, gracefully quits the old process, and resumes the same
conversation under tmux. Thinking/running, already-managed, Cursor,
disconnected, and generic sessions remain ineligible. History recovery also
uses the managed launcher when available.

Managed focus is exact. Unmanaged focus remains best-effort because the daemon
must locate and raise an existing terminal window without a pane identity.

If a managed terminal survives but its normal hook registration does not, use
**Copy Re-register Command** on its FocalPoint row and paste the command into
that exact agent. `focalpoint re-register` refuses to run outside a private
`fp-*` tmux server, verifies the exact pane/server/session tuple, and republishes
the provider session id, title, task relationship, tty, and managed ownership.
The wrapper transport log is `~/.local/state/focalpoint/managed-launch.log`;
daemon logs use `[managed-launch]`, `[managed-relaunch]`, and `[session]` fields
with task, title, slot, and private tmux identity for correlation.

## Approval noise

Claude and Codex permission hooks defer `waiting` briefly and cancel it when a
newer lifecycle event arrives. Successful auto-approvals therefore never enter
the attention queue; only requests that remain blocked are surfaced.
