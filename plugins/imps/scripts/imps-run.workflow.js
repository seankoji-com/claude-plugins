// imps-run.workflow.js — the free-text run's dispatch/merge/gate/review/finalize pipeline.
//
// Canonical copy at ${CLAUDE_PLUGIN_ROOT}/scripts/imps-run.workflow.js. commands/imps.md
// syncs it into ~/.claude/workflows/imps-run.js on every invocation (plugins can't ship a
// runnable Workflow directly) and calls Workflow({scriptPath, args}) FRESH every time —
// never resumeFromRunId (see the design note in commands/imps.md Phase 4 for why: it is
// same-session only, and its caching is a longest-unchanged-prefix match that would
// silently re-execute downstream side-effecting calls like PR creation and persona
// posting whenever an earlier retried call changed anything upstream).
//
// Resume works the way it always did: this script's own first step reads the run's state
// file and reconciles against it and git ground truth. Idempotency for side-effecting
// steps has two sources — merge relies on `git merge` of an already-merged branch being a
// no-op; PR creation, persona posting, and the learnings append each check an explicit
// persisted marker in the state file (`pr`, `verdicts`, `discussion_comment_url`,
// `learnings_saved`) before acting.
//
// args shape (all required): {
//   pluginRoot, stateFilePath, goalFilePath, personaPostingProtocolPath,
//   personaBriefPaths: {
//     "solution-architect": { path, model }, "grumpy-engineer": { path, model },
//     "sre": { path, model }, "business-analyst": { path, model },
//     "ux-designer": { path, model, requires: ["browser-surface"] }
//   }
// }
// Each entry carries its own dispatch model and capability tags — a persona's model
// routing and its eligibility for the browser-surface skip both live on the roster entry,
// not as hardcoded slug checks in this script, so a future persona (browser or non-browser)
// is handled by adding a roster entry, not by editing this file.
//
// Every filesystem/git touch routes through an agent() call with a fixed, reviewable
// prompt template — the script body itself has no FS access. "Deterministic" here means
// the loop/branching logic is real JS, not that zero model calls happen.

export const meta = {
  name: 'imps-run',
  description: 'Dispatch, merge, gate, review, and finalize one /imps:imps free-text run.',
  phases: [
    { title: 'Preflight' },
    { title: 'Dispatch' },
    { title: 'Integrate' },
    { title: 'Publish' },
    { title: 'Finalize' },
  ],
}

// Shim: the harness can deliver `args` as a JSON-encoded string; every
// `args.<field>` read below then resolves to undefined and the run
// degenerates (observed wf_c9dcca29-573: state file never read, zero imps
// dispatched, gates ran on an empty diff). Normalize before anything else.
if (typeof args === 'string') {
  args = JSON.parse(args)
}

// ---------------------------------------------------------------------------
// Schemas
// ---------------------------------------------------------------------------

const STATE_SCHEMA = {
  type: 'object',
  additionalProperties: true,
  properties: {
    schema: { type: 'number' },
    task: { type: 'string' },
    repo: { type: 'string' },
    branch: { type: 'string' },
    tasks: {
      type: 'array',
      items: {
        // MUST stay true. patchState() round-trips the ENTIRE state file through an LLM
        // on every dispatch heartbeat; a per-task field absent from this schema can be
        // silently dropped mid-run (the #87 silent zero-dispatch failure mode). Any new
        // per-task field goes in `properties` below AND relies on this staying open.
        additionalProperties: true,
        type: 'object',
        properties: {
          id: { type: 'number' },
          label: { type: 'string' },
          // The operative instructions this imp needs to act without improvising —
          // an imp receives ONLY what's in its dispatch prompt, never the plan
          // context. Optional for pre-existing state files; commands/imps.md
          // requires it for new runs.
          spec: { type: 'string' },
          model: { type: 'string' },
          type: { type: 'string', enum: ['code', 'query', 'publish'] },
          deps: { type: 'array', items: { type: 'number' } },
          // Machine-checkable acceptance command for the opencode execute tier: a shell
          // command run in the dispatch worktree, exit 0 == task done. Null/absent for
          // every ordinary Claude imp. Required (non-empty) for executor "opencode".
          oracle: { type: ['string', 'null'] },
          // Which execution tier runs this task. Absent == "claude". Note `model` stays
          // the CLAUDE model in both cases — for "opencode" it is the wrapper agent's
          // model (haiku suffices), never the open model, which opencode-dispatch.sh
          // picks itself.
          executor: { type: 'string', enum: ['claude', 'opencode'] },
        },
        // oracle/executor stay OUT of `required` so legacy state files still validate.
        required: ['id', 'label', 'model', 'type', 'deps'],
      },
    },
    phase: { type: 'string' },
    segment: { type: ['string', 'null'] },
    dispatched_at: { type: ['string', 'null'] },
    poll_interval_seconds: { type: 'number' },
    max_dispatch_hours: { type: 'number' },
    last_heartbeat: { type: ['string', 'null'] },
    tasks_done: { type: 'array', items: { type: 'number' } },
    // Task ids whose opencode execute-tier dispatch was skipped or abandoned and re-run
    // as a normal Claude imp. A RESULT fact, so it lives here at the top level next to
    // its peers — patchState() merges top-level keys only, and no call site patches
    // `tasks`, so a field on the task item is writable at plan time and never again.
    escalated_tasks: { type: 'array', items: { type: 'number' } },
    worktrees: { type: 'object', additionalProperties: { type: 'string' } },
    artifacts: { type: 'array', items: { type: 'object', additionalProperties: true } },
    pr: { type: ['object', 'null'], additionalProperties: true },
    verdicts: { type: ['object', 'null'], additionalProperties: true },
    discussion_comment_url: { type: ['string', 'null'] },
    source_discussion: { type: ['object', 'null'], additionalProperties: true },
    gate_commands: { type: ['object', 'null'], additionalProperties: true },
    learnings_saved: { type: ['array', 'null'] },
    operator_decision: { type: ['string', 'null'] },
    last_result: { type: ['object', 'null'], additionalProperties: true },
    failed_tasks: { type: 'array', items: { type: 'object', additionalProperties: true } },
  },
  required: ['schema', 'task', 'branch', 'tasks', 'phase'],
}

const IMP_RESULT_SCHEMA = {
  type: 'object',
  properties: {
    id: { type: 'number' },
    label: { type: 'string' },
    type: { type: 'string', enum: ['code', 'query', 'publish'] },
    status: { type: 'string', enum: ['done', 'failed'] },
    branch: { type: ['string', 'null'] },
    artifacts: { type: 'array', items: { type: 'object', additionalProperties: true } },
    notes: { type: 'string' },
  },
  required: ['id', 'label', 'type', 'status', 'branch', 'artifacts'],
}

const PREFLIGHT_SCHEMA = {
  type: 'object',
  properties: {
    ok: { type: 'boolean' },
    default_branch: { type: 'string' },
    branch_reset: { type: 'boolean', description: 'true if a bad state-file branch equaled the default branch and a fresh branch was cut' },
    new_branch: { type: ['string', 'null'] },
    error: { type: ['string', 'null'] },
  },
  required: ['ok', 'default_branch', 'branch_reset', 'new_branch', 'error'],
}

const MERGE_SCHEMA = {
  type: 'object',
  properties: {
    merged: { type: 'array', items: { type: 'object', properties: { id: { type: 'number' }, label: { type: 'string' }, files: { type: 'number' } }, required: ['id', 'label', 'files'] } },
    conflict: { type: ['object', 'null'], properties: { branch: { type: 'string' }, files: { type: 'array', items: { type: 'string' } } } },
    default_branch_violation: { type: 'boolean', description: 'true if HEAD resolved to the default branch — merge must NOT proceed' },
  },
  required: ['merged', 'conflict', 'default_branch_violation'],
}

const HEAD_IMP_SCHEMA = {
  type: 'object',
  properties: {
    verdict: { type: 'string', enum: ['APPROVE', 'CHANGES_REQUESTED'] },
    findings: { type: 'array', items: { type: 'string' } },
    amendments_applied: { type: 'number' },
  },
  required: ['verdict', 'findings', 'amendments_applied'],
}

const GATE_DISCOVERY_SCHEMA = {
  type: 'object',
  properties: {
    gates: {
      type: 'array',
      items: { type: 'object', properties: { name: { type: 'string' }, cmd: { type: 'string' } }, required: ['name', 'cmd'] },
    },
  },
  required: ['gates'],
}

const GATE_RUN_SCHEMA = {
  type: 'object',
  properties: {
    gate: { type: 'string' },
    cmd: { type: 'string' },
    pass: { type: 'boolean' },
    tail: { type: 'string' },
  },
  required: ['gate', 'cmd', 'pass', 'tail'],
}

const PR_CREATE_SCHEMA = {
  type: 'object',
  properties: {
    number: { type: 'number' },
    url: { type: 'string' },
  },
  required: ['number', 'url'],
}

const PERSONA_VERDICT_SCHEMA = {
  type: 'object',
  properties: {
    slug: { type: 'string' },
    verdict: { type: 'string', enum: ['APPROVE', 'CHANGES_REQUESTED'] },
    posted: { type: 'boolean' },
    findings: { type: 'array', items: { type: 'string' } },
  },
  required: ['slug', 'verdict', 'posted', 'findings'],
}

