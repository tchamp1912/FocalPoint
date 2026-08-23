# Formation research notes

Research and package selection date: **2026-08-22**. These notes summarize
public provider and secure-development guidance in original wording. Model
catalogs change quickly, so the exact model IDs should be reviewed against the
linked catalogs before publishing a later package version.

## Resulting package policy

The bundled examples resolve model choice before launch. Each agent type names
one provider and one exact current model ID; none inherits the model used by a
previous session or a provider's changing default. Formation roles reference
those types, so a role's provider and model are reviewable without running it.
The complexity labels below describe the expected judgment burden, not the
size of the diff alone.

| Complexity | Packaged types | Explicit provider and model | Why this tier |
| --- | --- | --- | --- |
| Low | `codebase-scout` | Claude / `claude-haiku-4-5` | Bounded search and evidence collection need speed and a separate context more than frontier planning. |
| Medium | `implementer` | Claude / `claude-sonnet-5` | A bounded coding slice benefits from a balanced agentic coding model. |
| Medium | `correctness-reviewer`, `perf-reviewer` | Codex / `gpt-5.6-terra` | Focused review still needs code reasoning, but normally does not justify the flagship tier. |
| Medium | `test-verifier` | Cursor / `composer-2.5` | The task is tool-heavy and bounded around existing checks; Composer is documented as a Cursor-native coding and tool-use model. |
| High | `planner`, `threat-modeler`, `synthesizer` | Claude / `claude-opus-5` | Decomposition, threat-boundary reasoning, and reconciling conflicting reports are ambiguity-heavy coordination tasks. |
| High | `security-reviewer` | Codex / `gpt-5.6-sol` | Adversarial review of trust boundaries and subtle exploit paths is assigned the flagship OpenAI tier. |

This is a curated default, not a universal ranking. Provider availability,
account entitlement, latency, and a repository-specific evaluation can justify
a new package version with a different binding. A launcher should fail when a
pinned model is unavailable instead of silently selecting a last-used model.

The selection follows the providers' current public distinctions:

- OpenAI describes GPT-5.6 Sol as the flagship, Terra as a strong lower-cost
  option, and Luna as the efficient high-volume tier. Its current model
  resolver returned `gpt-5.6-sol` on 2026-08-22. We use Sol for the highest-risk
  security judgment and Terra for narrower reviews. Luna is not bundled here
  because none of these examples is merely high-volume classification.
- Anthropic's model-selection guide places Opus 5 on complex agentic coding
  and long-horizon work, Sonnet 5 on scaled coding and tool use, and Haiku 4.5
  on fast, economical sub-agent tasks. The three Claude examples mirror those
  tiers rather than relying on Claude Code's default.
- Cursor documents `composer-2.5` as its own agentic model, optimized for
  sustained coding, tool choice, and terminal work. The test verifier uses it
  for a constrained verification lane, not as an automatic provider router.

## Formation choices

Parallel work is useful only when lanes can proceed independently. Provider
guides consistently warn, directly or by design, that every parallel agent has
its own context and cost, while overlapping edits need isolation. The package
set therefore uses three deliberately limited shapes:

- `review-fanout` runs correctness, test, performance, and security review in
  separate prepared worktrees, then gives a synthesizer responsibility for
  deduplication and visible disagreement. These lanes inspect the same change
  from distinct perspectives and do not own fixes.
- `risk-review` creates a threat model first, then launches a fixed set of
  specialist reviewers, then a fixed synthesizer. It is suitable when trust
  boundaries or sensitive data make an ordinary diff review too shallow.
- `bounded-delivery` permits implementation parallelism only after a planner
  proposes independent slices and a human confirms the resolved fan-out. Its
  automatic phase contains only the manifest's fixed verification roles.

The bundled catalog also provides task-specific entry points without adding
new agent types or unbounded teams:

- `discovery-planning` runs two independent, read-only repository maps before
  one fixed planner reconciles their evidence.
- `bug-fix-delivery` diagnoses first, then requires confirmation before at
  most two independently testable implementation slices, followed by fixed
  correctness and test lanes.
- `performance-investigation` separates baseline evidence from code-path
  mapping, then gives one performance reviewer the prepared handoff.
- `ui-verification` maps the user flow before fixed correctness and existing-
  check verification lanes inspect it independently.

These names describe the intended work shape, not extra authority. In
particular, the only plan-authored launches are capped fan-out phases behind a
`confirm` gate.

Anthropic's agent-team guidance recommends teams for independent research,
review, competing debugging hypotheses, and separately owned feature areas;
it recommends a simpler approach for sequential work and overlapping files.
Cursor's subagent guidance likewise points to isolated contexts for parallel
work and independent verification, and recommends isolated project copies when
workers edit concurrently. OpenAI's Codex subagent documentation says parallel
specialists are useful for independent parts of complex work and supports
different model configurations per custom agent. The examples adopt those
patterns at the FocalPoint package layer; they do not depend on a provider's
own nested-team feature.

## Review, testing, and security rationale

