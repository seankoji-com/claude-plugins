---
name: imps
description: Explicit Codex command for substantial implementation work that should be planned, dependency-mapped, delegated to subagents, integrated in isolated git worktrees, gated, and independently reviewed. Invoke with $imps; do not use for a read-only audit or a trivial direct edit.
metadata:
  version: "0.1.0"
  source-command: "plugins/imps/commands/imps.md"
  source-version: "0.3.50"
---

# Imps for Codex

This is the Codex translation of Claude's `/imps:imps`. Keep the outcome and safety
contract, but use native Codex subagents and ordinary git worktrees. Never call or
simulate Claude-only `Workflow`, `Agent`, `SendMessage`, `AskUserQuestion`, or
`ScheduleWakeup` tools.

## Resolve the maintained source

Resolve the directory containing this `SKILL.md` to its physical path first, following
any personal-skill symlink, and call that `IMPS_SKILL_ROOT`. Resolve the Imps plugin root
as `IMPS_SKILL_ROOT/../..` before reading or running bundled resources. Do not guess an
installed cache path or calculate the plugin root from the unresolved symlink path.

Use these maintained resources when relevant:

- Task boundaries: `IMPS_PLUGIN_ROOT/references/task-sizing.md`
- Bugs, regressions, flakes, and failing gates: `IMPS_PLUGIN_ROOT/references/diagnosis-loop.md`
- Checklist audits: `IMPS_PLUGIN_ROOT/references/checklist-mode.md`
- Discussion parsing and reply shape: `IMPS_PLUGIN_ROOT/references/discussion-mode.md`
- Independent diff review: `IMPS_PLUGIN_ROOT/references/opencode-review.md`
- Review roles: `IMPS_PLUGIN_ROOT/personas/`
- Read-only review helper: `IMPS_PLUGIN_ROOT/scripts/opencode-review.sh`
- Shared structured audit appender: `IMPS_PLUGIN_ROOT/scripts/audit-log.sh`

## Invocation

Treat the text accompanying `$imps` as the task. Strip these optional flags
before interpreting it:

- `--personas`: add the five-persona review panel after the merged diff passes gates.
- `--dry-run`: complete discovery, decomposition, and adversarial plan review, print the
  proposed run, and stop before creating branches, worktrees, files, or remote artifacts.

Choose one input mode:

1. A single whitespace-free, resolvable `.md` path means checklist mode. Read the
   checklist reference and preserve its command-confirmation gate, query-only dispatch,
   report shape, and separate remediation approval. Translate Claude paths and agent
   names to the Codex equivalents in this skill.
2. A request made only of GitHub issue numbers means issue mode. Fetch every issue and
   treat its current acceptance criteria and discussion as the brief.
3. A GitHub Discussion URL or `discussion N` means discussion mode. Read the discussion
   reference, fetch the title, body, and comments before planning, and retain its GraphQL
   node ID. The reviewed plan must disclose the final summary reply as an external
   mutation. Post it only after that plan is approved; if an approved run is aborted,
   post the short abort notice instead.
4. Everything else is a free-text task. If no task was supplied, ask one short question
   for it and stop that turn.

GitHub reads should use the GitHub connector when available, then `gh` as a fallback.
Never substitute an Issue API call for a Discussion GraphQL lookup.

## Hard boundaries

1. Perform read-only preflight and discovery first. Do not edit code, create a branch or
   worktree, push, publish, or make another external mutation until the user approves the
   concrete plan and its listed mutations. Prior approval in the same request counts.
2. Leave the user's current checkout untouched. Existing dirty or generated work belongs
   to the user. All implementation and integration happen in worktrees created for this
   run from a fetched default-branch commit.
3. Use subagents for every implementation task, including a one-task plan. If subagent
   tools are unavailable or disabled, produce the reviewed plan and stop. Do not quietly
   execute the implementation in the parent task.
4. Respect the live concurrency limit. Dispatch only dependency-ready tasks, in waves.
   Never invent parallel tasks when the work is one atomic unit.
