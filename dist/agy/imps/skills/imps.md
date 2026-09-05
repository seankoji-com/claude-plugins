---
name: imps
description: >
  Use when a substantial task should be decomposed, dependency-mapped, dispatched to
  model-routed imps, verified, and integrated on a dedicated run branch. Do not use for
  read-only audits or a single diff's impact analysis.
---

# /imps — summon the swarm

Decompose a vague task into dependency-mapped imps, dispatch them, and merge the result
back to a dedicated run branch cut off the default branch.

**Platform: Antigravity (agy).** On Claude Code this command hands the whole run to a
background `Workflow` script that dispatches isolated sub-agents in parallel. Agy has
neither, so **this skill is the driver**: it plans, writes the run state file, then walks
the task DAG itself, dispatching one task at a time with `agy -p` (matrix Item 8:
serial headless dispatch, **VIABLE**). Everything below is written for that model. Where
a Claude Code mechanism is named, it is named as a comparison, never as an instruction to
perform here.

## Context discipline (applies to every phase)

Planning happens in this session; **execution does not**. Each dispatched task runs in its
own `agy -p` invocation with its own context window, so the only things that cross into it
are its state-file entry and the files it reads for itself.

- Never paste a task's working files, diffs, or logs into this window to "help" it. Pass
  paths; let the task read them.
- Never accumulate per-task output here. Read the JSON envelope, record pass/fail in the
  state file, move on.
- Long reference material lives in `__PLUGIN_ROOT__/references/`; point at it rather than
  restating it.

(On Claude Code the same discipline is enforced structurally — dispatch onward lives
inside the Workflow script's own execution, invisible to the calling session. Here it is
enforced by you.)

## Rationalizations you will produce, and what to do instead

Every row below is a real failure from a real run, written in the voice you will hear it
in — as a reasonable-sounding thought, not as a rule you are breaking. Recognising the
sentence is the whole defence; each one is locally plausible and globally wrong.

| The thought | What actually happens | Instead |
| --- | --- | --- |
| "No arguments were passed, so this is a fresh start." | An empty invocation is the *signature* of a cleared context mid-run. Skipping the guard starts a second run against a live state file. | Run the **Guard: resume check** on every invocation, empty or not. |
| "The plan was approved while I was on this branch — I'll write it into the state file." | If that branch is the default branch, every task's work is dispatched, merged and gated straight onto production, and the PR step lands unreviewed or fails `head==base`. | Cut a fresh `imps/<slug>-<ts>` branch off a clean fetch of the default branch in Phase 2 Step 7, and write *that*. Never `git rev-parse --abbrev-ref HEAD`. |
| "The imps ran in isolated worktrees, so the shared checkout is untouched." | Isolation is not airtight — imps have repeatedly committed to the shared main checkout's local default branch instead of their assigned worktree. | Check `git status --short` and `git log --oneline -3` in the *actual* main checkout after every worktree-isolated wave — every time, not only when something looks off. |
| "I'll push the branch so this work isn't lost." | Pushing is the operator's gate, not a safety net. A publish imp that pushed and opened a PR on its own initiative bypassed the Push & PR gate entirely. | Nothing pushes before a `PR: yes` decision is persisted. Local commits are already durable. |
| "While I'm here, this extra issue is obviously worth filing." | The auto-mode classifier denies GitHub writes beyond the operator's explicit selection — and it denies the *whole* imp, not just the extra artifact, forcing a re-dispatch. | Create and close exactly the artifacts the operator named. If another one is worth filing, ask; don't add it. |
| "The audit/forage recommendation is minutes old, so the gap it names is real." | Fingerprints go stale immediately, and twice now a "missing capability" already existed in full in the target repo — the plan dispatched imps to rebuild it. | Grep or read the actual files for each claimed gap before writing a task around it. |
| "The Head Imp approved after I applied its fixes — one review pass is enough." | Round-1 fixes introduce round-2 bugs; a "make this executable" fix once turned out to be platform-unsound on the actual dev machine. | After substantial fixes, budget a second adversarial pass. An approval of the *unfixed* plan is not an approval of the fixed one. |
| "The diff is right here — pasting it into the reviewer's prompt is faster than a command." | The artifact enters this session's context, which is re-read every turn, and the reviewer reads a snapshot instead of the tree. | Pass artifacts by reference: a file path to `Read`, a command to run. See the Head Imp section. |
| "The signing agent looks locked — `--no-gpg-sign` just this once." | Under concurrent swarm agents that lock is usually transient, and the unsigned commit is permanent. | Retry the commit a few times with a short pause; if it persists, surface it as blocked. Never bypass signing. |
| "The PR is open, gates are green — the run is done." | The learnings gate has not run and the state file is still on disk. Stopping here loses the run's learnings and the `.prs.json` handoff. | The run ends at `done` — learnings persisted, state file deleted by the script. Not before. |

---

## Runtime flags

Parse and **strip** these flags from `$ARGUMENTS` **before** mode detection or any phase
runs — the remaining text is what mode detection and every phase below operate on. A
flag anywhere in the argument string counts; order does not matter.

- **`--personas`** — opt into the in-run five-persona review panel. **Default: OFF.**
  Without it, the Head Imp reviews the plan and a read-only Codex-first, OCR-fallback gate reviews the merged diff.
  With it, the full panel + fix-loop + adjudication runs exactly as before.

Derive a single boolean `PERSONA_PANEL` (`true` only if `--personas` was present) and
carry it through: free-text mode passes it into the Workflow call as `personaPanel`
(Phase 3 Step 2); issue-driven mode hands it to `commands/issue-mode.md`. Stripping the
flag first is what keeps `--personas 42 43` resolving to issue mode and
`--personas fix the parser` resolving to free-text — the flag is never part of the task
description, issue list, or discussion reference.

