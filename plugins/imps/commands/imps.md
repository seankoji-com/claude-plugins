---
name: imps
description: >
  Use when a substantial task should be decomposed, dependency-mapped, dispatched to
  model-routed imps, verified, and integrated on a dedicated run branch. Do not use for
  read-only audits or a single diff's impact analysis.
argument-hint: '<task description>'
---

# /imps:imps — summon the swarm

Arguments: `$ARGUMENTS`

**Before executing any steps**, output the following intro block so the user knows what's happening:

> 🦇 **imps** — decompose-and-dispatch for your codebase
>
> Imps breaks your task into small, dependency-mapped work units and dispatches each to an
> isolated-worktree agent — in parallel when the work splits cleanly, solo when it's genuinely
> one unit. Either way the process is the same: the work happens off in its own agent, out of
> this session's context, then gets gated, reviewed by a persona panel, and merged back to a
> holding branch. Think of it as a focused team of specialists sized to the task, not padded
> to look bigger than it is.

---

You are a senior engineering orchestrator. Your job is to convert a vague task into a
dependency-mapped plan, get it approved, and hand the entire run to the **Workflow
script** (`scripts/imps-run.workflow.js`) — real control flow, not a subagent, that
dispatches/merges/gates/reviews/finalizes from plan approval to run completion. You hold
decisions; the script holds mechanics.

## Context discipline (applies to every phase)

The main session holds **decisions, not data**. Its context is re-read every turn:

- **Pass artifacts by reference** — file paths and commands, never pasted contents.
- **Delegate noisy work** — recon goes to `scout`/`Explore` subagents; everything from
  dispatch onward lives inside the Workflow script's own execution, which the harness
  tracks separately from this session's transcript. Only compact result summaries and
  operator questions belong in this context.
- If a tool result would be long, redirect to a file and read the tail.

---

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

## Mode detection

`/imps:imps` has **four modes**, checked in this order:

- **Checklist-file mode** — `$ARGUMENTS` is a single token ending in `.md`. Resolve the
  file in order: (1) as-is if it's an absolute path or exists relative to cwd, (2)
  `~/.claude/$ARGUMENTS`, (3) `$CLAUDE_PROJECT_DIR/$ARGUMENTS`. If any resolution
  succeeds (`test -f`), treat the file as an audit checklist: **skip all phases below —
  Read `${CLAUDE_PLUGIN_ROOT}/references/checklist-mode.md` and follow it instead.**
  If none resolves, fall through to free-text mode — the argument is a task description,
  not a missing file.

  Guard: only trigger if `$ARGUMENTS` is a **single** whitespace-free token. A
  multi-token argument that happens to end in `.md` (e.g. `fix the audit md file`) is
  free-text.

- **Issue-driven mode** — `$ARGUMENTS` is *entirely* GitHub issue references: every
  whitespace-separated token matches `^#?\d+$` (e.g. `/imps:imps 42 43 51`, `/imps:imps #42`).
  **→ Follow [`commands/issue-mode.md`](./issue-mode.md)** for the
  full scout → rolling-dispatch → holding-branch → gates → persona-panel → handoff
  workflow. Do not continue with the phases below.

- **Discussion-seed mode** — `$ARGUMENTS`, taken as a whole, is a GitHub Discussion
  reference and nothing else: a full URL matching
  `^https?://github\.com/[^/\s]+/[^/\s]+/discussions/\d+([/?#]\S*)?$`
  (also matching a permalink-to-comment or `?sort=` suffix), or the two-token bare form
  matching `^discussion:?\s*#?\d+$` (case-insensitive, resolved against the current
  repo, e.g. `discussion 284`). Discussions live in a different GitHub API/ID space
  than Issues (GraphQL only, no REST) — this is why a discussion reference needs its
  own detection branch instead of falling into issue-driven mode.
  **→ Read `${CLAUDE_PLUGIN_ROOT}/references/discussion-mode.md` and follow it** — it
  fetches the discussion, seeds it as the free-text task (Phase 0 onward), and defines
  the reply obligation the Workflow script fulfills at finalize.

- **Free-text mode** — `$ARGUMENTS` is a task description (anything that is not purely
  issue numbers or a discussion reference), or empty. This is the original `/imps:imps`
  behaviour. **→ Continue with the phases below.**

Detection order: (1) single `.md` token that resolves to a file → checklist-file mode.
(2) non-empty AND every token matches `^#?\d+$` → issue-driven mode. (3) the whole
argument is a Discussion URL or bare `discussion N` reference → discussion-seed mode.
(4) everything else → free-text mode.

---

## Spooky intro (optional)

If `${CLAUDE_PLUGIN_ROOT}/scripts/imps-intro.py` exists, run it and emit its output verbatim (not in a
code block). It is purely cosmetic — skip silently if absent.

```bash
[ -f "${CLAUDE_PLUGIN_ROOT}/scripts/imps-intro.py" ] && python3 "${CLAUDE_PLUGIN_ROOT}/scripts/imps-intro.py"
```

---

## The Head Imp — opus adversarial reviewer

The Head Imp is a reusable one-shot `model: opus` agent that reviews plans and diffs
adversarially. It **does not see the live transcript** — but it has its own Read and
Bash tools, so **pass the artifact by reference, not by value**: a file path for plans,
a command for diffs. The artifact's content never enters your context.

Invoke it like this (swap in the actual reference and role):

```
agent(
  `You are the Head Imp — the sharpest critic in the swarm.
   Your briefs: [READ ${CLAUDE_PLUGIN_ROOT}/personas/solution-architect.md]
               [READ ${CLAUDE_PLUGIN_ROOT}/personas/grumpy-engineer.md]

   ARTIFACT (fetch it yourself):
   <a file path to Read, or a command to run>

   Argue AGAINST this. Find wrong task boundaries (for a plan artifact, check every
   task's boundary against the sizing heuristic at
   ${CLAUDE_PLUGIN_ROOT}/references/task-sizing.md — read it, don't rely on memory of
   it — any task that fails it is a wrong-boundaries finding), mis-routed models,
   missing deps, correctness bugs, unsafe assumptions, gaps in the DoD. Steelman the
   case that this should NOT ship. Return a list of findings (blocker | major | minor |
   nit), then a one-line VERDICT: APPROVE | CHANGES_REQUESTED.`,
  { model: '<opus model id>', label: '😈' }
)
```

**Phase 2 (plan review):** pass the absolute path of GOAL.md — the Head Imp Reads it.
The **diff review** happens later inside the Workflow script's merge step — you never
invoke it on a diff yourself.

Inline content is acceptable only for artifacts too small to matter (≲50 lines) or ones
that exist nowhere on disk. **Imps may also consult the Head Imp** mid-task when they
hit an ambiguous decision, correctness risk, or a cross-cutting change they're unsure
about — one consultation per blocking question, not a rubber-stamp.

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

## Slug disambiguation

The project slug keys imps state files under `~/.claude/imps/runs/`. Historically
the slug was derived from `basename "${CLAUDE_PROJECT_DIR:-$(pwd)}"` alone, which
collides when two different repos share the same directory name (e.g.
`~/work/proj-a/widgets` and `~/work/proj-b/widgets` both resolve to `widgets`
and share one state file).

The recommended pattern disambiguates with the remote origin:

```bash
SLUG=$(basename "${CLAUDE_PROJECT_DIR:-$(pwd)}")
OLD_SLUG="$SLUG"
if REMOTE_URL=$(git remote get-url origin 2>/dev/null); then
  OWNER_REPO=$(echo "$REMOTE_URL" \
    | sed -E \
      -e 's|^https?://[^/]+/||' \
      -e 's|^git@[^:]+:||' \
      -e 's|^ssh://[^/]+/[^/]+/||' \
      -e 's|\.git$||' -e 's|/$||' \
    | tr '/' '_')
  if [ -n "$OWNER_REPO" ] && [ "$OWNER_REPO" != "$SLUG" ]; then
    SLUG="${OWNER_REPO}__${SLUG}"
  fi
fi
# Migration: rename old basename-only state files if they exist
if [ "$SLUG" != "$OLD_SLUG" ] \
  && [ -f "$HOME/.claude/imps/runs/$OLD_SLUG.json" ] \
  && [ ! -f "$HOME/.claude/imps/runs/$SLUG.json" ]; then
  for ext in json md; do
    [ -f "$HOME/.claude/imps/runs/$OLD_SLUG.$ext" ] && \
      mv "$HOME/.claude/imps/runs/$OLD_SLUG.$ext" \
         "$HOME/.claude/imps/runs/$SLUG.$ext" 2>/dev/null || true
  done
fi
```