5. A query task is read-only unless its approved task specification says
   `MUTATIONS_ALLOWED` and names the mutation. A publish task may create only the approved
   artifact. No agent may push unless its task explicitly owns that push.
6. Never force-push, bypass branch protection, use an admin merge override, discard user
   changes, expose secrets, or hide a blocked command behind another tool.
7. Repair loops are capped at three rounds for any gate or review stage. After the cap,
   stop with the exact remaining failures. A review override requires the literal user
   instruction `override code review: <rationale>`.

## Phase 0: Preflight

Inspect and record:

- repository root, current branch, `git status --short`, remotes, and default branch;
- current remote default-branch SHA using a read-only remote query, without updating
  local refs before approval;
- applicable `AGENTS.md` files and repository instructions;
- repository gate, lint, test, build, and formatting commands;
- current subagent concurrency and the tools available to workers;
- existing incomplete Codex Imps run records for this repository;
- run start time for the final audit duration.

Run records live under `~/.codex/imps/runs/`. Key them by owner, repository, working
directory basename, and UTC timestamp so same-named repositories do not collide. If an
incomplete record exists, show its task, base commit, integration branch, worktree paths,
completed tasks, and blocker. Ask whether to resume it, archive it, or start a new run.
Never overwrite it silently.

Load `## Active rules` from `~/.codex/imps/learnings.md` and the repository's
`.codex/imps/learnings.md` when they exist. Apply both during planning, with project rules
winning on conflicts. These are operator-approved rules, not permission to widen scope.

For a bug, regression, flake, performance problem, or unexplained failing gate, read the
diagnosis-loop reference before planning. A red-capable reproduction is the first
deliverable when one does not already exist.

## Phase 1: Discover and plan

Keep the parent task focused on decisions. Delegate narrow mechanical reconnaissance to
scout agents and code-structure questions to explorer agents. Do not ask multiple agents
the same question.

Create a dependency table with one row per real unit of work:

| Field | Required content |
| --- | --- |
| ID | Stable positive integer |
| Goal | One independently verifiable outcome |
| Ownership | Exact files, modules, or external artifact owned by the task |
| Type | `code`, `query`, or `publish` |
| Depends on | IDs that must integrate first |
| Worker | `worker`, `explorer`, `scout`, or `default` |
| Verify | A command or observable done condition |

Read the task-sizing reference and apply it to every row. A dependent code task must be
created from the integration branch only after its dependencies merge. Task prompts must
carry the full operative specification, paths, constraints, and verification commands;
labels alone are not task specifications.

Before showing the plan to the user, spawn one read-only default subagent as the Head Imp.
Give it the plan path or full table, the task-sizing reference, repository rules, and the
original request. Ask it to argue against the plan across architecture, line-level
correctness, contract compliance, unsafe assumptions, missing dependencies, and weak
verification. It must return findings labelled `blocker`, `major`, `minor`, or `nit`, plus
`APPROVE` or `CHANGES_REQUESTED`. Amend the plan for supported findings, then run at most
one follow-up review on the amended plan.

Present the reviewed plan, base commit, expected branches/worktrees, gates, external
mutations, and publication outcome. If approval is not already explicit, ask whether to
execute this exact plan and stop that turn.

With `--dry-run`, stop here even when the plan is approved.

## Phase 2: Prepare the run

After approval:

1. Create a temporary root with `mktemp -d`. Record its exact path.
2. Fetch the recorded default branch, verify the fetched commit matches the reviewed
   plan's recorded remote SHA, and stop for re-review if it moved.
3. Create `imps/<slug>-<UTC timestamp>` from that immutable base commit.
4. Add an integration worktree for that branch under the temporary root. Do not switch
   branches in the user's checkout.
5. Write the reviewed plan and run metadata to a new run record. Include task status,
   base commit, integration branch and path, worker branches and paths, gates, decisions,
   source Discussion details when present, publication intent, and side-effect markers.
