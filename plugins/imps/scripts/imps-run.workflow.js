// imps-run.workflow.js — the free-text run's dispatch/merge/gate/review/finalize pipeline.
//
// PLATFORM ASSUMPTION — Claude Code only. This file assumes the `Workflow` tool, the
// `agent()` dispatch primitive with `isolation: 'worktree'`, model pins by Claude tier
// name, and ~/.claude/workflows/ as a load path. None of that exists on OpenCode or Agy
// (docs/platform-matrix.md), so build/generate.py excludes this script from dist/ — see
// build/overrides/imps/port.json's asset_exclude entry for it. The generated builds run
// the same pipeline as a foreground prose loop from build/overrides/imps/. Keep that in
// mind when changing the pipeline: the prose loop is a separate surface and does not
// track edits here automatically.
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
// args shape: {
//   pluginRoot, stateFilePath, goalFilePath, personaPostingProtocolPath,  // all required
//   personaBriefPaths: {                                                  // required
//     "solution-architect": { path, model }, "grumpy-engineer": { path, model },
//     "sre": { path, model }, "business-analyst": { path, model },
//     "ux-designer": { path, model, requires: ["browser-surface"] }
//   },
//   personaPanel: boolean  // OPTIONAL, default false. The in-run five-persona panel is
//                          // OPT-IN — only runs when this is exactly `true` (set by the
//                          // `--personas` flag in commands/imps.md). Absent/false: the
//                          // panel and its fix loop are skipped; OCR diff review is
//                          // the gate. personaBriefPaths is still passed either
//                          // way — it is only read when the panel actually runs.
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
        },
        required: ['id', 'label', 'model', 'type', 'deps'],
      },
    },
    phase: { type: 'string' },
    segment: { type: ['string', 'null'] },
    dispatched_at: { type: ['string', 'null'] },
    poll_interval_seconds: { type: 'number' },
    max_dispatch_hours: { type: 'number' },
    last_heartbeat: { type: ['string', 'null'] },
    // One-line clock-helper failure messages, fail-soft like the fields they sit beside
    // (dispatched_at falls back to the "agent-supplies-timestamp" sentinel, last_heartbeat
    // just keeps its prior value) — but recorded rather than silently swallowed, so a
    // persistently-flaking clock is visible in the audit trail instead of indistinguishable
    // from a healthy run. Cleared to null on the next clean read of the same helper.
    heartbeat_clock_error: { type: ['string', 'null'] },
    dispatch_clock_error: { type: ['string', 'null'] },
    tasks_done: { type: 'array', items: { type: 'number' } },
    worktrees: { type: 'object', additionalProperties: { type: 'string' } },
    artifacts: { type: 'array', items: { type: 'object', additionalProperties: true } },
    pr: { type: ['object', 'null'], additionalProperties: true },
    verdicts: { type: ['object', 'null'], additionalProperties: true },
    discussion_comment_url: { type: ['string', 'null'] },
    source_discussion: { type: ['object', 'null'], additionalProperties: true },
    gate_commands: { type: ['array', 'null'], items: { type: 'object', additionalProperties: true } },
    learnings_saved: { type: ['array', 'null'] },
    operator_decision: { type: ['string', 'null'] },
    last_result: { type: ['object', 'null'], additionalProperties: true },
    failed_tasks: { type: 'array', items: { type: 'object', additionalProperties: true } },
    // --- schema 4, all ADDITIVE and all optional (none joins `required`) --------------
    // A schema-3 state file still validates: these are top-level optional properties.
    // The #87 silent field-drop risk is specific to `tasks.items` (see the comment at
    // 70-73), which is why additionalProperties:true is load-bearing THERE and not here.
    //
    // These four carry free text (persona findings, ruling rationales). They are the ONE
    // established exception to "never embed long text in the state file" — a ruling's
    // rationale has nowhere else to live once deleteStateFile() runs. Nothing new may
    // join them; every other cross-agent text reaches its consumer as a GOAL.md pointer.
    parked_findings: { type: ['array', 'null'], items: { type: 'object', additionalProperties: true } },
    // One-line failure message from the most recent writeParkedFindings() call, if it threw.
    // Not free text like the quartet above — a fixed-format breadcrumb, same pattern as the
    // clock-error fields, so the durable-record promise it broke is at least visible
    // somewhere other than a silently-eaten catch block.
    parked_findings_write_error: { type: ['string', 'null'] },
    // One-line failure message from the most recent adjudicateFindings() call, if it threw.
    // Same fail-soft/carry-forward pattern as parked_findings_write_error: it must survive
    // an `override findings:` resume (which skips the panel block entirely) and reach
    // finalizeRun's advisoryNotes / the terminal result, so a run that shipped despite the
    // adjudicator never running is not indistinguishable from a healthy one.
    adjudication_error: { type: ['string', 'null'] },
    wontfix_rulings: { type: ['array', 'null'], items: { type: 'object', additionalProperties: true } },
    // Partial panel output. NEVER `verdicts` — that key is the panel-completion signal
    // ("the panel is finished, never run it again"), not a data slot.
    verdicts_pending: { type: ['object', 'null'], additionalProperties: true },
    fix_rounds_done: { type: ['number', 'null'] },
    // Bounds `retry findings`: incremented where the verb is CONSUMED, refused past 2.
    fix_cycles: { type: ['number', 'null'] },
    // Persisted so a findings resume — whose decision no longer starts with "PR:" —
    // does not silently degrade to posting_mode "none".
    posting_mode: { type: ['string', 'null'] },
    // Schema 5: OCR review is additive so legacy state files remain valid.
    review_engine: { type: ['string', 'null'] },
    review_model: { type: ['string', 'null'] },
    code_review_rounds: { type: ['number', 'null'] },
    code_review_findings: { type: ['array', 'null'], items: { type: 'object', additionalProperties: true } },
    code_review_sessions: { type: ['array', 'null'], items: { type: 'string' } },
    code_review_override: { type: ['string', 'null'] },
    // Operational OCR failures do not substitute for a review approval. Preserve the
    // helper's redacted contract so the authorization result can disclose that review
    // was unavailable while the workflow continues to publication.
    code_review_warning: { type: ['object', 'null'], additionalProperties: true },
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