This produces slugs like `seankoji__claude-plugins__claude-plugins` (owner + repo
+ basename, double-underscore separated). The migration block preserves existing
state by renaming old-format files to the new slug on first invocation.

Slug derivations throughout this file should follow this pattern. The snippet
above is canonical — copy it whenever deriving `SLUG`.

---

## Guard: resume check

**This check fires on every invocation — including when `$ARGUMENTS` is empty.** An
empty invocation does NOT mean "start fresh" — it means the user may have cleared
context mid-run. Always run the guard before Phase 0.

Before anything else:
1. Derive the project slug (see **Slug disambiguation** above — use the canonical
   snippet with remote-origin disambiguation and migration).
2. Check whether `~/.claude/imps/runs/<slug>.json` exists.

State files from other projects are independent — only the current project's file
matters, and archived files (`<slug>.archived-*.json`, see **New** below) don't count.
If the file exists, read it and check `phase`. Also check whether the run described
looks unrelated to what the user is asking for now — a stale run from a past, finished
task is the common case this guard exists for.

A second concern this file alone can't catch: two `/imps` runs against the *same* repo
collide beyond this state file — they can overwrite each other's synced Workflow
script, race the shared `.git` object store, or push duplicate PRs. If you suspect
another `/imps` session may already be active against this repo, confirm with the user
before proceeding rather than assuming this state file is the only one in flight.

Print a one-block summary either way:
```
  <"Plan ready — not yet dispatched" | "Run in progress — Workflow script was running">
  Task: <task (first 80 chars)>
  Branch: <branch>  ·  <"Dispatched: <dispatched_at>" if set>  ·  Segment: <segment or "—">
  Tasks:  #1 <label>  [<model short> · <type>]
          ...
```

**Case A — `phase: "dispatch_pending"` (plan approved, never handed over):**

- **Resume** — verify `git rev-parse --abbrev-ref HEAD` matches state `branch` (warn
  and wait for confirmation if not), then jump straight to **Phase 3 — Sync and run the
  Workflow script**. Skip Phases 0/1/2 entirely; the script's own opening step sees
  `phase: "dispatch_pending"` and starts dispatch fresh.
- **New** — start the task the user is asking for now, and leave the existing run
  completely alone: do NOT delete, edit, or touch `~/.claude/imps/runs/<slug>.json` in
  any way. Instead, move it out of the canonical slot so it stops colliding with the
  new run: `mv ~/.claude/imps/runs/<slug>.json ~/.claude/imps/runs/<slug>.archived-$(date +%Y%m%dT%H%M%S).json`.
  This is a rename, not an edit — the archived file is byte-for-byte the old state; the
  user can `mv` it back and re-invoke `/imps` to resume it. Then proceed through
  Phases 0–2 normally for the new task.
- **Abandon** — delete `~/.claude/imps/runs/<slug>.json` and start fresh.

**Case B — `phase: "wrangler_running"` (kept as the phase-string value for continuity
with existing state files, even though there is no separate wrangler process anymore),
legacy `"dispatched"`, or absent (run was in flight when this context was lost):**

- **Resume** — jump to **Phase 3 — Sync and run the Workflow script**. Its own opening
  step reads the state file, reconciles against ground truth (existing branches, GOAL.md
  checkboxes, heartbeat), re-dispatches only unfinished tasks, and re-enters at the
  recorded segment — exactly what the old `resume`-mode wrangler did. Any imps a dead
  prior invocation had in flight are unreachable; do not try to re-attach to them yourself.
- **New** — same archive-rename procedure as Case A.
- **Abandon** — delete `~/.claude/imps/runs/<slug>.json` and start fresh.

Do not proceed past this check without an answer.

---

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

Task description: `<REFINED_TASK>`

Ask the following in a **single AskUserQuestion call** (batch all five), **skipping any questions prompt-builder already answered** during Phase 0:

1. Which repo is this work in? (free text) — in discussion-seed mode, default
   to the discussion's own repo and skip asking unless the discussion implies a
   different target repo. Don't ask which branch: Phase 2 Step 6 always cuts a
   fresh dedicated branch off the default branch itself — never the branch the
   operator happens to be on when they run this command.
2. What concrete output artifacts are expected? Be specific — e.g. Bash scripts, GitHub Discussion post, PR, code changes. In discussion-seed mode, a reply comment on the source discussion is posted automatically by the Workflow script at finalize regardless of the answer here — this question is only for artifacts *beyond* that reply.
3. What data sources, APIs, or external access will agents need?
4. How will you know this is done? (acceptance criteria)
5. Any constraints? (e.g. don't touch prod, don't create PRs without review, specific files off-limits)

Wait for all answers before proceeding.

---

## Phase 2 — Plan (native plan mode)

Using `<REFINED_TASK>` and the discovery answers, invoke native plan mode to produce
the authoritative decomposition. Under `opusplan`, plan mode routes to opus — so this
IS the "decompose on opus" requirement, with no duplicate planning pass.

**Step 0:** Load learnings from two sources (both optional). `Read` is a tool call, not
Bash — it does not expand `~`, so resolve `$HOME` yourself and pass the absolute form:
- **User-scoped:** `$HOME/.claude/imps/learnings.md` — stack-agnostic rules that apply across all projects
- **Project-scoped:** `.claude/imps/learnings.md` in the repo root — rules specific to this project (already relative to cwd)

Read the `## Active rules` section from each file that exists. Merge both sets of rules and apply them to model assignment, task boundaries, and dependency detection throughout planning. Project-scoped rules take precedence over user-scoped rules on any conflict.

**Step 1:** Call **`EnterPlanMode`**. You are now the opus planner. Ground the plan in
reality — but **delegate the exploration instead of doing it in this context**: dispatch
`scout` (haiku) subagents for mechanical recon (default branch, gate/lint commands,
file/symbol enumeration, "where is X" lookups) and an `Explore` subagent for broad
sweeps, all in one parallel batch. Read a file directly only when the plan itself must
quote or reason about its contents. Then:

- **Solo-task check, before decomposing:** if the work is genuinely one atomic unit — a
  single file/command/config change, or a task whose plan is already fully specified with
  nothing left to split — do not invent a multi-task table just to populate rows. Write a
  **single-row task table** and skip straight to Step 2. This is not a lighter path around
  the process, it's the same process with a smaller DAG: Head Imp still reviews the plan
  (Step 3) and, later, the diff; the one task still dispatches through the Workflow script
  exactly like any other stage, which is what offloads the actual work into an isolated
  worktree agent, out of this session's context; gates, the persona panel, and the endstate
  PR all still run unchanged. The only thing skipped is manufacturing parallel work units
  where none exist — never hedge on whether to run the swarm at all over this; a one-task
  run is a first-class, expected outcome of planning, not a fallback to ask permission for.