const FINALIZE_SCHEMA = {
  type: 'object',
  properties: {
    pr_ready: { type: 'boolean' },
    discussion_comment_url: { type: ['string', 'null'] },
    prs_monitor: { type: ['object', 'null'], additionalProperties: true },
    run_stats: { type: 'object', additionalProperties: true },
    learnings_candidates: { type: 'array', items: { type: 'string' } },
  },
  required: ['pr_ready', 'discussion_comment_url', 'prs_monitor', 'run_stats', 'learnings_candidates'],
}

const LEARNINGS_APPEND_SCHEMA = {
  type: 'object',
  properties: {
    saved: { type: 'array', items: { type: 'object', properties: { rule: { type: 'string' }, scope: { type: 'string' } }, required: ['rule', 'scope'] } },
  },
  required: ['saved'],
}

const RAW_STATE_CHECK_SCHEMA = {
  type: 'object',
  properties: {
    raw_task_count: { type: 'number' },
    raw_phase: { type: 'string' },
    raw_error: { type: ['string', 'null'] },
  },
  required: ['raw_task_count', 'raw_phase'],
}

// Per-criterion requirement-coverage of the GOAL.md `## Definition of Done` against the
// merged diff (gsd-core's Verify "requirement coverage" pass). Functional criteria only —
// the fixed process-status lines are owned by the mechanical tickers elsewhere.
const DOD_COVERAGE_SCHEMA = {
  type: 'object',
  properties: {
    criteria: {
      type: 'array',
      items: {
        type: 'object',
        properties: {
          text: { type: 'string' },
          status: { type: 'string', enum: ['satisfied', 'unsatisfied', 'unverifiable'] },
          evidence: { type: 'string' },
        },
        required: ['text', 'status', 'evidence'],
      },
    },
  },
  required: ['criteria'],
}

// Cheap classification of whether the merged diff touches any browser-renderable surface,
// gating whether the ux-designer (browser) persona reviews. Fails toward MORE review.
const SURFACE_DETECTION_SCHEMA = {
  type: 'object',
  properties: {
    has_surface: { type: 'boolean' },
    reason: { type: 'string' },
  },
  required: ['has_surface', 'reason'],
}

// ---------------------------------------------------------------------------
// State-file helpers — every touch is an agent() call; the script body has no FS access.
// ---------------------------------------------------------------------------

// model: 'sonnet', not 'haiku' — see #87: on a state file with several long, escaped-regex
// task specs, haiku mismapped this verbatim-copy-through-a-schema read (nested the real
// content under last_result, defaulted tasks to []), and every downstream call trusted the
// empty result silently. readState() runs once per invocation and everything else in this
// script trusts its output — worth the extra cost of a stronger model.
function readState() {
  return agent(
    `Read the JSON file at ${args.stateFilePath} and return its exact contents, every field preserved (including any you don't recognize — this schema grows over time). If the file doesn't parse as JSON, that's a fatal setup error — return the error in an "error" field instead of guessing at a shape.`,
    { label: 'read-state', phase: 'Preflight', model: 'sonnet', schema: STATE_SCHEMA }
  )
}

// Independent cross-check for readState(): a single deterministic jq query per field,
// not an LLM-interpreted read of the whole file, so it can't fail the same way
// readState() itself can (#87). Used only to sanity-check readState()'s task count and
// phase before anything downstream trusts them.
function countStateTasks() {
  return agent(
    `Run \`jq '.tasks | length' ${args.stateFilePath}\` and report the integer result as "raw_task_count". Run \`jq -r '.phase' ${args.stateFilePath}\` and report the string result as "raw_phase". If either jq command fails (e.g. the file isn't valid JSON), report the error text as "raw_error" and use -1 and "" for the other two fields. Do not interpret or summarize the file's contents beyond these two command outputs.`,
    { label: 'count-state-tasks', phase: 'Preflight', model: 'haiku', schema: RAW_STATE_CHECK_SCHEMA }
  )
}

// Pure invariant check, kept separate from readState()/countStateTasks() so it's
// testable without stubbing agent() (#87's fix direction #2: fail loudly instead of
// silently proceeding when readState()'s task count doesn't match the raw file).
function validateStateRead(state, rawCheck) {
  if (state.error) {
    return { ok: false, error: `readState() reported a fatal error: ${state.error}` }
  }
  if (rawCheck.raw_error) {
    return { ok: false, error: `raw state-file cross-check failed: ${rawCheck.raw_error}` }
  }
  const tasksLen = (state.tasks || []).length
  if (tasksLen !== rawCheck.raw_task_count) {
    return {
      ok: false,
      error: `readState() returned ${tasksLen} task(s) but the raw file has ${rawCheck.raw_task_count} — this is the readState() mismapping failure mode (#87); refusing to proceed on an untrustworthy read.`,
    }
  }
  if (state.phase !== rawCheck.raw_phase) {
    return {
      ok: false,
      error: `readState() returned phase "${state.phase}" but the raw file has phase "${rawCheck.raw_phase}" — refusing to proceed on an untrustworthy read.`,
    }
  }
  return { ok: true, error: null }
}

function patchState(patch, label) {
  return agent(
    `Read the JSON file at ${args.stateFilePath}. Apply this exact patch — merge these top-level keys into the existing object, overwriting only the keys given, leaving every other existing field untouched: ${JSON.stringify(patch)}. Write the merged result back to the same path (pretty-printed JSON). Return the full resulting file contents so the caller can confirm the write landed.`,
    { label: label || 'patch-state', model: 'haiku', schema: STATE_SCHEMA }
  )
}

function saveResult(result) {
  return patchState({ last_result: result }, 'save-result')
}

// ---------------------------------------------------------------------------
// Preflight — git branch guard (re-asserted every invocation, never assumed from upstream)
// ---------------------------------------------------------------------------

function preflight(state) {
  return agent(
    `Run this git preflight in the current working tree and report back — do not guess, run each command:

1. \`git rev-parse --abbrev-ref HEAD\` — call this CURRENT.
2. \`git remote show origin | grep 'HEAD branch'\` — extract the default branch name, call it DEFAULT.
3. **Hard stop, checked every single invocation, not assumed from a prior run:** if CURRENT equals DEFAULT, the state file's branch field is wrong (or this is a legacy/hand-edited file) and dispatching or merging here would land every task's work straight onto DEFAULT. Do NOT proceed with rebase/dispatch/merge. Instead:
   \`git fetch origin DEFAULT && git checkout -b "imps/<slug>-$(date -u +%Y%m%d-%H%M%S)" origin/DEFAULT\`
   (derive <slug> from \`basename\` of the working directory). Report the new branch name as "new_branch" and set "branch_reset": true. If branch creation fails for any reason, do NOT fall back to DEFAULT — set "ok": false and describe the error.
4. If CURRENT does not equal DEFAULT (the expected case — CURRENT should equal "${state.branch}"): fetch and rebase: \`git fetch origin && git rebase origin/DEFAULT\`. Rebase conflict → abort it (\`git rebase --abort\`), set "ok": false, describe the conflict files in "error".
5. Report "default_branch": DEFAULT, "branch_reset" (bool), "new_branch" (the new branch name or null), "ok" (bool), "error" (string or null).`,
    { label: 'preflight', phase: 'Preflight', model: 'sonnet', schema: PREFLIGHT_SCHEMA }
  )
}

// ---------------------------------------------------------------------------
// Dispatch — topological staging (plain JS) + parallel agent() calls per stage
// ---------------------------------------------------------------------------

function stageTasks(tasks, doneIds, failed) {
  // Topologically sort into stages: a task lands in the first stage after all its deps
  // are satisfied. Plain graph code — no model call, matches the old wrangler's
  // "topologically sort into stages" instruction, just as real code instead of prose.
  // Tasks already in `failed` (terminally failed, or skip-confirmed by the operator) are
  // excluded from re-staging entirely — they were resolved by a prior invocation's
  // cascade or an explicit operator decision, not by completing. Their dependents were
  // already cascade-failed when that happened (or will be, in this invocation's own
  // stage loop) — this function only needs to not endlessly re-stage the resolved task
  // itself.
  const resolved = new Set([...doneIds, ...failed.keys()])
  const remaining = tasks.filter((t) => !resolved.has(t.id))
  const stages = []
  const satisfied = new Set(resolved)
  while (remaining.length) {
    const stage = remaining.filter((t) => t.deps.every((d) => satisfied.has(d)))
    if (!stage.length) break // cyclic or unsatisfiable — caller handles as dispatch_failed
    stages.push(stage)
    stage.forEach((t) => {
      satisfied.add(t.id)
      const idx = remaining.indexOf(t)
      remaining.splice(idx, 1)
    })
  }
  return { stages, unresolved: remaining }
}

