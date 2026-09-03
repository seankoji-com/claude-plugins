---
description: >
  Use when a substantial task should be decomposed, dependency-mapped, dispatched to
  model-routed imps, verified, and integrated on a dedicated run branch. Do not use for
  read-only audits or a single diff's impact analysis.
argument-hint: '[--personas] <task description | issue numbers | discussion ref | checklist.md>'
---

# /imps — summon the swarm

> ⚠️ **UNSUPPORTED on OpenCode.** Everything below assumed a dispatch harness
> (`opencode-dispatch.sh`, the `agent-safehouse`/Seatbelt oracle-loop wrapper this command
> was built to walk its task DAG through) that has been **removed from the Claude Code
> source repo** and has no replacement here. Do not attempt to run this command on
> OpenCode — `$IMPS_HARNESS` names a script that no longer exists anywhere in this
> checkout. The rest of this file is retained as a historical record of the prior design,
> not as working instructions, until a replacement execution mechanism is built and
> ported. `/imps:prs`, `/imps:issue-mode`, and `/imps:imp-agency` are unaffected — they
> dispatch via plain `opencode run -m`, not this harness.

Decompose a vague task into dependency-mapped imps, dispatch them, and merge the result
back to a dedicated run branch cut off the default branch.

**Platform: OpenCode.** On Claude Code this command hands the whole run to a background
`Workflow` script that dispatches isolated sub-agents. OpenCode has neither, so **this
command is the driver**: it plans, writes the run state file, then walks the task DAG
itself, dispatching one task at a time through the `opencode-dispatch.sh` oracle-loop
harness — **not bundled with this artifact**; see "Where `$IMPS_HARNESS` comes from" in
Step 3 for where to point it. Everything below is written for that model. Where a Claude
Code mechanism is named, it is named as a comparison, never as an instruction to perform
here.

## Context discipline (applies to every phase)

Planning happens in this session; **execution does not**. Each dispatched task runs in
its own `opencode run` invocation with its own context window, so the only things that
cross into it are its state-file entry and the files it reads for itself.

- Never paste a task's working files, diffs, or logs into this window to "help" it.
  Pass paths; let the task read them.
- Never accumulate per-task output here. Read the dispatch harness's JSON result,
  record pass/fail in the state file, move on.
- Long reference material lives in `__PLUGIN_ROOT__/references/`; point at it rather
  than restating it.

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
| "The plan was approved while I was on this branch — I'll write it into the state file." | If that branch is the default branch, every task's work is dispatched, merged and gated straight onto production, and the PR step lands unreviewed or fails `head==base`. | Cut a fresh `imps/<slug>-<ts>` branch off a clean fetch of the default branch in Phase 2 Step 6, and write *that*. Never `git rev-parse --abbrev-ref HEAD`. |
| "The imps ran in isolated worktrees, so the shared checkout is untouched." | Isolation is not airtight — imps have repeatedly committed to the shared main checkout's local default branch instead of their assigned worktree. | Check `git status --short` and `git log --oneline -3` in the *actual* main checkout after every worktree-isolated wave — every time, not only when something looks off. |
| "I'll push the branch so this work isn't lost." | Pushing is the operator's gate, not a safety net. A publish imp that pushed and opened a PR on its own initiative bypassed the Push & PR gate entirely. | Nothing pushes before a `PR: yes` / `PR: yes, no-post` decision is persisted. Local commits are already durable. |
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
  Without it, the Head Imp reviews the plan and read-only OCR reviews the merged diff.
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
  `~/.config/opencode/$ARGUMENTS`, (3) `$ARGUMENTS` relative to the repo root. If any
  resolution succeeds (`test -f`), treat the file as an audit checklist: **skip all phases
  below — Read `__PLUGIN_ROOT__/references/checklist-mode.md` and follow it instead.**
  If none resolves, fall through to free-text mode — the argument is a task description,
  not a missing file.

  Guard: only trigger if `$ARGUMENTS` is a **single** whitespace-free token. A multi-token
  argument that happens to end in `.md` (e.g. `fix the audit md file`) is free-text.