6. Recheck the user's checkout status and recent commits. Stop if preflight changed it.

## Phase 3: Dispatch and integrate

For each wave of dependency-ready tasks:

1. Create one branch and worktree per code task from the current integration `HEAD`.
   Query tasks may use read-only agents without a worktree. Publish tasks run only after
   their dependencies and approval conditions are satisfied.
2. Spawn the assigned subagents. Every code-task prompt must state its owned files, its
   worktree path, that other agents are working concurrently, that it must not revert or
   overwrite their work, and that it must commit but not push.
3. Wait for the wave. Inspect each actual worktree status, commit, diff, and verification
   result. Do not trust a success sentence without git evidence.
4. Merge successful worker branches into the integration worktree one at a time. If a
   merge conflicts, send the conflict and both intents back to the owning worker when
   practical. Otherwise stop for the user. Never pick a side merely by branch precedence.
5. Run the task's verification after merge and update the run record. Create dependent
   task worktrees only after their prerequisite commits are integrated.

If a worker fails, preserve its worktree and branch, record the exact blocker, and use a
follow-up turn on the same agent when available. Do not start a replacement agent until
you know the original cannot continue.

## Phase 4: Gate and review

Run the repository's full deterministic gates in the integration worktree. For a caused
failure, dispatch one bounded repair task from the current integration `HEAD`, merge it,
and rerun the failing gate followed by the full relevant suite. Record pre-existing
failures separately; do not relabel them as success.

After gates pass, run the existing OpenCode helper with the integration worktree, immutable
base commit, and run record as the goal file:

```text
IMPS_PLUGIN_ROOT/scripts/opencode-review.sh \
  --repo <integration-worktree> \
  --base <base-commit> \
  --goal <run-record>
```

Read the OpenCode review reference first. The helper is read-only and fail-closed. Missing
authentication, an unavailable model, timeout, malformed output, or unresolved findings
blocks publication. For `CHANGES_REQUESTED`, dispatch a repair worker, rerun deterministic
gates, and start a fresh review. Stop after three failed review rounds unless the user
provides the exact override instruction and rationale.

When `--personas` is present, review the approved diff with the applicable persona briefs.
Use separate read-only subagents, dispatching in waves. Skip the UX persona when the diff
has no browser-rendered surface. Fix supported blocking findings through the same bounded
repair, gate, and re-review loop.

## Phase 5: Publish and finish

Recheck the integration diff, status, base, and task acceptance criteria. Reconcile every
planned item against actual evidence. Do not push or open a pull request unless that was
part of the approved plan.

When publication is approved, push only the integration branch and open or update one PR
against the recorded default branch. Never merge it automatically. Include the task,
verification evidence, review result, known limitations, and any explicit override.

Remove only the exact temporary worktrees created by this run, and only after their commits
are safely integrated or their unresolved state has been reported. Keep the integration
branch and human-readable run record. Never use a broad recursive cleanup target.

Finish with:

- task outcomes and integrated commits;
- gates and independent-review verdict;
- branch and PR URL, when present;
- unresolved or pre-existing failures;
- retained worktrees or branches and why;
- the next operator action.

Before closing the run, propose only concrete, reusable learning candidates caused by
this run. Ask which, if any, should be saved. Append approved project-specific rules to
`.codex/imps/learnings.md` and stack-independent rules to
`~/.codex/imps/learnings.md`, under `## Active rules`. Mark the append in the run record
before retrying any finalization so a resumed run cannot duplicate it. Never rewrite this
skill automatically from its learnings.

Append one best-effort audit event with `scripts/audit-log.sh`, using `--plugin imps`,
`--command '$imps'`, the measured duration, the actual final status, and a short outcome
note. Telemetry failure must be reported but must not change the run verdict. Record that
the event was attempted so resume cannot append it twice.

Do not create an automatic monitor. If the user asks to watch the PR, use the current
Codex task's supported waiting or heartbeat mechanism and preserve the same fail-closed
rules.