Concretely, strip with a token filter, e.g.:
```bash
PERSONA_PANEL=false
STRIPPED_ARGS=""
for tok in $ARGUMENTS; do
  if [ "$tok" = "--personas" ]; then PERSONA_PANEL=true; else STRIPPED_ARGS="${STRIPPED_ARGS:+$STRIPPED_ARGS }$tok"; fi
done
```
Use `$STRIPPED_ARGS` wherever the sections below say `$ARGUMENTS`.

---

## Mode detection

`/imps` has **four modes**, checked in this order:

- **Checklist-file mode** — `$ARGUMENTS` is a single token ending in `.md`. Resolve the
  file in order: (1) as-is if it's an absolute path or exists relative to cwd, (2)
  `~/.gemini/config/$ARGUMENTS`, (3) `$ARGUMENTS` relative to the repo root. If any
  resolution succeeds (`test -f`), treat the file as an audit checklist: **skip all phases
  below — Read `__PLUGIN_ROOT__/references/checklist-mode.md` and follow it instead.**
  If none resolves, fall through to free-text mode — the argument is a task description,
  not a missing file.

  Guard: only trigger if `$ARGUMENTS` is a **single** whitespace-free token. A multi-token
  argument that happens to end in `.md` (e.g. `fix the audit md file`) is free-text.

- **Issue-driven mode** — `$ARGUMENTS` is *entirely* GitHub issue references: every
  whitespace-separated token matches `^#?\d+$` (e.g. `/imps 42 43 51`, `/imps #42`).
  **→ Follow `/issue-mode`** for the full scout → rolling-dispatch → holding-branch →
  gates → persona-panel → handoff workflow. Do not continue with the phases below.

- **Discussion-seed mode** — `$ARGUMENTS`, taken as a whole, is a GitHub Discussion
  reference and nothing else: a full URL matching
  `^https?://github\.com/[^/\s]+/[^/\s]+/discussions/\d+([/?#]\S*)?$`
  (also matching a permalink-to-comment or `?sort=` suffix), or the two-token bare form
  matching `^discussion:?\s*#?\d+$` (case-insensitive, resolved against the current repo,
  e.g. `discussion 284`). Discussions live in a different GitHub API/ID space than Issues
  (GraphQL only, no REST) — this is why a discussion reference needs its own detection
  branch instead of falling into issue-driven mode.
  **→ Read `__PLUGIN_ROOT__/references/discussion-mode.md` and follow it** — it fetches
  the discussion, seeds it as the free-text task (Phase 1 onward), and defines the reply
  obligation Phase 4's finalize step fulfills.

- **Free-text mode** — `$ARGUMENTS` is a task description (anything that is not purely
  issue numbers or a discussion reference), or empty. **→ Continue with the phases below.**

Detection order: (1) single `.md` token that resolves to a file → checklist-file mode.
(2) non-empty AND every token matches `^#?\d+$` → issue-driven mode. (3) the whole
argument is a Discussion URL or bare `discussion N` reference → discussion-seed mode.
(4) everything else → free-text mode.

## Spooky intro (optional)

If `__PLUGIN_ROOT__/scripts/imps-intro.py` exists, run it and emit its output verbatim (not in a
code block). It is purely cosmetic — skip silently if absent.

```bash
[ -f "__PLUGIN_ROOT__/scripts/imps-intro.py" ] && python3 "__PLUGIN_ROOT__/scripts/imps-intro.py"
```

---

## The Head Imp — deep-judgment adversarial reviewer