- **Issue-driven mode** — `$ARGUMENTS` is *entirely* GitHub issue references: every
  whitespace-separated token matches `^#?\d+$` (e.g. `/imps 42 43 51`, `/imps #42`).
  **→ Follow `/imps-issue-mode`** for the full scout → rolling-dispatch → holding-branch →
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
  the discussion, seeds it as the free-text task (Phase 0 onward), and defines the reply
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
tier available** (see [Model selection reference](#model-selection-reference)). It
reviews three axes independently: architecture, line correctness, and contract fit.
For a diff it reads applicable repository standards plus GOAL.md's Definition of Done and
Global Constraints; clean code cannot mask the wrong behavior or unauthorized scope.

Dispatch it the same way as any other task — one `opencode run` invocation, model passed
with `-m` at invocation:

```bash
opencode run -m "<deep-tier model>" \
  "You are the Head Imp. Read <ARTIFACT_PATH> and argue AGAINST it. \
   Report only what is wrong, missing, or mis-scoped."
```

- **Plan review** happens in Phase 2 Step 3, before the approval gate.
- **Diff review** happens after the merge step in Phase 3, against the merged diff.

It never edits; it returns findings. You act on them.

(On Claude Code the Head Imp is a registered `imps:😈` plan-review agent. OpenCode reviews
the merged diff after deterministic gates.)

### Never pre-judge a reviewer's findings inside its own prompt

You hand-compose the Head Imp's plan-review prompt in Phase 2 Step 3. **Nothing in that
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

Every imps run is keyed by a **slug**, which names its state file, its GOAL.md and its
`.prs.json` under `~/.config/opencode/imps/runs/`. The slug is derived by one script — call it,
never re-derive it inline:

```bash
eval "$("__PLUGIN_ROOT__/scripts/imps-paths.sh")"
```

That sets `REPO_ROOT`, `SLUG`, `RUNS_DIR`, `STATE_PATH`, `GOAL_PATH`, `PRS_PATH` and
`TMP_PREFIX`.

`scripts/imps-paths.sh` is the source of truth (this file used to inline the same
derivation in five places, which drifted). It:

- resolves the working tree with `git rev-parse --show-toplevel`, falling back to
  `${CLAUDE_PROJECT_DIR:-$(pwd)}` only when git cannot answer;
- disambiguates with the remote, so two repos sharing a directory name do not share a
  state file — producing slugs like `seankoji_claude-plugins__claude-plugins`;
- migrates any legacy basename-only state file to the new slug by **renaming only**,
  never overwriting an existing file.

`TMP_PREFIX` is a per-slug prefix for scratch files. Use it for anything you write under
`$TMPDIR` during a run — fixed names like `$TMPDIR/imps-state.json` are shared by every
run on the machine.

**Why the working tree, not the repository.** `--show-toplevel` returns the *worktree*
path, so two worktrees of one repo get two distinct slugs. That is what makes concurrent
runs possible (below), and it is why the derivation must not be keyed to
`CLAUDE_PROJECT_DIR`, which can point at the main checkout from inside a worktree and
silently collapse every run onto one state file. In a main checkout `--show-toplevel`
equals the repo root, so existing runs keep their slug and resume normally.

---

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
STATE_PATH=~/.config/opencode/imps/runs/${SLUG}.json
test -f "$STATE_PATH" && jq -r '.phase, .segment, .branch' "$STATE_PATH"
```

If it exists, tell the user what it says and ask whether to resume or discard:

```
  <"Plan ready — not yet dispatched" | "Run in progress — dispatch loop was interrupted">
  branch: <branch>   phase: <phase>   done: <n>/<total>
```

- **Resume** — jump to **Phase 3 — Dispatch loop**. Its opening step reconciles the
  state file against git ground truth (branches, worktrees, merged commits) before
  dispatching anything, so an interrupted run picks up where it stopped instead of
  re-running finished tasks.
- **Discard** — delete the state file and start from Phase 0. GOAL.md stays; it is the
  human-readable record.

One state file per project slug. Two concurrent runs in the same project will overwrite
each other — finish or discard one first.

## Phase 0 — Brief refinement

Before asking discovery questions, invoke the `prompt-builder` skill to sharpen the task brief (if installed). A well-refined brief reduces decomposition ambiguity and often pre-answers several Phase 1 questions. If `prompt-builder` is not available, refine the brief inline to 1–2 sharp sentences and continue.

**Discussion-seed mode:** skip the "What's the task?" prompt entirely — use
`<DISCUSSION_TASK_SEED>` (built per `references/discussion-mode.md`) as the raw
material below instead of `$ARGUMENTS`.

If `$ARGUMENTS` is empty AND the guard check (above) found no pending state file AND
this is not discussion-seed mode, ask "What's the task?" and wait — collect it here
before invoking prompt-builder.

Use the **Skill tool**:
- `skill`: `prompt-builder:prompt-builder`
- `args`: `MODE: brief-only` as the first line, then a blank line, then the raw task
  description alone (no framing preamble) — `<DISCUSSION_TASK_SEED>` in
  discussion-seed mode, otherwise `$ARGUMENTS` or the collected answer. This sentinel
  opts into prompt-builder's own embedded/brief-only mode (defined in its command
  file), which skips the intro banner, the one-off-vs-reusable reframe, framework
  selection, and the full deliverable template — no steering needed on our side, and
  no diagnosis logic duplicated here. If the installed `prompt-builder` predates this
  mode (ignores the sentinel and runs its full standalone flow), steer once after its
  first response: "Skip model selection, test cases, and save-path guidance — I just
  need 1–2 sharp sentences I can decompose into parallel agents."

Take prompt-builder's `Refined brief: ...` line as `<REFINED_TASK>` directly. If it
instead ran an interactive session (see fallback above), wait for the user to confirm a
refined description before storing it as `<REFINED_TASK>`. Use `<REFINED_TASK>` in
place of `$ARGUMENTS` for all subsequent phases.

---

## Phase 1 — Discovery

Ask the following in a single batched question (skip anything already answered):

1. Which repo/owner is this for?
2. What concrete output artifacts are expected? Be specific — scripts, a GitHub
   Discussion post, a PR, code changes.
3. What are the gate commands (build · lint · test · type)?
4. What is the default branch?
5. Any constraints every task must satisfy?

In discussion-seed mode, the outcome comment on the source discussion is posted by the
finalize step of Phase 4 regardless of the answer to Q2 — that question is only about
artifacts *beyond* that reply.

## Phase 2 — Plan

Using `<REFINED_TASK>` and the discovery answers, produce the authoritative
decomposition. Do the planning at the **deepest reasoning tier available** — on OpenCode
that is a model you select for this session, not a plan-mode routing rule.

**Step 0:** Load learnings from two sources (both optional):
- **User-scoped:** `~/.config/opencode/imps/learnings.md` — stack-agnostic rules
- **Project-scoped:** `.opencode/imps/learnings.md` in the repo root

Read the `## Active rules` section from each that exists. Project-scoped rules win on
conflict. Apply them to tier assignment, task boundaries, and dependency detection.

**Step 1:** Ground the plan in reality — but **delegate the exploration** rather than
doing it in this context: dispatch cheap read-only recon runs for mechanical lookups
(default branch, gate commands, file/symbol enumeration, "where is X"). Read a file
directly only when the plan must quote or reason about its contents. Then:

- **Solo-task check, before decomposing:** if the work is genuinely one atomic unit, write
  a **single-row task table** and go straight to Step 2. This is the same process with a
  smaller DAG — the Head Imp reviews the plan and OpenCode reviews the merged diff, the one task still
  dispatches through the harness into its own worktree, and gates, the persona panel and
  the endstate PR all still run. A one-task run is a first-class outcome, not a fallback.
- Otherwise, break the work into discrete, atomic tasks, each with one clearly-stated
  output and independently completable.
  - **Sizing heuristic:** read `__PLUGIN_ROOT__/references/task-sizing.md` and apply it
    to every task boundary.
- For each task assign:
  - **Spec** — the operative instructions the imp needs to act without improvising:
    concrete inputs (repo/owner, file paths, exact commands), the expected output
    artifact, and any constraints. **Specs must travel with tasks** — a dispatched task
    receives ONLY its state-file entry, never this planning context. Either embed the
    full spec or open it with an explicit pointer ("Read <GOAL_PATH>, section T<N>,
    before acting"). Label-only tasks improvise, and improvised work is how runs produce
    unauthorized artifacts.
    For a bug, regression, flake, performance problem, or unexplained failing gate, the
    installed command text shows an absolute
    `__PLUGIN_ROOT__/references/diagnosis-loop.md` path because the installer replaces that
    placeholder. Copy the resolved absolute path into the durable task spec; never write the
    `__PLUGIN_ROOT__` token itself. Include the known failing command. If none exists,
    constructing and running a red-capable command is the task's first deliverable.
  - **Tier** — assign by reasoning complexity (see
    [Model selection reference](#model-selection-reference)). The tier is resolved to a
    concrete model id and passed with `-m` at dispatch; **never** written into command
    frontmatter. Matrix Item 3 measured that Claude Code's `model:` frontmatter
    convention is not honored by OpenCode, and did not establish a differently-named
    field that is — so no generated artifact here declares one.
  - **Type** — `code` (file changes, worktree-isolated) · `query` (read-only by default;
    add `MUTATIONS_ALLOWED` to the task spec to authorize live mutations) · `publish`
    (GitHub artifacts; use `gh api graphql` for Discussions, not REST)
  - **Oracle** *(optional, `code` tasks only)* — a machine-checkable acceptance command
    that **fails today**. The harness runs `--expect-oracle red` and aborts if the oracle
    is already green at start: a green-at-start oracle cannot distinguish "implemented
    correctly" from "did nothing". Omit it rather than guess one.
  - **Depends-on** — prerequisite task IDs, or `—` if independent. A worktree-isolated
    task is cut from the remote default branch HEAD at spawn time, not from a
    not-yet-merged dependency's branch. If a task needs its dependency's changes, say so
    in the spec.

**Step 2:** Write **`GOAL.md`** to an absolute path under `~/.config/opencode/imps/runs/`
— not the repo root, so the write never needs project-directory access:

```sh
mkdir -p ~/.config/opencode/imps/runs
SLUG=$(basename "$(pwd)")
GOAL_PATH=~/.config/opencode/imps/runs/${SLUG}.md
echo "$GOAL_PATH"
```

Pass the echoed value as the write target. Step 6 re-derives the same `SLUG` (and its own
`STATE_PATH`) independently — shell state does not carry across tool calls. Write with
this structure:

```markdown

# GOAL — <REFINED_TASK (one line)>

## Definition of Done
- [ ] <acceptance criterion 1>
- [ ] <acceptance criterion 2 — one line each from discovery>
- [ ] Gates green (build · lint · test · type — per GATE_CMDS)
- [ ] Head Imp reviewed the plan; OCR reviewed the merged diff; all blocker/major findings addressed
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
`$GOAL_PATH` value echoed in Step 2. It Reads the file itself and argues against the
plan: wrong boundaries, mis-routed tiers, missing deps, gaps in the DoD. Fix what the
critique exposes before proceeding.

**Step 4 — approval gate.** Present the plan and get an explicit yes. Do not dispatch
without it. If the user requests changes, revise `GOAL.md` and re-ask.

**Step 5:** Set `poll_interval_seconds: 300`.

**Step 6:** Cut the run's dedicated working branch, then write the durable state file.
**Never write the branch you happen to be on into the state file** — that includes the
default branch, and doing so is exactly how a run commits every task's work straight onto
the default branch. Always cut a fresh branch off a clean fetch:

```sh
mkdir -p ~/.config/opencode/imps/runs
SLUG=$(basename "$(pwd)")
STATE_PATH=~/.config/opencode/imps/runs/${SLUG}.json
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
- `spec` — required for every task; what the imp actually executes.
- `tier` — `cheap` · `standard` · `deep`, resolved to a model id at dispatch (see
  [Model selection reference](#model-selection-reference)). There is no `model:` field
  anywhere in this plugin's OpenCode artifacts, by design.
- `oracle` — the machine-checkable acceptance command, run in the task's worktree; exit 0
  means done. `null`/absent for an ordinary task.
- `deps` — prerequisite task ids.

Then proceed to Phase 3.

## Phase 3 — Dispatch loop

This is the dispatch backend for OpenCode. On Claude Code everything from here to run
completion is control flow inside one background `Workflow` script; **that tool does not
exist on OpenCode**, so this command runs the loop itself, in the foreground, one task at
a time.

**Step 0 — platform preflight, in this order. Both checks run before any dispatch.**

```bash
[ "$(uname -s)" = "Darwin" ] || {
  echo "imps: refusing to dispatch — the OpenCode dispatch harness sandboxes each run \
with Seatbelt via agent-safehouse, and Seatbelt does not nest, so it is Darwin-only. \
No sbpl fallback is implemented. Run the tasks yourself, or dispatch from macOS." >&2
  exit 1
}
command -v opencode >/dev/null || { echo "imps: opencode is not on PATH" >&2; exit 1; }
```

That `uname -s` check is the **only** refusal branch in this command. Its reason is
recorded in `docs/platform-matrix.md` Item 9 ("Sandboxed execution").

**Known unknown — the headless bash permission gate.** OpenCode's `permission.bash` map
defaults to `"*": "ask"`. What a *headless* `opencode run` does when a dispatched task
hits a bash call with no matching allow-rule is recorded as
`OPENCODE_BASH_GATE: unmeasured` in the matrix's "PR 2 re-verification" section: the
original 60-second hang that looked like a silent permission stall was refuted by a
positive control (a run needing no permission at all hung identically), so the hang is
environmental and the gate's real behaviour is simply **not measured**. This is prose, not
a branch — there is deliberately **no** generated refusal for it. Practical consequence:
if dispatched tasks stall with no output, suspect the gate, and add the allow-rules your
tasks need to your own `opencode.json` under `permission.bash`. **This plugin never adds
them for you and never bypasses these prompts with an unattended-override flag.**

**Step 1 — reconcile.** Read the state file. Cross-check it against git ground truth
before trusting it — `git branch --list`, `git worktree list`, and the merge state of the
run branch. A task listed in `tasks_done` whose branch does not exist did not run;
a branch that exists for a task not in `tasks_done` did. Ground truth wins; correct the
state file, then continue. Never route on a state file that disagrees with git.

**Step 2 — stage the DAG.** Topologically sort `tasks` by `deps` into stages. Tasks in a
stage are independent of each other; stages run in order. OpenCode dispatch is
**serial** — there is no parallel agent primitive here — so a stage is a batch you run
one after another, not concurrently.

**Step 3 — dispatch each task.** There is exactly **one** OpenCode dispatch path: the
existing `opencode-dispatch.sh` oracle-loop harness. Do not invent a second one.

```bash
python3 - <<'PY' > "$TMPDIR/imps-task.md"
# write the task prompt: its spec, its oracle, and the pointer
#   Read <GOAL_PATH> section "Global Constraints" before acting
PY

bash "$IMPS_HARNESS" \
  --task-id "<id>" \
  --prompt-file "$TMPDIR/imps-task.md" \
  --model "<the tier's resolved model id>" \
  --expect-oracle red \
  --oracle "<the oracle command, if any>"
```

**Where `$IMPS_HARNESS` comes from.** `opencode-dispatch.sh` and its Seatbelt wrapper
`sandbox-wrap.sh` are **deliberately not bundled into this generated artifact**: they
resolve the `agent-safehouse` binary through Homebrew prefixes and canonicalise the home
directory, and no generated artifact may carry an absolute machine path. They ship in the
`claude-plugins` checkout under `plugins/imps/scripts/`, documented in
`plugins/imps/references/opencode-harness.md`. Point `$IMPS_HARNESS` at that checkout's
copy. If you do not have it, dispatch is unavailable — run the tasks yourself rather than
improvising a second dispatch mechanism.

The harness owns worktree creation, the Seatbelt sandbox, the oracle loop, and its own
attempt cap; it returns a JSON result. Read it and record:
- success → append the id to `tasks_done`, record the branch under `worktrees`
- failure or abort → append `{ id, reason }` to `failed_tasks`

**The model tier is passed here, at invocation, with `-m`** (the harness forwards
`--model` to `opencode run -m`). It is never declared in frontmatter — matrix Item 3
measured that OpenCode does not honor Claude Code's `model:` convention, and did not rule
out some differently-named field, so this plugin emits none and resolves the tier at
dispatch instead. Resolve it through the order in
[Model selection reference](#model-selection-reference) — operator env pin first, then the
tier table, then the session model — and record the id you used with the task's result.

Heartbeat `last_heartbeat` and `tasks_done` into the state file as each task returns, so
an interrupted loop can be resumed by Step 1 rather than restarted.

**Step 4 — merge.** After each stage, merge its task branches into the run branch, in
task-id order, one at a time. On conflict, stop the loop and surface the branch plus the
conflicting paths — do not resolve silently. After merging, do not trust the recorded
worktree path alone: check `git status --short` and `git log --oneline -3` in the real
checkout before assuming the tree is clean.

**Step 5 — diff review and gates.** The Head Imp reviews the plan only. Review the merged
diff against GOAL.md after gates with the runtime's independent OpenAI-lineage reviewer.
Fix blocker/major findings, rerun all gates, and use a fresh review session. A reviewer
failure blocks: never silently fall back to Claude. **The five-persona panel runs only when
`--personas` was passed** (`PERSONA_PANEL` true).

## Phase 4 — Decision points

The loop stops at a decision point rather than guessing. Each one is a question to the
operator; the answer is persisted into the state file's `operator_decision` field so an
interrupted session resumes from it:

```bash
jq --arg d '<decision>' '.operator_decision = $d' \
  ~/.config/opencode/imps/runs/<slug>.json > "$TMPDIR/imps-state.json" \
  && mv "$TMPDIR/imps-state.json" ~/.config/opencode/imps/runs/<slug>.json
```

Decision vocabulary: `resolved, continue` · `retry <gate>: <guidance>` · `skip <gate>` ·
`reconciled, continue` · `retry tasks #N,#M: <guidance>` · `skip tasks #N,#M` ·
`integrate partial` · `retry findings` · `override findings: <rationale>` · `PR: yes` ·
`PR: yes, no-post` · `PR: no` · `learnings: <json|none>` · `abort`.

**The anti-pre-judging rule applies to every guidance string you compose here.**
Guidance says *what* failed and *how*; it never says what the reviewer should conclude.
"This is fine now", "don't flag the sizing again", "just get it to APPROVE" are
pre-judgments. If you want a finding overruled, `override findings:` does it **on the
record**; `skip <gate>` and `skip tasks #N` are the equivalents at the other gates. All
three leave a trace. Steering a reviewer's prompt leaves none.

**Blocked states:**
- `dispatch_failed` — preflight rebase conflict, or the harness aborted. Fix the tree,
  then `resolved, continue` or `abort`.
- `imps_failed` — failed tasks block the DoD. `retry tasks #N: ...`, `skip tasks #N`,
  `integrate partial`, or `abort`.
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
thread, so the PR must exist first. Ask once branches are merged, the independent diff
review has approved, and gates are green:

1. `Push & open PR, personas post live reviews`
2. `Push & open PR, findings only (no persona posts)`
3. `Not yet` — no push, no PR; findings return inline and the branch stays local.

Without `--personas` there is no panel to post: option 1 collapses into a plain
`Push & open PR` and no persona posting happens either way — the PR still opens for
whatever GitHub-side review the repo runs. The `unresolved_findings` state and the
`retry findings` / `override findings:` verbs below cannot occur on a panel-less run.

**Self-review disclosure.** If this session wrote code directly into the diff during the
Head Imp fix loop, say so before asking. Persona posting under dedicated GitHub App
identities (`__PLUGIN_ROOT__/references/persona-posting.md`) is attribution and audit
trail only; it is not an independent review of content this same session authored. Pushing
and PR creation is a separate authorization from letting personas post live reviews — one
does not imply the other.

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
  verdicts:  solution-architect APPROVE (posted) · grumpy-engineer APPROVE (inline) · ...
  PR:        <url, "ready for review"> | "no PR — branch is local"
```

Tag each verdict with how it was delivered — `(posted)` for a real GitHub review under
that persona's own identity, `(inline — <reason>)` when it fell back. A partial panel must
never read as full independent sign-off.

Then the **learnings gate**, its own explicit step: present any candidates, persist
`learnings: [...]` or `learnings: none`, append the confirmed ones to the user- or
project-scoped `learnings.md`, and only then delete the state file. GOAL.md stays — it is
the human-readable record.

If `pr` is non-null, invoke `/imps-prs` to start the PR monitor. If it is null, say:
"Branch is local only and no PR was opened — push and open a PR, then invoke `/imps-prs`
to activate the monitor."

## Design note — why resume is a state-file read, not a platform feature

Resume here is deliberately a **state-file reconciliation**, not anything the platform
provides: Phase 3 Step 1 re-reads the state file and cross-checks it against git before
dispatching. Idempotency for side-effecting steps has two sources — **merge** relies on
`git merge` of an already-merged branch being a no-op, and **PR creation, persona posting
and the learnings append** each check an explicit persisted marker in the state file
(`pr`, `verdicts`, `discussion_comment_url`, `learnings_saved`) before acting.

(On Claude Code the same design holds for a different reason: that platform's
`Workflow` resume feature is same-session-only and prefix-cached, so it could not survive
a new session and would defeat the duplicate-post guards. OpenCode has no equivalent
feature to decline in the first place.)

## Model selection reference

Assign by reasoning complexity, not duration or volume. Tasks carry a **tier**, not a
model name:

| Tier | Use for | Resolved at dispatch to |
|------|---------|-------------------------|
| `cheap` | mechanical work — deterministic output, no judgment | the small model configured for this session, else the session model |
| `standard` | judgment — context, decisions, synthesis | the session model |
| `deep` | deep judgment — large decision space, architectural tradeoffs | the strongest model you have configured |

The tier is resolved to a concrete model id and passed as `opencode run -m <id>` **at
invocation**, by the dispatch step. It is never written into command frontmatter: matrix
Item 3 measured that OpenCode does not honor Claude Code's `model:` frontmatter
convention. That item did **not** rule out some differently-named OpenCode field, so
emitting none is a deliberate safe default here rather than a settled platform fact.

OpenCode model ids are provider-scoped strings (`provider/model`). Read the ids available
in this session from `opencode models` rather than hardcoding any — and note that Claude
Code's short tier aliases name no model on this platform at all.

**Resolution order, and the documented override.** For each tier, in order:

1. `$IMPS_TIER_MODEL_CHEAP` / `$IMPS_TIER_MODEL_STANDARD` / `$IMPS_TIER_MODEL_DEEP`, if
   set — the operator's explicit pin. It is passed to `-m` verbatim; nothing is inferred
   from it, and no tier is derived from its name.
2. The tier's row in the table above, resolved against `opencode models`.
3. The session model, for every tier — the safe fallback when nothing else resolves. Say
   which tier fell back to it in the dispatch log rather than resolving silently.

Never substitute a *stronger* model for a `cheap` task to make it pass; that hides a
mis-tiered task. Re-tier it in the task table instead, where the operator can see it.

## Constraints

- Never start the dispatch loop without explicit approval of the task list (Phase 2
  Step 4 is that gate).
- Never `git merge --force`, `git reset --hard`, or `git push` without explicit user
  instruction — **exceptions**: (1) after plan approval the dispatch loop rebases the run
  branch and merges task branches autonomously, and it pushes and opens the endstate PR
  only after one of the `Push & open PR …` answers is persisted; (2) the `/imps-prs`
  monitor pushes fix commits to the PR branch once activated.
- Never create GitHub PRs without user instruction — the Push & PR gate in Phase 4 is that
  instruction for the endstate PR.
- Persona live-posting is a separate authorization from push/PR creation, not implied by
  it — only the `personas post live reviews` answer authorizes real GitHub reviews.
- **Never bypass permission prompts with an unattended-override flag, and never write
  permission allow-rules into a user's `opencode.json` on their behalf.** Document what a run needs and let the
  operator add it.
- If a task touches a production system, pause and confirm before that task runs.
- Worktree isolation is not airtight — after each merge step, check `git status --short`
  and `git log --oneline -3` in the actual checkout before assuming the tree is clean.
- Never bypass commit signing because the signing agent looks locked or contended —
  that's usually transient. Retry with a short pause before surfacing it as blocked.