// The single predicate both dispatchImp() (route or not) and runDispatch() (escalate or
// not) consult. Two independently-written conditions on the same fact is how they drift.
// A green-at-start oracle cannot distinguish "implemented correctly" from "did nothing",
// so eligibility is only half the gate — dispatchOpencodeImp passes `--expect-oracle red`
// unconditionally and the script aborts on a green start.
function eligibleForOpencode(task) {
  return (
    task.type === 'code' &&
    task.executor === 'opencode' &&
    typeof task.oracle === 'string' &&
    task.oracle.trim().length > 0
  )
}

// executor:"opencode" — offload one mechanical task to the cheap-model execute tier.
//
// This workflow script has no filesystem or exec primitive (only agent/parallel/phase/log),
// so the tier is reached through a thin WRAPPER agent that shells out to
// opencode-dispatch.sh from its own isolated worktree and reshapes the harness's contract
// line into IMP_RESULT_SCHEMA. task.model is that wrapper's Claude model — haiku suffices,
// it only runs one command and reads JSON. The open model is opencode-dispatch.sh's own
// default; there is no per-task override, deliberately (a non-Claude id in `model` would
// be handed straight to agent()).
//
// AUTHORIZATION: the Bash call must run sandbox-off because Seatbelt does not nest. That
// is NOT guaranteed by a deterministic allow rule — `.claude/settings.local.json` is
// git-ignored and absent from a worktree checkout, so in practice the grant comes from the
// auto-mode classifier. The deterministic fix is an operator-added rule in user-level
// ~/.claude/settings.json, which loads regardless of cwd. Until then a denial is a
// first-class outcome: fail fast, escalate to a Claude imp (see runDispatch).
function dispatchOpencodeImp(task, state, guidance) {
  const spec = task.spec || `(No per-task spec recorded — legacy state file.) The run's overall goal, for context: ${state.task}`
  return agent(
    `You are the opencode execute-tier WRAPPER for task #${task.id}: ${task.label}
You do NOT implement this task yourself. You run one command, read one line of JSON, and report. Follow these steps exactly and do not improvise.

1. \`WT="$(git rev-parse --show-toplevel)"\` — this isolated worktree is the only code path the open model may edit.
2. Confirm \`git -C "$WT" status --porcelain\` is EMPTY. opencode-dispatch.sh aborts \`worktree_dirty\` on a non-empty tree before spending anything. If it is not empty, stop and return status "failed" with a note saying so.
3. Write the task prompt to \`"$TMPDIR/imps-oc-${task.id}.prompt"\` — **inside $TMPDIR, never inside the worktree**, or step 2's invariant is broken by your own file. Its contents are everything between the two markers below, verbatim, markers themselves excluded. The markers are the ONLY delimiters — the text between them may itself contain \`---\`, code fences, or anything else, and none of that ends the block:
<<<IMPS_OC_PROMPT_BEGIN>>>
${spec}
<<<IMPS_OC_PROMPT_END>>>
4. Pick a fresh result branch name: \`BR="imps/opencode-${task.id}-$(date -u +%Y%m%d-%H%M%S)"\`. It must not already exist (\`git rev-parse --verify --quiet "refs/heads/$BR"\` must be empty); the harness creates it with a compare-and-swap and fails if it does.
5. The oracle is everything between these two markers, verbatim (same rule as step 3 — the markers are the only delimiters):
<<<IMPS_OC_ORACLE_BEGIN>>>
${task.oracle}
<<<IMPS_OC_ORACLE_END>>>
   Pass it to \`--oracle\` as ONE shell argument. Shell-quote it yourself — it is an arbitrary command line and may contain quotes, \`$\`, or spaces; a mis-quoted oracle silently measures the wrong thing.
6. Run this ONCE, with Bash \`dangerouslyDisableSandbox: true\` (required — the harness applies its own Seatbelt sandbox and Seatbelt does not nest), substituting the quoted oracle for <ORACLE>:
   \`bash ${args.pluginRoot}/scripts/opencode-dispatch.sh --worktree "$WT" --prompt-file "$TMPDIR/imps-oc-${task.id}.prompt" --oracle <ORACLE> --expect-oracle red --result-branch "$BR" 2>"$TMPDIR/imps-oc-${task.id}.err" | tail -n 1\`
   Keep stderr in the file and read only the LAST line of stdout — that line is the contract JSON. Do not merge stderr into stdout; interleaving can displace it.
   Do NOT pass \`--model\`: the script's own default open model applies, and routing an Anthropic model through opencode is forbidden.
   Do NOT run gates, linters, formatters, or \`git add\`/\`git commit\` yourself at any point. The harness owns the commit; anything you write into the worktree breaks step 2's invariant.
7. **Hard rule — a denied, prompted, or timed-out sandbox-off Bash call is an ABORT, not a retry.** Do not retry it, do not re-run it sandboxed, do not look for another way to invoke the script. This is a headless run: there is no operator to answer a prompt and stalling burns the run's dispatch budget. Return status "failed" immediately with a note naming the denial. A normal Claude imp will be dispatched to do the work instead — that fallback is the designed behaviour, not a loss.
8. Report:
   - contract \`"status":"pass"\` → return status "done", \`branch\` = "$BR", and put attempts / cost_usd / commit_sha / oracle_start_state in "notes".
   - ANY other outcome (\`"status":"fail"\`, unparseable output, no output, non-zero exit with no contract line, or the abort in step 7) → status "failed", \`branch\`: **null**, and put \`abort_reason\` plus the last few lines of the stderr file in "notes". This includes \`result_ref_failed\`, which carries a real commit_sha — do not try to recover that commit or invent a branch for it.
${guidance ? `\nOperator guidance from a prior attempt: ${guidance}\n` : ''}
Return via the required schema.`,
    {
      label: `imp-${task.id}-opencode`,
      phase: 'Dispatch',
      model: task.model,
      schema: IMP_RESULT_SCHEMA,
      isolation: 'worktree',
    }
  )
}

function dispatchImp(task, state, guidance, escalated) {
  if (!escalated && eligibleForOpencode(task)) return dispatchOpencodeImp(task, state, guidance)
  const isCode = task.type === 'code'
  // Specs must travel with tasks: the label is a one-line title, not instructions.
  // An imp dispatched with only the label improvises — observed failures include
  // "couldn't find repo owner", "concluded nothing to publish", and unauthorized
  // GitHub issues filed as the "deliverable". The spec (or a legacy state file's
  // run-level task string as fallback) is the imp's operative context.
  const spec = task.spec || `(No per-task spec recorded — legacy state file.) The run's overall goal, for context: ${state.task}`
  return agent(
    `You are one imp in a parallel swarm. Task #${task.id}: ${task.label}
Type: ${task.type}
Spec — your operative instructions; follow these, do not improvise beyond them:
${spec}
${guidance ? `\nThis is a retry. Operator guidance: ${guidance}\n` : ''}
${isCode ? 'You run in an isolated git worktree, created from the default branch\'s last committed HEAD (not the run\'s working branch — in-progress commits on a side branch are not visible to you). Make the minimal change that satisfies the task. Resolve this repo\'s gate/lint commands yourself and run them (plus any autofix) before committing — fix failures you caused, note pre-existing ones. Stage and commit; do not push. Return the branch name.' : ''}
${task.type === 'query' ? 'Read-only. No file changes. Return structured data. Cite sources (file paths, line numbers, URLs) for every claim.' : ''}
${task.type === 'publish' ? 'Create GitHub artifacts (PRs, issues, comments, Discussions) from the main working branch only, never from an isolated worktree branch. Use `gh api graphql` for Discussions. Confirm the artifact URL.' : ''}

Do exactly this task. Nothing more — note anything else you notice but do not fix it.
Return via the required schema: status "done" or "failed" (with a ≤50-word reason in notes if failed).`,
    {
      label: `imp-${task.id}${escalated ? '-escalated' : guidance ? '-retry' : ''}`,
      phase: 'Dispatch',
      model: task.model,
      schema: IMP_RESULT_SCHEMA,
      isolation: isCode ? 'worktree' : undefined,
    }
  )
}