const CODE_REVIEW_SCHEMA = {
  type: 'object',
  properties: {
    status: { type: 'string', enum: ['ok', 'blocked'] },
    verdict: { type: ['string', 'null'], enum: ['APPROVE', 'CHANGES_REQUESTED', null] },
    findings: { type: 'array', items: { type: 'object', additionalProperties: true } },
    model: { type: 'string' }, provider: { type: ['string', 'null'] },
    session_id: { type: ['string', 'null'] }, duration_ms: { type: 'number' },
    cost_usd: { type: ['number', 'null'] }, reason: { type: ['string', 'null'] },
  },
  required: ['status', 'verdict', 'findings', 'model', 'provider', 'session_id', 'duration_ms', 'cost_usd', 'reason'],
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

// One persona fix round's outcome. fixLoopRound() was schema-less and its return
// discarded, so a "WONTFIX: <rationale>" was free-text that reached nobody: the operator's
// only surviving record (the terminal result object) never carried it. A rationale is
// REQUIRED per wontfix entry — a bare "not valid" discard is exactly the silent-drop this
// schema exists to prevent.
const FIX_ROUND_SCHEMA = {
  type: 'object',
  properties: {
    fixed: { type: 'array', items: { type: 'string' } },
    wontfix: {
      type: 'array',
      items: {
        type: 'object',
        properties: { finding: { type: 'string' }, rationale: { type: 'string' } },
        required: ['finding', 'rationale'],
      },
    },
    summary: { type: 'string' },
  },
  required: ['fixed', 'wontfix', 'summary'],
}

// Adjudication of findings that survived the 3-round fix cap. The enum here is only the
// three rulings the ADJUDICATOR may return; `operator-overridden` is the fourth ruling
// value in the shared vocabulary and is applied by this script (never by the adjudicator)
// when the operator answers `override findings: <rationale>`.
const ADJUDICATION_SCHEMA = {
  type: 'object',
  properties: {
    rulings: {
      type: 'array',
      items: {
        type: 'object',
        properties: {
          finding: { type: 'string' },
          ruling: { type: 'string', enum: ['parked-contestable', 'parked-deferred', 'load-bearing'] },
          rationale: { type: 'string' },
        },
        required: ['finding', 'ruling', 'rationale'],
      },
    },
  },
  required: ['rulings'],
}

const NOW_ISO_SCHEMA = {
  type: 'object',
  properties: { iso: { type: 'string' } },
  required: ['iso'],
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

// Real ISO timestamp. `Date.now()`, `Math.random()` and argless `new Date()` all throw
// inside a Workflow script, so the only clock available is a command run by an agent.
// The command is NAMED deliberately: a prompt saying "the current UTC time" invites a
// model with no clock to fabricate a schema-valid but wrong date, which is strictly worse
// than the loud `agent-supplies-timestamp` sentinel this replaces.
//
// TELEMETRY, NEVER A GATE. Every call site must wrap this in try/catch — see the heartbeat
// in runDispatch(), which persists a completed stage's tasks_done/worktrees/artifacts/
// failed_tasks. runDispatch is called with no try/catch of its own, so a transient throw
// here would kill the run and lose bookkeeping for imps that already ran and cost real
// tokens. The string literal this replaced could not throw; a cosmetic timestamp must not
// become able to destroy dispatch state.
function nowIso() {
  return agent(
    'Run the command `date -u +%Y-%m-%dT%H:%M:%SZ` and return its exact stdout as "iso". Do not compute or guess the value — run the command and copy what it printed.',
    { label: 'now', model: 'haiku', schema: NOW_ISO_SCHEMA }
  )
}

// The pointer every code-writing and code-reviewing agent call carries. Cross-cutting
// invariants live in GOAL.md, not in the state file: patchState() round-trips the entire
// file through haiku and truncates, so constraint TEXT would decay. A pointer cannot.
function constraintsPointer() {
  return `MANDATORY FIRST ACTION: Read ${args.goalFilePath} section "Global Constraints". Every constraint listed there binds this work — they are invariants true of every task in the run, not acceptance criteria to tick. If the section is absent or empty, proceed; if it is unreadable, stop and report that rather than guessing.`
}

// Same pointer for the two REVIEWER calls, which need one extra instruction the writers
// don't: a constraint violation is a finding, not a style note.
function constraintsPointerForReviewer() {
  return `${constraintsPointer()} A diff that violates any constraint in that section is at least a MAJOR finding — raise it as one.`
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
4. If CURRENT does not equal DEFAULT (the expected case — CURRENT should equal "${state.branch}"): run \`git fetch origin\`, then decide whether a rebase is needed at all before running one — \`git merge-base --is-ancestor origin/DEFAULT HEAD\`. Exit 0 means origin/DEFAULT is ALREADY an ancestor of HEAD (the branch is up to date with the default branch): SKIP the rebase entirely, it can only rewrite SHAs for nothing. Only on a non-zero exit run \`git rebase origin/DEFAULT\`. Rebase conflict → abort it (\`git rebase --abort\`), set "ok": false, describe the conflict files in "error".
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

function dispatchImp(task, state, guidance) {
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
${constraintsPointer()}
Spec — your operative instructions; follow these, do not improvise beyond them:
${spec}
${guidance ? `\nThis is a retry. Operator guidance: ${guidance}\n` : ''}
${isCode ? 'You run in an isolated git worktree, created from the default branch\'s last committed HEAD (not the run\'s working branch — in-progress commits on a side branch are not visible to you). Make the minimal change that satisfies the task. Resolve this repo\'s gate/lint commands yourself and run them (plus any autofix) before committing — fix failures you caused, note pre-existing ones. Stage and commit; do not push. Return the branch name.' : ''}
${task.type === 'query' && !/\bMUTATIONS_ALLOWED\b/.test(spec) ? 'Read-only. No file changes. Return structured data. Cite sources (file paths, line numbers, URLs) for every claim.' : ''}
${task.type === 'publish' ? 'Create GitHub artifacts (PRs, issues, comments, Discussions) from the main working branch only, never from an isolated worktree branch. Use `gh api graphql` for Discussions. Confirm the artifact URL.' : ''}

Do exactly this task. Nothing more — note anything else you notice but do not fix it.
Return via the required schema: status "done" or "failed" (with a ≤50-word reason in notes if failed).`,
    {
      label: `imp-${task.id}${guidance ? '-retry' : ''}`,
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
    // The timestamp is cosmetic; this patch is not. It is the only durable record of a
    // completed stage's tasks_done/worktrees/artifacts/failed_tasks, and runDispatch is
    // called with no try/catch of its own — so a throw from the clock helper here would
    // kill the run and lose bookkeeping for imps that already ran and cost real tokens.
    // Telemetry never gates: on failure, omit the key entirely and keep the prior value
    // rather than overwriting it with a sentinel.
    let heartbeatIso = null
    // Fail-soft (never gates dispatch), but NOT silent: `cat`-ing the state file is what
    // README.md tells operators to do for progress, so a frozen last_heartbeat needs to be
    // distinguishable from a genuinely wedged dispatch stage. Persisted (not just a local
    // var) so it survives to whichever later invocation reaches finalizeRun's advisory
    // notes — heartbeats run inside runDispatch(), many invocations before Finalize.
    let heartbeatClockError = null
    try {
      heartbeatIso = (await nowIso()).iso
    } catch (e) {
      heartbeatClockError = `heartbeat timestamp unavailable, last_heartbeat left at its prior value: ${e && e.message ? e.message : e}`
    }
    await patchState(
      {
        ...(heartbeatIso ? { last_heartbeat: heartbeatIso } : {}),
        // Cleared to null on a clean heartbeat so a one-time flake doesn't read as
        // persistently wedged once the clock recovers.
        heartbeat_clock_error: heartbeatClockError,
        tasks_done: [...doneIds],
        worktrees,
        artifacts,
        failed_tasks: [...failed.values()],
      },
      'heartbeat'
    )
    // If this cascade drained the whole remaining pipeline, stop early rather than
    // continuing to "run" empty stages.
    if (failed.size && doneIds.size + failed.size >= state.tasks.length) break
  }

  return { blocked: false, doneIds, failed: [...failed.values()], worktrees, artifacts }
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

function ocrReview(defaultBranch) {
  return agent(
    `You are a mechanical wrapper. Do not read, summarize, review, edit, or otherwise inspect code or a diff. Run exactly this command from the current checkout, capture its final stdout JSON line, and return it unchanged through the required schema:
REPO="$(git rev-parse --show-toplevel)"
"${args.pluginRoot}/scripts/run-ocr.sh" --repo "$REPO" --base "origin/${defaultBranch}" --head HEAD --goal "${args.goalFilePath}"
If the command exits non-zero, still return its final JSON contract. Never substitute a Claude review or alter the contract.`,
    { label: 'ocr-review', phase: 'Integrate', model: 'haiku', schema: CODE_REVIEW_SCHEMA }
  )
}

function ocrPreflight() {
  return agent(
    `You are a mechanical wrapper. Do not inspect code. Run exactly \`${args.pluginRoot}/scripts/run-ocr.sh --check\`, capture its final stdout JSON line, and return it unchanged through the required schema. Never replace it with a Claude review.`,
    { label: 'ocr-review-preflight', phase: 'Preflight', model: 'haiku', schema: CODE_REVIEW_SCHEMA }
  )
}

function fixOcrReview(findings) {
  return agent(
    `OCR returned these blocker/major review findings on the merged diff: ${JSON.stringify(findings)}. Fix only those findings in the current checkout. ${constraintsPointer()} Do not push, open a PR, or claim review approval.`,
    { label: 'fix-ocr-review', phase: 'Integrate', model: 'sonnet' }
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
    `Gate "${gate.name}" (\`${gate.cmd}\`) failed. Log tail:\n${tail}\n${guidance ? `Operator guidance: ${guidance}\n` : ''}${constraintsPointer()}\nDiagnose and fix the failure — make the minimal change needed to get this gate green. Do not touch unrelated code. When done, report what you changed in one line.`,
    { label: `fix-${gate.name}`, phase: 'Integrate', model: 'sonnet' }
  )
}

// Parses `retry <gate>: <guidance>` / `skip <gate>` into structured form. Gate names are
// matched against the discovered gate list's own names (build/lint/test/type), not
// task IDs — distinguished from parseTaskDecision by the absence of "tasks #".
function parseGateDecision(decision) {
  if (!decision) return null
  const retryMatch = decision.match(/^retry ([^:]+):\s*(.*)$/i)
  if (retryMatch) return { kind: 'retry', gate: retryMatch[1].trim(), guidance: retryMatch[2].trim() }
  const skipMatch = decision.match(/^skip (.+)$/i)
  if (skipMatch) return { kind: 'skip', gate: skipMatch[1].trim() }
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

${constraintsPointerForReviewer()}

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
    `These persona findings are open (blocker/major only, already deduped): ${JSON.stringify(findings)}.
${constraintsPointer()}
Group by disjoint file sets. For disjoint groups, make the fix directly (small, targeted). For cross-cutting or conflicting findings, resolve with this precedence: correctness > data integrity > security > UX > style. Commit your changes and push to the current branch.
If a finding is not actually valid, do NOT force a change — declare it in "wontfix" instead. Every "wontfix" entry MUST carry a "rationale" saying why the finding does not hold; the schema requires it and an entry without one is not a discard you are permitted to make. Silence is not a ruling.
Return via the required schema: "fixed" (one line per finding you actually fixed), "wontfix" ([{finding, rationale}]), "summary" (one line describing this round's changes).`,
    { label: 'fix-round', phase: 'Publish', model: 'sonnet', schema: FIX_ROUND_SCHEMA }
  )
}

// The adjudicator that runs ONCE, after the 3-round fix cap, on findings that survived it.
//
// The anchor is the whole point. A single agent handed three-rounds-failed findings on an
// open PR has every gradient pointing at "park it", and an authoritative ruling discourages
// re-reading in a way today's raw printout does not — so a ruling may only be load-bearing
// against an EXTERNAL referent: a quoted DoD criterion, or a named breaking input. Anchor
// (b) is not garnish: a DoD enumerates deliverables, not defects, so with (a) alone an
// unanticipated correctness finding would be unblockable by construction.
//
// `dissentingByPersona` keeps slug attribution deliberately — the flattened findings list
// the fix loop uses would make the ">=2 personas" rule inapplicable.
function adjudicateFindings(dissentingByPersona, fixHistory, defaultBranch) {
  return agent(
    `Three fix rounds have run against this PR and these persona findings are STILL open. You are the sole adjudicator. Rule on each one.

Open findings, grouped by the persona that raised them (attribution matters — see the >=2-personas rule below):
${JSON.stringify(dissentingByPersona)}

What the fix rounds already tried and why each round did not close these out:
${JSON.stringify(fixHistory)}

Read the merged diff yourself — \`git diff origin/${defaultBranch}..HEAD -- ':!*lock*' ':!dist'\` — and read the "## Definition of Done" section of ${args.goalFilePath}. Never accept a diff or a DoD pasted to you. ${constraintsPointer()}

Assign every open finding exactly one ruling:
- "load-bearing" — the run MUST NOT finalize with this finding open.
- "parked-deferred" — real, but legitimately deferrable to follow-up work.
- "parked-contestable" — the finding does not hold, or is a matter of taste.

Rules, applied strictly:
1. A ruling of "load-bearing" is permitted ONLY if ANY of: (a) the finding falsifies a named criterion under GOAL.md "## Definition of Done" — and you QUOTE that criterion verbatim in the rationale; (b) the finding names a concrete breaking input, a data-loss path, or a security defect reachable in the merged diff — and you STATE that input in the rationale; OR (c) the finding is a violation of a constraint listed in GOAL.md "## Global Constraints" (read via the pointer above) — and you QUOTE that constraint verbatim in the rationale. A Global Constraints violation is AT LEAST a MAJOR finding by the same rule every code-writing and code-reviewing call in this run is held to; it cannot be parked merely for lacking a DoD criterion or a named breaking input when a constraint already covers it.
2. A ruling with none of (a), (b), (c) MUST NOT be "load-bearing". Absent an external referent, park it.
3. A finding raised by >=2 DISTINCT personas defaults to "load-bearing". If you park such a finding anyway, the rationale MUST state which Definition-of-Done criterion survives it.
4. Every rationale cites the fix round that failed on this finding and why it failed.
5. "Reviewed and parked" is not "never reviewed". A persona whose verdict is "SKIPPED" never reviewed and produced no finding to rule on — do not manufacture a parked ruling for it, and do not treat its absence as agreement.
6. The "finding" field of every ruling MUST be copied byte-for-byte from the open findings list above — do not paraphrase, summarize, retitle, or re-wrap it, even to shorten or clarify it. A later cycle matches rulings back to findings by exact string equality; a reworded finding silently defeats that match and the same finding can be handed back to another fix round or double-listed in GOAL.md.

Return via the required schema: "rulings": [{finding, ruling, rationale}], one entry per open finding, "finding" copied verbatim from the input (see rule 6), none omitted.`,
    { label: 'adjudicate-findings', phase: 'Publish', model: 'opus', schema: ADJUDICATION_SCHEMA }
  )
}

// Writes the rulings into GOAL.md's "## Parked findings" section. This script has no
// filesystem primitive — every FS touch is an agent() call with a fixed prompt — so this is
// a real dispatch, not a one-liner. Follows dodCoverage()'s surgical-section-edit
// precedent, and deliberately stays off the DoD checkboxes that dodCoverage owns: the two
// GOAL.md writers are both awaited on the same sequential path, so there is no race, only a
// scope boundary each must respect.
function writeParkedFindings(rulings) {
  return agent(
    `Update the "## Parked findings" section of ${args.goalFilePath}. Do BOTH steps, in order, and touch nothing else in the file.

1. Locate the existing heading line "## Parked findings". Its BODY is everything from the line after that heading up to (but NOT including) the next line beginning with "## ", or end-of-file if no further "## " heading follows — whichever comes first. This boundary rule is not optional: the section sits LAST in some GOAL.md layouts and MID-FILE in others, and a to-end-of-file implementation would swallow every section after it. If the heading does not exist, add it at the end of the file and treat its body as empty.

2. REPLACE that body — do not append, and never emit a second "## Parked findings" heading — with one bullet per ruling below, formatted \`- **<ruling>** — <finding> — <rationale>\`. If a ruling object also carries an "operator_rationale" field (only "operator-overridden" rulings do — it is the operator's OWN reason for overriding, distinct from "rationale", which is the adjudicator's original reasoning for why the finding was load-bearing), append it to the same bullet as \` (operator override: <operator_rationale>)\` — do not drop it, and do not substitute it for "rationale". If the list below is empty, the body must be exactly \`_None._\` and nothing else.

Rulings to render (JSON):
${JSON.stringify(rulings)}

Hard rules:
- The section must contain NO markdown checkboxes ("- [ ]" or "- [x]"). A stray unticked checkbox outside "## Definition of Done" is read elsewhere as a phantom task. Use plain bullets.
- Do NOT touch the "## Definition of Done" section, its checkbox characters, or any other section's prose. Another step owns those boxes.
- Every ruling gets rendered, labelled by its ruling value verbatim — including "operator-overridden" ones, which are not parked but have no other home in this document.`,
    { label: 'write-parked-findings', phase: 'Publish', model: 'sonnet' }
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

function finalizeRun(state, prInfo, verdicts, dispatchStats, dodCoverageCriteria, dodCoverageError, surfaceDetectionError, heartbeatClockError, dispatchClockError, parkedFindingsWriteError, adjudicationError) {
  // All six are advisory-pass failures (surface-detection, dod-coverage, the two clock
  // helpers behind last_heartbeat/dispatched_at, a failed GOAL.md parked-findings write, and
  // an adjudicate-findings call that never completed) that must reach the audit trail the
  // same way — none is fatal to the run (an `override findings:` can still finalize it), but
  // a silent null on any of them would hide a degraded advisory check behind a clean-looking
  // finalize. Their source text (a haiku classifier's freeform "reason", or a thrown
  // error's .message) is untrusted — it can legitimately contain backticks around a file
  // path, `$(...)`-shaped text, or other shell metacharacters — and this string ends up
  // inside a shell `--notes "..."` argument the agent constructs below. Stripping only `"`
  // (as an earlier version of this line did) still let backticks/`$(` reach that argument
  // verbatim, a real command-injection path via the finalize agent dutifully copying it in
  // "verbatim". Strip every shell-meaningful character here (not just at each call site)
  // rather than relying on the agent's own quoting discipline to neutralize untrusted text.
  const advisoryNotes = [surfaceDetectionError, dodCoverageError, heartbeatClockError, dispatchClockError, parkedFindingsWriteError, adjudicationError]
    .filter(Boolean)
    .join('; ')
    .replace(/[`"$\\]/g, '')
  return agent(
    `Finalize this /imps run. State file: ${args.stateFilePath}. GOAL.md: ${args.goalFilePath}.
1. You MUST run this now, before any other step below (the script itself is fail-soft about a missing \`jq\` or unwritable log dir — but \`--duration-ms\` itself is a required, strictly-validated argument: passing anything non-numeric, including omitting the flag, makes the script exit 1 and drop this mandatory line entirely): \`${args.pluginRoot}/scripts/audit-log.sh --plugin imps --command /imps:imps --exit-status <choose completed, partial, blocked, failed, or cancelled from the run outcome> --duration-ms <computed from the state file's dispatched_at, same basis as run_stats.elapsed below, in ms; if dispatched_at is not a real timestamp — see step 6 — pass 0 here instead of omitting the flag> --scope <project-or-user> --notes "<one-line summary>"\`. Choose \`blocked\` for a tool or permission refusal, \`partial\` when some work landed but a required phase failed, \`failed\` when no usable result was produced, and \`cancelled\` when the operator stopped the run. The \`--notes\` value is a one-line summary you write yourself${advisoryNotes ? ` — it MUST ALSO mention this verbatim, even though it wasn't part of your own summary (it is a separate, required fact, not a suggestion): ${advisoryNotes}` : ''}. Use single quotes for any quoting you need inside the \`--notes\` value — never a literal double quote, backtick, dollar sign, or backslash, since any of those would break out of or reinterpret this command's own double-quoted argument.
2. If a PR exists (${prInfo ? `#${prInfo.number}` : 'none'}), flip it to ready: \`gh pr ready ${prInfo ? prInfo.number : ''}\`. Skip if no PR.
3. Collect artifact links from the state file's "artifacts" field into the result.
4. If the state file's "source_discussion" is non-null AND "discussion_comment_url" is still null, post a short outcome comment (≤150 words: what shipped, PR/artifact URLs, unresolved findings — persona verdicts/findings for reference: ${JSON.stringify(verdicts)}; DoD acceptance-criteria coverage for reference, mention any unsatisfied ones: ${JSON.stringify(dodCoverageCriteria || [])}${dodCoverageError ? `, noting the coverage check itself did not complete: ${dodCoverageError}` : ''}) via \`gh api graphql\` addDiscussionComment using source_discussion.id verbatim. Write the returned comment URL into the state file's discussion_comment_url field immediately (patch the state file yourself) — a non-null URL means never post again on a future invocation.
5. If a PR was opened, write ~/.claude/imps/runs/<slug>.prs.json (derive slug from the state file path) with: repo, pr_number, pr_url, branch, base_branch, poll_interval_seconds (from state file), started_at (now, ISO), handled_comment_ids: [], ci_fix_attempts: {}, max_age_hours: 48.
6. Assemble run_stats: dispatched_at (from state file), elapsed (now minus dispatched_at, "Xm Ys" — but FIRST check that dispatched_at is a real ISO-8601 timestamp. A state file written before this run's clock helper existed, or one whose timestamp call failed, carries the literal placeholder "agent-supplies-timestamp" there. If dispatched_at is that placeholder, absent, or otherwise not parseable as a date, set elapsed to "unknown" and do not guess or fabricate a duration), tokens_spent and model_counts (from: ${JSON.stringify(dispatchStats)}), tasks ([{id, model}] for every task), achieved (≤5 one-liners in plain value terms — what changed for the user, not implementation detail), decision_points (one line per pivot: Head Imp amendments, conflicts resolved, skipped gates/tasks${advisoryNotes ? `, the advisory-check note(s) above` : ''} — omit if none).
7. Persist decision_points into ${args.goalFilePath}. Locate the existing heading line "## Decision trail". Its body is everything after that heading up to, but not including, the next line beginning with "## ", or end-of-file. Replace that bounded body; never append to it and never emit a second heading. If the heading is missing, add it at end-of-file. Write one plain bullet per decision point, with no checkboxes. If decision_points is empty, the body must be exactly underscore-None-dot-underscore (_None._). Record only pivots, not routine actions or achieved outcomes. This GOAL.md update is mandatory and idempotent.
8. Set the state file's "phase" to "final" (NOT deleted yet — deletion happens only after the learnings step, so a death here still resumes gracefully).

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

// A `blocked/unresolved_findings` resume re-enters the SAME Publish block by widening its
// guard — it is deliberately NOT a new top-level `if` further down. The next top-level `if`
// is reachable only when this one declines, and control there falls through to
// phase('Dispatch'): a branch placed down there would re-run merge, a fresh opus
// headImpReview, and every gate before emitting a duplicate awaiting_authorization on a PR
// that already exists.
const resumingFindings = !!(
  lastStatus === 'blocked' &&
  state.last_result.reason === 'unresolved_findings' &&
  decision &&
  (decision === 'retry findings' || decision.startsWith('override findings:'))
)
// Fail-closed companion to the comment above. The widened guard covers the THREE recognised
// verbs; every other decision string on this state — `override findings` with the colon
// dropped, `Retry findings` capitalised (both verbs are matched case-SENSITIVELY, unlike
// parseTaskDecision/parseGateDecision), a stray gate verb, or no decision at all because the
// script was re-invoked before the operator answered — declines the guard and falls straight
// through to phase('Dispatch'), which is exactly the path the comment above says must never
// be taken from here: re-merge, a fresh opus headImpReview, every gate again, and a duplicate
// awaiting_authorization on a PR that already exists — answering `PR: yes` at THAT gate then
// finds `verdicts` still null and re-dispatches all five personas, posting five more live
// GitHub reviews. `abort` is already returned far above, so re-emitting the prior blocked
// result here loses no reachable path; it costs nothing and it tells the operator the exact
// vocabulary. Not a new state machine branch — the same result object, re-surfaced.
if (lastStatus === 'blocked' && state.last_result.reason === 'unresolved_findings' && !resumingFindings) {
  const result = {
    ...state.last_result,
    detail: {
      ...state.last_result.detail,
      note: `unrecognized decision ${JSON.stringify(decision || null)} at the unresolved-findings gate — nothing was re-run. Resubmit exactly one of \`retry findings\`, \`override findings: <rationale>\`, or \`abort\` (verbatim, lower-case, colon included).`,
    },
  }
  await saveResult(result)
  return result
}
if ((lastStatus === 'awaiting_authorization' && decision && decision.startsWith('PR:')) || resumingFindings) {
  // On a findings resume the decision no longer starts with "PR:", so the ternary alone
  // would evaluate to "none" — silently un-pushing the fix rounds' commits, telling the
  // re-review not to post, and changing findings_inline's shape. Read the persisted value
  // first; the ternary is only the first-entry derivation.
  // Precedence matters: a decision that CARRIES a posting choice must beat the persisted one.
  // With `state.posting_mode ||` first, an operator who answered `PR: yes, no-post` on one
  // invocation and then deliberately re-answered `PR: yes` on the next would have the stale
  // no-post win silently — the persisted value is a fallback for resumes whose decision says
  // nothing about posting, not an override of an explicit answer.
  const postingMode = decision && decision.startsWith('PR:')
    ? decision === 'PR: yes'
      ? 'live'
      : decision === 'PR: yes, no-post'
        ? 'no-post'
        : 'none'
    : state.posting_mode || 'none'
  const overriding = resumingFindings && decision.startsWith('override findings:')
  phase('Publish')

  // Cycle bound. Incremented HERE — where the `retry findings` verb is consumed — not where
  // the blocked result is re-emitted: `fix_cycles: (state.fix_cycles || 1)` written at the
  // return site is a floor, not an increment, so it writes 1 forever and this refusal is
  // unreachable. Each granted cycle costs a five-persona panel, three fix rounds, an opus
  // dodCoverage recompute and an opus adjudicator.
  // In-memory mirror of state.fix_cycles for THIS invocation. `state` is deliberately never
  // reassigned from the grant patch below (see its comment), so `state.fix_cycles` stays at the
  // pre-grant value for the rest of the run — reading it later tags a granted cycle 2's rulings
  // as cycle 1, colliding with cycle 1's own entries. Everything downstream reads this instead.
  let currentFixCycle = state.fix_cycles || 1
  if (resumingFindings && decision === 'retry findings') {
    const cycles = (state.fix_cycles || 1) + 1
    if (cycles > 2) {
      // Re-return the PRIOR blocked result. It is already field-complete from the last
      // invocation; do not try to rebuild its shape here — coverageCriteria,
      // parkedFindings and wontfixRulings are all declared inside the panel block far
      // below this point and are out of scope.
      const result = {
        ...state.last_result,
        detail: {
          ...state.last_result.detail,
          // Exactly ONE retry is ever granted: fix_cycles starts unset (-> 1, the initial
          // panel), the first `retry findings` grants cycle 2, and the second computes 3 > 2
          // and lands here. Saying "two retry cycles" contradicts commands/imps.md and
          // overstates what the operator got. "Granted" not "ran", though: the patch lands
          // BEFORE the cycle it authorizes, so a crash mid-cycle burns the grant without the
          // cycle completing.
          note: 'retry findings refused — the one retry cycle available was already granted (cycle 2 of 2; it may not have finished) — only `override findings:` or `abort` remain',
        },
      }
      await saveResult(result)
      return result
    }
    // NO `state = ` here, deliberately. Nothing in THIS invocation reads state.fix_cycles;
    // the write exists only so the next invocation's refusal check sees it. Taking the
    // return would swap the sonnet-validated `state` for an unvalidated haiku round-trip
    // immediately before the reseed reads state.verdicts_pending — the largest free-text
    // field in the file. A truncated read there yields current={} -> results=[] ->
    // dissenting=[] -> the fix loop never enters -> verdicts={} is persisted as the
    // panel-completion signal -> the run finalizes with the load-bearing finding gone.
    await patchState({ fix_cycles: cycles }, 'grant-retry-cycle')
    // The one thing that MUST be mirrored in memory, precisely because `state` is not.
    currentFixCycle = cycles
  }

  let prInfo = state.pr
  if (postingMode !== 'none' && !prInfo) {
    prInfo = await pushAndOpenPR(state, state.last_result.default_branch)
    await patchState({ pr: prInfo }, 'save-pr')
  }
  // `verdicts` stores {slug: {verdict, findings}} — full content, not just the verdict
  // label, so a no-post/findings-inline run still has each persona's actual findings to
  // show the operator (a bare verdict word is not "the review record").
  //
  // On `override findings:` the operator has accepted the open findings, so the withheld
  // verdicts_pending is PROMOTED to verdicts. That is the whole mechanism of the override:
  // a non-null `verdicts` closes the panel/fix-loop block below and drops control straight
  // to phase('Finalize'). prInfo is guaranteed non-null on this path — the block below only
  // ever runs when prInfo is set, so no path that reaches the unresolved_findings return
  // can have state.pr unset.
  // `|| {}` is load-bearing, not defensive padding. If verdicts_pending came back null or
  // absent — a patchState() haiku round-trip truncating the file's largest free-text field
  // is the exact failure this module keeps calling out — a bare promotion leaves `verdicts`
  // null, and the next patchState below then writes `verdicts: null` AND `verdicts_pending:
  // null`, destroying the withheld panel record. Control would then fall into the panel
  // block and re-dispatch all five personas, posting five more GitHub reviews in `live`
  // mode and re-entering the fix loop — i.e. `override findings:` would not override.
  // An empty map still closes the block; the rulings the operator overrode survive in
  // parked_findings and in the result object.
  let verdicts = state.verdicts || (overriding ? state.verdicts_pending || {} : null)
  // Rulings carry across invocations: the adjudicator's output persisted before the blocked
  // return, plus every WONTFIX rationale the fix rounds accumulated. Declared out here (not
  // inside the panel block) because both terminal result objects below read them, and the
  // override path mutates them without ever entering that block.
  let parkedFindings = state.parked_findings || []
  const wontfixRulings = [...(state.wontfix_rulings || [])]
  // Carried the same way surfaceDetectionError/heartbeatClockError/dispatchClockError are:
  // a stale value from a PRIOR invocation survives via the state field read here, and a
  // failure written by THIS invocation (at either writeParkedFindings call site below)
  // updates this local directly so it reaches advisoryNotes/finalizeRun/the terminal result
  // without waiting for a resume to re-read the state file.
  let parkedFindingsWriteError = state.parked_findings_write_error || null
  // Same carry-forward reasoning: a prior invocation's blocked `adjudication_error` result
  // must survive into this one, including an `override findings:` resume that skips the
  // panel block below entirely (verdicts is already set by the promotion a few lines down).
  let adjudicationError = state.adjudication_error || null
  if (overriding) {
    // `load-bearing` is the only ruling an override changes. A parked ruling was never
    // blocking, so re-labelling it would erase the adjudicator's actual judgment — which is
    // exactly why load-bearing rulings are NEVER written into state.parked_findings (see the
    // `if (loadBearing.length)` branch below: it patches `parked_findings: parkedFindings`
    // with load-bearing entries already filtered OUT). Mapping over state.parked_findings
    // here for a 'load-bearing' entry is therefore a guaranteed no-op — the record this
    // override needs to act on is state.last_result.detail.load_bearing, the exact snapshot
    // saveResult() persisted right before returning the blocked result the operator is
    // resuming from.
    const operatorRationale = decision.slice('override findings:'.length).trim()
    if (!operatorRationale) {
      // FIX_ROUND_SCHEMA requires a rationale for every sonnet WONTFIX; the operator's
      // override of a load-bearing finding is the higher-stakes ruling and gets the same
      // bar — silence is not a ruling here either.
      const result = {
        ...state.last_result,
        detail: {
          ...state.last_result.detail,
          note: 'override findings: requires a rationale after the colon — resubmit as `override findings: <why this is safe to ship anyway>`',
        },
      }
      await saveResult(result)
      return result
    }
    const lastDetail = (state.last_result && state.last_result.detail) || {}
    const loadBearingFromLastResult = lastDetail.load_bearing || []
    const overridden = loadBearingFromLastResult.map((r) => ({
      ...r,
      ruling: 'operator-overridden',
      operator_rationale: operatorRationale,
    }))
    // The adjudication-error and fix-round-error blocked paths both hardcode
    // detail.load_bearing to [] — neither ever reached a load-bearing ruling, so there is
    // nothing there to override — but the findings that were AWAITING that ruling
    // (verdicts_pending, promoted to `verdicts` above) are exactly what the operator is
    // choosing to override here. Without recording that explicitly, `overridden` above is a
    // guaranteed no-op on these paths and nothing in parked_findings, GOAL.md, or the
    // terminal result shows the failure happened and an override was made anyway.
    const unresolvedErrorReason = lastDetail.adjudication_error || lastDetail.fix_round_error || null
    const adjudicationErrorOverride = unresolvedErrorReason
      ? Object.entries(state.verdicts_pending || {}).flatMap(([slug, v]) =>
          (v.findings || []).map((finding) => ({
            slug,
            finding,
            // `operator-overridden`, NOT a fifth enum value. The ruling vocabulary is pinned at
            // four everywhere (STATE_SCHEMA, commands/imps.md, the CI contract check); a fifth
            // value coined here reached GOAL.md verbatim and slipped the check, whose grep -F
            // matched it as a substring of this one. What is special about these entries is WHY
            // they were overridden, which belongs in the rationale text, not in the enum.
            ruling: 'operator-overridden',
            operator_rationale: operatorRationale,
            // Must be `rationale`: writeParkedFindings' format spec renders
            // `- **<ruling>** — <finding> — <rationale>` and never reads `note`, so carrying the
            // reason under `note` rendered a blank rationale and silently dropped the one fact
            // this block exists to record.
            rationale: `never fully adjudicated — ${unresolvedErrorReason}`,
          }))
        )
      : []
    // Dedupe by finding text — a resumed override invocation must not re-append the same
    // findings a second time if this block ever runs twice against the same saved state.
    const alreadyRecorded = new Set(parkedFindings.map((r) => r && r.finding))
    parkedFindings = [
      ...parkedFindings,
      ...[...overridden, ...adjudicationErrorOverride].filter((r) => !alreadyRecorded.has(r.finding)),
    ]
    // Clear the carried adjudication_error now that the override recorded it durably above —
    // otherwise it would keep reporting "adjudicator never ran" in advisoryNotes/the terminal
    // result on every subsequent invocation even after the operator explicitly ruled on it.
    adjudicationError = null
    await patchState(
      { verdicts, verdicts_pending: null, parked_findings: parkedFindings, posting_mode: postingMode, adjudication_error: null },
      'operator-override'
    )
    try {
      await writeParkedFindings(parkedFindings)
      parkedFindingsWriteError = null
    } catch (e) {
      // GOAL.md rendering is a record, not a gate — the rulings are in the result object.
      // But a silent drop here is still a silently-missing durable record, so leave a
      // breadcrumb an operator reading the state file (or a future finalize) can see.
      parkedFindingsWriteError = `write-parked-findings failed after operator override: ${e && e.message ? e.message : e}`
      await patchState({ parked_findings_write_error: parkedFindingsWriteError }, 'parked-findings-write-error').catch(() => {})
    }
  }
  // Persisted alongside verdicts (not just a local var) so a resumed invocation that skips
  // the panel below (verdicts already saved) still has this for the finalizeRun call further
  // down — set only when detection itself errors, so a persistently-flaking classifier is
  // visible in the audit trail instead of an eternal, silent "ran all five personas."
  let surfaceDetectionError = state.surface_detection_error || null
  // Same carry-across-invocations reasoning as surfaceDetectionError above: both clock
  // errors are recorded many invocations earlier, inside runDispatch(), so only the
  // persisted state field survives to reach finalizeRun's advisory notes.
  const heartbeatClockError = state.heartbeat_clock_error || null
  const dispatchClockError = state.dispatch_clock_error || null
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
  // Hoisted above the panel/fix-loop block (not declared `let round = 0` inside it) so the
  // terminal `status: 'final'` result below can read it even on a path that skips the block
  // entirely (verdicts already set, e.g. an `override findings:` resume) — falls back to the
  // persisted count from a prior invocation's fix loop rather than always reporting 0.
  let round = state.fix_rounds_done || 0
  // Persona panel is OPT-IN (args.personaPanel). Default OFF: the callers here run PRs
  // through a GitHub-side persona-review App, which makes an in-run panel redundant — the
  // Head Imp diff review (Integrate phase, above) is the gate. When the panel is disabled
  // we short-circuit `verdicts` to an empty (no-dissent) map right before the guard below,
  // reusing the exact "verdicts already set -> skip the panel/fix-loop block -> drop to
  // phase('Finalize')" path the `override findings:` resume relies on. finalizeRun,
  // findings_inline, PR creation and learnings all stay intact; the only thing skipped is
  // dispatching the five persona agents and the fix loop.
  //
  // Gated on `!resumingFindings` deliberately: `retry findings` / `override findings:` only
  // arrive from a prior `unresolved_findings` block, which the panel itself produces — so a
  // panel-disabled run can never legitimately reach a findings resume. If one somehow does
  // (a hand-edited or cross-version state file), let it fall through to the real block
  // rather than silently swallowing it here.
  const personaPanelEnabled = args.personaPanel === true
  if (!personaPanelEnabled && !verdicts && !resumingFindings) {
    verdicts = {}
    await patchState(
      {
        verdicts,
        verdicts_pending: null,
        posting_mode: postingMode,
      },
      'skip-persona-panel'
    )
  }
  if (!verdicts && prInfo) {
    let results
    let current
    if (resumingFindings && decision === 'retry findings') {
      // Reseed from the withheld panel output instead of re-running it. A literal
      // implementation of `retry findings` would re-dispatch all five personas — posting
      // five more GitHub reviews in `live` mode before the re-review rounds add yet more —
      // and would discard verdicts_pending along with its `posted` flags and the SKIPPED
      // ux-designer entry. The fix loop below then starts over at round 0 against the
      // dissenters recorded there.
      current = state.verdicts_pending || {}
      // Subtract findings the opus adjudicator already ruled on in a prior cycle
      // (parked-deferred / parked-contestable — load-bearing ones are never in
      // parked_findings, see the override block above). Without this, a cycle-2 fix round
      // gets handed findings already dismissed, and the re-adjudication below re-appends
      // them to parkedFindings with nothing deduping against cycle 1's entries, so GOAL.md
      // ends up listing each one twice.
      const alreadyParked = new Set(parkedFindings.map((r) => r && r.finding))
      results = Object.entries(current).map(([slug, v]) => ({
        slug,
        ...v,
        findings: (v.findings || []).filter((f) => !alreadyParked.has(f)),
      }))
      // `current` itself must carry the same filtering as `results`, not just the derived
      // array — `current` (not `results`) is what later becomes `verdicts` once the loop
      // below converges. Left unfiltered, a persona whose findings were ALL already parked
      // is correctly excluded from `dissenting` (by the findings.length>0 guard below) and
      // so never gets re-reviewed or updated in `current` — it would otherwise survive into
      // the final `verdicts` still reporting CHANGES_REQUESTED with findings GOAL.md already
      // has rulings for, i.e. already-resolved findings reported back to the operator as open.
      current = Object.fromEntries(results.map((v) => [v.slug, { verdict: v.verdict, posted: v.posted, findings: v.findings }]))
      // verdicts_pending is the state file's largest free-text field — the one most exposed
      // to a haiku patchState() round-trip truncating it (see the retry-cycle commentary
      // above). An empty or fully-filtered reseed must never be mistaken for "the panel
      // converged": that would fall through to `verdicts = current` below with an empty
      // `current`, finalize the run clean, and silently erase the load-bearing finding that
      // was blocking it in the first place.
      const priorLoadBearing =
        (state.last_result && state.last_result.detail && state.last_result.detail.load_bearing) || []
      // The adjudication-error and fix-round-error blocked paths (see the `if
      // (adjudicationError)` / `if (fixRoundError)` branches below) hardcode
      // detail.load_bearing to [] — neither ever reached a load-bearing verdict, which made
      // priorLoadBearing.length alone a false negative on those paths: a truncated
      // verdicts_pending reseeding to current={} -> dissenting=[] looked identical to a
      // legitimately empty panel and finalized the run clean with the original findings
      // erased. Gate on both error breadcrumbs too.
      const priorAdjudicationError =
        (state.last_result && state.last_result.detail && state.last_result.detail.adjudication_error) || null
      const priorFixRoundError =
        (state.last_result && state.last_result.detail && state.last_result.detail.fix_round_error) || null
      const stillDissenting = results.some((v) => v.verdict === 'CHANGES_REQUESTED' && (v.findings || []).length > 0)
      if ((priorLoadBearing.length || priorAdjudicationError || priorFixRoundError) && !stillDissenting) {
        const result = {
          ...state.last_result,
          detail: {
            ...state.last_result.detail,
            note: 'retry findings: the withheld panel record (verdicts_pending) came back empty or already fully adjudicated — treating this as data loss, not convergence. Use `override findings: <rationale>` or `abort` instead.',
          },
        }
        await saveResult(result)
        return result
      }
    } else {
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
      results = await runPersonaPanel(state, prInfo.number, state.last_result.default_branch, postingMode, personaFilter)
      current = Object.fromEntries(results.map((v) => [v.slug, { verdict: v.verdict, posted: v.posted, findings: v.findings }]))
      // Record the skip as a ux-designer finding so it surfaces in findings_inline / the final
      // report. "SKIPPED" is not "CHANGES_REQUESTED", so the dissenter fix-loop never re-reviews it.
      if (uxSkipFinding) {
        current['ux-designer'] = { verdict: 'SKIPPED', findings: [uxSkipFinding] }
      }
    }

    // Fix loop, max 3 rounds. Deliberately does NOT persist `verdicts` to the state file
    // until the whole loop (or a resume of it) is done — persisting early made a crash
    // mid-loop look "done" to a resumed invocation, silently skipping the remaining
    // rounds and finalizing with unaddressed persona findings.
    // Reassigned (not redeclared) — `round` is hoisted above this block so the terminal
    // result can still read it on a path that skips this block entirely. Every entry into
    // this block starts a fresh cycle's round count at 0, same as before hoisting.
    round = 0
    // The cycle this fix loop is actually running under. Read from `currentFixCycle`, NOT from
    // `state.fix_cycles`: `grant-retry-cycle` above patched the file but deliberately did not
    // reassign `state`, so state.fix_cycles is still the pre-grant value here and would tag a
    // granted cycle 2's wontfix_rulings as cycle 1 — indistinguishable from cycle 1's own
    // entries, and with no dedupe on wontfixRulings the operator cannot tell a once-declined
    // finding from a twice-declined one.
    const fixCycle = currentFixCycle
    // `findings.length > 0` matters only on the retry-reseed path (a fresh panel's
    // CHANGES_REQUESTED verdicts always carry findings) — it excludes a persona whose
    // findings were entirely already-parked and just filtered to empty above, so the fix
    // loop doesn't re-run a persona with nothing new to fix.
    let dissenting = results.filter((v) => v.verdict === 'CHANGES_REQUESTED' && (v.findings || []).length > 0)
    // Each round's own account of itself. Kept LOCAL, never persisted: the adjudicator is
    // the only consumer and it runs in this same invocation, and the state file's free-text
    // budget is already spent on the four fields that have nowhere else to live.
    const fixHistory = []
    while (dissenting.length && round < 3) {
      round += 1
      const findings = dissenting.flatMap((v) => v.findings)
      // The return was previously discarded, which made the WONTFIX invitation in this
      // prompt a black hole: a rationale the operator never saw. Capture both halves.
      let fixRound = null
      let fixRoundError = null
      try {
        fixRound = await fixLoopRound(findings)
      } catch (e) {
        // Unlike adjudicateFindings (which has had a try/catch since the adjudication-error
        // fix above), this call was previously unguarded: a schema-validation throw here left
        // `current`/`verdicts_pending` unset entirely, so a resumed invocation fell back to
        // the top of the `if (!verdicts && prInfo)` guard and re-ran and re-posted the FULL
        // five-persona panel just to reproduce the exact `dissenting` set already in memory.
        fixRoundError = `fix-round ${round} errored: ${e && e.message ? e.message : e}`
      }
      if (fixRoundError) {
        await patchState(
          {
            verdicts_pending: current,
            parked_findings: parkedFindings,
            wontfix_rulings: wontfixRulings,
            fix_rounds_done: round,
            posting_mode: postingMode,
            surface_detection_error: surfaceDetectionError,
          },
          'save-fix-round-error'
        )
        const result = {
          status: 'blocked',
          // Same reuse of the existing `unresolved_findings` reason as the adjudication-error
          // path just below, for the same operator-facing reason: findings are still open,
          // just for a different underlying cause.
          reason: 'unresolved_findings',
          default_branch: state.last_result.default_branch,
          diff_stat: state.last_result.diff_stat,
          dispatch: state.last_result.dispatch,
          dod_coverage: coverageCriteria,
          dod_coverage_error: coverageError,
          dod_coverage_status: coverageStatus,
          parked_findings: parkedFindings,
          wontfix_rulings: wontfixRulings,
          detail: {
            parked_findings: parkedFindings,
            wontfix_rulings: wontfixRulings,
            load_bearing: [],
            fix_round_error: fixRoundError,
            fix_rounds_done: round,
          },
        }
        await saveResult(result)
        return result
      }
      if (fixRound) {
        fixHistory.push({ round, summary: fixRound.summary || '', fixed: fixRound.fixed || [] })
        for (const w of fixRound.wontfix || []) {
          if (w && w.finding) wontfixRulings.push({ cycle: fixCycle, round, finding: w.finding, rationale: w.rationale || '' })
        }
      }
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
      // Same guard as the initial `dissenting` assignment above (and for the same reason):
      // without it, a re-reviewed persona that came back CHANGES_REQUESTED with an empty
      // findings array still loops back through fixLoopRound([]) and, at the round cap,
      // hands opus an adjudication with nothing to rule on.
      dissenting = reReview.filter((v) => v.verdict === 'CHANGES_REQUESTED' && (v.findings || []).length > 0)
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

    // Adjudication at the cap. The loop above stops at 3 rounds whether or not anything
    // converged; before this, survivors were printed and the run finalized anyway.
    if (dissenting.length) {
      let adjudication
      // Reuses the outer-scoped `adjudicationError` (declared above the override block, seeded
      // from state.adjudication_error) rather than shadowing it with a fresh local — this is
      // the one place that can produce a NEW adjudication error, and both the blocked-return
      // patchState below and finalizeRun further down need the same variable to see it.
      adjudicationError = null
      try {
        adjudication = await adjudicateFindings(
          // Per-persona shape, NOT the flattened list the fix loop uses: flattening discards
          // the attribution the ">=2 distinct personas defaults to load-bearing" rule needs.
          dissenting.map((v) => ({ slug: v.slug, findings: v.findings })),
          fixHistory,
          state.last_result.default_branch
        )
      } catch (e) {
        adjudicationError = `adjudicate-findings errored: ${e && e.message ? e.message : e}`
      }
      if (adjudicationError) {
        // This is the one new agent call in the block with no try/catch until now — an
        // uncaught throw here left NOTHING persisted for the cycle: `verdicts` correctly
        // stays unset (see the load-bearing branch's own comment on that), but so did
        // `verdicts_pending`, so a resumed invocation fell straight back to the top of this
        // `if (!verdicts && prInfo)` guard and re-ran the FULL five-persona panel — five more
        // live GitHub reviews — just to reproduce the exact `dissenting` set already sitting
        // in memory when adjudicateFindings threw. Persist verdicts_pending here exactly as
        // the load-bearing branch below does, so `retry findings` reseeds from the withheld
        // panel output (resumingFindings' existing path) instead of re-dispatching personas.
        await patchState(
          {
            verdicts_pending: current,
            parked_findings: parkedFindings,
            wontfix_rulings: wontfixRulings,
            fix_rounds_done: round,
            posting_mode: postingMode,
            surface_detection_error: surfaceDetectionError,
            // Must survive a resume (including `override findings:`, which skips this whole
            // panel block) so it reaches finalizeRun's advisoryNotes / the terminal result
            // instead of vanishing the moment control leaves this invocation.
            adjudication_error: adjudicationError,
          },
          'save-adjudication-error'
        )
        const result = {
          status: 'blocked',
          // Reuses the existing `unresolved_findings` reason (not a new one) so this resumes
          // through the already-documented `resumingFindings` gate and operator verbs (`retry
          // findings` / `override findings:` / `abort`) instead of requiring a parallel state
          // machine branch for a failure that, from the operator's chair, looks the same:
          // findings are still open and unresolved, just for a different reason.
          reason: 'unresolved_findings',
          default_branch: state.last_result.default_branch,
          diff_stat: state.last_result.diff_stat,
          dispatch: state.last_result.dispatch,
          dod_coverage: coverageCriteria,
          dod_coverage_error: coverageError,
          dod_coverage_status: coverageStatus,
          parked_findings: parkedFindings,
          wontfix_rulings: wontfixRulings,
          detail: {
            parked_findings: parkedFindings,
            wontfix_rulings: wontfixRulings,
            load_bearing: [],
            adjudication_error: adjudicationError,
            fix_rounds_done: round,
          },
        }
        await saveResult(result)
        return result
      }
      const rulings = (adjudication && adjudication.rulings) || []
      const loadBearing = rulings.filter((r) => r && r.ruling === 'load-bearing')
      // Dedupe by finding text — same guard as the override block's alreadyRecorded Set. The
      // reseed's `alreadyParked` filter (above, at the top of the retry-findings branch) only
      // covers a fresh reseed at cycle start; it does NOT cover a finding that comes back
      // verbatim through the unfiltered reReview overwrite (`for (const v of reReview) current[v.slug]
      // = ...` in the fix loop above) and reaches this adjudication a second time. Without this,
      // a previously-parked finding re-raised in a later cycle is re-adjudicated and double-listed.
      const alreadyRecordedRulings = new Set(parkedFindings.map((r) => r && r.finding))
      parkedFindings = [
        ...parkedFindings,
        ...rulings.filter((r) => r && r.ruling !== 'load-bearing' && !alreadyRecordedRulings.has(r.finding)),
      ]
      // Runs on BOTH exits below — the parked-only path continues to finalize and must
      // still leave the rulings in GOAL.md, not only in a state file that is about to be
      // deleted. Never fatal: the rulings also travel in the result object.
      try {
        await writeParkedFindings(parkedFindings)
        // Clear a stale write-error carried from an earlier cycle now that a write has
        // actually succeeded — unlike surfaceDetectionError/heartbeatClockError, this field
        // was never reset on the success path, so a cycle-1 failure kept reporting itself in
        // advisoryNotes/the terminal result even after a cycle-2 write succeeded.
        parkedFindingsWriteError = null
      } catch (e) {
        // GOAL.md rendering is a record, not a gate — the rulings are in the result object.
        // But a silent drop here means the durable record README.md promises silently does
        // not exist; leave a breadcrumb rather than discarding the exception outright.
        parkedFindingsWriteError = `write-parked-findings failed after adjudication: ${e && e.message ? e.message : e}`
        await patchState({ parked_findings_write_error: parkedFindingsWriteError }, 'parked-findings-write-error').catch(() => {})
      }
      if (loadBearing.length) {
        // `verdicts` stays UNSET here, deliberately. Its guard encloses the whole panel and
        // fix loop, so persisting it would make the next resume skip both, fall through to
        // finalizeRun, and finalize with the load-bearing finding untouched while looking
        // like another round had happened. Partial panel output goes to verdicts_pending.
        // fix_cycles is NOT written here either — it is incremented where the retry verb is
        // consumed, at the top of this block.
        await patchState(
          {
            verdicts_pending: current,
            parked_findings: parkedFindings,
            wontfix_rulings: wontfixRulings,
            fix_rounds_done: round,
            posting_mode: postingMode,
            // Carried across the block the same way it is on the converged path: the
            // reseed below skips surface detection entirely, so without this a flaking
            // classifier recorded in this cycle would vanish on the next one.
            surface_detection_error: surfaceDetectionError,
            // Adjudication just succeeded on this cycle, so both must be persisted as
            // cleared — otherwise a stale value from an earlier cycle's blocked result
            // survives in the state file and keeps reporting a resolved problem.
            adjudication_error: adjudicationError,
            parked_findings_write_error: parkedFindingsWriteError,
          },
          'save-adjudication'
        )
        // Field-complete by construction. This result becomes `state.last_result` for the
        // resume that re-enters this same block, and eight reads of state.last_result.<field>
        // live between the block's guard and its final return — all written under the old
        // guarantee that lastStatus was 'awaiting_authorization'. default_branch is the fatal
        // one: personaReview tells each persona to run `git diff origin/<branch>..HEAD`
        // itself, so `undefined` means five personas review a failed command and return
        // plausible verdicts on nothing.
        const result = {
          status: 'blocked',
          reason: 'unresolved_findings',
          default_branch: state.last_result.default_branch,
          diff_stat: state.last_result.diff_stat,
          dispatch: state.last_result.dispatch,
          dod_coverage: coverageCriteria,
          dod_coverage_error: coverageError,
          dod_coverage_status: coverageStatus,
          parked_findings: parkedFindings,
          wontfix_rulings: wontfixRulings,
          detail: {
            parked_findings: parkedFindings,
            wontfix_rulings: wontfixRulings,
            load_bearing: loadBearing,
            fix_rounds_done: round,
          },
        }
        await saveResult(result)
        return result
      }
    } else {
      // Converged cycle: nothing dissents. Both breadcrumbs above are cleared only INSIDE the
      // dissenting branch, so without this a cycle-1 failure rode into advisoryNotes, the
      // mandatory audit-log --notes line and the terminal result of a cycle that was actually
      // healthy — permanently recording a clean run as degraded, the inverse of what every
      // sibling breadcrumb (surface_detection_error, heartbeat_clock_error) does on recovery.
      //
      // The two are NOT symmetric, and clearing both unconditionally would trade one wrong
      // report for a worse one:
      //   - adjudication_error is genuinely resolved. Nothing is left unadjudicated when
      //     nothing dissents, so a carried "the adjudicator never ran" is stale by definition.
      //   - parked_findings_write_error may still be TRUE. writeParkedFindings() is called only
      //     inside the dissenting branch, so a prior cycle's failed GOAL.md write has not been
      //     retried by reaching here — clearing it blind would claim a durable record exists
      //     when it does not. Retry the write instead, and clear only on a real success.
      adjudicationError = null
      if (parkedFindingsWriteError) {
        if (parkedFindings.length) {
          try {
            await writeParkedFindings(parkedFindings)
            parkedFindingsWriteError = null
          } catch (e) {
            parkedFindingsWriteError = `write-parked-findings retry failed on a converged cycle: ${e && e.message ? e.message : e}`
          }
        } else {
          // Nothing to write, so nothing is missing from GOAL.md — the error described a write
          // that is no longer owed.
          parkedFindingsWriteError = null
        }
      }
    }

    verdicts = current
    await patchState(
      {
        verdicts,
        // The panel is finished; nothing is pending any more. A `cat` of the state file is
        // what README.md tells operators to do for progress — leaving a stale
        // verdicts_pending alongside a populated verdicts makes that read a lie.
        verdicts_pending: null,
        parked_findings: parkedFindings,
        wontfix_rulings: wontfixRulings,
        fix_rounds_done: round,
        posting_mode: postingMode,
        surface_detection_error: surfaceDetectionError,
        adjudication_error: adjudicationError,
        parked_findings_write_error: parkedFindingsWriteError,
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
  const finalized = await finalizeRun(
    state,
    prInfo,
    verdicts,
    state.last_result.dispatch,
    coverageCriteria,
    coverageError,
    surfaceDetectionError,
    heartbeatClockError,
    dispatchClockError,
    parkedFindingsWriteError,
    adjudicationError
  )
  const result = {
    status: 'final',
    pr: prInfo ? { url: prInfo.url, number: prInfo.number, ready: finalized.pr_ready } : null,
    verdicts,
    // Whether the in-run persona panel ran this cycle. Skipped by default (see the
    // `personaPanelEnabled` short-circuit above) unless `--personas` was passed; surfaced
    // here so the operator's record shows the empty `verdicts` above means "panel not run",
    // not "panel ran and found nothing" — the two are indistinguishable from `verdicts`
    // alone once the state file is deleted.
    persona_panel: personaPanelEnabled ? 'ran' : 'skipped (--personas not set)',
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
    // Same reasoning as surface_detection_error immediately above — a persistently-flaking
    // clock helper must be distinguishable, in the operator's only surviving record, from a
    // healthy run once the state file is deleted.
    heartbeat_clock_error: heartbeatClockError,
    dispatch_clock_error: dispatchClockError,
    // Same reasoning again — deleteStateFile() removes the only other copy of this field,
    // so a failed GOAL.md parked-findings write must be visible here too, not just as a
    // breadcrumb inside the state file it is about to outlive.
    parked_findings_write_error: parkedFindingsWriteError,
    // Same reasoning again — an override that happened despite the adjudicator never running
    // must be visible in the operator's only surviving record once deleteStateFile() runs,
    // not just as a parked_findings breadcrumb (see the override block's `operator-overridden`
    // entries whose rationale records that the panel never fully adjudicated them).
    adjudication_error: adjudicationError,
    // commands/imps.md documents this as "surfaced in the result" — previously it was written
    // to the state file on every blocked/resumed cycle but omitted here, so on a converged run
    // deleteStateFile() removed the only surviving copy.
    fix_rounds_done: round,
    // Rendered in the terminal result, not only in the state file: deleteStateFile() removes
    // that file at the end of a completed run, so without these two the operator's surviving
    // record would lose every ruling and every WONTFIX rationale the run produced. They are
    // NOT folded into `verdicts` — that map is {slug: {verdict, posted, findings}}, a
    // {finding, rationale} pair has no slug, and findings_inline below would silently drop
    // any extra key it grew.
    parked_findings: parkedFindings,
    wontfix_rulings: wontfixRulings,
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
  const reviewPreflight = await ocrPreflight()
  // OCR is advisory when the service cannot return a trustworthy contract. Keep the
  // complete redacted failure record for the authorization result instead of presenting
  // an invented approval, but do not strand otherwise-tested work on provider setup,
  // installation, timeout, or malformed-output failures.
  const codeReviewWarning = reviewPreflight.status === 'ok' && reviewPreflight.verdict
    ? null
    : reviewPreflight
  state = await patchState({ review_engine: 'ocr', review_model: reviewPreflight.model || null, code_review_rounds: 0, code_review_findings: [], code_review_sessions: [], code_review_override: null, code_review_warning: codeReviewWarning }, 'save-review-preflight')
}
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
  // Same fail-soft rule as the heartbeat: a clock failure must not abort a run that is
  // about to dispatch. `dispatched_at` gates `if (!state.dispatched_at)` above, so it must
  // stay truthy — fall back to the old loud sentinel, which finalizeRun knows to read as
  // "elapsed unknown" rather than computing a duration from a non-date.
  let dispatchIso = null
  // Fail-soft, but the fallback sentinel is silent by design (finalizeRun reads it as
  // "elapsed unknown") — record why it was needed so the audit trail doesn't lose the
  // signal entirely. Persisted, not local: finalizeRun reads it many invocations later.
  let dispatchClockError = null
  try {
    dispatchIso = (await nowIso()).iso
  } catch (e) {
    dispatchClockError = `dispatched_at set to the "agent-supplies-timestamp" placeholder — clock command failed: ${e && e.message ? e.message : e}`
  }
  await patchState(
    { dispatched_at: dispatchIso || 'agent-supplies-timestamp', dispatch_clock_error: dispatchClockError, segment: 'dispatch' },
    'claim-run'
  )
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

const hasDiff = mergeResult.merged.length > 0
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

// Gates are deliberately before review. A review-driven fix reruns every gate and is then
// sent to a fresh OCR run; operational OCR failures remain visible warnings, never Claude
// review fallbacks or invented approvals.
let codeReviewWarning = state.code_review_warning || null
let codeReview = codeReviewWarning
  ? { status: 'ok', verdict: 'APPROVE', findings: [], model: state.review_model || null, provider: 'unavailable', session_id: null, duration_ms: null, cost_usd: null, reason: codeReviewWarning.reason || 'code_review_unavailable' }
  : hasDiff ? await ocrReview(defaultBranch) : { status: 'ok', verdict: 'APPROVE', findings: [], model: state.review_model || 'openai/gpt-5.4', provider: 'openai', session_id: null, duration_ms: 0, cost_usd: null, reason: null }
let codeReviewRounds = 0
let codeReviewSessions = codeReview.session_id ? [codeReview.session_id] : []
if (codeReview.status !== 'ok' || !codeReview.verdict) {
  codeReviewWarning = codeReview
  codeReview = { ...codeReview, status: 'ok', verdict: 'APPROVE', findings: [] }
}
while (codeReview.verdict === 'CHANGES_REQUESTED' && codeReviewRounds < 3) {
  codeReviewRounds += 1
  await fixOcrReview(codeReview.findings)
  const repairedGates = await runGatesWithRetry(gateCommands, null)
  if (repairedGates.blockedOn) {
    const failedResult = repairedGates.results[repairedGates.results.length - 1]
    const result = { status: 'blocked', reason: 'gate_red', detail: { gate: repairedGates.blockedOn.name, cmd: repairedGates.blockedOn.cmd, tail: failedResult.tail, after_code_review: true } }
    await saveResult(result)
    return result
  }
  codeReview = await ocrReview(defaultBranch)
  if (codeReview.session_id) codeReviewSessions.push(codeReview.session_id)
  if (codeReview.status !== 'ok' || !codeReview.verdict) {
    codeReviewWarning = codeReview
    codeReview = { ...codeReview, status: 'ok', verdict: 'APPROVE', findings: [] }
  }
}
state = await patchState({ code_review_rounds: codeReviewRounds, code_review_findings: codeReview.findings, code_review_sessions: codeReviewSessions, code_review_warning: codeReviewWarning }, 'save-code-review')
if (codeReview.verdict === 'CHANGES_REQUESTED') {
  const overridePrefix = 'override code review:'
  const codeReviewOverride = state.operator_decision && state.operator_decision.startsWith(overridePrefix)
    ? state.operator_decision.slice(overridePrefix.length).trim()
    : ''
  if (codeReviewOverride) {
    await patchState({ code_review_override: codeReviewOverride }, 'override-code-review')
    codeReview = { ...codeReview, verdict: 'APPROVE' }
  } else {
  const result = { status: 'blocked', reason: 'code_review_red', detail: { findings: codeReview.findings, rounds: codeReviewRounds, model: codeReview.model, provider: codeReview.provider, sessions: codeReviewSessions } }
  await saveResult(result)
  return result
  }
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
  // `APPROVE` is a control-flow value after an unavailable review, not a claim about
  // OCR's conclusion. Expose null plus the helper contract in that case.
  code_review: { engine: 'ocr', provider: codeReviewWarning ? codeReviewWarning.provider : codeReview.provider, model: codeReviewWarning ? codeReviewWarning.model : codeReview.model, verdict: codeReviewWarning ? null : codeReview.verdict, rounds: codeReviewRounds, findings: codeReview.findings, warning: codeReviewWarning },
  code_review_override: state.operator_decision && state.operator_decision.startsWith('override code review:') ? state.operator_decision.slice('override code review:'.length).trim() : null,
  gates: gateOutcome.results,
  diff_stat: diffStatInfo.diff_stat,
  default_branch: defaultBranch,
  dod_coverage: (coverage && coverage.criteria) || [],
  dod_coverage_error: dodCoverageError,
  dod_coverage_status: dodCoverageStatus,
  // Carried through the operator gate as well as the final result. A run that already went
  // through a findings cycle and came back round for another integrate pass would otherwise
  // present the operator a clean-looking authorization prompt with its prior rulings and
  // WONTFIX rationales nowhere in sight.
  parked_findings: state.parked_findings || [],
  wontfix_rulings: state.wontfix_rulings || [],
  dispatch: {
    model_counts: modelCounts,
    tokens_spent: null,
    artifacts: dispatchOutcome.artifacts,
  },
}
await patchState({ segment: 'publish_finalize' }, 'enter-publish')
await saveResult(result)
return result
