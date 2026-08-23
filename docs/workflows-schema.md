# FocalPoint workflow package schema

This document defines schema version 1 for agent-type and formation packages.
Packages are inert, untrusted data. Loading a package does not authorize a
process launch, create a worktree, or execute package content.

## Bundled catalog installation

The app may ship a read-only catalog of formation and agent-type directories in
its resources. Bundled packages are listed separately from packages installed
under `~/.config/focalpoint/` (or `$XDG_CONFIG_HOME/focalpoint/`) in both the
menu-bar **Start Workflow** picker and **Workflow Editor**. Selecting a bundled
formation is still inert. Installation requires an explicit UI confirmation and
copies that formation plus every fixed role and fan-out agent type it
references. The destination set is checked before copying and checked again
immediately before each copy; any collision fails the request. The app never
merges, replaces, or silently overwrites an installed package.

## Model catalog and explicit resolution

`packages/model-catalog.toml` is the bundled, versioned model policy. Every
launch resolves the exact tuple `(provider, complexity, agent_type)` against
it, yielding one concrete model ID. There is no provider-default fallback.

The installer creates the user override at
`~/.config/focalpoint/model-catalog.toml` (or
`$XDG_CONFIG_HOME/focalpoint/model-catalog.toml`) only when absent. It is an
exact-key overlay: a valid user `[[selection]]` replaces the bundled selection
with the same provider, complexity, and agent type; all other bundled entries
remain in effect. User entries cannot introduce duplicate keys, unknown
providers/complexities, or `auto`, `default`, `general`, or
`provider-default` values. Invalid user catalogs make resolution fail closed
instead of falling back to an ambient provider model.

Precedence is deterministic: a valid explicit user model in a launch form is
used after validation; otherwise its selected provider/type/complexity resolves
through the valid user overlay, then the bundled catalog. A missing key, an
unknown value, or any default sentinel is a launch error. To upgrade a provider
model, edit catalog/package data rather than runtime Swift or Rust control
flow.

## Agent-type packages

An agent type is a directory with exactly two required files:

```text
security-reviewer/
    type.toml
    persona.md
```

`type.toml` has the following shape:

```toml
[type]
name        = "security-reviewer"
version     = 1
description = "Adversarial reviewer; findings only, no fixes"

[provider]
prefer   = ["codex", "claude"]
model    = "gpt-5.6-sol"       # optional
requires = ["channels"]        # optional, checkable capabilities

[persona]
prompt = "persona.md"
title  = "Security review"

[advisory]
scope       = "Report findings; never modify source."
output      = "Ranked list, most severe first, with file:line."
escalate_as = "blocker"

[enforced]
read_only   = true
allow_paths = ["."]
```

Required fields are `type.name`, `type.version`, `type.description`, a nonempty
`provider.prefer`, `persona.prompt`, and `persona.title`. Names use lowercase
kebab-case, versions are positive integers, and every provider preference must
be one of `claude`, `codex`, or `cursor`. `persona.prompt` is a relative path
to the package's required `persona.md` file.

`provider.prefer` is ordered. Resolution selects the first available provider
that satisfies every `provider.requires` capability and every `[enforced]`
constraint. `model` is optional and is omitted to use the selected provider's
default. `requires` is an optional list of capabilities the launcher can check;
`channels` excludes Cursor attachable mode because that mode is not a live
FocalPoint channel member.

Although schema version 1 permits an omitted model, every bundled example pins
one provider and one provider-valid model ID. This keeps example launches from
inheriting a last-used or changing provider default and makes their
complexity-based selection auditable. See
[the 2026-08-22 formation research notes](formation-research-2026-08-22.md).

### Advisory is prompt text, never enforcement

The entire optional `[advisory]` table is prompt material prepended to the task.
It is not a permission, sandbox, restriction, or guarantee. UIs may present it
as a description only. They must never label advisory values as enforced or
imply that FocalPoint will prevent the model from ignoring them.

The schema recognizes these advisory strings:

- `scope`: requested behavioral scope.
- `output`: requested response shape.
- `escalate_as`: channel message kind the persona should use for escalation.

### Enforced constraints fail closed

The optional `[enforced]` table declares guarantees that prep must materialize
through the selected provider's project-local enforcement surface before
launch. Version 1 defines:

- `read_only = true`: prevent source modification. `false` is invalid because
  it makes no enforceable claim.
- `allow_paths = ["relative/path", ...]`: constrain access to nonempty relative
  paths rooted in the prepared working directory. Absolute paths and `..`
  traversal are invalid.

Unknown enforced fields are rejected. Every provider in `provider.prefer` must
have a verified project-local surface capable of delivering every declared
field. If any provider cannot deliver one, validation fails and that type must
refuse the provider; implementations must not drop or convert the constraint
to advisory text. At launch time, prep must also hard-refuse when the project
is untrusted, the provider ignores the prepared settings, or materialization
otherwise fails. The launcher must verify effective settings too: a
higher-precedence command-line option must not weaken Codex's project config,
and Cursor headless mode must retain explicit deny rules or fail-closed hooks
rather than relying on prompt-only Ask mode.