// Parses `retry tasks #N,#M: <guidance>` / `skip tasks #N,#M` into structured form.
function parseTaskDecision(decision) {
  if (!decision) return null
  const retryMatch = decision.match(/^retry tasks #([\d,#\s]+):\s*(.*)$/i)
  if (retryMatch) {
    const ids = retryMatch[1].split(',').map((s) => Number(s.replace('#', '').trim()))
    return { kind: 'retry', ids, guidance: retryMatch[2].trim() }
  }
  const skipMatch = decision.match(/^skip tasks #([\d,#\s]+)$/i)
  if (skipMatch) {
    const ids = skipMatch[1].split(',').map((s) => Number(s.replace('#', '').trim()))
    return { kind: 'skip', ids }
  }
  return null
}

async function runDispatch(state) {
  const doneIds = new Set(state.tasks_done || [])
  const escalatedIds = new Set(state.escalated_tasks || [])
  const failed = new Map((state.failed_tasks || []).map((f) => [f.id, f]))
  let worktrees = { ...(state.worktrees || {}) }
  let artifacts = [...(state.artifacts || [])]

  const taskDecision = parseTaskDecision(state.operator_decision)
  const retryGuidance = new Map()
  if (taskDecision && taskDecision.kind === 'retry') {
    for (const id of taskDecision.ids) {
      failed.delete(id) // eligible for re-dispatch again
      retryGuidance.set(id, taskDecision.guidance)
    }
  } else if (taskDecision && taskDecision.kind === 'skip') {
    for (const id of taskDecision.ids) {
      const existing = failed.get(id) || { id, label: `task #${id}` }
      failed.set(id, { ...existing, notes: 'skipped by operator', skip_confirmed: true })
    }
  }

  const { stages, unresolved } = stageTasks(state.tasks, doneIds, failed)
  if (unresolved.length && !stages.length) {
    return { blocked: true, reason: 'dispatch_failed', detail: { step: 'topo_sort', unresolved: unresolved.map((t) => t.id) } }
  }

  for (const stage of stages) {
    // Dependency-failure propagation: never dispatch a task whose dep already failed
    // (a dep that's only "skip_confirmed" but not truly failed still blocks — the
    // dependent needs the skipped task's output, which doesn't exist).
    const runnable = stage.filter((t) => t.deps.every((d) => !failed.has(d)))
    const skipped = stage.filter((t) => !runnable.includes(t))
    for (const t of skipped) {
      if (!failed.has(t.id)) failed.set(t.id, { id: t.id, label: t.label, notes: `dependency failed` })
    }
    if (!runnable.length) continue

    const results = await parallel(
      runnable.map((t) => () => dispatchImp(t, state, retryGuidance.get(t.id)).then((r) => ({ task: t, result: r })))
    )

    // Escalation. An opencode-executor task that exhausted its attempts, aborted, or hit
    // a denied sandbox-off Bash call falls back to a normal Claude imp rather than failing
    // the run. So does one the planner marked `executor:"opencode"` without a usable
    // oracle — that never reached the tier at all (dispatchImp routed it to Claude
    // directly, costing nothing), but it is still a plan error that has to show up in the
    // measurement rather than looking like a task that never touched opencode.
    //
    // This runs BEFORE the bookkeeping forEach below on purpose: the fallback's branch has
    // to reach `worktrees` in the same heartbeat patch. runDispatch keeps only
    // id/branch/artifacts on success and discards notes, so `escalated_tasks` is the only
    // durable record that a merged branch came from a second attempt.
    const escalations = []
    for (let i = 0; i < runnable.length; i += 1) {
      const t = runnable[i]
      if (t.executor !== 'opencode') continue
      if (!eligibleForOpencode(t)) {
        escalatedIds.add(t.id) // ineligible: no oracle, already ran as a Claude imp
        continue
      }
      const r = results[i] ? results[i].result : null
      if (!r || r.status === 'failed') escalations.push({ index: i, task: t })
    }
    if (escalations.length) {
      const fallbacks = await parallel(
        escalations.map((e) => () =>
          dispatchImp(e.task, state, retryGuidance.get(e.task.id), true).then((r) => ({ task: e.task, result: r }))
        )
      )
      escalations.forEach((e, k) => {
        escalatedIds.add(e.task.id)
        results[e.index] = fallbacks[k] || null
      })
    }

    results.forEach((entry, i) => {
      // parallel() resolves a thunk that threw (e.g. worktree-creation contention) to
      // null — entry.task is unavailable in that case, so recover the task from its
      // position in `runnable` rather than silently dropping it uncounted.
      const task = entry ? entry.task : runnable[i]
      const result = entry ? entry.result : null
      if (!result) {
        failed.set(task.id, { id: task.id, label: task.label, notes: entry ? 'no result returned' : 'agent call errored (dropped by parallel())' })
        return
      }
      if (result.status === 'failed') {
        failed.set(task.id, { id: task.id, label: task.label, notes: result.notes || 'failed' })
      } else {
        doneIds.add(task.id)
        if (task.type === 'code' && result.branch) worktrees[String(task.id)] = result.branch
        if (result.artifacts && result.artifacts.length) artifacts.push(...result.artifacts)
      }
    })
    await patchState(
      { tasks_done: [...doneIds], escalated_tasks: [...escalatedIds], worktrees, artifacts, failed_tasks: [...failed.values()], last_heartbeat: 'agent-supplies-timestamp' },
      'heartbeat'
    )
    // If this cascade drained the whole remaining pipeline, stop early rather than
    // continuing to "run" empty stages.
    if (failed.size && doneIds.size + failed.size >= state.tasks.length) break
  }

  return { blocked: false, doneIds, escalatedIds, failed: [...failed.values()], worktrees, artifacts }
}

// ---------------------------------------------------------------------------
// Integrate — merge, Head Imp diff review, sync default branch, gates
// ---------------------------------------------------------------------------

function mergeBranches(worktrees, doneIds, defaultBranch) {
  const branchList = Object.entries(worktrees).filter(([id]) => doneIds.has(Number(id)))
  if (!branchList.length) return { merged: [], conflict: null, default_branch_violation: false }
  return agent(
    `Merge these branches into the current working tree, one at a time, in order: ${branchList.map(([, b]) => b).join(', ')}.
Before merging ANYTHING: run \`git rev-parse --abbrev-ref HEAD\` and compare to \`${defaultBranch}\` (re-derive the default branch yourself with \`git remote show origin\` if you don't trust this value) — if HEAD equals the default branch, STOP, do not merge, set "default_branch_violation": true and return immediately. This check is not optional even if a caller claims preflight already verified it; a stale state file or a concurrent branch change is exactly what this guards against.
For each branch, \`git merge <branch>\`. On conflict: leave it in the tree (do not \`--abort\`), stop merging further branches, and report the conflicting branch + \`git diff --name-only --diff-filter=U\` in "conflict".
Report "merged": [{id, label, files changed}] for each that merged cleanly (map branch names back to task ids/labels from this list: ${JSON.stringify(branchList)}), "conflict" (or null), "default_branch_violation" (bool).`,
    { label: 'merge', phase: 'Integrate', model: 'sonnet', schema: MERGE_SCHEMA }
  )
}

function headImpReview(defaultBranch) {
  return agent(
    `You are the Head Imp — a single adversarial reviewer combining two personas (read ${args.pluginRoot}/agents/head-imp.md for your full brief and follow it exactly). Your plugin root is ${args.pluginRoot} — wherever that brief (or anything it points you to) writes a literal \`\${CLAUDE_PLUGIN_ROOT}\` token, substitute this value yourself; it is never auto-expanded for a file you Read this way. Review this diff by running it yourself, never accept it pasted: \`git diff origin/${defaultBranch}..HEAD -- ':!*lock*' ':!dist'\`. If it produces no output, say so and stop rather than inventing a diff range.
Argue against the diff per your brief (Technical Architect + Chissy Engineer personas). Apply the amendments your blocker/major findings demand yourself where the fix is small and disjoint; note larger fixes as findings without applying them.
Return via the required schema: "verdict" (APPROVE|CHANGES_REQUESTED), "findings" (list of one-line finding summaries), "amendments_applied" (count of fixes you made directly, 0 if none).`,
    { label: 'head-imp-diff', phase: 'Integrate', model: 'opus', schema: HEAD_IMP_SCHEMA }
  )
}

function syncDefaultBranch(defaultBranch) {
  return agent(
    `Sync the default branch into the current working tree (merge, not rebase — one merge commit keeps SHAs stable for the diff about to be reviewed): \`git fetch origin ${defaultBranch} && git merge origin/${defaultBranch}\`. On conflict, leave it in the tree and report it. Return via the required schema (reuse "merged": [] and "conflict" fields; "default_branch_violation": false always here since this step only ever merges FROM the default branch, never onto it).`,
    { label: 'sync-default', phase: 'Integrate', model: 'sonnet', schema: MERGE_SCHEMA }
  )
}

function discoverGates() {
  return agent(
    `Resolve this repo's gate commands once: inspect package.json scripts, Makefile, pyproject.toml, CI config (.github/workflows/*), and AGENTS.md/CONTRIBUTING.md for the canonical build/lint/test/type commands. Return the ordered list (build, then lint, then test, then type — omit any that don't apply to this repo) via the required schema: "gates": [{name, cmd}].`,
    { label: 'discover-gates', phase: 'Integrate', model: 'sonnet', schema: GATE_DISCOVERY_SCHEMA }
  )
}

function runGate(gate, guidance) {
  return agent(
    `Run this command, redirecting output to a file and reading only the tail (the log itself can be large): \`${gate.cmd} > "$TMPDIR/imps-gate-${gate.name}.log" 2>&1; echo "exit: $?"\`.${guidance ? ` Apply this guidance first if it suggests a fix: ${guidance}` : ''}
Return via the required schema: "gate": "${gate.name}", "cmd": "${gate.cmd}", "pass" (exit 0), "tail" (last 20 lines of the log).`,
    { label: `gate-${gate.name}`, phase: 'Integrate', model: 'sonnet', schema: GATE_RUN_SCHEMA }
  )
}

function fixGate(gate, tail, guidance) {
  return agent(
    `Gate "${gate.name}" (\`${gate.cmd}\`) failed. Log tail:\n${tail}\n${guidance ? `Operator guidance: ${guidance}\n` : ''}Diagnose and fix the failure — make the minimal change needed to get this gate green. Do not touch unrelated code. When done, report what you changed in one line.`,
    { label: `fix-${gate.name}`, phase: 'Integrate', model: 'sonnet' }
  )
}

// Parses `retry <gate>: <guidance>` / `skip <gate>` into structured form. Gate names are
// matched against the discovered gate list's own names (build/lint/test/type), not
// task IDs — distinguished from parseTaskDecision by the absence of "tasks #".
function parseGateDecision(decision) {
  if (!decision) return null
  const retryMatch = decision.match(/^retry (\w+):\s*(.*)$/i)
  if (retryMatch) return { kind: 'retry', gate: retryMatch[1], guidance: retryMatch[2].trim() }
  const skipMatch = decision.match(/^skip (\w+)$/i)
  if (skipMatch) return { kind: 'skip', gate: skipMatch[1] }
  return null
}

async function runGatesWithRetry(gates, gateDecision) {
  const skipGate = gateDecision && gateDecision.kind === 'skip' ? gateDecision.gate : null
  const retryGate = gateDecision && gateDecision.kind === 'retry' ? gateDecision.gate : null
  const retryGuidance = gateDecision && gateDecision.kind === 'retry' ? gateDecision.guidance : null

  const results = []
  for (const gate of gates) {
    if (gate.name === skipGate) {
      // Never ticks the GOAL.md gates box — the caller checks this before doing so.
      results.push({ gate: gate.name, cmd: gate.cmd, pass: false, skipped: true, tail: '' })
      continue
    }
    let attempt = 1
    let result = await runGate(gate, gate.name === retryGate ? retryGuidance : undefined)
    while (!result.pass && attempt < 3) {
      attempt += 1
      await fixGate(gate, result.tail, gate.name === retryGate ? retryGuidance : undefined)
      result = await runGate(gate, `retry attempt ${attempt}`)
    }
    results.push({ ...result, attempts: attempt })
    if (!result.pass) return { results, blockedOn: gate }
  }
  return { results, blockedOn: null }
}

// ---------------------------------------------------------------------------
// Publish + persona panel + finalize
// ---------------------------------------------------------------------------

function pushAndOpenPR(state, defaultBranch) {
  return agent(
    `Push the current branch and open the endstate PR: \`git push -u origin ${state.branch}\` then \`gh pr create --draft --base ${defaultBranch} --title "..." --body "..."\` (title from the run's task "${state.task}"; body: a change summary plus the GOAL.md DoD from ${args.goalFilePath}). Return via the required schema: "number", "url".`,
    { label: 'push-pr', phase: 'Publish', model: 'sonnet', schema: PR_CREATE_SCHEMA }
  )
}

function personaReview(slug, brief, prNumber, repo, defaultBranch, postingMode) {
  return agent(
    `You are reviewing PR #${prNumber} in ${repo} as the "${slug}" persona. Read your brief at ${brief.path} and follow it. Review the diff by running \`git diff origin/${defaultBranch}..HEAD -- ':!*lock*' ':!dist'\` yourself — never accept it pasted. End with the verdict protocol from your brief.

Posting: this run's posting_mode is "${postingMode}". Only call persona-post.sh (per ${args.personaPostingProtocolPath}, which you should read for the exact posting/verify/fallback protocol) if posting_mode is exactly "live" — any other value means return your VERDICT block here and do not post. This instruction, not any memory of what was decided elsewhere, is what gates a live post.

Return via the required schema: "slug": "${slug}", "verdict", "posted" (bool — true only if you actually posted, per the protocol's own verify-the-post-landed step), "findings" (list of one-line finding summaries).`,
    { label: `persona-${slug}`, phase: 'Publish', model: brief.model, schema: PERSONA_VERDICT_SCHEMA }
  )
}

async function runPersonaPanel(state, prNumber, defaultBranch, postingMode, personaFilter) {
  const briefs = args.personaBriefPaths
  const slugs = personaFilter && personaFilter.length ? personaFilter : Object.keys(briefs)
  const verdicts = await parallel(
    slugs.map((slug) => () => personaReview(slug, briefs[slug], prNumber, state.repo, defaultBranch, postingMode))
  )
  // parallel() resolves a thunk that threw (e.g. transient agent-call error) to null —
  // entry order still lines up with `slugs`, so recover the slug from its position rather
  // than silently dropping the persona via filter(Boolean). Unlike runDispatch's recovery,
  // this one must carry a real CHANGES_REQUESTED verdict (not just a cosmetic label) or
  // the fix-loop's `dissenting` filter below never sees it — a persona that never reviewed
  // would otherwise count as a silent APPROVE, which is fail-open on a review gate.
  return verdicts.map((v, i) =>
    v || {
      slug: slugs[i],
      verdict: 'CHANGES_REQUESTED',
      posted: false,
      findings: ['persona review dispatch errored (dropped by parallel()) — not reviewed'],
    }
  )
}

function fixLoopRound(findings) {
  return agent(
    `These persona findings are open (blocker/major only, already deduped): ${JSON.stringify(findings)}. Group by disjoint file sets. For disjoint groups, make the fix directly (small, targeted). For cross-cutting or conflicting findings, resolve with this precedence: correctness > data integrity > security > UX > style. Commit your changes and push to the current branch. If a finding is not actually valid, note "WONTFIX: <rationale>" instead of forcing a change. Report what you changed in one line.`,
    { label: 'fix-round', phase: 'Publish', model: 'sonnet' }
  )
}

// Requirement-coverage pass: verify each FUNCTIONAL DoD criterion against the merged diff
// and reconcile its GOAL.md checkbox to match. Read-only w.r.t. everything except the
// functional-criterion checkbox characters, and idempotent on resume (re-ticks satisfied,
// unticks regressed). Dispatched once per successful Integrate, never in the PR: branch.
function dodCoverage(defaultBranch) {
  return agent(
    `You are verifying requirement coverage for this run. Two jobs — do BOTH, in order.

1. Read the "## Definition of Done" section of ${args.goalFilePath}. Identify the FUNCTIONAL acceptance criteria only — the checkbox lines describing what the work must actually deliver. EXCLUDE these fixed process-status lines, which are owned by other mechanisms and must NEVER be touched, reconciled, or reported here: any line reading roughly "Gates green ...", "Persona panel reviewed ...", "No merge conflicts ...", "CI green on the PR", "Outcome comment posted to the source Discussion".

2. Run \`git diff origin/${defaultBranch}..HEAD\` yourself (never accept a diff pasted to you). For each functional criterion, judge it against the ACTUAL diff and assign a status:
   - "satisfied" — the diff clearly implements it (evidence: the file paths / concrete changes that do so),
   - "unsatisfied" — the diff does not implement it, or contradicts it,
   - "unverifiable" — cannot be determined from the diff alone (e.g. needs a runtime or manual check).
   For each, capture {text (the criterion's wording, without the checkbox), status, evidence (a one-line justification)}.

3. RECONCILE each functional criterion's checkbox in ${args.goalFilePath} to match the status you just assigned — idempotently AND correctly on regression:
   - "satisfied" -> the box MUST end up "[x]" (tick it if currently "[ ]"; leave it if already "[x]").
   - "unsatisfied" -> the box MUST end up "[ ]" (UNTICK it — change "[x]" to "[ ]" — if currently ticked; leave it if already "[ ]"). A criterion an earlier resume ticked but that is no longer satisfied MUST end up unticked, not left stale.
   - "unverifiable" -> do NOT touch the box either way. "Cannot be judged from the diff alone" is not the same claim as "not met" — a human may have already manually verified and ticked it (e.g. "smoke-tested manually in Chrome"), and unticking on every resume would erase that. Leave whatever box state you found.
   Edit ONLY the box characters of functional-criterion lines you are ticking/unticking under the rules above. Do NOT touch the excluded process-status lines, their boxes, prose, or any other text.

Return via the required schema: "criteria": [{text, status, evidence}] for every functional criterion (empty array if the DoD has no functional criteria).`,
    { label: 'dod-coverage', phase: 'Integrate', model: 'opus', schema: DOD_COVERAGE_SCHEMA }
  )
}

// Cheap surface-detection: does the merged diff touch any browser-renderable file? Gates
// whether the ux-designer persona reviews (change B). Read-only. Fails toward MORE review.
function detectBrowserSurface(defaultBranch) {
  return agent(
    `Run \`git diff --name-only origin/${defaultBranch}..HEAD\` yourself and classify whether ANY changed path is a browser-renderable surface — a file that is served to and rendered by a browser (component, template, style, markup, or asset). Judge by ROLE and LOCATION, not by bare extension: a plain .js/.ts file can absolutely BE the browser surface (e.g. a React component at src/components/Button.js, an Angular component at nav.component.ts, a client-side route/page file) — extension alone must never rule it out. Instead, EXCLUDE paths that are clearly not browser-rendered by role: build/CI/workflow scripts (scripts/, .github/), server/backend code (server/, api/, backend/), config files (*.config.*, *.rc, package.json, tsconfig.json), test files (*.test.*, *.spec.*, __tests__/), and docs (*.md). Everything else plausibly UI-facing (including an ambiguous bare .js/.ts under a components/pages/views/routes-style path) counts as a surface — this classifier fails toward MORE review, so treat ambiguity as "yes, it's a surface." Return via the required schema: "has_surface" (true if at least one changed path is such a surface, else false) and "reason" (one line naming the deciding file(s), or stating none were found).`,
    { label: 'detect-surface', phase: 'Publish', model: 'haiku', schema: SURFACE_DETECTION_SCHEMA }
  )
}

function finalizeRun(state, prInfo, verdicts, dispatchStats, dodCoverageCriteria, dodCoverageError, surfaceDetectionError) {
  // Both are advisory-pass failures (surface-detection, dod-coverage) that must reach the
  // audit trail the same way — neither is fatal to the run, but a silent null on either
  // would hide a degraded advisory check behind a clean-looking finalize. Their source text
  // (a haiku classifier's freeform "reason", or a thrown error's .message) is untrusted —
  // it can legitimately contain backticks around a file path, `$(...)`-shaped text, or other
  // shell metacharacters — and this string ends up inside a shell `--notes "..."` argument
  // the agent constructs below. Stripping only `"` (as an earlier version of this line did)
  // still let backticks/`$(` reach that argument verbatim, a real command-injection path via
  // the finalize agent dutifully copying it in "verbatim". Strip every shell-meaningful
  // character here (not just at each call site) rather than relying on the agent's own
  // quoting discipline to neutralize untrusted text.
  const advisoryNotes = [surfaceDetectionError, dodCoverageError].filter(Boolean).join('; ').replace(/[`"$\\]/g, '')
  return agent(
    `Finalize this /imps run. State file: ${args.stateFilePath}. GOAL.md: ${args.goalFilePath}.
1. You MUST run this now, before any other step below (the script itself is fail-soft — a missing \`jq\` or unwritable log dir just warns and exits 0 — but calling it is not optional): \`${args.pluginRoot}/scripts/audit-log.sh --plugin imps --command /imps:imps --exit-status completed --duration-ms <computed from the state file's dispatched_at, same basis as run_stats.elapsed below, in ms> --scope <project-or-user> --notes "<one-line summary>"\`. The \`--notes\` value is a one-line summary you write yourself${advisoryNotes ? ` — it MUST ALSO mention this verbatim, even though it wasn't part of your own summary (it is a separate, required fact, not a suggestion): ${advisoryNotes}` : ''}. Use single quotes for any quoting you need inside the \`--notes\` value — never a literal double quote, backtick, dollar sign, or backslash, since any of those would break out of or reinterpret this command's own double-quoted argument.
2. If a PR exists (${prInfo ? `#${prInfo.number}` : 'none'}), flip it to ready: \`gh pr ready ${prInfo ? prInfo.number : ''}\`. Skip if no PR.
3. Collect artifact links from the state file's "artifacts" field into the result.
4. If the state file's "source_discussion" is non-null AND "discussion_comment_url" is still null, post a short outcome comment (≤150 words: what shipped, PR/artifact URLs, unresolved findings — persona verdicts/findings for reference: ${JSON.stringify(verdicts)}; DoD acceptance-criteria coverage for reference, mention any unsatisfied ones: ${JSON.stringify(dodCoverageCriteria || [])}${dodCoverageError ? `, noting the coverage check itself did not complete: ${dodCoverageError}` : ''}) via \`gh api graphql\` addDiscussionComment using source_discussion.id verbatim. Write the returned comment URL into the state file's discussion_comment_url field immediately (patch the state file yourself) — a non-null URL means never post again on a future invocation.
5. If a PR was opened, write ~/.claude/imps/runs/<slug>.prs.json (derive slug from the state file path) with: repo, pr_number, pr_url, branch, base_branch, poll_interval_seconds (from state file), started_at (now, ISO), handled_comment_ids: [], ci_fix_attempts: {}, max_age_hours: 48.
6. Assemble run_stats: dispatched_at (from state file), elapsed (now minus dispatched_at, "Xm Ys"), tokens_spent and model_counts (from: ${JSON.stringify(dispatchStats)}), tasks ([{id, model}] for every task), achieved (≤5 one-liners in plain value terms — what changed for the user, not implementation detail), decision_points (one line per pivot: Head Imp amendments, conflicts resolved, skipped gates/tasks${advisoryNotes ? `, the advisory-check note(s) above` : ''} — omit if none).
7. Set the state file's "phase" to "final" (NOT deleted yet — deletion happens only after the learnings step, so a death here still resumes gracefully).

Return via the required schema: pr_ready (bool), discussion_comment_url (string or null), prs_monitor (object or null: {state_file, pr_number}), run_stats (object), learnings_candidates (array of ≤10 concise "rule to apply next time" strings — surprising, wrong, or notably effective things about this run; empty array if trivial/no surprises).`,
    { label: 'finalize', phase: 'Finalize', model: 'sonnet', schema: FINALIZE_SCHEMA }
  )
}

function appendLearnings(candidates) {
  // Deliberately does NOT delete the state file here — the caller must persist the
  // learnings_saved marker FIRST (via patchState) and only delete afterward. Deleting
  // inside this same call, before the marker is durably written, is exactly the ordering
  // bug a Head Imp review caught: a crash between the append and the delete leaves
  // learnings_saved unset, so the next fresh invocation's guard (`if (state.learnings_saved)`)
  // is false and re-appends — and deleting from inside this agent call would also mean a
  // subsequent patchState() targets a file that no longer exists.
  return agent(
    `The operator confirmed these learnings should be saved: ${JSON.stringify(candidates)}. For each, classify its scope: project-specific (mentions this repo's stack, commands, file paths, conventions) -> append to .claude/imps/learnings.md in the repo root; generally applicable (model routing, task boundaries, dispatch patterns) -> append to ~/.claude/imps/learnings.md. Format: under a "## YYYY-MM-DD — <project> <task>" heading (create "## Active rules" section first if the file doesn't have one yet, ≤10 bullets, promote a repeated rule into it). Do NOT touch the run's state file or GOAL.md in this step — that happens separately, afterward.
Return via the required schema: "saved": [{rule, scope}] for each learning actually written.`,
    { label: 'append-learnings', phase: 'Finalize', model: 'sonnet', schema: LEARNINGS_APPEND_SCHEMA }
  )
}

function deleteStateFile() {
  return agent(
    `Delete the run state file at ${args.stateFilePath}. Do NOT delete ${args.goalFilePath} (GOAL.md) — it is the human-readable record and stays after the run ends.`,
    { label: 'delete-state-file', phase: 'Finalize', model: 'haiku' }
  )
}

// ---------------------------------------------------------------------------
// Main
// ---------------------------------------------------------------------------

phase('Preflight')
let state = await readState()

// Cross-check readState()'s output against the raw file before trusting anything in
// `state` — including operator_decision/last_result below, which come from the same
// possibly-mismapped read (#87). A mismatch here means readState() itself is
// untrustworthy, so fail loudly instead of silently routing on garbled fields.
const rawStateCheck = await countStateTasks()
const stateValidation = validateStateRead(state, rawStateCheck)
if (!stateValidation.ok) {
  const result = { status: 'blocked', reason: 'state_read_mismatch', detail: { error: stateValidation.error } }
  await saveResult(result)
  return result
}

// ---- Route on operator_decision + last_result.status for a resumed/blocked run ----
const decision = state.operator_decision
const lastStatus = state.last_result && state.last_result.status

if (decision === 'abort') {
  if (state.source_discussion) {
    await agent(
      `Post "Run aborted: ${(state.last_result && state.last_result.reason) || 'operator abort'}. No changes were merged." as a Discussion comment via \`gh api graphql\` addDiscussionComment using source_discussion.id verbatim: ${JSON.stringify(state.source_discussion)}.`,
      { label: 'abort-notice', phase: 'Finalize', model: 'haiku' }
    )
  }
  const result = { status: 'aborted', tree_state: 'left as-is per operator abort', abort_notice_posted: !!state.source_discussion }
  await saveResult(result)
  return result
}

if (lastStatus === 'final' && decision && decision.startsWith('learnings:')) {
  const raw = decision.slice('learnings:'.length).trim()
  const candidates = raw === 'none' ? [] : JSON.parse(raw)
  if (state.learnings_saved) {
    // Already appended (marker is set) by a prior invocation that died before the
    // state-file delete completed — do NOT re-append, just finish the delete.
    await deleteStateFile()
    return { status: 'done', learnings_saved: state.learnings_saved }
  }
  // Order matters: append, THEN persist the marker, THEN delete — in that exact
  // sequence. A crash between append and marker-write re-appends once more on the next
  // invocation (learnings.md dedup risk is accepted as the lesser failure); a crash
  // between marker-write and delete is safe (the branch above just finishes the delete).
  // Deleting before the marker is set, or inside the same call as the append, is the bug
  // a Head Imp review caught in an earlier draft — never do that.
  const appended = await appendLearnings(candidates)
  await patchState({ learnings_saved: appended.saved }, 'mark-learnings-saved')
  await deleteStateFile()
  return { status: 'done', learnings_saved: appended.saved }
}

if (lastStatus === 'awaiting_authorization' && decision && decision.startsWith('PR:')) {
  const postingMode = decision === 'PR: yes' ? 'live' : decision === 'PR: yes, no-post' ? 'no-post' : 'none'
  phase('Publish')
  let prInfo = state.pr
  if (postingMode !== 'none' && !prInfo) {
    prInfo = await pushAndOpenPR(state, state.last_result.default_branch)
    await patchState({ pr: prInfo }, 'save-pr')
  }
  // `verdicts` stores {slug: {verdict, findings}} — full content, not just the verdict
  // label, so a no-post/findings-inline run still has each persona's actual findings to
  // show the operator (a bare verdict word is not "the review record").
  let verdicts = state.verdicts
  // Persisted alongside verdicts (not just a local var) so a resumed invocation that skips
  // the panel below (verdicts already saved) still has this for the finalizeRun call further
  // down — set only when detection itself errors, so a persistently-flaking classifier is
  // visible in the audit trail instead of an eternal, silent "ran all five personas."
  let surfaceDetectionError = state.surface_detection_error || null
  // DoD-coverage snapshot to publish at finalize. Defaults to the Integrate-phase snapshot;
  // overwritten below only if the persona fix loop actually pushes commits (round > 0) —
  // that changes the diff the Integrate-phase snapshot was judged against, so a criterion
  // the fix loop just satisfied must not still be published/ticked as unsatisfied. A legacy
  // state file predating `dod_coverage_status` can't tell "checked" apart from "not
  // applicable" or "failed" — treat it as "unknown" rather than guessing "checked".
  let coverageCriteria = state.last_result.dod_coverage || []
  let coverageError = state.last_result.dod_coverage_error || null
  let coverageStatus = state.last_result.dod_coverage_status || 'unknown'
  if (state.dod_coverage_status_final) {
    // A prior invocation already ran the post-fix-loop recompute below and persisted it —
    // this resume must keep using that, not the older pre-fix-loop Integrate snapshot.
    coverageCriteria = state.dod_coverage_final || []
    coverageError = state.dod_coverage_error_final || null
    coverageStatus = state.dod_coverage_status_final
  }
  if (!verdicts && prInfo) {
    // Surface-detection skip (change B): only the ux-designer (browser) persona depends on
    // a browser-renderable surface being in the diff. Cheaply classify the changed paths and,
    // if none is a browser surface, drop ux-designer from the INITIAL panel only (the dissenter
    // re-review below is an orthogonal filter and is left untouched). Fail toward MORE review:
    // has_surface true, or ANY error in classification, runs all five personas.
    let personaFilter
    let uxSkipFinding = null
    try {
      const surface = await detectBrowserSurface(state.last_result.default_branch)
      if (surface && surface.has_surface === false) {
        // Derived from each roster entry's own `requires` tags, not a hardcoded slug — a
        // future persona (browser or non-browser) is handled by its roster entry, not by
        // editing this filter.
        personaFilter = Object.entries(args.personaBriefPaths)
          .filter(([, brief]) => !(brief.requires || []).includes('browser-surface'))
          .map(([slug]) => slug)
        uxSkipFinding = `ux-designer skipped — no browser-renderable surface: ${surface.reason}`
        surfaceDetectionError = null // clean detection — clear any stale error from a prior invocation
      } else if (!surface || typeof surface.has_surface !== 'boolean') {
        // Non-throwing but malformed (missing/mistyped has_surface) resolves to the same
        // fail-open "run all personas" outcome as the catch below — but without this branch
        // it left no record of why, defeating the flaking-classifier visibility this field
        // exists for. Describe the fields rather than JSON.stringify-ing the whole object —
        // a raw JSON blob can carry double quotes that break the shell `--notes "..."`
        // argument finalizeRun's audit-log call later builds from this string.
        surfaceDetectionError = `surface-detection returned a malformed result, ran all personas: has_surface=${surface ? String(surface.has_surface) : 'undefined'}, reason=${surface && surface.reason ? surface.reason : 'none given'}`
      } else {
        surfaceDetectionError = null // clean detection (surface found) — clear any stale error
      }
    } catch (e) {
      // fail-open on the skip = fail-closed on review: personaFilter stays undefined, all
      // five personas run — but record why, for finalize/audit visibility.
      surfaceDetectionError = `surface-detection errored, ran all personas: ${e && e.message ? e.message : e}`
    }
    const results = await runPersonaPanel(state, prInfo.number, state.last_result.default_branch, postingMode, personaFilter)
    let current = Object.fromEntries(results.map((v) => [v.slug, { verdict: v.verdict, posted: v.posted, findings: v.findings }]))
    // Record the skip as a ux-designer finding so it surfaces in findings_inline / the final
    // report. "SKIPPED" is not "CHANGES_REQUESTED", so the dissenter fix-loop never re-reviews it.
    if (uxSkipFinding) {
      current['ux-designer'] = { verdict: 'SKIPPED', findings: [uxSkipFinding] }
    }

    // Fix loop, max 3 rounds. Deliberately does NOT persist `verdicts` to the state file
    // until the whole loop (or a resume of it) is done — persisting early made a crash
    // mid-loop look "done" to a resumed invocation, silently skipping the remaining
    // rounds and finalizing with unaddressed persona findings.
    let round = 0
    let dissenting = results.filter((v) => v.verdict === 'CHANGES_REQUESTED')
    while (dissenting.length && round < 3) {
      round += 1
      const findings = dissenting.flatMap((v) => v.findings)
      await fixLoopRound(findings)
      if (postingMode !== 'none') {
        await agent(`Push fix-round ${round}'s commits to the PR branch: git push.`, { label: `push-fix-${round}`, phase: 'Publish', model: 'haiku' })
      }
      const reReview = await runPersonaPanel(
        state,
        prInfo.number,
        state.last_result.default_branch,
        postingMode,
        dissenting.map((v) => v.slug) // only re-review personas that dissented — not the whole panel
      )
      for (const v of reReview) current[v.slug] = { verdict: v.verdict, posted: v.posted, findings: v.findings }
      dissenting = reReview.filter((v) => v.verdict === 'CHANGES_REQUESTED')
    }
    if (round > 0) {
      // The fix loop just pushed real commits — the Integrate-phase coverage snapshot
      // (taken before any of this ran) is now stale. Recompute against the actual diff so
      // a criterion the fix loop just satisfied isn't still published/ticked as unsatisfied.
      try {
        const recomputed = await dodCoverage(state.last_result.default_branch)
        coverageCriteria = recomputed.criteria || []
        coverageError = null
        coverageStatus = 'checked'
      } catch (e) {
        coverageError = `dod-coverage re-check after the persona fix loop failed, publishing the pre-fix-loop snapshot instead: ${e && e.message ? e.message : e}`
        coverageStatus = 'failed'
      }
    }
    verdicts = current
    await patchState(
      {
        verdicts,
        surface_detection_error: surfaceDetectionError,
        dod_coverage_final: coverageCriteria,
        dod_coverage_error_final: coverageError,
        dod_coverage_status_final: coverageStatus,
      },
      'save-verdicts'
    )
  }

  phase('Finalize')
  // finalizeRun itself is not internally idempotent (it can rewrite .prs.json and
  // re-append to audit.jsonl) — guard against re-running it on a resume that only
  // needed to catch up the persona panel/fix loop above. `phase: "final"` is set as
  // finalizeRun's own last step, so its presence means finalize already completed.
  if (state.phase === 'final' && state.last_result && state.last_result.status === 'final') {
    return state.last_result
  }
  const finalized = await finalizeRun(state, prInfo, verdicts, state.last_result.dispatch, coverageCriteria, coverageError, surfaceDetectionError)
  const result = {
    status: 'final',
    pr: prInfo ? { url: prInfo.url, number: prInfo.number, ready: finalized.pr_ready } : null,
    verdicts,
    diff_stat: state.last_result.diff_stat,
    // Reflects the post-fix-loop recompute above when one happened, not just the
    // Integrate-phase snapshot — otherwise a criterion the fix loop just satisfied would
    // still reach the PR body, the Discussion outcome comment, and audit.jsonl as unsatisfied.
    dod_coverage: coverageCriteria,
    // `dod_coverage_status` ("checked" | "not_applicable" | "failed" | "unknown")
    // disambiguates an empty/stale `dod_coverage` array's cause explicitly, instead of
    // making the caller infer it from emptiness-plus-error-presence.
    dod_coverage_error: coverageError,
    dod_coverage_status: coverageStatus,
    // Visible in the final result the same way dod_coverage_error is — previously dropped
    // here (unlike dod_coverage_error three lines below it used to be), so a persistently
    // flaking surface-detection classifier was indistinguishable from a healthy run once the
    // state file was deleted.
    surface_detection_error: surfaceDetectionError,
    discussion_comment_url: finalized.discussion_comment_url,
    prs_monitor: finalized.prs_monitor,
    run_stats: finalized.run_stats,
    learnings_candidates: finalized.learnings_candidates,
    // Full findings content, not just the verdict label — this is the operator's only
    // record of what each persona actually found when nothing was posted to GitHub.
    findings_inline:
      postingMode === 'none' || postingMode === 'no-post'
        ? Object.entries(verdicts || {}).flatMap(([slug, v]) => (v.findings || []).map((f) => `${slug}: ${f}`))
        : [],
  }
  await saveResult(result)
  return result
}

if (decision === 'integrate partial') {
  // Only reachable after `imps_failed` — confirm every currently-unresolved failure as
  // an accepted omission (same effect as the operator naming them all in `skip tasks`)
  // so the triage step below doesn't immediately re-block on the same failures. Without
  // this, `integrate partial` would silently loop: dispatch reruns, nothing new
  // completes, triage sees the same unconfirmed failures, and re-emits `imps_failed`.
  const stillFailed = (state.failed_tasks || []).filter((f) => !f.skip_confirmed)
  if (stillFailed.length) {
    const confirmed = stillFailed.map((f) => ({ ...f, skip_confirmed: true }))
    const untouched = (state.failed_tasks || []).filter((f) => f.skip_confirmed)
    state = await patchState({ failed_tasks: [...untouched, ...confirmed] }, 'confirm-partial-integrate')
  }
}
// `retry tasks #N,#M`, `skip tasks #N,#M`, `resolved, continue`, `reconciled, continue`,
// and (having just been normalized above) `integrate partial` all fall through to the
// normal dispatch/integrate flow below — the relevant step reads `decision` itself (e.g.
// runGate/fixGate honor retry guidance; dispatch honors retry/skip task lists via the
// state file's tasks_done/failed_tasks, which the operator's chosen path — or the
// normalization above — already updated before re-invoking).

// ---- Normal flow: dispatch -> integrate -> awaiting_authorization ----

phase('Dispatch')
if (!state.dispatched_at) {
  const pre = await preflight(state)
  if (!pre.ok) {
    const result = { status: 'blocked', reason: 'dispatch_failed', detail: { error: pre.error } }
    await saveResult(result)
    return result
  }
  if (pre.branch_reset) {
    state = await patchState({ branch: pre.new_branch }, 'branch-reset')
  }
  await patchState({ dispatched_at: 'agent-supplies-timestamp', segment: 'dispatch' }, 'claim-run')
}

const dispatchOutcome = await runDispatch(state)
if (dispatchOutcome.blocked) {
  const result = { status: 'blocked', reason: dispatchOutcome.reason, detail: dispatchOutcome.detail }
  await saveResult(result)
  return result
}

const unconfirmedFailures = dispatchOutcome.failed.filter((f) => !f.skip_confirmed)
if (unconfirmedFailures.length) {
  // Triage against GOAL.md's DoD is itself a judgment call — ask once, not per task.
  // Tasks the operator already confirmed "skip" are excluded — don't re-ask the same
  // question a second time just because they still show up in the failed list.
  const triage = await agent(
    `Read the DoD in ${args.goalFilePath}. These tasks failed: ${JSON.stringify(unconfirmedFailures)}. Does any failure block an acceptance criterion? Return "blocking": true/false and, if true, nothing else changes — the caller emits a blocked result.`,
    { label: 'triage-failures', phase: 'Dispatch', model: 'sonnet', schema: { type: 'object', properties: { blocking: { type: 'boolean' } }, required: ['blocking'] } }
  )
  if (triage.blocking) {
    const result = { status: 'blocked', reason: 'imps_failed', detail: { failed: unconfirmedFailures, done: [...dispatchOutcome.doneIds] } }
    await saveResult(result)
    return result
  }
}

phase('Integrate')
await patchState({ segment: 'integrate' }, 'enter-integrate')
const defaultBranchInfo = await agent('Run `git remote show origin | grep \'HEAD branch\'` and return just the branch name.', { label: 'get-default-branch', phase: 'Integrate', model: 'haiku', schema: { type: 'object', properties: { default_branch: { type: 'string' } }, required: ['default_branch'] } })
const defaultBranch = defaultBranchInfo.default_branch

const mergeResult = await mergeBranches(dispatchOutcome.worktrees, dispatchOutcome.doneIds, defaultBranch)
if (mergeResult.default_branch_violation) {
  const result = { status: 'blocked', reason: 'branch_mismatch', detail: { note: 'HEAD resolved to the default branch at merge time' } }
  await saveResult(result)
  return result
}
if (mergeResult.conflict) {
  const result = { status: 'blocked', reason: 'merge_conflict', detail: mergeResult.conflict }
  await saveResult(result)
  return result
}

let headImp = null
const hasDiff = mergeResult.merged.length > 0
if (hasDiff) {
  headImp = await headImpReview(defaultBranch)
}

const syncResult = await syncDefaultBranch(defaultBranch)
if (syncResult.conflict) {
  const result = { status: 'blocked', reason: 'merge_conflict', detail: syncResult.conflict }
  await saveResult(result)
  return result
}

let gateCommands = state.gate_commands
if (!gateCommands) {
  const discovery = await discoverGates()
  gateCommands = discovery.gates
  await patchState({ gate_commands: gateCommands }, 'save-gate-commands')
}

const gateOutcome = await runGatesWithRetry(gateCommands, parseGateDecision(state.operator_decision))
if (gateOutcome.blockedOn) {
  const failedResult = gateOutcome.results[gateOutcome.results.length - 1]
  const result = { status: 'blocked', reason: 'gate_red', detail: { gate: gateOutcome.blockedOn.name, cmd: gateOutcome.blockedOn.cmd, tail: failedResult.tail } }
  await saveResult(result)
  return result
}

const diffStatInfo = await agent(`Run \`git diff origin/${defaultBranch}..HEAD --stat\` and return the summary line (e.g. "12 files changed, 340 insertions(+), 25 deletions(-)").`, { label: 'diff-stat', phase: 'Integrate', model: 'haiku', schema: { type: 'object', properties: { diff_stat: { type: 'string' } }, required: ['diff_stat'] } })

const anyGateSkipped = gateOutcome.results.some((g) => g.skipped)
if (!anyGateSkipped) {
  await agent(`Mark the gates Definition-of-Done checkbox "[x]" in ${args.goalFilePath} (the line reading roughly "Gates green (build · lint · test · type ...)").`, { label: 'tick-gates-box', phase: 'Integrate', model: 'haiku' })
}

// Requirement-coverage pass: verify each functional DoD criterion against the merged diff
// and reconcile its GOAL.md checkbox. Idempotent on resume (this segment only re-runs after
// a gate/merge block, by which point dispatch+merge are no-ops); it re-ticks satisfied boxes
// and unticks regressed ones. Never runs in the PR:-decision branch, so it fires at most once
// per successful Integrate. Guarded by hasDiff (same guard as headImpReview above): on an
// artifact-only/zero-code run there is no diff to judge criteria against, so every functional
// criterion would otherwise come back "unsatisfied" — a false "N acceptance criteria not met"
// callout for a run that never touched code. Also never let this advisory step's own failure
// take down the whole finalize path — every other failure in this segment returns a
// structured {status: "blocked"}; this one degrades to an empty coverage list plus an error
// note instead of throwing past patchState/saveResult.
let coverage
let dodCoverageError = null
let dodCoverageStatus = 'checked'
if (!hasDiff) {
  coverage = { criteria: [] }
  dodCoverageStatus = 'not_applicable'
  // Wording deliberately doesn't assert this invocation was "artifact-only" — hasDiff only
  // means this invocation's merge step had nothing new to merge, which is equally true when
  // every code branch was already merged by a prior invocation of the same run.
  dodCoverageError = 'dod-coverage not checked: no newly-merged diff in this invocation to judge criteria against (no code tasks ran, or their branches were already merged by a prior invocation)'
} else {
  try {
    coverage = await dodCoverage(defaultBranch)
  } catch (e) {
    coverage = { criteria: [] }
    dodCoverageStatus = 'failed'
    dodCoverageError = `dod-coverage check failed, treating as unverified: ${e && e.message ? e.message : e}`
  }
}

// model_counts is derivable from the task table itself (plain JS, no agent call needed).
// tokens_spent is NOT available here: unlike the old design (which read the Agent tool's
// own `subagent_tokens` usage metadata directly off each imp's completion), a Workflow
// script's agent() call has no documented way to surface per-call token usage — left
// null rather than faked. commands/imps.md's summary rendering must treat this as
// "often unavailable," not "always populated."
const modelCounts = {}
for (const t of state.tasks) modelCounts[t.model] = (modelCounts[t.model] || 0) + 1

const result = {
  status: 'awaiting_authorization',
  merged: mergeResult.merged,
  failed_tasks: dispatchOutcome.failed,
  head_imp: headImp ? { verdict: headImp.verdict, amendments: headImp.amendments_applied } : null,
  gates: gateOutcome.results,
  diff_stat: diffStatInfo.diff_stat,
  default_branch: defaultBranch,
  dod_coverage: (coverage && coverage.criteria) || [],
  dod_coverage_error: dodCoverageError,
  dod_coverage_status: dodCoverageStatus,
  dispatch: { model_counts: modelCounts, tokens_spent: null, artifacts: dispatchOutcome.artifacts },
}
await patchState({ segment: 'publish_finalize' }, 'enter-publish')
await saveResult(result)
return result
