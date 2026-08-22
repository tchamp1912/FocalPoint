# FocalPoint Generic Adapter

`wrap.sh` is a universal wrapper for any command-line tool or script. It tracks command execution with FocalPoint's state machine, making it trivial to add status feedback to any workflow.

## Installation

```bash
mkdir -p ~/.config/focalpoint/adapters
cp wrap.sh ~/.config/focalpoint/adapters/
chmod +x ~/.config/focalpoint/adapters/wrap.sh
```

## Basic Usage

```bash
# Wrap any command
~/.config/focalpoint/adapters/wrap.sh npm test
~/.config/focalpoint/adapters/wrap.sh ./deploy.sh production
~/.config/focalpoint/adapters/wrap.sh make build

# Useful alias
alias viberun='~/.config/focalpoint/adapters/wrap.sh'
viberun docker build .
```

## How It Works

```
Before:   focalpoint set-state running
Execute:  your_command arg1 arg2 ...
After:    focalpoint set-state done      (if exit code 0)
          focalpoint set-state error     (if exit code != 0)
```

Exit codes pass through transparently — if your command fails, `wrap.sh` exits with the same code.

## Multi-Session Tracking

By default `wrap.sh` drives the sessionless aggregate state, same as always.
Pass `--session`/`--kind`/`--label` (parsed *before* the wrapped command) to
register the run as its own numbered-key session instead (PROTOCOL.md §3):

```bash
wrap.sh [--session ID] [--kind KIND] [--label LABEL] <command> [args...]
```

- `--session ID` — unique id for this run. Required to claim a slot at all;
  without it, `--kind`/`--label` are ignored and behavior is unchanged.
- `--kind KIND` — free-form tool identifier. Defaults to `"generic"`.
- `--label LABEL` — human-readable label shown wherever sessions are listed.

```bash
# A one-off CI run gets its own key for the duration of the job
wrap.sh --session "ci-$BUILD_ID" --kind ci --label "release build" ./build.sh

# A local script that calls an OpenRouter-backed CLI tool, tracked as its
# own "openrouter" session rather than lumped into the generic aggregate
wrap.sh --session "openrouter-$$" --kind openrouter --label "summarize-pr" \
  ./bin/openrouter-cli --model deepseek/deepseek-chat --prompt "$(cat prompt.txt)"
```

The session is not auto-ended when the wrapped command exits — it lives until
something calls `focalpoint end-session <id>`. You may opt an unverified
integration into `unverified_ttl_minutes`, which defaults to off. If you want the slot freed
the moment the command finishes, call that yourself right after `wrap.sh`
returns:

```bash
wrap.sh --session "ci-$BUILD_ID" --kind ci ./build.sh
focalpoint end-session "ci-$BUILD_ID" 2>/dev/null || true
```

## Examples

### One-Liners

```bash
# Run tests with FocalPoint feedback
focalpoint set-state running && npm test && focalpoint set-state done || focalpoint set-state error

# Or use wrap.sh alias
alias viberun='~/.config/focalpoint/adapters/wrap.sh'
viberun npm test
viberun pytest tests/

# Long-running build
viberun cargo build --release
```

### Git Pre-Push Hook

Wire FocalPoint into your pre-push hook to signal tests running:

**`.git/hooks/pre-push`:**

```bash
#!/bin/bash
# Run tests before pushing, with FocalPoint feedback
~/.config/focalpoint/adapters/wrap.sh npm test
exit $?  # Fail push if tests fail
```

Then:

```bash
chmod +x .git/hooks/pre-push
git push   # Tests show as running on FocalPoint; LED shows result when done
```

### Watch Reactions

The `focalpoint watch` command streams device events (key presses, dial, joystick) as JSON. Combine with `wrap.sh` for complex workflows:

```bash
#!/bin/bash
# Example: watch for joystick north flick, then run a command with FocalPoint feedback

focalpoint watch | while read -r event; do
  if echo "$event" | grep -q '"gesture":"north"'; then
    echo "→ Running linter..."
    ~/.config/focalpoint/adapters/wrap.sh npm run lint
  fi
done
```

### Makefile Integration

```makefile
.PHONY: test
test:
	@~/.config/focalpoint/adapters/wrap.sh npm test

.PHONY: build
build:
	@~/.config/focalpoint/adapters/wrap.sh npm run build

.PHONY: deploy
deploy: test build
	@~/.config/focalpoint/adapters/wrap.sh npm run deploy
```

Then:

```bash
make test    # FocalPoint shows running → done/error
```

### Bash Script Example

```bash
#!/bin/bash
# deploy.sh - deploy with FocalPoint feedback

~/.config/focalpoint/adapters/wrap.sh docker build -t myapp .

if [ $? -ne 0 ]; then
  echo "Build failed, skipping deploy"
  exit 1
fi

~/.config/focalpoint/adapters/wrap.sh docker push myapp

echo "Deploy complete!"
```

## Requirements

- `focalpoint` CLI (provided by `focalpointd`)
- Bash or sh
- Any command or script you want to wrap

## Troubleshooting

**Daemon not running?**
- `wrap.sh` silently succeeds even if the daemon is down, so your commands still work
- Install `focalpointd` to enable LED feedback

**Command doesn't execute?**
- Verify the command exists and is in your PATH, or use an absolute path
- `wrap.sh ~/my-script.sh` works; `wrap.sh my-script.sh` requires `./my-script.sh` or PATH

**State not updating?**
- Check: `focalpoint ping` (daemon running?)
- Check: `focalpoint get-state` (responds?)
- Run manually: `focalpoint set-state running` (works?)

## Architecture

```
Your script / CLI tool
  ↓
  wrap.sh
  ├─→ focalpoint set-state running
  ├─→ execute command
  ├─→ focalpoint set-state done/error (based on exit code)
  ↓
focalpointd (daemon)
  ↓
FocalPoint device (LED update)
```

## MIT License

See `adapters/README.md`.