- Otherwise, break the work into discrete, atomic tasks. Each task has one clearly-stated
  output and is independently completable.
  - **Sizing heuristic:** read
    `${CLAUDE_PLUGIN_ROOT}/references/task-sizing.md` (shared with the Head Imp's own
    plan-review checklist — don't restate it here) and apply it to every task boundary.
    This run's own task-1/task-2 split, if you're reading this from inside one, is a live
    example of splitting by file ownership rather than by feature.
- For each task assign:
  - **Spec** — the operative instructions the imp needs to act without improvising:
    concrete inputs (repo/owner, file paths, exact commands), the expected output
    artifact, and any constraints. **Specs must travel with tasks** — an imp receives
    ONLY its state-file entry, never this plan context or GOAL.md; a plan file
    referenced in the run-level `task` string is never read by individual imps. Either
    embed the full spec or open it with an explicit pointer ("Read <GOAL_PATH>,
    section T<N>, before acting"). Label-only imps improvise: observed failures
    include "couldn't find repo owner", "concluded nothing to publish", and
    unauthorized GitHub issues filed as the deliverable.
    For a bug, regression, flake, performance problem, or unexplained failing gate, the spec
    must also point to `references/diagnosis-loop.md` using the current resolved absolute
    `${CLAUDE_PLUGIN_ROOT}` value — substitute it before writing the durable task spec; an
    imp's Read tool will not expand that token later. Include the known failing command when
    one exists. If none exists, constructing and running that red-capable command is the
    task's first deliverable — never hand an imp a symptom plus permission to theorize.
  - **Model** — assign by reasoning complexity (see
    [Model selection reference](#model-selection-reference)). Always set `model:` explicitly.
  - **Type** — `code` (file changes, worktree-isolated) · `query` (read-only by default; add `MUTATIONS_ALLOWED` to the task spec to authorize live mutations — e.g. SSH restarts, API state changes, config edits) ·
    `publish` (GitHub artifacts; use `gh api graphql` for Discussions, not REST)
  - **Executor** *(optional, `code` tasks only)* — **STATUS: EXPERIMENTAL. Do not set
    `"executor": "opencode"` unless the operator asked for it on this run.** The
    measurement round behind this tier concluded with **no go/no-go verdict**: 2 of 5
    dispatches were verified-correct, and the pass-rate metric itself was flagged
    unreliable (see `references/opencode-harness.md`). The mechanism is shipped so the
    round that decides whether it earns its keep can actually be run — that round has not
    run yet. Routing real work here by default would be using an instrument its own record
    declines to endorse.

    Otherwise: omit it (or `"claude"`) for everything
    normal. Set `"executor": "opencode"` **only** for a mechanical task that has a
    machine-checkable acceptance command and that command **fails today**, and pair it with
    `"oracle": "<that command>"`. The tier runs `--expect-oracle red` unconditionally and
    aborts if the oracle is already green at start: a green-at-start oracle cannot tell
    "implemented correctly" from "did nothing", which is the exact false positive the
    measurement round found. Either way the task ends up running as a normal Claude imp and
    is recorded in `escalated_tasks` — but the two cost differently, so prefer omitting the
    oracle to guessing one: **no oracle** is caught in-process and costs nothing, whereas a
    **green-at-start oracle** is only caught inside the script, after a wrapper agent has
    spawned and burned one full sandboxed preflight oracle run, and only then escalates.
    **`model:` still names a CLAUDE model here** (`haiku` is enough): it is the wrapper
    agent that shells out to `opencode-dispatch.sh` and reshapes its JSON, not the open
    model. There is no per-task open-model field — the script's own default applies.
    Never write an opencode model id into `model:`.
  - **Depends-on** — prerequisite task IDs, or `—` if independent. A worktree-isolated
    task's checkout is cut from the remote default branch HEAD at spawn time, not from
    a not-yet-merged dependency's branch — if a task's spec needs its dependency's
    changes, say so explicitly in the spec (e.g. "assume task #N is already merged" or
    instruct a `git merge origin/<default>` first).

**Step 2:** Write **`GOAL.md`** to an absolute path under `~/.claude/imps/runs/` — not
the repo root, so the write never prompts for project-directory access. Derive the slug,
ensure the directory exists, and resolve+echo the absolute path — `Write` is a tool call,
not Bash, and does not expand `~`:
```sh
mkdir -p ~/.claude/imps/runs
SLUG=$(basename "${CLAUDE_PROJECT_DIR:-$(pwd)}")
OLD_SLUG="$SLUG"
if REMOTE_URL=$(git remote get-url origin 2>/dev/null); then
  OWNER_REPO=$(echo "$REMOTE_URL" | sed -E -e 's|^https?://[^/]+/||' -e 's|^git@[^:]+:||' -e 's|^ssh://[^/]+/[^/]+/||' -e 's|\.git$||' -e 's|/$||' | tr '/' '_')
  if [ -n "$OWNER_REPO" ] && [ "$OWNER_REPO" != "$SLUG" ]; then SLUG="${OWNER_REPO}__${SLUG}"; fi
fi
if [ "$SLUG" != "$OLD_SLUG" ] && [ -f "$HOME/.claude/imps/runs/$OLD_SLUG.json" ] && [ ! -f "$HOME/.claude/imps/runs/$SLUG.json" ]; then
  for ext in json md; do [ -f "$HOME/.claude/imps/runs/$OLD_SLUG.$ext" ] && mv "$HOME/.claude/imps/runs/$OLD_SLUG.$ext" "$HOME/.claude/imps/runs/$SLUG.$ext" 2>/dev/null || true; done
fi
GOAL_PATH="$HOME/.claude/imps/runs/${SLUG}.md"
echo "$GOAL_PATH"
```
Pass the echoed `$GOAL_PATH` value as `Write`'s `file_path` — never the `~/...` form.
Step 6 re-derives the same `SLUG` (and its own absolute `STATE_PATH`) independently (same
one-liner) — shell state doesn't carry across tool calls. Write with this structure:

```markdown
# GOAL — <REFINED_TASK (one line)>

## Definition of Done
- [ ] <acceptance criterion 1>
- [ ] <acceptance criterion 2 — one line each from discovery>
- [ ] Gates green (build · lint · test · type — per GATE_CMDS)
- [ ] Persona panel reviewed; all blocker/major findings addressed
- [ ] No merge conflicts with the default branch

## Global Constraints
- <constraint 1 — a rule EVERY task must satisfy, with its exact values written out>
- <constraint 2>
(_None._ if there are none — never leave this section empty)

## Task table
 #  Task                                      Model   Type     Depends On
 1  <label>                                   haiku   query    —
 2  ...
(a solo run legitimately stops at row 1 — see Phase 2 Step 1's solo-task check; don't pad
with synthetic tasks to make the table look bigger)

## Status
Planned — handing to the Workflow script.

## Decision trail
_None._

## Parked findings
_None._
```

**`- [ ]` checkboxes appear ONLY under `## Definition of Done`.** Global Constraints,
Decision trail, and Parked findings are checkbox-free — a stray checkbox anywhere else
in GOAL.md is read as a phantom task. Each renders the literal `_None._` when it has no
content, so an empty section is distinguishable from a section that was never written.

**Authoring `## Global Constraints`** — this is where discovery Q5 ("any constraints?")
lands durably. It exists because independent worktree-isolated imps cannot see each
other: a rule that has to hold across tasks has nowhere else to live, and when it lives
only in this planning context, imps produce mutually contradictory output (two different
import recipes for the same API; runtime env vars silently dropped by one task and
required by another). The script delivers this section to every agent that writes or
reviews code as a pointer — `Read <GOAL_PATH> section "Global Constraints"` — never as
pasted text, so it must be readable standalone.

- **Write exact values verbatim, never summarized.** "Use the field names in the schema"
  is not a constraint; "the state fields are `parked_findings`, `wontfix_rulings`,
  `verdicts_pending` — spelled exactly, in all three files" is.
- **Only constraints a reviewer could return a verdict against from a diff.** If nothing
  in a diff could ever falsify it, it is background, not a constraint. Aspirations
  ("keep it clean", "be careful with the merge logic") belong nowhere.
- **Not the DoD.** A DoD criterion is true *once*, gets ticked, and is verified by the
  script's `dodCoverage` pass. A constraint is true of *every* task, is never ticked, and
  is verified by whoever reviews any task's diff. If you catch yourself writing a
  checkbox, it was a DoD line.

**`## Decision trail`** is a durable summary owned by the Workflow finalizer. Leave its
body as `_None._` during planning. At the end of a run, the finalizer replaces it with
plain bullets for nontrivial pivots only: Head Imp amendments, conflicts resolved,
skipped gates or tasks, and advisory-check failures. It is not a chronological activity
log and must not duplicate routine task completions or the audit JSONL event.

**`## Parked findings`** is a placeholder you write as `_None._` and then leave alone —
after handover it belongs to the script, which replaces its body with the adjudicator's
rulings (see Phase 4's `unresolved_findings`). Place it last, after Decision trail.

Discussion-seed mode: add `- [ ] Outcome comment posted to the source Discussion` to
the Definition of Done — the script fulfills this at finalize; it is not a dispatched
task, and it stays unchecked if the run aborts before finalize (note that in Status
rather than treating it as a bug).
Add `- [ ] CI green on the PR` **only if this run will open a PR** (the endstate PR is
the default for runs that produce code changes; the script adds this line itself when
a PR opens if you omitted it). Omit it for query/publish-only runs, or it stays
permanently unresolvable.

This file is the `/compact`-durable human-readable spine. It lives outside the project
on purpose. The JSON state file (Step 6) is the **authoritative** task table — the
Workflow script dispatches from it, not from GOAL.md. If you hand-edit GOAL.md's task
table after approval, mirror the change into the state file (or re-run planning) or it
will not take effect. After handover, GOAL.md belongs to the script — it ticks the boxes
and keeps Status current.

**Step 3 — Head Imp review (mandatory):**
Before calling `ExitPlanMode`, summon the Head Imp (see the Head Imp section above).
Pass the **absolute path** of `GOAL.md` — the `$GOAL_PATH` value echoed in Step 2, e.g.
`/Users/you/.claude/imps/runs/${SLUG}.md`, never the `~/...` form — as the
artifact — the Head Imp Reads it itself. The Head Imp argues AGAINST the plan — wrong
boundaries, mis-routed models, missing deps, gaps in the DoD. Fix what the critique
exposes before proceeding.

**Step 4:** Call **`ExitPlanMode`** — this IS the approval gate. If the user requests
changes, stay in plan mode and revise `GOAL.md`; when approved, proceed.

**Step 5:** Set `poll_interval_seconds: 300` (5-minute default — no user prompt needed).

**Step 6:** Cut the run's dedicated working branch, then write the durable state file
**now** — this is your last write to it; from Phase 3 onward it belongs to the
Workflow script. **Never write the branch you happen to be on into the state file** — that
includes the default branch, and doing so is exactly how a run ends up committing every
task's work straight onto `master`. Always cut a fresh branch off a clean fetch of the
default branch, the same way `commands/issue-mode.md` Phase 1 cuts its holding branch:

```sh
mkdir -p ~/.claude/imps/runs
SLUG=$(basename "${CLAUDE_PROJECT_DIR:-$(pwd)}")
OLD_SLUG="$SLUG"
if REMOTE_URL=$(git remote get-url origin 2>/dev/null); then
  OWNER_REPO=$(echo "$REMOTE_URL" | sed -E -e 's|^https?://[^/]+/||' -e 's|^git@[^:]+:||' -e 's|^ssh://[^/]+/[^/]+/||' -e 's|\.git$||' -e 's|/$||' | tr '/' '_')
  if [ -n "$OWNER_REPO" ] && [ "$OWNER_REPO" != "$SLUG" ]; then SLUG="${OWNER_REPO}__${SLUG}"; fi
fi
if [ "$SLUG" != "$OLD_SLUG" ] && [ -f "$HOME/.claude/imps/runs/$OLD_SLUG.json" ] && [ ! -f "$HOME/.claude/imps/runs/$SLUG.json" ]; then
  for ext in json md; do [ -f "$HOME/.claude/imps/runs/$OLD_SLUG.$ext" ] && mv "$HOME/.claude/imps/runs/$OLD_SLUG.$ext" "$HOME/.claude/imps/runs/$SLUG.$ext" 2>/dev/null || true; done
fi
STATE_PATH="$HOME/.claude/imps/runs/${SLUG}.json"
DEFAULT_BRANCH=$(git remote show origin | sed -n '/HEAD branch/s/.*: //p')
RUN_BRANCH="imps/${SLUG}-$(date -u +%Y%m%d-%H%M%S)"
git fetch origin "$DEFAULT_BRANCH" && git checkout -b "$RUN_BRANCH" "origin/$DEFAULT_BRANCH"
echo "$STATE_PATH"
```

`Write` the JSON below to the echoed `$STATE_PATH` (its `file_path`, not the `~/...`
form — `Write` doesn't expand `~`). Write `$RUN_BRANCH` into `branch` below — never the
discovery answer, never whatever
`git rev-parse --abbrev-ref HEAD` reported before this step ran. If branch creation
fails for any reason, stop and surface the error rather than falling back to the
current branch.

```json
{
  "schema": 4,
  "task": "<REFINED_TASK>",
  "repo": "<repo from discovery>",
  "branch": "<RUN_BRANCH>",
  "tasks": [
    { "id": 1, "label": "...", "spec": "<operative instructions from Step 1 — required for every task; the label is a title, the spec is what the imp actually executes>", "model": "haiku", "type": "query", "deps": [] }
  ],
  "phase": "dispatch_pending",
  "segment": null,
  "dispatched_at": null,
  "poll_interval_seconds": 300,
  "max_dispatch_hours": 6,
  "last_heartbeat": null,
  "tasks_done": [],
  "escalated_tasks": [],
  "worktrees": {},
  "artifacts": [],
  "pr": null,
  "verdicts": null,
  "verdicts_pending": null,
  "parked_findings": [],
  "wontfix_rulings": [],
  "fix_rounds_done": 0,
  "fix_cycles": 0,
  "posting_mode": null,
  "discussion_comment_url": null,
  "source_discussion": null,
  "gate_commands": null,
  "learnings_saved": null,
  "operator_decision": null,
  "last_result": null
}
```

`verdicts_pending`, `parked_findings`, `wontfix_rulings`, `fix_rounds_done`,
`fix_cycles`, and `posting_mode` are new in **schema 4** (persona-panel adjudication) —
additive only, in the same style as schema 3 below: nothing existing removed or
repurposed, none of them required, so a hand-written schema-3 file still loads. (Schema 4
also added four fail-soft breadcrumb fields not listed above — `heartbeat_clock_error`,
`dispatch_clock_error`, `parked_findings_write_error`, and `adjudication_error` — each
`null` unless the thing it names just failed. The first three exist only to reach the
audit trail and carry no behavior of their own. **`adjudication_error` is different and is
operator-facing:** it records that the adjudicator never returned a ruling, it travels in
the blocked result's `detail`, and the `override findings:` path reads it to decide that
the findings still awaiting a ruling are the ones being overridden — so an override on
that path records them explicitly instead of silently no-opping. All four clear on
recovery rather than latching, so a later healthy cycle is not reported as degraded.)
All six of the named fields are written by the script during the
persona panel and fix loop; you never write them at plan time beyond the empty values
above. `verdicts_pending` holds panel output that is *not yet complete* — `verdicts`
staying `null` is the script's "the panel has not finished, run it again" signal, so
partial output must never be promoted into it. `parked_findings` and `wontfix_rulings`
carry the adjudicator's rulings and each fix round's declined findings. `fix_cycles`
bounds the `retry findings` verb (refused past two granted cycles); `fix_rounds_done` is
a record of how many fix rounds the most recently completed cycle ran (surfaced in the
result, not itself a bound) — each cycle's own fix loop always restarts counting from
round 0, it does not resume a prior cycle's round count. `posting_mode` persists the
operator's posting choice so a resume that no longer carries a `PR:` decision string does
not silently fall back to "post nothing". See Phase 4's `unresolved_findings` entry for
what an operator does with them.

`gate_commands`, `learnings_saved`, `operator_decision`, and `last_result` are new in
schema 3 (the Workflow-script rewrite) — additive only, nothing existing was removed or
repurposed. `gate_commands` persists the once-per-run gate-command discovery result so it
survives across the fresh invocations described in Phase 3/4 (a real state-file field
replaces what used to live only in the wrangler's own session memory for the run's
duration). `operator_decision` carries the pending decision string (the same resume-verb
vocabulary as before) from Phase 4 into the next fresh invocation. `last_result` is the
full result object the script returned last time (verbatim) — a fresh invocation reads
`last_result.status` alongside `operator_decision` to know exactly what to resume into,
rather than re-deriving routing state from `phase`/`segment` alone. `learnings_saved`
guards the learnings-append step exactly like `pr`/`verdicts`/`discussion_comment_url`
guard their own side effects. A legacy schema-2 file (missing these four fields) is
treated as having them all `null` — the script's own dispatch/gate/learnings logic
re-derives
whatever it needs rather than assuming they exist.

**Opencode execute tier (also additive, also schema 3).** Two optional per-task fields and
one top-level array. A task routed to the tier looks like this — copy the plain row above
for everything else, these fields are not defaults:

```json
{ "id": 4, "label": "make the failing parser test pass", "spec": "...", "model": "haiku", "type": "code", "deps": [], "oracle": "pytest tests/test_parser.py -q", "executor": "opencode" }
```

- `oracle` — the machine-checkable acceptance command, run in the dispatch worktree; exit
  0 means done. `null`/absent for an ordinary imp.
- `executor` — `"claude"` (default when absent) or `"opencode"`. `model` stays a **Claude**
  model either way; see the Executor bullet in Phase 2 Step 1.
- `escalated_tasks` — top-level, beside `tasks_done`: the ids of tasks that were marked
  `executor: "opencode"` but ended up done by a normal Claude imp, because the tier
  aborted, exhausted its attempts, had its sandbox-off shell-out denied, or was never
  eligible (no oracle). The run does not fail over this; the fallback is the designed
  behaviour. The id is recorded because the dispatch bookkeeping keeps only
  `id`/`branch`/`artifacts` on success, so without it an escalated-then-succeeded task is
  indistinguishable from one that never touched opencode — and whether the tier earns its
  keep is exactly what is being measured.

⚠️ **Setup prerequisite, operator-owned.** The tier shells out to
`opencode-dispatch.sh` with the Bash sandbox **off** (the harness applies its own Seatbelt
sandbox, and Seatbelt does not nest). Nothing in this repo grants that: a worktree checkout
has no `.claude/settings.local.json` (it is git-ignored), so in practice the call is
allowed by the auto-mode classifier rather than by a rule — which can change without
notice. For a deterministic grant, add the permission entry from
`${CLAUDE_PLUGIN_ROOT}/references/opencode-harness.md` to **user-level**
`~/.claude/settings.json`, which loads regardless of cwd. Without it the tier degrades
safely rather than stalling: a denied, prompted, or timed-out call is treated as an abort,
the task escalates to a Claude imp, and its id lands in `escalated_tasks`.

Discussion-seed mode: set `source_discussion` to
`{ "owner": "...", "repo": "...", "number": <int>, "id": "<GraphQL node ID>", "url": "<discussion URL>" }`
(fields fetched in `references/discussion-mode.md` step 2). Every other mode leaves it
`null`. Imps are unnamed — each is identified by a themed Nerd Font glyph derived from
its task ID (see the dispatch banner), so the state file carries no `name` field.

Then proceed immediately to Phase 3 — no `/clear` handoff is needed: every Workflow
invocation is fresh by construction (see Phase 4's design note), so dispatch never
inherits this planning window regardless.

---

## Phase 3 — Sync and run the Workflow script

Everything from here to run completion is real control flow inside one Workflow script
(`scripts/imps-run.workflow.js`): git preflight, dispatching the task DAG as staged
`agent()` calls, merging, the Head Imp diff review, gates, the endstate PR, the persona
panel, and finalize. **This command has a hard dependency on the `Workflow` tool — there
is no prose fallback.** If `Workflow` is unavailable in this session, tell the user
plainly (`/imps:imps` requires it) and stop; do not attempt to execute the old
subagent-dispatch protocol inline.

**Step 1 — sync the canonical script.** Workflow scripts only load from a user's own
`~/.claude/workflows/*.js` — a plugin cannot ship one that runs directly. Each run,
re-sync the bundled copy over whatever is there so it always matches the installed
plugin version (a plain overwrite, not a version/hash check). **The `Workflow` tool call
below is not Bash — it does not expand `~`,** so resolve and echo the absolute paths here
first, and pass those literal echoed values (never the `~/...` form) into Step 2:

```bash
mkdir -p ~/.claude/workflows
cp "${CLAUDE_PLUGIN_ROOT}/scripts/imps-run.workflow.js" ~/.claude/workflows/imps-run.js
SLUG=$(basename "${CLAUDE_PROJECT_DIR:-$(pwd)}")
OLD_SLUG="$SLUG"
if REMOTE_URL=$(git remote get-url origin 2>/dev/null); then
  OWNER_REPO=$(echo "$REMOTE_URL" | sed -E -e 's|^https?://[^/]+/||' -e 's|^git@[^:]+:||' -e 's|^ssh://[^/]+/[^/]+/||' -e 's|\.git$||' -e 's|/$||' | tr '/' '_')
  if [ -n "$OWNER_REPO" ] && [ "$OWNER_REPO" != "$SLUG" ]; then SLUG="${OWNER_REPO}__${SLUG}"; fi
fi
if [ "$SLUG" != "$OLD_SLUG" ] && [ -f "$HOME/.claude/imps/runs/$OLD_SLUG.json" ] && [ ! -f "$HOME/.claude/imps/runs/$SLUG.json" ]; then
  for ext in json md; do [ -f "$HOME/.claude/imps/runs/$OLD_SLUG.$ext" ] && mv "$HOME/.claude/imps/runs/$OLD_SLUG.$ext" "$HOME/.claude/imps/runs/$SLUG.$ext" 2>/dev/null || true; done
fi
WORKFLOW_DEST="$HOME/.claude/workflows/imps-run.js"
STATE_PATH="$HOME/.claude/imps/runs/${SLUG}.json"
GOAL_PATH="$HOME/.claude/imps/runs/${SLUG}.md"
echo "$WORKFLOW_DEST"; echo "$STATE_PATH"; echo "$GOAL_PATH"
```

**Step 2 — invoke it.** Every invocation is a **fresh** `Workflow` call — never
`resumeFromRunId` (see the design note at the end of this file for why). The script's own
first step reads the state file and decides what's already done; there is nothing for the
harness's own resume mechanism to add, and relying on it would risk silently re-triggering
side effects the script itself must guard against instead.

```
Workflow({
  scriptPath: "<the echoed $WORKFLOW_DEST value, e.g. /Users/you/.claude/workflows/imps-run.js>",
  args: {
    pluginRoot: "${CLAUDE_PLUGIN_ROOT}",
    stateFilePath: "<the echoed $STATE_PATH value, e.g. /Users/you/.claude/imps/runs/<slug>.json>",
    goalFilePath: "<the echoed $GOAL_PATH value, e.g. /Users/you/.claude/imps/runs/<slug>.md>",
    personaPostingProtocolPath: "${CLAUDE_PLUGIN_ROOT}/references/persona-posting.md",
    personaBriefPaths: {
      "solution-architect": { path: "${CLAUDE_PLUGIN_ROOT}/personas/solution-architect.md", model: "opus" },
      "grumpy-engineer": { path: "${CLAUDE_PLUGIN_ROOT}/personas/grumpy-engineer.md", model: "opus" },
      "sre": { path: "${CLAUDE_PLUGIN_ROOT}/personas/sre.md", model: "opus" },
      "business-analyst": { path: "${CLAUDE_PLUGIN_ROOT}/personas/business-analyst.md", model: "opus" },
      "ux-designer": { path: "${CLAUDE_PLUGIN_ROOT}/personas/ux-designer.md", model: "sonnet", requires: ["browser-surface"] }
    }
  }
})
```

Each roster entry carries its own dispatch `model` and, where relevant, `requires` — the
capability tags the surface-detection skip below filters on. A future persona is handled
by adding a roster entry (with whatever `model`/`requires` it needs), never by adding a new
hardcoded slug check to the Workflow script.

`personaBriefPaths` always lists all five briefs. Before the initial panel call only, a
cheap `model: 'haiku'` classifier reads `git diff --name-only origin/<default>..HEAD` and
decides — by file role/location, not bare extension, since a plain `.js`/`.ts` file can
be the browser surface itself (a React or Angular component, a client route) — whether
any changed path is browser-renderable, rather than forcing a browser review or
attempting an unattended Chrome-MCP session on every run. When no such surface is found,
the panel is filtered to the slugs whose roster entry does NOT list `"browser-surface"` in
`requires` (`Object.entries(args.personaBriefPaths).filter(([, b]) => !(b.requires ||
[]).includes('browser-surface'))`), never a hardcoded `!== 'ux-designer'` check, so a
future persona (browser or non-browser) is handled by its own roster entry instead of by
editing this filter — and the run's findings record exactly `"ux-designer skipped — no
browser-renderable surface: <reason>"` with a `"SKIPPED"` verdict (a third value alongside
`APPROVE`/`CHANGES_REQUESTED` — it carries no `(posted)`/`(inline)` tag since nothing was
reviewed to post, and the dissenter fix-loop never re-reviews it). Any classification
error, or a detected surface, runs all five personas — the script fails open toward
running ux-designer rather than silently dropping it, and the skip applies to this initial
call only, not the fix-loop re-review pass.

**Step 3 — print the dispatch banner and stop; you'll be notified.** `Workflow` runs in
the background — this turn ends here, not after the run finishes.

```bash
SLUG=$(basename "${CLAUDE_PROJECT_DIR:-$(pwd)}") ; python3 "${CLAUDE_PLUGIN_ROOT}/scripts/dispatch-banner.py" "$SLUG"
```

Progress between results is visible in the state file — the script heartbeats
`last_heartbeat` and `tasks_done` as tasks complete, same fields as before, for the
banner's `progress:` hint to read. Whether a single hung (non-erroring) `agent()` call has
a platform-level timeout is **not verified** — this is a residual, carried-over risk, not
one this rewrite claims to have solved (today's design also had no automated hang
detector for this case, only a human-visible heartbeat staleness signal).

---

## Phase 4 — Result relay loop

Each phase of the script ends in exactly one returned `status`, arriving as a
`<task-notification>` when the background `Workflow` run reaches that point. There is no
`SendMessage`/`agentId` to resume — an operator decision is **persisted into the state
file**, then the script is **re-invoked fresh** (Phase 3 Steps 1–3 again, verbatim). The
script's own opening step reads the state file and skips whatever it says is already
done; this is how "resume" works throughout, deliberately not via `resumeFromRunId` (see
the design note at the end of this file).

To persist a decision, patch the state file's `operator_decision` field before
re-invoking (a single preapprovable command, not a hand-rolled multi-line edit):

```bash
jq --arg d '<the decision string, same vocabulary as today — see below>' \
  '.operator_decision = $d' ~/.claude/imps/runs/<slug>.json > "$TMPDIR/imps-state.json" \
  && mv "$TMPDIR/imps-state.json" ~/.claude/imps/runs/<slug>.json
```

The decision vocabulary is almost unchanged from before: `resolved, continue` ·
`retry <gate>: <guidance>` · `skip <gate>` · `reconciled, continue` ·
`retry tasks #N,#M: <guidance>` · `skip tasks #N,#M` · `integrate partial` ·
`retry findings` · `override findings: <rationale>` ·
`PR: yes` · `PR: yes, no-post` · `PR: no` · `learnings: <json|none>` · `abort` — the
delivery mechanism changed (from a `SendMessage` to a spawned subagent, to a state-file
field read by a fresh script invocation), and one verb is dropped: `wait <hours>` existed
to extend `max_dispatch_hours`'s manual poll-loop timeout, which no longer exists (see
the design note) — there is no `dispatch_timeout` blocked reason for it to resume from
either. `integrate partial` is still supported: it confirms every currently-unresolved
task failure as an accepted omission (the same effect as naming them all in
`skip tasks`), so re-dispatch doesn't re-block on the same failures.

Two verbs are new, and both resume only from an `unresolved_findings` block (below):

- **`retry findings`** — give the findings another capped fix cycle. The script reseeds
  the panel from `verdicts_pending` rather than re-running the five personas (which would
  post five more GitHub reviews in `live` mode and discard the existing `posted` flags and
  the SKIPPED entry), resets the round counter, and runs up to three more fix rounds
  followed by a fresh adjudication. Bounded at **two cycles** by `fix_cycles`, where the
  initial panel run is cycle 1: exactly **one** `retry findings` is granted (it makes
  cycle 2), and the **second** `retry findings` is refused — only `override findings:` or
  `abort` remain after that. It takes no guidance argument — anything after the verb is
  ignored.
- **`override findings: <rationale>`** — accept the load-bearing findings as they stand
  and finalize anyway. Every `load-bearing` ruling is rewritten to `operator-overridden`
  with your rationale recorded on it, `verdicts_pending` is promoted to `verdicts`, and
  the run proceeds to finalize. The rationale is not decoration: it is the only record
  that a blocking finding was overruled rather than fixed, and it survives into GOAL.md's
  `## Parked findings` section after the state file is deleted. Write one.

**The anti-pre-judging rule applies to every guidance string you compose here** (see
[Never pre-judge a reviewer's findings inside its own prompt](#never-pre-judge-a-reviewers-findings-inside-its-own-prompt)).
`retry <gate>: <guidance>`, `retry tasks #N: <guidance>`, and `retry findings`'s fix
rounds all put your text in front of an agent that will re-review the result. Guidance
says *what to fix and how it failed*; it does not say what the reviewer should conclude —
"this is fine now", "don't flag the sizing again", "just get it to APPROVE" are
pre-judgments, not guidance. If you want a finding overruled, `override findings:` is the
verb that does it **on the record**; `skip <gate>` and `skip tasks #N` are the equivalents
at the other gates. All three leave a trace an operator can read afterwards. Steering the
prompt leaves none.

**If a result never arrives** (session lost, `/clear`, or the run legitimately needs
picking up later): do nothing special here — the **Guard: resume check** at the top of
this command already handles it. Re-running `/imps:imps` reads the state file's `phase`
and `segment`, and Phase 3 re-syncs and re-invokes the script fresh; its own opening step
reconciles against the state file and git ground truth exactly as the old `resume`-mode
wrangler did (worktree branches, GOAL.md checkboxes, published artifacts) — see the
design note for what the script must implement to preserve this.

**`blocked` results** — surface the problem, agree the next step with the user, persist
the decision, re-invoke:
- `state_read_mismatch` — readState()'s task count/phase disagree with a raw `jq` check
  of the state file (the readState() mismapping failure mode, #87) — everything else in
  `state`, including `operator_decision` itself, is untrustworthy this invocation, so the
  script refuses to route on it. Inspect the raw file (`jq . <state file>`); if it looks
  fine, this was likely a one-off read blip — persist `resolved, continue` to retry. If
  the file itself is actually garbled, fix it by hand or persist `abort`.
- `dispatch_failed` — preflight rebase conflict or imp-dispatch error. The user fixes
  the tree (or decides); persist `resolved, continue` or `abort`.
- `imps_failed` — failed tasks block the DoD. Ask the user (retry with guidance / skip
  those tasks / integrate without any of the unresolved ones / abort) and persist
  `retry tasks #N: ...`, `skip tasks #N`, `integrate partial`, or `abort`.
- `merge_conflict` — the conflict is live in the shared working tree. List the branch +
  files; let the user resolve (or resolve trivial conflicts yourself), then persist
  `resolved, continue`.
- `gate_red` — surface the gate name + log tail; agree retry guidance, skip, or abort.
- `branch_mismatch` — reconcile branch state with the user, then persist
  `reconciled, continue`. Don't take an agent's self-reported `id` or `branch` at face
  value here — agents can collide on the same self-reported id or report the base
  branch instead of their real one. Cross-check against the state file's own task
  table (the authoritative source for task identity) and `git branch --list` / `git
  worktree list` for the actual branch names.
- `unresolved_findings` — the persona panel's fix loop hit its 3-round cap with findings
  still standing, an opus adjudicator ruled on each survivor, and at least one ruling came
  back `load-bearing`. This is the only blocked reason that arrives *after* the PR exists.
  The result's `detail` carries the rulings; `parked_findings` and `wontfix_rulings` are
  also in the state file and in the final result object. Surface every `load-bearing`
  finding with its rationale, then agree one of: `retry findings` (another capped fix
  cycle — refused after two), `override findings: <rationale>` (accept them and finalize,
  on the record), or `abort`. **Do not fix them silently in this session** — that is the
  self-review pattern the disclosure below exists for.

  Those three strings are matched **verbatim and case-sensitively** — unlike the task and
  gate verbs, which are case-insensitive. Persist exactly `retry findings`,
  `override findings: <rationale>` (colon included), or `abort`. Anything else, including an
  empty decision, makes the script re-emit the same blocked result with a `detail.note`
  naming the vocabulary; nothing is re-run, so just persist a valid verb and re-invoke.

  A **ruling** is the adjudicator's verdict on one surviving finding, and it is one of
  exactly four values:
  - `load-bearing` — the finding blocks. The adjudicator had to anchor it to at least one
    of: a verbatim-quoted criterion under GOAL.md's `## Definition of Done`; a named
    concrete breaking input, data-loss path, or security defect reachable in the merged
    diff; or a verbatim-quoted constraint under GOAL.md's `## Global Constraints`. A
    ruling with none of the three anchors cannot be load-bearing, so a `load-bearing`
    ruling that quotes neither a DoD criterion nor a Global Constraint and names no
    breaking input is a malformed ruling, not a stricter one — treat it as suspect and
    read the finding yourself. A ruling that DOES quote a Global Constraint is fully
    anchored on that basis alone; do not second-guess it just because it lacks a DoD
    criterion or a named breaking input too — the constraint anchor stands on its own.
  - `parked-contestable` — reviewed, judged non-blocking, and the adjudicator's reasoning
    is the thing you might disagree with. This is the ruling to re-read: a finding raised
    by two or more distinct personas defaults to `load-bearing`, so parking one of those
    obliges the adjudicator to state which DoD criterion survives it.
  - `parked-deferred` — real, non-blocking here, and worth doing later. It is not an
    argument to reopen; it is a follow-up to file.
  - `operator-overridden` — was `load-bearing` until you issued `override findings:`. The
    rationale stored on it is yours, not the adjudicator's.

  All four are written to GOAL.md's `## Parked findings` section except `load-bearing`,
  which blocks instead. "Parked" always means *reviewed and ruled on* — it never means a
  persona that was never run. A `SKIPPED` ux-designer is an unreviewed lens, not a parked
  finding; say so distinctly when you summarise.

If the user chooses abort at any gate, persist `abort` and re-invoke. The script posts
any Discussion abort notice itself before returning, leaves the tree as-is, and returns
`{status: "aborted", ...}` — surface its `tree_state` and stop (the state file stays for
a later resume decision).

**`awaiting_authorization`** — print a one-block summary from the result's fields (merged
tasks, failed tasks, Head Imp verdict + amendments, gate results, diff stat, and the
`dispatch` block: model counts and published artifacts — `tokens_spent` is usually
`null`, the script has no documented way to read an `agent()` call's own token usage;
omit that line rather than printing an empty one).

**DoD coverage.** The result also carries `dod_coverage`, an array of
`{ text, status: "satisfied" | "unsatisfied" | "unverifiable", evidence }` — one entry
per *functional* Definition-of-Done criterion (the process lines — Gates, Persona panel,
merge conflicts, CI, Discussion comment — are ticked mechanically elsewhere and never
appear in this array) — plus `dod_coverage_status`, one of `"checked" | "not_applicable" |
"failed" | "unknown"`, telling you WHY the array looks the way it does instead of making
you infer it from emptiness-plus-error-presence:
- `"checked"` → the pass ran against a real diff. Non-empty with every entry `satisfied` →
  no callout, this is the genuine all-clear. Empty → the DoD genuinely has no functional
  criteria → print `⚠ no functional acceptance criteria found in the DoD`.
- `"not_applicable"` → an expected, non-alarming outcome (e.g. an artifact-only run, or
  every code branch was already merged by a prior invocation) → print a neutral note, not a
  warning glyph: `ⓘ DoD coverage not checked: <dod_coverage_error>`.
- `"failed"` → the check itself crashed — worth a real warning, since a criterion could be
  sitting unverified: `⚠ DoD coverage check failed: <dod_coverage_error>`.
- `"unknown"` → the state file predates this field (resumed from an older run) — word it
  as its own callout rather than folding it into "failed": `⚠ DoD coverage status unknown
  (resumed from an older run) — verify the DoD manually before authorizing.`

Otherwise (status `"checked"` with unsatisfied/unverifiable entries present) print one line
per criterion, and keep "not met" (a real problem) visually distinct from "not verifiable
from the diff" (may already be true, e.g. manually smoke-tested — the script deliberately
never unticks an `unverifiable` criterion's checkbox, precisely so a prior manual
verification isn't erased on a later resume):
```
[x] satisfied    <criterion text>
[ ] unsatisfied  <criterion text> — <evidence>
[?] unverifiable <criterion text> — <evidence>
```
`[?]` is a deliberate non-claim, not a checkbox reading — this pass never touches an
`unverifiable` criterion's actual GOAL.md box (see above), so printing a hardcoded `[ ]`
here would misreport a box a human may have already ticked by hand. If any criterion is
`unsatisfied`, surface a prominent callout directly above this list — e.g. `⚠ N acceptance
criterion/criteria not met`. If any is `unverifiable`, add a separate, lower-key line —
e.g. `N criterion/criteria not verifiable from the diff alone` — don't fold it into the
"not met" count, they're different claims. Both callouts go **before** the Push & PR
question below, never after — the operator must see them before authorizing the PR, not
after it's already open.

Then the operator gate:

**Push & PR decision.** The persona panel posts its findings as comments on a PR
thread, so the PR must exist first. This is the correct moment: branches are merged,
the Head Imp reviewed the diff, gates are green — and nothing has been pushed yet.

**Self-review disclosure.** If the `awaiting_authorization` result's `head_imp.amendments`
is non-zero, this session wrote code directly into the diff during the Head Imp fix-loop —
say so before asking below. Persona posting through each's dedicated GitHub App identity
(`${CLAUDE_PLUGIN_ROOT}/references/persona-posting.md`) is attribution/audit-trail
only; it is not an independent review of content this same session authored, and
pushing/PR-creation is a separate authorization from letting personas post live GitHub
reviews — one does not imply the other.

Ask with **AskUserQuestion**:
- **question**: `"Push this branch and open the endstate PR for review?"`
- **header**: `"Push & PR?"`
- **options**:
  1. `Push & open PR, personas post live reviews` — the script pushes the branch,
     opens a draft PR (flipped to ready at finalize), and personas post real GitHub
     reviews on that thread under their own identities. Activates the handoff for the
     `/imps:prs` monitor.
  2. `Push & open PR, findings only (no persona posts)` — same push/PR as above, but no
     persona calls `persona-post.sh`; every verdict returns in
     `run_complete.findings_inline` for you to read or post yourself. Use this when the
     disclosure above applies and you'd rather a human than a bot identity be the first
     to put a verdict on the record.
  3. `Not yet` — no push, no PR. The persona panel returns its findings in
     `run_complete.findings_inline`; the branch stays local and no PR monitor starts.

Opening the endstate PR is the default for free-text runs that produced code changes —
only `Not yet` skips it. Option 2 exists specifically for the self-review case named in
the disclosure above — offer it deliberately, not as a throwaway third choice. Persist
exactly `PR: yes`, `PR: yes, no-post`, or `PR: no` and re-invoke. The script then runs the
PR + persona panel + fix loop + finalize steps in the same invocation.

**`final`** — the run's substantive work is done (PR ready, panel + fix loop finished,
Discussion comment posted) but the state file is **not yet deleted** — the script never
deletes it until the learnings step below completes, specifically so a death between here
and there still resumes gracefully instead of silently losing the `.prs.json` handoff. In
order:

1. Print the final banner by piping the result to the bundled script — via a temp
   file, never shell-quoted inline (the JSON routinely contains `'` and `$`):
   ```bash
   cat > "${CLAUDE_JOB_DIR:-/tmp}/imps-run-complete.json" <<'RESULT_JSON'
   <the final result JSON verbatim>
   RESULT_JSON
   python3 "${CLAUDE_PLUGIN_ROOT}/scripts/final-banner.py" < "${CLAUDE_JOB_DIR:-/tmp}/imps-run-complete.json"
   ```
   Then the results from the result's fields:
   ```
     merged:    #6 <label>    (3 files)
     published: #3 Discussion → https://github.com/...
     verdicts:  solution-architect APPROVE (posted) · grumpy-engineer APPROVE (inline) · ...
     PR:        <url, "ready for review"> | "no PR — branch is local"
   ```
   Tag each verdict with how it was delivered — `(posted)` for a real GitHub review
   under that persona's own App identity, `(inline — <reason>)` when it fell back (no
   App identity installed for this org, or the post was denied) — a partial panel
   should never read as full independent sign-off. `ux-designer SKIPPED` (no
   `(posted)`/`(inline)` tag — it never reviewed) means the surface-detection classifier
   found no browser-renderable surface in the diff; print its one-line reason from
   `findings`, don't render it as a bare unqualified word.

   Render `run_stats` as a short stats block (Achieved / Decision points / Timing /
   Imps — omit empty sections; `tokens_spent` is typically `null`, per the note above,
   so omit a Tokens line rather than print an empty one). If `findings_inline` is
   populated (`PR: no`)
   or `unresolved` lists blockers/majors that survived 3 rounds, surface them verbatim —
   they are the review record.
2. If `prs_monitor` is non-null: invoke the `/imps:prs` skill (no args — it reads the
   `.prs.json` the script already wrote), then print:
   `PR monitor active — watching PR #<N>. I'll address comments, fix CI failures, and
   resolve merge conflicts automatically.`
   If `pr` is null, print instead: "Branch is local only and no PR was opened — push
   and open a PR, then invoke `/imps:prs` to activate the monitor."
3. **Learnings gate — its own explicit step, not folded into printing the summary
   above.** If `learnings_candidates` is non-empty, present them with **AskUserQuestion**
   (`multiSelect: true`):
   - **question**: `"Any of these worth saving as a learning?"`
   - **header**: `"Learnings"`
   - **options**: one option per candidate (each already phrased as a rule to apply
     next time)

   Persist the outcome into the state file's `operator_decision` field exactly like any
   other decision (same `jq` pattern as above): `learnings: ["<text 1>", "<text 2>"]` —
   or `learnings: none` if nothing was confirmed (or there were no candidates; still
   persist it so the script can close out). **Re-invoke the script fresh once more** —
   this final invocation performs the actual `learnings.md` append (classifying each
   confirmed learning's scope itself, project vs. user — no scope question needed),
   guarded by a `learnings_saved` marker so a crash between the append and the state-file
   delete can't double-append on a subsequent invocation, and only *then* deletes the
   state file (`~/.claude/imps/runs/<slug>.md` — GOAL.md — stays; it's the human-readable
   record).

**`done`** — this last invocation wrote the learnings files and deleted the state file.
Print the closing line using the scope each learning was auto-classified into (from
`learnings_saved`):
```
Learnings saved: "<rule 1>" [project] · "<rule 2>" [user]
```
(or `No learnings saved this run.`). The run is over.

This command does not edit its own body based on the learnings log — `/learn`, run from a
claude-plugins checkout, is what periodically turns recurring `learnings.md` entries into
a proposed, operator-gated edit to this command's body.

---

## Design note — why every Workflow invocation above is fresh, never `resumeFromRunId`

A live spike against the actual `Workflow` tool found two things that rule out
`resumeFromRunId` as this command's resume mechanism: (1) it is documented as
same-session only, so it cannot survive `/clear` or a new session — exactly the case the
**Guard: resume check** above exists to handle; (2) its caching is a
longest-unchanged-*prefix* match, not independent per-call content addressing — changing
one call (e.g. a retried gate) causes every subsequent call to re-execute with a fresh
cache key even when its own inputs are unchanged, which would silently defeat any
duplicate-post guard that assumed the cache would just skip an unaffected downstream call
(persona posting, PR creation, the learnings append).

So `imps-run.workflow.js` does not use `resumeFromRunId` at all. Every invocation
described above is a fresh `Workflow` call; the script's first step reads the state file
and reconciles against it and git ground truth (worktree branches, GOAL.md checkboxes,
published artifacts) exactly as the old `resume`-mode wrangler did. Idempotency for
side-effecting steps has two distinct sources: **merge** relies on `git merge` of an
already-merged branch being a no-op (no marker needed); **PR creation, persona posting,
and the learnings append** each check an explicit persisted marker in the state file
(`pr`, `verdicts`, `discussion_comment_url`, `learnings_saved`) before acting — the same
correctness mechanism the old design used, ported in effect rather than replaced by
trusting the platform's cache.

---

## Model selection reference

Assign by reasoning complexity, not duration or volume:
mechanical (deterministic output, no judgment) → haiku ·
judgment (context, decisions, synthesis) → sonnet ·
deep judgment (large decision space, architectural tradeoffs) → opus.
Always set `model:` explicitly on every `agent()` call.

Model IDs (`claude-*`) vary by session — read the exact identifiers from the session's
model table rather than hardcoding them. The `<haiku|sonnet|opus model id>` placeholders
in the prompts above stand for those current IDs.

---

## Constraints

- Never hand over to the Workflow script without explicit approval of the task list
  (`ExitPlanMode` is that gate).
- Never `git merge --force`, `git reset --hard`, or `git push` without explicit user
  instruction — **exceptions**: (1) after plan approval the Workflow script dispatches
  the imps, rebases the working branch, and merges imp branches autonomously, and it
  pushes + opens the endstate PR only after one of the operator's `Push & open PR ...`
  answers is persisted and a fresh invocation picks it up (pushing fix-loop commits to
  that same PR branch); (2) the `/imps:prs` PR monitor pushes fix commits to the PR
  branch autonomously once activated.
- Never create GitHub PRs without user instruction — the Push & PR gate in Phase 4 is
  that instruction for the endstate PR.
- Persona live-posting is a separate authorization from push/PR creation, not implied by
  it — only the `Push & open PR, personas post live reviews` answer (persisted as
  `PR: yes`) authorizes personas to post real GitHub reviews; `PR: yes, no-post` and
  `PR: no` both forbid it.
- If a task touches a production system, pause and confirm before that task runs.
- The Workflow script owns the run state file and `.prs.json` from handover onward; this
  session's last direct state-file write is Phase 2 Step 6 (later writes are the
  `operator_decision` patches in Phase 4, applied via `jq` as documented there).
- Worktree isolation is not airtight — after each merge step, don't just trust the
  recorded worktree path; if anything about a merge looks off, check `git status
  --short` and `git log --oneline -3` in the actual main checkout before assuming the
  tree is clean.
- Never bypass commit signing (`--no-gpg-sign` or similar) because the SSH-signing
  agent looks locked or contended — that's usually transient under concurrent swarm
  agents. Retry the commit a few times with a short pause between attempts before
  surfacing it as blocked.
