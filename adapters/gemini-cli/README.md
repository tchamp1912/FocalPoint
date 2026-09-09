# Gemini CLI adapter

Reports Gemini CLI sessions to FocalPoint through the documented [hook interface](https://geminicli.com/docs/hooks/reference/). It requires `jq` and `focalpoint` on PATH. `FOCALPOINT_PATH` can select the CLI explicitly.

| Hook | FocalPoint state |
| --- | --- |
| SessionStart | idle, refresh process identity |
| BeforeAgent | thinking |
| BeforeTool | running |
| AfterTool | thinking, or error when tool_response.error is present |
| AfterAgent | done |
| Notification, ToolPermission only | approval |
| SessionEnd | remove session |

The adapter always returns `{}` and never modifies prompts, tool results, or permission decisions. It forwards the provider session ID with `--kind gemini`; it does not derive identities from titles, prompts, or child model calls. Missing or malformed IDs cause no registry mutation.

Managed sessions include launcher metadata and exact tmux coordinates. Discovery requires `TMUX`, `FOCALPOINT_TMUX_SERVER`, and `TMUX_PANE`; tmux queries target that pane explicitly. FocalPoint resolves terminal/process identity through its normal CLI identity resolver.

Model and PreCompress hooks are deliberately omitted: the installed Gemini implementation shares the main configuration/session ID with local subagents and supplies no child discriminator in model-hook payloads. Tracking those calls could overwrite the parent model or mark it compacting while a child compacts. No inferred token counts or costs are published. SessionEnd is best effort in Gemini; daemon process liveness remains the fallback for abrupt exits.

## Installation

The repository `install.sh` copies `hooks.sh` to the configured adapter directory as `gemini-hooks.sh`. It backs up and merges `~/.gemini/settings.json`, accepting line and block comments and preserving unrelated settings and hooks. Comments remain in the backup when an update rewrites the file as JSON. Python 3 is required for the merge; malformed settings fail before modification. Named `focalpoint-gemini-*` hooks are replaced idempotently across all events (obsolete model/compression hooks are removed), including when FocalPoint moves to another path. Commands are shell-quoted, including paths with spaces or quotes.

The merge helper only renders JSON and does not change its inputs:

```sh
./adapters/gemini-cli/merge-hooks.sh ~/.gemini/settings.json \
  ./adapters/gemini-cli/settings-fragment.json \
  "$HOME/.config/focalpoint/adapters/gemini-hooks.sh"
```

Restart Gemini and check `/hooks panel`. User `hooksConfig.enabled` and `hooksConfig.disabled` settings are preserved; the installer does not override an explicit choice to disable hooks. See the [Gemini hooks guide](https://geminicli.com/docs/hooks/).

## Verification

```sh
python3 adapters/gemini-cli/tests/test_adapter.py
bash -n adapters/gemini-cli/hooks.sh adapters/gemini-cli/merge-hooks.sh install.sh
```

Tests use fake FocalPoint/tmux executables and temporary settings files. They do not launch a model, alter authentication, or install hooks.