The Head Imp is a one-shot adversarial reviewer dispatched at the **deepest reasoning
tier available** (see [Model selection reference](#model-selection-reference)). It reviews
three axes independently: architecture, line correctness, and contract fit. For a diff it
reads applicable repository standards plus GOAL.md's Definition of Done and Global
Constraints; clean code cannot mask the wrong behavior or unauthorized scope.

Dispatch it exactly like any other task — one `agy -p` invocation, model passed at
invocation:

```bash
agy -p "You are the Head Imp. Read <ARTIFACT_PATH> and argue AGAINST it. \
Report only what is wrong, missing, or mis-scoped." \
  --model "<deep-tier model id>" --output-format json
```

- **Plan review** happens in Phase 2 Step 3, before the approval gate.
- **Diff review** happens after the merge step in Phase 3, against the merged diff.

It never edits; it returns findings. You act on them.

(On Claude Code the Head Imp is a registered `imps:😈` plan-review agent. OpenCode reviews
the merged diff after deterministic gates.)

### Never pre-judge a reviewer's findings inside its own prompt

You hand-compose the Head Imp's plan-review prompt in Phase 2 Step 4. **Nothing in that
prompt may tell the reviewer what to conclude.** Before sending it, read the composed
string back and delete any sentence that:

- pre-clears something — "the sizing objection is already settled", "task 1 is
  deliberately large, don't flag it", "we've decided X is acceptable";
- narrows the mandate — "only look at the DoD", "skip the task boundaries";
- supplies the verdict — "this should APPROVE unless something is badly wrong",
  "expect minor findings only".

Facts are not pre-judgments. "The repo is `seankoji/claude-plugins`", "gates are
`bash tests/run.sh`", "worktree isolation defeats a `deps` split here" are context the
reviewer needs. The test is whether the sentence would change the reviewer's *verdict*
without changing the artifact.

**Overriding a finding is legitimate. Doing it invisibly is not.** The run has real,
recorded override paths — `skip <gate>`, `skip tasks #N`, `integrate partial`,
`override findings: <rationale>`, and the adjudicator's own rulings, all of which land
in the state file or GOAL.md where an operator can read them afterwards. Steering the
prompt has none of that: the finding is never made, so nothing records that it was
overruled, and the resulting APPROVE reads as independent when it isn't. If you disagree
with an expected finding, let it be raised and then override it on the record.

This is a rule for you, not a check the script runs — **there is no script-side
enforcement.** No reviewer function takes a guidance parameter, so there is no channel
to police mechanically; the discipline is in what you type.

---

## Run identity and the slug

Every run is keyed by a **slug**, which names its run record, its `GOAL.md` and its
`.prs.json`:

```bash
SLUG=$(basename "$(pwd)")
```

Derive it from the **working directory**, not from the repository. A run started in its
own git worktree then gets its own slug with nothing further to configure, and that is
exactly what stops two concurrent runs against one repo from sharing a record (see
**Concurrent runs against one repo**).

Where two checkouts can share a directory name, disambiguate with the remote's
owner/repository so same-named repositories never collide.

## Concurrent runs against one repo

Several `/imps` runs can work on the same repo at once — **one run per git worktree,
each in its own session.**

The constraint is the working tree, not the state file. Every orchestration step (cutting
the run branch, merging imp branches, running gates, syncing the default branch, pushing
the PR) acts on the session's own checkout with a plain `git` command and no explicit
path. Two runs sharing one checkout therefore share one HEAD, and the first run's
`git checkout -b` sends the second's merges onto the wrong branch. A worktree per run
makes each session's cwd correct by construction.

The run slug is `basename "$(pwd)"`, so a run started from its own worktree already gets
its own state file, GOAL.md and `.prs.json` with nothing further to configure.

```bash
git fetch origin "$DEFAULT_BRANCH"
git worktree add --detach ../<repo>.imps/<name> "origin/$DEFAULT_BRANCH"
```

Then install the repo's dependencies in the new worktree — a fresh worktree has none, and
gates run in the session's own tree — and start a new session with it as cwd.

Two caveats worth knowing. Git's auto-gc rewrites `packed-refs` and can race a concurrent
`git worktree add`; if you see "cannot lock ref" under several runs, pin it off with
`git config gc.auto 0` and compact once no run is live. And the user-scoped
`learnings.md` is shared by every run, so a run that rewrites it wholesale can drop
another's entry — append to it, never read-modify-write.

## Guard: resume check

Before anything else, check for an existing run state file:

```bash
SLUG=$(basename "$(pwd)")
STATE_PATH=~/.gemini/config/imps/runs/${SLUG}.json
test -f "$STATE_PATH" && jq -r '.phase, .segment, .branch' "$STATE_PATH"
```

If it exists, tell the user what it says and ask whether to resume or discard:

```
  <"Plan ready — not yet dispatched" | "Run in progress — dispatch loop was interrupted">
  branch: <branch>   phase: <phase>   done: <n>/<total>
```

- **Resume** — jump to **Phase 3 — Dispatch loop**. Its opening step reconciles the state
  file against git ground truth (branches, worktrees, merged commits) before dispatching
  anything, so an interrupted run picks up where it stopped instead of re-running finished
  tasks.
- **Discard** — delete the state file and start from Phase 1. GOAL.md stays; it is the
  human-readable record.

One state file per project slug. Two concurrent runs in the same project will overwrite
each other — finish or discard one first.

## 🎯 Phase 1 — Define

One phase, two paths, then a shared tail. Triage the brief first: it is **sufficient**
when it names both a concrete deliverable and at least one repo anchor (a file, path,
command, or reproducible symptom). Sufficient briefs pass through verbatim to the
questions below; a thinner one earns an interrogation instead, drawing on
`__PLUGIN_ROOT__/references/brief-probes.md`. Exactly one of the two runs. Discussion-seed
mode never interrogates — the discussion body is already the brief.

If the brief was sufficient, ask these in one batched question:

1. What concrete output artifacts are expected? Be specific — scripts, a GitHub
   Discussion post, a PR, code changes.
2. What access will agents need — and does any task have to change live state rather
   than read it?
3. What must be true of the diff for this to be done, and which command proves it?
   Reject vague criteria; every answer becomes a Definition-of-Done line.
4. What constrains this? Ask for two distinct things: what is off-limits (safety), and
   what must hold identically across independently-written tasks — exact field names,
   shared signatures, an API shape more than one task touches (consistency). The second
   is what `## Global Constraints` exists for.

Then, on **both** paths, settle the run's autonomy contract in one more batched question.
This is what lets the later phases run unattended:

1. **Endstate** — stop at a green PR, merge the green PR, or merge and release.
2. **Plan review** — show the plan before dispatch, or only stop if the Head Imp objects.
3. **Learnings** — save what the run finds, ask at the end, or save nothing.

Persist them as `endstate` (`"pr" | "merge" | "release"`), `plan_review`
(`"ask" | "on_objection"`) and `learnings_policy` (`"auto" | "ask" | "none"`). **Each
falls back to its most conservative value** when absent or unrecognized — `"pr"`,
`"ask"`, `"ask"`. A policy this build cannot read is never consent to merge or to skip
plan review.

Also settle here what this build cannot discover for itself: the gate commands
(build · lint · test · type) and the default branch. Then confirm the checkout can
actually run those gates — a lockfile with no installed dependencies, a declared venv
that is not there — and stop if it cannot. An uninstalled dependency otherwise surfaces
later as a red gate, and the gate fixer goes off editing source to "fix" it.

In discussion-seed mode, the outcome comment on the source discussion is posted by the
finalize step regardless of the artifacts answer — that question is only about artifacts
*beyond* that reply.

## Phase 2 — Plan

Using `<REFINED_TASK>` and the discovery answers, produce the authoritative decomposition.
Do the planning at the **deepest reasoning tier available** — on Agy that is a model you
select for this session, not a plan-mode routing rule.

**Step 0:** Load learnings from two sources (both optional):
- **User-scoped:** `~/.gemini/config/imps/learnings.md` — stack-agnostic rules
- **Project-scoped:** `.agy/imps/learnings.md` in the repo root

Read the `## Active rules` section from each that exists. Project-scoped rules win on
conflict. Apply them to tier assignment, task boundaries, and dependency detection.

**Step 1:** Ground the plan in reality — but **delegate the exploration** rather than
doing it in this context: dispatch cheap read-only runs for mechanical recon (default
branch, gate commands, file/symbol enumeration, "where is X"). Read a file directly only
when the plan must quote or reason about its contents. Then:

- **Solo-task check, before decomposing:** if the work is genuinely one atomic unit, write
  a **single-row task table** and go straight to Step 2. This is the same process with a
  smaller DAG — the Head Imp reviews the plan and OpenCode reviews the merged diff, the one task still
  dispatches into its own worktree, and gates, the persona panel and the endstate PR all
  still run. A one-task run is a first-class outcome, not a fallback.
- Otherwise, break the work into discrete, atomic tasks, each with one clearly-stated
  output and independently completable.
  - **Sizing heuristic:** read `__PLUGIN_ROOT__/references/task-sizing.md` and apply it to
    every task boundary.
- For each task assign:
  - **Spec** — the operative instructions the imp needs to act without improvising:
    concrete inputs (repo/owner, file paths, exact commands), the expected output
    artifact, and any constraints. A dispatched task receives ONLY its state-file entry,
    never this planning context. **Write the full spec into GOAL.md's `## Task specs`
    section and put a pointer in the state file** — "MANDATORY FIRST ACTION: Read
    <GOAL_PATH> section '### T<N>'; if unreadable, return failed" — substituting the
    resolved absolute path, since a dispatched task cannot expand a placeholder later.
    Only a spec short enough to be obviously intact at a glance may travel inline: a long
    embedded spec has been observed reaching a task truncated to its first line, and the
    task then improvises the rest. Label-only tasks improvise too, and improvised work is
    how runs produce unauthorized artifacts.
    For a bug, regression, flake, performance problem, or unexplained failing gate, the
    installed command text shows an absolute
    `__PLUGIN_ROOT__/references/diagnosis-loop.md` path because the installer replaces that
    placeholder. Copy the resolved absolute path into the durable task spec; never write the
    `__PLUGIN_ROOT__` token itself. Include the known failing command. If none exists,
    constructing and running a red-capable command is the task's first deliverable.
  - **Tier** — assign by reasoning complexity (see
    [Model selection reference](#model-selection-reference)). The tier is resolved to a
    concrete model id and passed with `--model` at dispatch (matrix Item 8 records that
    `agy -p` accepts `--model`). No per-skill model field is emitted anywhere in this
    plugin's Agy artifacts — none is established for this platform.
  - **Type** — `code` (file changes, worktree-isolated) · `query` (read-only by default;
    add `MUTATIONS_ALLOWED` to the task spec to authorize live mutations) · `publish`
    (GitHub artifacts; use `gh api graphql` for Discussions, not REST)
  - **Oracle** *(optional, `code` tasks only)* — a machine-checkable acceptance command
    that **fails today**. Verify it is red before dispatch and green after: an oracle
    already green at start cannot distinguish "implemented correctly" from "did nothing".
    Omit it rather than guess one.
  - **Depends-on** — prerequisite task IDs, or `—` if independent. A worktree-isolated
    task is cut from the remote default branch HEAD at spawn time, not from a
    not-yet-merged dependency's branch. If a task needs its dependency's changes, say so
    in the spec.

**Step 2:** Write **`GOAL.md`** to an absolute path under `~/.gemini/config/imps/runs/` —
not the repo root, so the write never needs project-directory access:

```sh
mkdir -p ~/.gemini/config/imps/runs
SLUG=$(basename "$(pwd)")
GOAL_PATH=~/.gemini/config/imps/runs/${SLUG}.md
echo "$GOAL_PATH"
```

Pass the echoed value as the write target. Step 6 re-derives the same `SLUG` (and its own
`STATE_PATH`) independently — shell state does not carry across tool calls. Write with
this structure:

```markdown

# GOAL — <REFINED_TASK (one line)>

## Original request
<the operator's own words, verbatim — the raw $ARGUMENTS, the collected answer, or the
discussion body. Never a paraphrase; this section exists to be checked against.>

## Definition of Done
- [ ] <acceptance criterion 1>
- [ ] <acceptance criterion 2 — one line each from discovery>
- [ ] Gates green (build · lint · test · type — per GATE_CMDS)
- [ ] Head Imp reviewed the plan; Codex or OCR reviewed the merged diff; all blocker/major findings addressed
- [ ] No merge conflicts with the default branch

## Global Constraints
- <constraint 1 — a rule EVERY task must satisfy, with its exact values written out>
- <constraint 2>
(_None._ if there are none — never leave this section empty)

## Task table
 #  Task                                      Tier    Type     Depends On
 1  <label>                                   cheap   query    —
 2  ...
(a solo run legitimately stops at row 1 — see Phase 2 Step 1's solo-task check; don't pad
with synthetic tasks to make the table look bigger)

## Task specs

### T1 — <label>
<the full operative spec: concrete inputs, repo/owner, absolute file paths, exact
commands, the expected output artifact, and any task-local constraints. This is what the
imp actually executes; the state file only points here.>

### T2 — <label>
...

## Status
Planned — not yet dispatched.

## Decision trail
_None._

## Parked findings
_None._
```

**`- [ ]` checkboxes appear ONLY under `## Definition of Done`.** A stray checkbox
anywhere else in GOAL.md is read as a phantom task. `## Status` and `## Parked findings`
render the literal `_None._` when empty, so an empty section is distinguishable from one
that was never written.

**Authoring `## Global Constraints`** — this is where discovery Q5 lands durably. It
exists because independent worktree-isolated tasks cannot see each other: a rule that has
to hold across tasks has nowhere else to live, and when it lives only in this planning
context, tasks produce mutually contradictory output. This section is delivered to every
task that writes or reviews code **as a pointer** — `Read <GOAL_PATH> section "Global
Constraints"` — never as pasted text, so it must read standalone.

- **Write exact values verbatim, never summarized.** "Use the field names in the schema"
  is not a constraint; "the state fields are `parked_findings`, `wontfix_rulings`,
  `verdicts_pending` — spelled exactly, in all three files" is.
- **Only constraints a reviewer could return a verdict against from a diff.** If nothing
  in a diff could falsify it, it is background, not a constraint.
- **Not the DoD.** A DoD criterion is true *once* and gets ticked. A constraint is true of
  *every* task and is never ticked. If you catch yourself writing a checkbox, it was a DoD
  line.

**`## Parked findings`** is a placeholder you write as `_None._` and then leave alone —
after handover the dispatch loop replaces its body with the adjudicator's rulings (Phase
4). Place it last, after `## Status`.

Discussion-seed mode: add `- [ ] Outcome comment posted to the source Discussion` to the
Definition of Done — finalize fulfills it; it is not a dispatched task. Add `- [ ] CI
green on the PR` **only if this run will open a PR**, or it stays permanently
unresolvable.

GOAL.md is the durable human-readable spine and lives outside the project on purpose. The
JSON state file (Step 6) is the **authoritative** task table — the dispatch loop reads it,
not GOAL.md. Hand-edit GOAL.md's task table after approval and you must mirror the change
into the state file or it will not take effect.

**Step 3 — Head Imp review (mandatory):** before the approval gate, dispatch the Head Imp
(see the Head Imp section above) with the **absolute path** of `GOAL.md` — the
`$GOAL_PATH` value echoed in Step 2. It Reads the file itself and argues against the plan:
wrong boundaries, mis-routed tiers, missing deps, gaps in the DoD. Fix what the critique
exposes before proceeding.

**Step 4 — approval gate.** Present the plan and get an explicit yes. Do not dispatch
without it. If the user requests changes, revise `GOAL.md` and re-ask.

**Step 5:** Set `poll_interval_seconds: 300`.

**Step 6:** Cut the run's dedicated working branch, then write the durable state file.
**Never write the branch you happen to be on into the state file** — that includes the
default branch, and doing so is exactly how a run commits every task's work straight onto
the default branch. Always cut a fresh branch off a clean fetch:

```sh
mkdir -p ~/.gemini/config/imps/runs
SLUG=$(basename "$(pwd)")
STATE_PATH=~/.gemini/config/imps/runs/${SLUG}.json
DEFAULT_BRANCH=$(git remote show origin | sed -n '/HEAD branch/s/.*: //p')
RUN_BRANCH="imps/${SLUG}-$(date -u +%Y%m%d-%H%M%S)"
git fetch origin "$DEFAULT_BRANCH" && git checkout -b "$RUN_BRANCH" "origin/$DEFAULT_BRANCH"
echo "$STATE_PATH"
```

Write the JSON below to the echoed `$STATE_PATH`. Write `$RUN_BRANCH` into `branch` —
never the discovery answer, never whatever `git rev-parse --abbrev-ref HEAD` reported
before this step ran. If branch creation fails, stop and surface the error rather than
falling back to the current branch.

```json
{
  "schema": 4,
  "task": "<REFINED_TASK>",
  "repo": "<repo from discovery>",
  "branch": "<RUN_BRANCH>",
  "tasks": [
    { "id": 1, "label": "...", "spec": "<operative instructions — required for every task; the label is a title, the spec is what the imp executes>", "tier": "cheap", "type": "query", "deps": [] }
  ],
  "phase": "dispatch_pending",
  "segment": null,
  "dispatched_at": null,
  "poll_interval_seconds": 300,
  "last_heartbeat": null,
  "tasks_done": [],
  "failed_tasks": [],
  "worktrees": {},
  "artifacts": [],
  "pr": null,
  "verdicts": null,
  "verdicts_pending": null,
  "parked_findings": [],
  "wontfix_rulings": [],
  "fix_cycles": 0,
  "operator_decision": null,
  "learnings_saved": null
}
```

Per-task fields:
- `spec` — required for every task. Normally a pointer into GOAL.md's `## Task specs`
  rather than the instructions themselves; see the Spec rule in the planning phase.
- `tier` — `cheap` · `standard` · `deep`, resolved to a model id at dispatch (see
  [Model selection reference](#model-selection-reference)).
- `oracle` — the machine-checkable acceptance command, run in the task's worktree; exit 0
  means done. `null`/absent for an ordinary task.
- `deps` — prerequisite task ids.

Then proceed to Phase 3.

## Phase 3 — Dispatch loop

This is the dispatch backend for Agy. On Claude Code everything from here to run
completion is control flow inside one background `Workflow` script; **that tool does not
exist on Agy**, so this skill runs the loop itself, in the foreground, one task at a time.

**Step 0 — preflight.**

```bash
command -v agy >/dev/null || { echo "imps: agy is not on PATH" >&2; exit 1; }
command -v jq  >/dev/null || { echo "imps: jq is required to read dispatch results" >&2; exit 1; }
```

**Permissions, stated plainly.** `agy -p` is headless and **fail-closed**: a tool call
needing a permission the CLI cannot prompt for is auto-denied with an actionable error
naming `permissions.allow` in `settings.json` (matrix Item 9 — confirmed live, fails
closed *and* fails loud). Add the allow-rules your tasks need to your own settings before
dispatching. **This plugin never adds them for you and never bypasses these prompts
with an unattended-override flag.**

**Step 1 — reconcile.** Read the state file. Cross-check it against git ground truth
before trusting it — `git branch --list`, `git worktree list`, and the merge state of the
run branch. A task listed in `tasks_done` whose branch does not exist did not run; a
branch that exists for a task not in `tasks_done` did. Ground truth wins; correct the state
file, then continue. Never route on a state file that disagrees with git.

**Step 2 — stage the DAG.** Topologically sort `tasks` by `deps` into stages. Tasks within
a stage are independent; stages run in order. Agy dispatch is **serial** — there is no
parallel agent primitive here — so a stage is a batch you run one after another, not
concurrently.

**Step 3 — dispatch each task.** For each task in the current stage, cut its worktree with
plain git, then run one headless invocation:

```bash
git worktree add "$TMPDIR/imps-t<id>" -b "imps/t<id>" "origin/$DEFAULT_BRANCH"

RESULT=$(cd "$TMPDIR/imps-t<id>" && agy -p "<the task's spec, plus: Read <GOAL_PATH> \
section \"Global Constraints\" before acting>" \
  --model "<the tier's resolved model id>" \
  --output-format json)
```

**Step 4 — judge the result by its `response` content, never by exit code or `status`.**
This is the single most important rule of the Agy backend. Matrix Item 8 measured a run
whose tool call was fail-closed-denied and which still returned `EXIT=0` with
`"status":"SUCCESS"` and an **empty** `"response":""` — the CLI process succeeded while
the task did nothing. So:

```bash
RESPONSE=$(printf '%s' "$RESULT" | jq -r '.response // ""')
if [ -z "$RESPONSE" ] || [ "${#RESPONSE}" -lt 1 ]; then
  # EXIT=0 + status SUCCESS + empty response == a FAILED run. Treat it as failed.
  echo "task <id>: empty response — treating as failed (see matrix Item 8)" >&2
fi
```

Record the outcome: success (non-empty `response`, and a green oracle where one is set) →
append the id to `tasks_done` and record the branch under `worktrees`; anything else →
append `{ id, reason }` to `failed_tasks`. Where a task needs a machine-readable result,
pass `--json-schema <path>` and read the parsed `structured_output` field alongside
`response` (matrix Item 8).

Heartbeat `last_heartbeat` and `tasks_done` into the state file as each task returns, so an
interrupted loop can be resumed by Step 1 rather than restarted.

**Step 5 — merge.** After each stage, merge its task branches into the run branch, in
task-id order, one at a time. On conflict, stop the loop and surface the branch plus the
conflicting paths — do not resolve silently. After merging, do not trust the recorded
worktree path alone: check `git status --short` and `git log --oneline -3` in the real
checkout before assuming the tree is clean.

**Step 6 — independent diff review.** Review the merged diff against GOAL.md after gates
with the runtime's independent OpenAI-lineage reviewer. Fix blocker/major findings, rerun
gates, and re-review with a fresh session. A reviewer failure blocks. **The five-persona panel runs only when
`--personas` was passed** (`PERSONA_PANEL` true); by default it is skipped and the Head Imp
diff review here is the review gate — see the Runtime flags section.

## Phase 4 — Decision points

The loop stops at a decision point rather than guessing. Each one is a question to the
operator; the answer is persisted into the state file's `operator_decision` field so an
interrupted session resumes from it:

```bash
jq --arg d '<decision>' '.operator_decision = $d' \
  ~/.gemini/config/imps/runs/<slug>.json > "$TMPDIR/imps-state.json" \
  && mv "$TMPDIR/imps-state.json" ~/.gemini/config/imps/runs/<slug>.json
```

Decision vocabulary: `resolved, continue` · `retry <gate>: <guidance>` · `skip <gate>` ·
`reconciled, continue` · `retry tasks #N,#M: <guidance>` · `skip tasks #N,#M` ·
`integrate partial` · `retry findings` · `override findings: <rationale>` ·
`override code review: <rationale>` · `skip code review: <rationale>` · `PR: yes` ·
`PR: no` · `learnings: <json|none>` · `abort`.

**The anti-pre-judging rule applies to every guidance string you compose here.** Guidance
says *what* failed and *how*; it never says what the reviewer should conclude. "This is
fine now", "don't flag the sizing again", "just get it to APPROVE" are pre-judgments. If
you want a finding overruled, `override findings:` does it **on the record**; `skip
<gate>` and `skip tasks #N` are the equivalents at the other gates. All three leave a
trace. Steering a reviewer's prompt leaves none.

**Blocked states:**
- `dispatch_failed` — preflight rebase conflict, or a dispatch error. Fix the tree, then
  `resolved, continue` or `abort`.
- `imps_failed` — failed tasks block the DoD. `retry tasks #N: ...`, `skip tasks #N`,
  `integrate partial`, or `abort`. An empty-`response` run lands here.
- `merge_conflict` — live in the working tree. List branch + files, let the user resolve,
  then `resolved, continue`.
- `gate_red` — surface the gate name and log tail; agree retry guidance, skip, or abort.
- `branch_mismatch` — reconcile against the state file's own task table and
  `git branch --list` / `git worktree list`; never take a task's self-reported branch at
  face value. Then `reconciled, continue`.
- `unresolved_findings` — the persona panel's fix loop hit its 3-round cap with findings
  still standing and at least one adjudicator ruling came back `load-bearing`. Surface
  every load-bearing finding with its rationale, then agree `retry findings` (one more
  capped cycle; refused after two), `override findings: <rationale>`, or `abort`. **Do not
  fix them silently in this session** — that is the self-review pattern the disclosure
  below exists for. These three strings match verbatim and case-sensitively.

A **ruling** is the adjudicator's verdict on one surviving finding, one of exactly four:
- `load-bearing` — blocks. Must be anchored to at least one of: a verbatim-quoted
  criterion under GOAL.md's `## Definition of Done`; a named concrete breaking input,
  data-loss path, or security defect reachable in the merged diff; or a verbatim-quoted
  constraint under `## Global Constraints`. A `load-bearing` ruling with none of the three
  anchors is malformed, not stricter — read the finding yourself.
- `parked-contestable` — reviewed, judged non-blocking, and the reasoning is the part you
  might disagree with. A finding raised by two or more distinct personas defaults to
  `load-bearing`, so parking one of those obliges a stated surviving DoD criterion.
- `parked-deferred` — real, non-blocking here, worth doing later. A follow-up to file.
- `operator-overridden` — was load-bearing until you issued `override findings:`.

All four are written to GOAL.md's `## Parked findings` except `load-bearing`, which
blocks. "Parked" always means *reviewed and ruled on* — never a persona that was never
run. A skipped persona is an unreviewed lens, not a parked finding; say so distinctly.

**Push & PR decision.** With `--personas` set, the persona panel posts findings on a PR
thread, so the PR must exist first. Ask once branches are merged, the Head Imp has
reviewed, and gates are green:

**Do not ask whether to open the PR — derive it.** `endstate`, settled in Phase 1,
already answered it. Persist `PR: yes` when there is a diff and `endstate` is `"pr"`,
`"merge"` or `"release"`; persist `PR: no` when there is no diff, since an empty PR is
worse than none. `PR: no` stays available for an operator who wants the branch kept local
despite a diff, but it is no longer a question the run asks.

**The persona panel never posts.** Its verdicts always return inline. Personas used to
publish real GitHub reviews under dedicated App identities; that was removed once the
read-only diff review became this run's on-the-record code review, since bot-authored
approvals of a diff the same session wrote read as independent sign-off without being it.
The `unresolved_findings` state and the `retry findings` / `override findings:` verbs
below cannot occur on a panel-less run.

**Self-review disclosure.** Print it — it is no longer attached to a question, so it is
the only thing between a self-reviewed diff and a published one. Say so whenever the code
review ran fix rounds, was overridden, or was skipped outright; a skipped review means
this diff was never reviewed at all, and that is the strongest thing to lead with.

**DoD coverage.** Before asking the Push & PR question, walk each *functional* DoD
criterion against the merged diff and print one line per criterion:

```
[x] satisfied    <criterion text>
[ ] unsatisfied  <criterion text> — <evidence>
[?] unverifiable <criterion text> — <evidence>
```

`[?]` is a deliberate non-claim, not a checkbox reading — never untick an `unverifiable`
criterion's actual GOAL.md box, since a human may have verified it by hand. Surface a
prominent callout above the list if any criterion is unsatisfied, and a separate lower-key
line if any is unverifiable — they are different claims. Both go **before** the Push & PR
question, never after.

**Finalize.** Before printing results, assemble the run's nontrivial decision points:
Head Imp amendments, conflicts resolved, skipped gates or tasks, and advisory-check
failures. Replace the bounded body of GOAL.md's existing `## Decision trail` section with
one plain, checkbox-free bullet per pivot, or `_None._` when there were none. Never append
or emit a second heading; routine actions and achieved outcomes do not belong there.

Then print the results block:

```
  merged:    #6 <label>    (3 files)
  published: #3 Discussion → https://github.com/...
  verdicts:  solution-architect APPROVE · grumpy-engineer APPROVE · ...
  PR:        <url, "ready for review"> | "no PR — branch is local"
  endstate:  merge → merged · release → merged, released <url>
```

Every verdict is delivered inline — nothing is posted to GitHub — so no delivery tag is
needed. A `SKIPPED` persona is an unreviewed lens, not an approval; say so distinctly.

Then the **learnings gate**, its own explicit step: present any candidates, persist
`learnings: [...]` or `learnings: none`, append the confirmed ones to the user- or
project-scoped `learnings.md`, and only then delete the state file. GOAL.md stays — it is
the human-readable record.

If `pr` is non-null, invoke `/prs` to start the PR monitor. If it is null, say: "Branch is
local only and no PR was opened — push and open a PR, then invoke `/prs` to activate the
monitor."

## 🚢 Phase 5 — PR

**PR, Merge, or Release — whichever `endstate` was set to in Phase 1.** The work is the
same either way; `endstate` decides only how far it goes.

1. **Open** — push the branch and open the PR.
2. **Panel** — the five personas and their fix loop, only with `--personas`. Verdicts
   always return inline; nothing is posted.
3. **Green** — read the PR's real state (failing checks, merge conflicts, unresolved
   review threads), fix what is blocking, push, and re-read. **Bounded at three rounds**,
   the same cap as the gate and panel fix loops. Resolve conflicts first, then failing
   checks (read the actual logs, never guess from a check name), then review comments.
   Change the code when a comment is right; when it is not, leave it and say why — never
   force a change to silence a reviewer, and never resolve a thread you did not address.
   Waiting for in-flight CI is not a round; let checks settle before counting one.
4. **Close** — if `endstate` is `"merge"` or `"release"` **and** the PR is green, merge
   it. Green means checks passing, **mergeability actually reported clean**, and no
   unresolved threads: a host that has not computed mergeability yet has not said the PR
   is safe to merge, so treat that as not-green and fail closed. Then, for `"release"`
   only, cut a release following the repo's **own** convention,
   determined by reading its existing tags, prior releases, and any release workflow. If
   there is no discernible convention, or a workflow already releases on merge, do
   nothing and say why — a guessed tag format is worse than no release.
5. **Land** — final summary, monitor handoff, learnings.

Exhausting the round cap is a **hand-off, not a failure**: report which round it stopped
on and what was still red. A merge that a permission rule refuses is likewise final —
surface the PR URL and stop. Do not retry, do not substitute a direct push to the base
branch, and do not delegate it to another agent. An `endstate` of `"merge"` that ends in
a green unmerged PR is a complete run with one step left to a human, and reads that way.

Both irreversible steps are guarded by their own persisted marker (`merged_at`,
`release_url`), recorded **independently**. A resumed run re-reads the PR state and
re-does neither — but an already-merged PR skips only the merge, so a run that merged and
then died can still cut the release it never reached.

## Design note — why resume is a state-file read, not a platform feature

Resume here is deliberately a **state-file reconciliation**, not anything the platform
provides: Phase 3 Step 1 re-reads the state file and cross-checks it against git before
dispatching. Idempotency for side-effecting steps has two sources — **merge** relies on
`git merge` of an already-merged branch being a no-op, and **PR creation, the merge/release
and the learnings append** each check an explicit persisted marker in the state file
(`pr`, `verdicts`, `discussion_comment_url`, `learnings_saved`) before acting.

(On Claude Code the same design holds for a different reason: that platform's `Workflow`
resume feature is same-session-only and prefix-cached, so it could not survive a new
session and would defeat the duplicate-post guards. Agy has no equivalent feature to
decline in the first place — each `agy -p` call is independent by construction.)

## Model selection reference

Assign by reasoning complexity, not duration or volume. Tasks carry a **tier**, not a
model name:

| Tier | Use for | Resolved at dispatch to |
|------|---------|-------------------------|
| `cheap` | mechanical work — deterministic output, no judgment | the fastest/lowest model you have configured |
| `standard` | judgment — context, decisions, synthesis | the session's default model |
| `deep` | deep judgment — large decision space, architectural tradeoffs | the strongest model you have configured |

The tier is resolved to a concrete model id and passed as `agy -p --model <id>` **at
invocation** (matrix Item 8). No per-skill model field is emitted: no matrix item
establishes one for this platform, so model choice is made at the call site instead.

Read the model ids available to you from the CLI rather than hardcoding any — Claude
Code's short tier aliases name no model on this platform.

**Resolution order, and the documented override.** For each tier, in order:

1. `$IMPS_TIER_MODEL_CHEAP` / `$IMPS_TIER_MODEL_STANDARD` / `$IMPS_TIER_MODEL_DEEP`, if
   set — the operator's explicit pin, passed to `--model` verbatim.
2. The tier's row in the table above.
3. The session's default model, for every tier — the safe fallback when nothing else
   resolves. Say which tier fell back to it rather than resolving silently.

Never substitute a *stronger* model for a `cheap` task to make it pass; re-tier it in the
task table instead, where the operator can see it.

## Constraints

- Never start the dispatch loop without explicit approval of the task list (Phase 2 Step 4
  is that gate).
- Never `git merge --force`, `git reset --hard`, or `git push` without explicit user
  instruction — **exceptions**: (1) after plan approval the dispatch loop rebases the run
  branch and merges task branches autonomously, and it pushes and opens the endstate PR
  only after one of the `Push & open PR …` answers is persisted; (2) the `/prs` monitor
  pushes fix commits to the PR branch once activated.
- Never create GitHub PRs without user instruction — the Push & PR gate in Phase 4 is that
  instruction for the endstate PR.
- Personas never post to GitHub. The panel's verdicts always return inline — the
  read-only diff review is this run's on-the-record code review.
- `endstate` is the only authorization to merge, and it is settled in Phase 1. A merge
  refused by a permission rule is final: hand off, never retry or route around it.
- **Never bypass permission prompts with an unattended-override flag, and never write
  permission allow-rules into a user's `settings.json` on their behalf.** Document what a run needs and let the
  operator add it.
- Never treat a zero exit code or `"status":"SUCCESS"` as proof a dispatched task did its
  job — inspect the `response` (matrix Item 8).
- If a task touches a production system, pause and confirm before that task runs.
- Worktree isolation is not airtight — after each merge step, check `git status --short`
  and `git log --oneline -3` in the actual checkout before assuming the tree is clean.
- Never bypass commit signing because the signing agent looks locked or contended — that's
  usually transient. Retry with a short pause before surfacing it as blocked.
