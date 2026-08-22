# HANDOFF — parallel workflows-impl work

Append-only log between agents working this worktree (see SPLIT.md). Name
yourself; don't edit another agent's section.

---

## Agent C — session #3 "Workflow launcher UI" (Cursor) — §8.2 launcher

### Files

- **Created `app/Sources/WorkflowLauncher.swift`** — all of it:
  - a minimal TOML subset parser (tables, arrays of tables, basic/literal
    strings, integers, booleans, arrays, comments, multi-line arrays) sized to
    `docs/workflows-schema.md`;
  - `FormationPackage` / `FormationIssue` + a schema-v1 loader covering both
    the single-phase `[[role]]` and phased `[[phase]]` forms;
  - `WorkflowLauncherModel` (`@MainActor ObservableObject`): scans
    `$XDG_CONFIG_HOME/focalpoint/workflows` (else `~/.config/focalpoint/
    workflows`, mirroring the daemon's config root), owns its own
    `DaemonClient` for one-shot requests, and launches;
  - `WorkflowLauncherSection`: the "Start Workflow" row for the dropdown.
- **Edited `app/Sources/MenuContentView.swift` only**: one `@StateObject`
  property and one section inserted between the usage section and the footer.
  Nothing else in the file changed.

### The architectural boundary, kept

The app never expands a formation. `start(_:)` makes exactly one socket call,
`launch-session` with `role: "orchestrator"`, a per-run task id
(`wf-<name>-<6 hex>`), `cwd` = the package directory, and a task body that is
the §8.2 sentence made literal: "run this formation, here is the manifest
path, follow the focalpoint-orchestrator skill, honor the gates." Validation,
per-role provider resolution, worktree prep, channel creation, sequencing —
all of it happens inside the launched orchestrator agent. No daemon or
protocol change was needed (as SPLIT.md predicted).

### States handled, honestly

- **No workflows installed**: menu shows "No Workflows Installed" + the path;
  "Open Workflows Folder…" creates the directory and opens it.
- **Malformed manifest**: the package's directory appears as a warning-tagged
  menu item naming the problem (`formation.toml line N: …`, "missing
  [escalate] table", "unsupported schema version 2", …); clicking it reveals
  the directory in Finder. A count badge sits next to the menu with the full
  list in its tooltip. Directories missing `formation.toml` are flagged too
  (half-installed packages). Valid packages are unaffected.
- **Daemon offline**: the row says "Daemon offline", launch items are
  disabled with an explanatory disabled menu line, but browsing, Refresh, and
  the folder shortcut still work. A launch that fails anyway (stale
  connection, old daemon without `launch-session`) surfaces the daemon's
  error string in a dismissable red line.

### Wiring — none required from agent A

Deliberately self-contained: `MenuContentView` owns the model via
`@StateObject` and passes only the already-public `model.connected`. If the
integrator prefers launcher state on `AppModel` (e.g. to drive a widget
affordance later), move `WorkflowLauncherModel` ownership there — the view
takes it as `@ObservedObject` and needs no other change.

Deferred decision for the integrator: the orchestrator launches as
**provider `claude`** (constant `orchestratorProvider` in
WorkflowLauncher.swift), because the focalpoint-orchestrator skill currently
ships as a Claude skill. If/when the skill ships for Codex or Cursor, this
wants a Settings picker, not more constants.

### §10.4 (fan-out gate in the app?) — recommendation: **do not surface it in
the app; keep it in the orchestrator's terminal, and make the existing
attention loop deliver the human to it.**

Reasoning, strongest first:

1. **The app must never become an approval surface.** The permanent
   invariant is that a formation never answers its own approvals and the UI
   routes attention rather than discharging it (§8.6). A `gate = "confirm"`
   *is* an approval — over plan-authored process creation, the highest-stakes
   kind. If the app renders "Launch these 3? [y/edit/no]", the app has grown
   exactly the judgment verb the design works to keep out of every client.
2. **The gate needs context the panel doesn't have.** The decision is "do I
   trust this plan's decomposition?" — that requires the plan, the
   orchestrator's reasoning, and room to type "edit". A 340pt menu-bar
   popover is where that context goes to die; the likely failure mode is
   reflexive approval, which is worse than no gate.
3. **The delivery mechanism already exists.** The orchestrator is a managed
   session. When it needs a human, it blocks on input in its own terminal,
   its adapter reports `waiting`, its key lights, the attention badge
   increments, one key-press focuses the pane. That is the product. The
   fan-out gate should ride it unchanged — with §7 grouping, the lit key even
   says *which crew* is asking.
4. **The cost is real.** A new app↔orchestrator path means either a new
   socket verb (protocol change the spec explicitly avoids) or piggybacking
   channels (widening an agent-mail trust boundary into a UI control
   channel). Both buy a worse version of something that already works.

If a future need is legitimate — e.g. noticing from the widget that a crew
is *stuck* at a gate — implement it as **read-only** signal plus
click-to-focus (the orchestrator's session state already conveys it; at most
a style/glyph treatment), never as in-app approve buttons.

### Not finished / not verified — please read before merging

- **I could not compile anything.** My environment rejected every shell
  command, so `cd app && ./build.sh` was **not run**. The code is written
  against the existing module's patterns (DaemonClient request/response,
  `@StateObject`, `Metrics.hPad`, footer button styling) but is unverified —
  the human must build before integrating.
- **The TOML parser is untested at runtime.** It is deliberately small and
  targets the schema's constructs; both `packages/workflows/*/formation.toml`
  examples should load ("review-fanout · 3 roles", "bounded-delivery · 3
  phases · 2 roles · fan-out ≤ 4"). Round that through a real build first.
- **Visual/interactive checks are all yours**: submenu rendering inside the
  MenuBarExtra window, the `person.3.sequence` symbol, the offline caption,
  the issue badge tooltip, and a real launch against a live `focalpointd`
  (mock-device included: the orchestrator terminal should open and the row
  should appear).
- **Repeat launches mint a fresh task id per run** (each run is its own crew;
  grouping keys on it). Double-click protection is the in-flight guard, not
  task-id idempotency — if a slower "same formation, same params"
  de-duplication is wanted later, it belongs orchestrator-side, not here.

---

## Agent C — session #5 "Workflow launcher UI" (Cursor) — verification + fixes

Session #3 built the feature but could not run a single shell command, so
nothing was ever compiled. This session picked it up, fixed the build,
reviewed the design, and changed one thing that mattered. Files touched:
`app/Sources/WorkflowLauncher.swift`, `app/Sources/MenuContentView.swift`
(both my lane); this section of HANDOFF.md. Nothing else.

### Fixed to compile (was: zero successful builds)

`Result<TomlValue, String>` / `Result<FormationPackage, String>` are invalid
Swift — `String` does not conform to `Error` — and every `.success(.string(…))`
site failed to typecheck in cascade. Introduced two private error types in
WorkflowLauncher.swift: `TomlValueError` (value parsers; `parse` rethrows as
`TomlError` with the line number) and `ManifestInvalid` (schema validation).
No behavior change; the error strings the menu shows are identical.

### Design change, deliberate — supersedes "cwd = the package directory" above

The launch `cwd` is now the **target workspace**, not the package directory:
the focused session's cwd, else the most recently active connected session's,
else home (`workflowTargetCwd` in MenuContentView.swift — reads existing
`AppModel` state only; still no AppModel edit needed). A formation runs
*against* something (§8.2's "against the auth refactor"); starting the
orchestrator inside `~/.config/focalpoint/workflows/<pkg>` guarantees a wasted
round-trip and invites worktree prep inside a config directory. The menu shows
**"Runs in …"** as its first line so the target is visible before anything
launches; the orchestrator task text names the target and instructs the
orchestrator to confirm with the human when the formation plainly targets
something else; `start(_:targetCwd:)` fails honestly ("Target directory no
longer exists") rather than sending the daemon a dead cwd.

Also added `hasScanned` so "No Workflows Installed" can't flash for a frame in
front of a populated directory before the first scan lands.

### §10.4 — concur with session #3, independently

I formed a view from the spec before reading the section above and landed in
the same place: **keep the gate in the orchestrator's terminal.** My sharpest
version of the argument: an in-app "Launch these 3? [y/n]" over plan-authored
process creation is exactly the judgment verb Appendix A.1 was written to keep
out of every client, and a gate you can approve without reading the slices is
worse than a gate in a terminal. The attention loop (orchestrator goes
`waiting`, key lights, one press focuses the pane) is already the delivery
mechanism. If a staleness signal is ever needed, make it read-only.

### Verified (actually ran)

- `cd app && ./build.sh` **passes** (SDK 26.5, Liquid Glass enabled), after
  the fixes above. The previous session's claim that it could not build is
  resolved.
- TOML parser + schema validation, runtime-tested out-of-process (extracted
  verbatim into a scratch harness, since the parser is file-private): both
  bundled manifests load — `review-fanout` → "3 roles", `bounded-delivery` →
  "3 phases · 2 roles · fan-out ≤ 4" — and seven synthetic cases (missing
  `[formation]`, version 2, unterminated string, mixed `[[role]]`/`[[phase]]`,
  missing `[escalate]`, role without type, multi-line array + trailing
  comment) each produce the correct load or the correct reported error with
  line number. Scratch harness deleted afterwards.
- Daemon config-root claim checked against `daemon/src/config.rs`: the
  `$XDG_CONFIG_HOME/focalpoint` → `~/.config/focalpoint` rule in
  `workflowsDirectory` does mirror the daemon.

### Not finished / not verified — for the human

- **All visual/interactive checks remain yours** (I cannot see the rendered
  UI): the submenu rendering inside the MenuBarExtra window,
  `.menuStyle(.borderlessButton)` sitting next to the glass footer buttons on
  macOS 26, the `.menuIndicator(.visible)` chevron, the `person.3.sequence`
  symbol, the "Runs in …" line's middle-truncation on long paths, the issue
  badge tooltip, and a real end-to-end launch against a live `focalpointd`
  (`--mock-device` is enough: the orchestrator terminal should open and its
  row should appear, then the crew per the orchestrator's own saga).
- The launch outcome line auto-clears ~12 s after success; failure persists
  until dismissed. Unverified visually.
- Late in this session my shell tool stopped returning exit statuses; the
  build and parser tests above completed *before* that, so their results
  stand, but I could not run a final `git status` to confirm no other agent's
  edits landed mid-session. If AppModel.swift/DesktopOverlay.swift changed
  after my last build, rebuild before integrating.

---

## Agent C (Cursor) — session 6: workflow editor (user-requested)

The human asked for "a workflow editor… where I can go and design agents and
their prompts as well as gates between different phases of the workflows."
Built entirely inside agent C's lane: two new files plus two small edits to
`WorkflowLauncher.swift`. **No other agent's files touched.**

### What was added

- `app/Sources/WorkflowEditor.swift` (new) — model layer:
  - Editable value-type models for both package kinds (`EditableFormation` /
    `EditablePhase` / `EditableRole` / `EditableFanout` / `EditableEscalate`,
    `EditableAgentType`). Dirty tracking is an Equatable diff against the
    last-loaded/saved snapshot.
  - `FormationLoader` / `AgentTypeLoader`: full schema-v1 load through the
    launcher's own `TomlParser` (now module-internal — one TOML dialect for
    the whole app). Unknown fields/tables become **load warnings** ("saving
    rewrites the file without it"); unknown `[enforced]` fields are load
    **errors**, matching the schema's fail-closed rule. A phase missing
    `gate` loads with the schema's only stated defaults (fan-out → confirm,
    else authorized) plus a warning that saving makes it explicit.
  - `FormationSerializer` / `AgentTypeSerializer`: canonical TOML emission.
    **Deliberate trade-off:** save is a full canonical rewrite, not a
    toml_edit-style targeted patch — hand-written comments and unknown
    fields in an edited manifest are dropped. The daemon's config.toml rule
    (byte-preserving edits) does not extend to these packages, which the
    editor now owns; the UI says this plainly under the Package card.
  - `EditorValidation`: save-gating checks mirroring docs/workflows-schema.md
    — kebab-case names, unique role names across the whole manifest, `after`
    must name an earlier phase, fan-out `from` must name a role in an earlier
    phase, **`gate = auto` on a fan-out phase is a hard error** (schema:
    "plan-authored process creation is new authority and requires a human
    gate"), relative-path containment for `cwd_root`/`allow_paths`/persona
    prompt, provider names ∈ {claude, codex, cursor}. Roles referencing
    uninstalled agent types are **warnings**, not errors (resolution is the
    orchestrator's run-time job).
  - `WorkflowEditorModel`: scan/save/create/delete (delete = move to Trash,
    recoverable). Reload preserves dirty in-memory edits over fresh disk
    loads — a reload never silently discards typing.
  - `WorkflowEditorWindow`: owns the one editor window, following the
    Settings-window pattern (lazy NSWindow + NSHostingController,
    non-opaque, transparent titlebar) but self-contained here so
    `FocalPointApp.swift` stays untouched.
- `app/Sources/WorkflowEditorView.swift` (new) — view layer:
  `NavigationSplitView`; sidebar lists Workflows + Agent Types (broken
  packages included with the load failure, same honesty rule as the
  launcher) with dirty dots; detail is a card-based editor using
  `.settingsCard` glass and the app's caption/callout type. The phase card
  is the gate editor the human asked for: per-phase segmented
  Authorized/Confirm/Auto picker whose per-choice summary text states
  plainly what the gate does (wording lifted from §5.3/§6.3 of the
  proposal), an "Runs after" dependency picker limited to earlier phases,
  fixed-roles vs bounded-fan-out content toggle, and fan-out fields
  (from/max/type/cwd_root) with the containment contract spelled out. The
  agent-type editor covers provider preference ordering, model, requires,
  advisory (captioned as prompt text, never enforcement, per schema), and
  enforced (read_only + allow_paths), plus a monospaced editor for the
  persona markdown itself.
- `WorkflowLauncher.swift` edits: TOML parser types un-`private`d (now the
  shared dialect), and a "Workflow Editor…" item at the bottom of the Start
  Workflow submenu. `MenuContentView.swift` unchanged this session.

### Design notes for whoever reviews

- The editor edits the installed packages under
  `~/.config/focalpoint/{workflows,agents}/` directly — the same files the
  launcher scans and the orchestrator reads. No new source of truth, no
  daemon involvement, no protocol change (packages stay inert data; saving
  never launches anything).
- Structure toggle (single-phase ⇄ phases) keeps *both* drafts in the model
  and only flips which one serializes, so toggling never destroys work.
- Phase `after` and fan-out `from` are name references; renaming a phase or
  role does not auto-rewrite referrers — validation flags the dangling
  reference with a specific message instead. Deliberate: silent rewrites of
  references the human may not have finished editing are worse.
- The launcher menu rescans on every dropdown open, so editor saves show up
  in Start Workflow without any cross-model wiring.

### Not verified — for the human

- **This session's shell tool never executed a single command** (the
  environment died at the end of session 5 and did not recover), so
  **nothing here has been compiled**. Both files were written against a
  careful re-read of the existing code and a line-by-line self-review, and
  the `Result<_, String>` mistake that broke session 3 was specifically
  avoided (a `PackageLoad` enum instead), but `cd app && ./build.sh` is the
  first thing to run. Most likely failure spots if any: the
  `switch` over `Unicode.Scalar` literal patterns in `TomlEmit.basicString`,
  and SwiftUI binding plumbing in the phase/role cards.
- All visual/interactive checks are yours: window vibrancy, sidebar
  selection, gate picker copy, fan-out form, persona editor, dirty dots,
  Save/Revert, Trash flow, and round-tripping a bundled package
  (load `bounded-delivery`, save unchanged, diff should be empty modulo
  formatting/comments).
