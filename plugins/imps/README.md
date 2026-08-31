<!-- PLATFORM-SUPPORT: opencode=full agy=full -->

# imps — swarm orchestrator for Claude Code

## Platforms

| Claude Code | OpenCode | Agy |
| --- | --- | --- |
| native (this README) — full swarm, `Workflow`-driven | full — generated | full — generated |

The orchestration prose ports, but the Claude `Workflow` script that drives it does
not run on either target: OpenCode dispatch goes through the
`opencode execute-tier dispatcher` referenced in the table below (model tiers passed
at invocation via `opencode run -m`, never as frontmatter); Agy dispatch is serial
`agy -p`, inspecting response content rather than exit status (see
`docs/platform-matrix.md` Item 8). Per-platform dispatch prose comes from
`build/overrides/imps/`; generated output lives under `dist/opencode/` and
`dist/agy/imps/`. See
[`docs/plans/cross-platform-compat.md`](../../docs/plans/cross-platform-compat.md) and
[`docs/platform-matrix.md`](../../docs/platform-matrix.md) for how and why.

## What it does

`/imps:imps` decomposes a task (or a batch of GitHub issues) into model-routed agents
("imps") — parallel when the work splits into independent units, solo when it's genuinely
one — dispatches them as staged background subagents, and integrates results through
deterministic gates and an adversarial **Head Imp** review. An optional five-persona
review panel runs on top when you pass `--personas` (see [Runtime flags](#runtime-flags)).

The orchestrating session is deliberately minimal: it holds only the operator-facing
work (plan approval, the push/PR gate, conflict decisions, learnings) while everything
else — dispatch, imp monitoring, merges, diffs, gate logs, persona traffic,
finalize — is real control flow inside a **`Workflow` script**
(`scripts/imps-run.workflow.js`), not a subagent. The command syncs the bundled script
into `~/.claude/workflows/` and invokes it fresh on every run (plugins can't ship a
runnable `Workflow` directly); the script's own opening step reads the run's state file
and resumes from wherever it left off, so long runs never grind the main context down —
the harness tracks the script's internal `agent()` dispatches separately from the calling
session's transcript, the same isolation property the old subagent-based design achieved
by hand.

## Prerequisites

| Requirement | Needed for |
| --- | --- |
| **`gh` CLI** (authenticated) | Issue-driven mode (issue reads, PR creates, CI checks). |
| **GitHub MCP** (`mcp__github__*`) | PR/issue reads in `/imps:prs`; improves issue-driven mode. |
| **Bundled agent types** (`🦇`, `😈`, `👺`) | Registered automatically once installed (`agents/*.md`). If registration fails for any reason, `agent()` calls inside the Workflow script fall back the same way any Agent-tool call does. |
| **The `Workflow` tool** | **Hard dependency for the free-text run — no fallback.** `/imps:imps` syncs `scripts/imps-run.workflow.js` into `~/.claude/workflows/imps-run.js` and invokes it; if `Workflow` is unavailable in the session, the command stops and says so rather than falling back to an inline protocol. |

Optional:

| Requirement | Needed for |
| --- | --- |
| **`CLAUDE_CDP_URL`** env var | Browser panel via CDP (default `ws://localhost:3000`). Point at a headless-Chrome container, local or LAN. |
| **Claude-in-Chrome MCP** | Browser panel fallback if no CDP endpoint is reachable. |
| **`~/.claude/scripts/persona-post.sh`** implementing the protocol in `${CLAUDE_PLUGIN_ROOT}/references/persona-posting.md`, with per-persona GitHub App identities whose credentials live in your secret store | Independent, per-persona review identity for the persona panel (see [The persona panel](#the-persona-panel)). Absent or failing → that persona's verdict goes to `findings_inline` instead of posting — it never falls back to the orchestrator's own identity. |

## Install

```sh
claude plugin install imps@seankoji
```

Or via the marketplace:

```sh
claude plugin marketplace add seankoji/claude-plugins
claude plugin install imps@seankoji
```

## Usage

Four entry modes, auto-detected from the argument:

| Invocation | Mode | What it does |
| --- | --- | --- |
| `/imps:imps <free-text task>` | Free-text | Refine → plan (opus plan mode) → decompose → hand to the Workflow script (staged dispatch → merge → gates → endstate PR; persona panel only with `--personas`) |
| `/imps:imps 42 43 51` | Issue-driven | Scout issues → rolling dispatch in isolated worktrees → holding branch → gates → operator handoff (persona panel only with `--personas`) |
| `/imps:imps https://github.com/<owner>/<repo>/discussions/284` | Discussion-seed | Fetch the discussion via GraphQL, seed it as the free-text task, run the normal free-text flow, and always post a summary comment back to the discussion at the end |
| `/imps:imps path/to/checklist.md` | Checklist-file | Run each `Verify:`/`Done when:` item as a read-only audit, then offer remediation dispatch |

### Runtime flags

| Flag | Default | Effect |
| --- | --- | --- |
| `--personas` | off | Opt into the in-run five-persona review panel (solution-architect, grumpy-engineer, sre, business-analyst, ux-designer). **Without it, no persona panel runs** on either the free-text or issue-driven path — the adversarial **Head Imp** review (plan + diff) is the gate. Intended for repos whose PRs already receive persona reviews from a GitHub-side automation, where an in-run panel would just duplicate that. Combine freely with any mode: `/imps:imps --personas 42 43`, `/imps:imps --personas fix the parser`. The flag is stripped before mode detection, so it never affects which mode is selected. |

Note: issue-driven mode has no Head Imp gate of its own, so with `--personas` off its
review path is the deterministic gates plus whatever review your PR draws on GitHub —
only turn the panel off there if such a PR review genuinely exists.


### Free-text mode walkthrough

1. `/imps:imps` with a task description (or empty — it will ask).
2. `/imps:imps` refines the brief via `prompt-builder`, asks five discovery questions, then enters plan mode (opus) to decompose and write `GOAL.md` (to `~/.claude/imps/runs/<slug>.md`, not the repo — see [Runtime state](#runtime-state)). Discovery question 5 ("any constraints?") feeds a `## Global Constraints` section in `GOAL.md` — cross-cutting invariants, stated verbatim, that every task must honor; unlike the Definition of Done (true once, ticked, verified), constraints are true of every task and never ticked. Every code-writing or code-reviewing agent call the script makes receives it by pointer, not by copy.
3. The Head Imp (opus) adversarially reviews the plan; findings are addressed before dispatch.
4. After plan approval, `/imps:imps` syncs and invokes the Workflow script, then returns control — `Workflow` runs in the background, and you're notified when it reaches a result. The script does the git preflight, dispatches the task DAG as staged `agent()` calls, and tracks progress in the run state file, so progress is `cat ~/.claude/imps/runs/<slug>.json` (the imps run inside the script's own tracked execution, invisible to the main session's transcript the same way the old subagent design was).
5. When the imps finish, the script flows straight into integration: merges code branches, drives the Head Imp diff review, runs gates, then returns an `awaiting_authorization` result. After you approve the push, the script (re-invoked fresh with your decision persisted to the state file) opens the endstate PR (the default for runs that change code — decline the push to skip it), runs the persona panel on that PR **only if you passed `--personas`** (otherwise it finalizes on the Head Imp review alone), applies fixes, and finalizes the run (PR ready, Discussion comment, run stats, monitor state). The main session only relays your decisions, then makes the one `/imps:prs` call to activate the PR monitor.

### Issue-driven mode walkthrough

1. `/imps:imps 42 43 51` — all tokens are issue numbers.
2. Scouts (haiku) fan out in parallel per issue; results seed the implementation queue.
3. Implementation agents run in isolated worktrees up to `PARALLEL_CAP=6` concurrent; file-overlapping issues serialize naturally.
4. After all issues merge into the holding branch, `/imps:imps` runs full gates, opens the integration PR, and runs the persona panel **only if you passed `--personas`** (otherwise it goes straight to handoff after gates).
5. Operator handoff — `/imps:imps` does NOT merge the integration PR.

### Discussion-seed mode walkthrough

1. `/imps:imps https://github.com/<owner>/<repo>/discussions/284` (or the bare `discussion 284` inside that repo).
2. `/imps:imps` fetches the discussion's title, body, and comments via `gh api graphql` (Discussions have no REST endpoint) and uses that content as the task description, skipping the "what's the task?" prompt.
3. Everything from there follows the free-text mode walkthrough above (discovery → plan → dispatch → integration).
4. Regardless of what the discovery answers say about output artifacts, the Workflow script always posts one summary comment back to the source discussion once the run finalizes (or a short abort notice if the run is aborted) — this is not optional and does not require a PR to exist.

### Checklist-file mode

Pass a single `.md` token that resolves to a file with `- [ ]` checklist items, each having `Verify:` and `Done when:` sub-lines. `/imps:imps` fans out read-only verification imps and emits a pass/fail audit report, then offers to dispatch remediation.

### Direct `/imps:issue-mode` invocation & handoff contract

Issue-driven mode is also directly invokable as `/imps:issue-mode` — useful for an upstream
audit or handoff tool that wants to skip `/imps:imps`'s mode detection. It accepts either bare
issue numbers (`/imps:issue-mode 42 43 51`) or a structured JSON input:

```json
{ "issues": [42, 43, 51, 60], "holdingBranch": "audit/2026-06-12" }
```

- `issues` (required) — the issue numbers to work (capped at `ISSUE_CAP=200`).
- `holdingBranch` (optional) — the branch to integrate onto; defaults to
  `swarm/<YYYY-MM-DD>` cut fresh from the repo's default branch. If the branch and its
  tracking issue already exist, the run resumes from the first incomplete phase.

## Sub-commands

Self-rescheduling via `ScheduleWakeup` — do NOT wrap it with `/loop`.

- **`/imps:prs`** — proactive PR monitor. After `/imps:imps` pushes and creates the endstate PR, activate this to automatically address review comments, fix CI failures, and resolve merge conflicts. Stops when the PR is merged, closed, or 48 h old.
- **`/imps:blast-radius`** — read-only, proof-led analysis of a PR, diff, commit range,
  or file change. Traces consumers outside the edited lines and reports which risks reached
  executable proof, which were cleared, and which remain unproven. It never fixes or
  publishes findings.

## `/imps:imp-agency` — audit → imps-ready plan

The upstream counterpart to a remediation run: a **read-only whole-repo health audit** that
produces a `/imps:imps` checklist-file plan, so the audit and the fix are one continuous
loop (`/imps:imp-agency` → `/clear` → `/imps:imps <plan>`).

The main session does one thing in its own context — resolve the project profile and show
it to the user as a gate — then hands the whole audit to a single **imp-agency** subagent
(unlike the free-text run, this path is unchanged: a single-segment subagent, not a
Workflow script — see [What it does](#what-it-does)). Inside it, one finder per applicable
dimension (`purpose`, `docs`, `ci`, `tests`, `security`, `performance`, `ux`, `stack`,
`ops`, `dx`, `verification`) fans out as nested background `imp` agents (the Workflow tool is not
available to subagents), every P0/P1 finding is adversarially refuted, a completeness
critic catches the suspiciously-clean dimension, and the survivors are synthesized into
the checklist plan.

**Effectiveness before craftsmanship.** The `purpose` finder audits fitness for purpose —
does each component earn its existence against the repo's reason-for-being (confirmed by
you at the profile gate)? It may verdict **delete**; delete verdicts face a 2-of-3
refuter panel, supersede fix findings on the same component, and land in an
operator-decision section of the plan — imps never auto-delete. If you wouldn't accept
"delete this component" as a finding, `--focus` away from `purpose`. The orchestrator gets back only the plan's `## Context` block and the item split —
finder returns, refuter traffic, and critic output never touch its context.

**Model routing follows reasoning shape.** The wrangler shell (dispatch/monitor/merge) is
sonnet; the parts with real analysis are upgraded: the deep-judgment finders (`purpose`,
`stack`, `security`, `performance`, `tests`) and every adversarial refuter run on **opus**,
synthesis is an **opus** sub-call (it writes the most-read output), and the
cross-dimension completeness critic runs on **fable** — the widest-decision-space call —
falling back to opus where Fable isn't available. The evidence-gathering finders (`docs`,
`ci`, `ux`, `ops`, `dx`, `verification`) stay on sonnet: a stronger model doesn't find
more stale docs or missing lint gates. The `verification` finder inventories and drives
existing project-local launch, doctor, scenario, evidence, and cleanup paths, then
distinguishes harness gaps from product defects.

```
/imps:imp-agency [--focus docs,tests,security] [--out /abs/path/plan.md]
```

- `--focus` (optional) — restrict to a subset of the dimension keys; default is all applicable.
- `--out` (optional) — where to write the plan (absolute, whitespace-free, **outside the
  repo** — the audit is read-only there). Default: `~/.claude/audits/<repo>-<date>.md`.

Every checklist item is a claim about the fixed end-state with a read-only `Verify:` command
that **fails now and passes once fixed** — so `/imps:imps <plan>` re-verifies each, reports
the failures, and offers to dispatch remediation. Read-only throughout: the only write is the
plan file outside the repo.

## The persona panel

**Opt-in — the panel runs only when you pass `--personas`** (see
[Runtime flags](#runtime-flags)). By default the Head Imp review is the gate and this
whole panel is skipped; the briefs below describe what runs when the flag is set.

Five reviewer briefs, each argued from a distinct, deliberately-conflicting lens.
Bundled at `${CLAUDE_PLUGIN_ROOT}/personas/` — no manual setup needed.

| Slug | Name | Lens | Type | Model |
| --- | --- | --- | --- | --- |
| `solution-architect` | Bramble | Boundaries, contracts, coupling — "should this exist, in this shape?" | code | opus |
| `grumpy-engineer` | Grudge | Edge cases, error paths, lazy shortcuts — "is this line correct?" | code | opus |
| `sre` | Klaxon | Failure modes, ops, idempotency, resource limits — "what does the operator see at 3am?" | code | opus |
| `business-analyst` | Ledger | Diff satisfies each issue's acceptance criteria — "did we build the right thing?" | code | opus |
| `ux-designer` | Glint | Hierarchy, affordance, consistency, mobile — "what does the user actually see?" | browser | sonnet |

Each persona ends its review with a parseable verdict line:
```
VERDICT: APPROVE | CHANGES_REQUESTED @ <sha>
```
`CHANGES_REQUESTED` requires at least one `[blocker]` or `[major]` finding. Minors and
nits are recorded but never block. By default each persona posts as a **real GitHub PR
review under its own dedicated GitHub App identity** via a posting script
(`~/.claude/scripts/persona-post.sh`) that implements the protocol in
`${CLAUDE_PLUGIN_ROOT}/references/persona-posting.md` — never the orchestrator's own
`gh`/GitHub-MCP access, so each review is attributed to and traceable as a genuinely
separate GitHub actor, not the session that authored the diff. The posting script uses
per-persona identities drawn from your secret store; the maintainer's deployment
(dedicated GitHub Apps + 1Password) is one example. This is independent *attribution*,
not an unforgeable *gate*: the orchestrator still holds the credentials the posting
script uses to mint every App's token, so it isn't a control the authoring session is
structurally unable to satisfy — it fixes the previous self-approval-under-one's-own-
name problem, not every trust concern a branch-protection rule might assume. If that
script is absent, fails, or its post can't be verified on the PR for a given persona
(GitHub Apps not installed on the target repo, secret store unavailable, etc.), that
persona's verdict fails **closed**: it goes into `findings_inline` for the operator to
read or post by hand, never under the orchestrator's own identity — the rest of the
panel is unaffected.

Pushing/opening the endstate PR and authorizing personas to post live GitHub reviews are
two separate operator decisions, not one — the `Push & PR?` question (asked once the
Workflow script returns `awaiting_authorization`) offers a `findings only (no persona
posts)` option precisely for runs where this session's own Head-Imp-driven amendments
make an independent review under a bot identity misleading. The posting-identity
protocol itself lives in `references/persona-posting.md`, shared by this panel and
`/imps:issue-mode`'s — not duplicated between them.

Findings survive up to three fix rounds. A `WONTFIX: <rationale>` in any round is captured, not
discarded — every rationale is retained as a `wontfix_rulings` entry and rendered in the run's
terminal result, not just the state file.

### When findings still don't converge

If dissenting findings remain after the three-round cap, one opus adjudicator rules on each,
anchored to at least one of: a named `## Definition of Done` criterion (quoted verbatim); a
concrete breaking input, data-loss path, or security defect in the merged diff; or a named
`## Global Constraints` violation (quoted verbatim) — a finding meeting none of the three
anchors cannot be ruled `load-bearing`. Each ruling is one of `parked-contestable`,
`parked-deferred`, `load-bearing`, or `operator-overridden`. A `load-bearing` ruling blocks the
run: the Workflow script returns a `blocked` result with `reason: "unresolved_findings"`, and you
choose `retry findings` (one more capped fix cycle, refused after two cycles) or
`override findings: <rationale>` (converts every `load-bearing` ruling to `operator-overridden`,
records your rationale, and proceeds to finalize). Every non-`load-bearing` ruling — and every
override — is written into `GOAL.md`'s `## Parked findings` section, so a run's disagreements have
a durable, readable record even after the state file is deleted at finalize.

## Bundled assets

| Asset | Location |
| --- | --- |
| Persona briefs (5) | `${CLAUDE_PLUGIN_ROOT}/personas/<slug>.md` |
| Persona posting-identity protocol (shared) | `${CLAUDE_PLUGIN_ROOT}/references/persona-posting.md` |
| `🦇` agent type | `${CLAUDE_PLUGIN_ROOT}/agents/imp.md` |
| `😈` agent type | `${CLAUDE_PLUGIN_ROOT}/agents/head-imp.md` |
| `👺` agent type (audit orchestrator) | `${CLAUDE_PLUGIN_ROOT}/agents/imp-agency.md` |
| Free-text run's Workflow script | `${CLAUDE_PLUGIN_ROOT}/scripts/imps-run.workflow.js` — synced to `~/.claude/workflows/imps-run.js` on every invocation |
| Checklist-file mode workflow | `${CLAUDE_PLUGIN_ROOT}/references/checklist-mode.md` |
| Discussion-seed mode workflow | `${CLAUDE_PLUGIN_ROOT}/references/discussion-mode.md` |
| Summon banner (cosmetic) | `${CLAUDE_PLUGIN_ROOT}/scripts/imps-intro.py` |
| Dispatch banner (cosmetic) | `${CLAUDE_PLUGIN_ROOT}/scripts/dispatch-banner.py` |
| Final banner (cosmetic) | `${CLAUDE_PLUGIN_ROOT}/scripts/final-banner.py` |
| Structured audit-log appender | `${CLAUDE_PLUGIN_ROOT}/scripts/audit-log.sh` |
| opencode execute-tier dispatcher | `${CLAUDE_PLUGIN_ROOT}/scripts/opencode-dispatch.sh` — hand-invocable; see `${CLAUDE_PLUGIN_ROOT}/references/opencode-harness.md` |
| OS sandbox wrapper (macOS) | `${CLAUDE_PLUGIN_ROOT}/scripts/sandbox-wrap.sh` |
| Sandbox containment assertions | `${CLAUDE_PLUGIN_ROOT}/scripts/sandbox-smoke.sh` |
| `--worktree` linked-worktree-shape assertions | `${CLAUDE_PLUGIN_ROOT}/tests/worktree-shape.sh` |

No manual setup needed for any of these — the plugin installs them at
`${CLAUDE_PLUGIN_ROOT}` and the commands resolve them at runtime. The bundled
`😈` agent type resolves whenever anything invokes it via the `Agent` tool
(`Agent(subagent_type: "imps:😈", ...)`).

## Runtime state

Written to `~/.claude/imps/` on first run — not bundled:

| Path | Purpose |
| --- | --- |
| `~/.claude/imps/runs/<slug>.json` | Per-project run state — resume spine, owned by the Workflow script after handover; it heartbeats `last_heartbeat` + `tasks_done` while imps run, so `cat` this file for live progress. Every invocation of the script is fresh (never `resumeFromRunId`) — this file, plus git ground truth, is the entire resume mechanism |
| `~/.claude/imps/runs/<slug>.md` | Per-run `GOAL.md` spine (`/compact`-durable), including the final nontrivial decision trail — lives here, not in the repo, so writing it never needs project-directory permission |
| `~/.claude/imps/runs/<slug>.prs.json` | Per-PR monitor state for `/imps:prs` |
| `~/.claude/imps/learnings.md` | Self-tuning `## Active rules` (≤10 bullets) + per-run notes |
| `~/.claude/audit.jsonl` | One structured JSON line per completed run — shared across plugins in this marketplace (schema in the root `AGENTS.md`) |

The `learnings.md` `## Active rules` section is read at startup on every run and applied
to model routing, task boundaries, and dependency detection. `/imps:imps` appends a new run
entry after each completed run; confirmed learnings are promoted into Active rules. The
Workflow script also appends a structured `audit.jsonl` entry at finalize — best-effort,
skipped with a warning (not a failure) if `jq` is missing.

## Browser review (optional)

The persona panel includes a browser half when the diff touches a renderable UI surface.
Transport is resolved in order:

1. **CDP endpoint** — set `CLAUDE_CDP_URL` (e.g. `ws://localhost:3000` or
   `ws://<lan-host>:3000` for a remote rig). Connect via `chromium.connectOverCDP` —
   never `connect()` (hangs); never pass `http://` (returns 426).
2. **Chrome MCP fallback** — if no CDP endpoint is reachable, the panel uses
   `mcp__claude-in-chrome__*` tools (requires the Claude-in-Chrome extension).
3. **No browser** — neither available → panel runs code-only; skip is noted in the report.

Repos with no UI surface skip the browser half entirely.

## License

MIT