Current surface inventory, verified 2026-08-20:

| Provider | Project-local surface used during prep | Version 1 status |
| --- | --- | --- |
| Claude Code | `.claude/settings.json` permissions | `read_only`, `allow_paths` supported |
| Codex | trusted-project `.codex/config.toml`, including `sandbox_mode` and `sandbox_workspace_write.*` | `read_only`, `allow_paths` supported |
| Cursor CLI | `.cursor/cli.json` permissions and, where needed, fail-closed `.cursor/hooks.json` checks | `read_only`, `allow_paths` supported |

This answers the proposal's section 10.1 question for current Codex and Cursor:
both now document project-local enforcement surfaces. Codex documents
project-scoped configuration plus sandbox keys in its
[configuration reference](https://developers.openai.com/codex/config-reference/).
Cursor documents project-specific CLI permission configuration, relative paths
scoped to the workspace, and deny precedence in its
[permissions reference](https://docs.cursor.com/cli/reference/permissions), and
documents project hooks that run in the CLI and can deny tool use in its
[hooks reference](https://cursor.com/docs/hooks). These surfaces still require
prep and trust checks; their existence is not permission to silently continue
when configuration cannot be installed or loaded.

## Formation packages

A formation package is a directory containing `formation.toml`:

```text
review-fanout/
    formation.toml
```

Every manifest begins with:

```toml
[formation]
name        = "review-fanout"
version     = 1
description = "Three-perspective review, one synthesizer"
```

All three fields are required. Names use lowercase kebab-case and versions are
positive integers. A manifest uses exactly one of the single-phase `[[role]]`
form or the phased `[[phase]]` form.

### Single-phase roles

```toml
[[role]]
name = "synth"
kind = "orchestrator"
type = "synthesizer"

[[role]]
name = "security"
type = "security-reviewer"
prep = "worktree"
task = "Review the change described in HANDOFF.md."
```

`role.name` and `role.type` are required nonempty strings and role names must be
unique. `kind` is optional (`worker` by default; `orchestrator` launches first
and owns the channel). `prep` is optional; version 1 accepts `worktree`. It is a
request that the orchestrator satisfies before launch, never a daemon command.
`task` is optional fixed task text.

### Escalation and completion

Every manifest requires:

```toml
[escalate]
channel_kinds = ["blocker"]
states        = ["error", "approval"]
completion    = "all-roles-done"
```

The two lists must be nonempty lists of strings and `completion` must be a
nonempty string. Completion is lifecycle policy, not a reduction of member
states; in particular, `approval` and `error` remain visible.

### Phases and fixed roles

Phased formations keep one orchestrator alive while it runs multiple formation
sagas. Each phase has a unique `name`, an optional `after` dependency on an
earlier phase, and a `gate` of `authorized`, `confirm`, or `auto`.

```toml
[[phase]]
name = "plan"
gate = "authorized"

[[phase.role]]
name = "planner"
type = "planner"

[[phase]]
name  = "review"
after = "plan"
gate  = "auto"

[[phase.role]]
name = "reviewer"
type = "security-reviewer"
```

Each phase contains either one or more `[[phase.role]]` entries, with the same
role fields as above, or one `[phase.fanout]` table. It cannot contain both.
`auto` is appropriate only when the phase adds no new authority: its role count,
types, and task text are fixed by the manifest.

### Bounded fan-out

```toml
[[phase]]
name  = "implement"
after = "plan"
gate  = "confirm"

[phase.fanout]
from     = "planner"
max      = 4
type     = "implementer"
cwd_root = "worktrees/"
```

All fan-out fields are required:

- `from`: role in an earlier phase whose untrusted output names the slices.
- `max`: positive integer hard ceiling. Planner output cannot raise it.
- `type`: fixed agent type used for every slice.
- `cwd_root`: nonempty relative path beneath which every slice cwd is prepared;
  absolute paths and `..` traversal are invalid.

The plan may choose only the slice count up to `max`, each slice name, and each
slice task. The manifest fixes the ceiling, agent type, cwd root, and gate.
Fan-out defaults to `gate = "confirm"` when `gate` is omitted. A fan-out phase
must never use `gate = "auto"` because plan-authored process creation is new
authority and requires a human gate.

## Validation

Run the included validator against one package, several packages, or all
bundled examples:

```sh
packages/validate.sh packages/agents/security-reviewer
packages/validate.sh packages/workflows/review-fanout
packages/validate.sh
```

With no arguments it discovers packages below the script's `agents/` and
`workflows/` directories. Validation parses TOML and checks required fields,
provider values and enforcement compatibility, positive fan-out bounds,
relative contained paths, phase dependencies, and persona file presence.