One general reviewer is easy to prompt but hard to audit. The examples separate
correctness, tests, performance, and security so each report has a narrow
contract and so failed checks are not blurred into an overall approval.
Anthropic's managed Code Review describes parallel specialists followed by a
candidate-verification step; this supports the independent-lanes-plus-synthesis
shape. Cursor's Agent Review exposes quick and deep modes based on diff risk,
which supports routing routine review to a balanced tier and security-sensitive
or large refactors to a stronger tier.

Testing and security remain distinct evidence sources. OWASP's Secure Code
Review guidance says contextual manual review complements automated analysis,
especially for business logic, authorization, and trust-boundary flaws. Its
AI secure-coding guidance also recommends independent analysis rather than
treating passing tests as sufficient security evidence. NIST SSDF 1.1 frames
secure development practices as additions to the development lifecycle rather
than a single end-stage scan. Accordingly, `test-verifier` reports commands
actually run and coverage gaps, while `security-reviewer` and `threat-modeler`
report contextual risk without claiming tests prove safety.

## FocalPoint safety invariants

These examples do not expand authority:

1. Loading a package remains inert; it does not launch a process or prepare a
   worktree.
2. The first phase uses `gate = "authorized"`, meaning it is covered only by
   the user's initial authorization.
3. Any plan-authored fan-out uses `gate = "confirm"`. Its type, maximum worker
   count, and relative worktree root remain fixed by the manifest, and the
   generated role list must be shown to the user before launch.
4. `gate = "auto"` appears only on phases whose role count, type, and task text
   are fixed in the manifest. Automatic phases never consume planner output to
   create processes.
5. `approval` and `error` states remain escalation conditions, and completion
   still requires every role to finish. A synthesizer cannot erase a pending
   approval, an error, a failed check, or reviewer disagreement.
6. Read-only language in reviewer personas is advisory prompt text. The types
   intentionally do not declare `[enforced]`: until launch preparation installs
   and verifies the chosen provider's project-local restrictions, the package
   must not present a behavioral request as a sandbox guarantee.
7. Every provider/model pairing is explicit. A missing provider entitlement or
   unavailable model is a launch-time error, not permission to inherit a
   session default or silently cross providers.

## Public sources

All links were checked on **2026-08-22**.

- OpenAI, [Model guidance](https://developers.openai.com/api/docs/guides/latest-model)
  (live documentation checked 2026-08-22): current GPT-5.6 family roles and
  the Sol/Terra/Luna capability-cost split.
- OpenAI, [Codex subagents](https://learn.chatgpt.com/docs/agent-configuration/subagents)
  (live documentation checked 2026-08-22): parallel specialist workflows,
  token cost, and per-agent model configuration.
- Anthropic, [Run agents in parallel](https://code.claude.com/docs/en/agents)
  (live documentation checked 2026-08-22): choosing among subagents, teams,
  and worktree isolation.
- Anthropic, [Orchestrate teams of Claude Code sessions](https://code.claude.com/docs/en/agent-teams)
  (experimental feature documentation checked 2026-08-22): independent-lane
  suitability, coordination overhead, approval, and team limitations.
- Anthropic, [Choosing the right model](https://platform.claude.com/docs/en/about-claude/models/choosing-a-model)
  (live documentation checked 2026-08-22): Opus, Sonnet, and Haiku workload
  guidance and the recommendation to evaluate on representative tasks.
- Anthropic, [Code Review](https://code.claude.com/docs/en/code-review)
  (research-preview documentation checked 2026-08-22): specialized parallel
  analysis and verification of candidate findings.
- Cursor, [Subagents](https://cursor.com/docs/subagents)
  (live documentation checked 2026-08-22): context isolation, independent
  verification, parallel work, exact model selection, and isolated copies.
- Cursor, [Composer 2.5](https://cursor.com/docs/models/cursor-composer-2-5)
  (live documentation checked 2026-08-22): exact model ID and intended agentic
  coding/tool-use strengths.
- Cursor, [Agent Review](https://cursor.com/docs/agent/agent-review)
  (live documentation checked 2026-08-22): quick versus deep review based on
  change complexity and security sensitivity.
- OWASP, [Secure Code Review Cheat Sheet](https://cheatsheetseries.owasp.org/cheatsheets/Secure_Code_Review_Cheat_Sheet.html)
  (live community-standard guidance checked 2026-08-22): complementary manual
  and automated review, risk-based scoping, and evidence-oriented reporting.
- OWASP, [Secure Coding with AI Cheat Sheet](https://cheatsheetseries.owasp.org/cheatsheets/Secure_Coding_with_AI_Cheat_Sheet.html)
  (live community-standard guidance checked 2026-08-22): independent review of
  agent-produced changes and the limits of passing tests as security evidence.
- NIST, [SP 800-218, Secure Software Development Framework 1.1](https://csrc.nist.gov/pubs/sp/800/218/final)
  (published 2022-02-03; checked 2026-08-22): integrating secure practices into
  the software lifecycle to reduce and remediate vulnerabilities.
