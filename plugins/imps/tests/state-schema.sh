#!/usr/bin/env bash
# state-schema.sh — guards imps-run.workflow.js's STATE_SCHEMA against the silent
# field-drop failure mode first seen as the #87 silent zero-dispatch bug.
#
# Why a schema test and not a behavioural one: patchState() round-trips the ENTIRE state
# file through an LLM on every dispatch heartbeat, constrained by STATE_SCHEMA. A per-task
# field the schema does not know about can be silently dropped mid-run — precedent is the
# #87 silent zero-dispatch bug. The failure is schema-driven, so the assertion is too;
# demonstrating a real round-trip would need a live agent() call inside a running Workflow,
# which no test can do. This costs nothing: pure node, no LLM, no sandbox, no network.
#
# Asserts:
#   - STATE_SCHEMA.properties.tasks.items.additionalProperties === true  (the landmine)
#   - the six schema-4 review-discipline fields are TOP-LEVEL and correctly shaped
#   - a schema-4 state object validates, AND a hand-written schema-3 one still does
#     (the schema-4 fields are additive; none of them joined `required`)
#   - negative controls: bad enum / missing required / wrong item type all FAIL to validate
#     (without these, a no-op validator would make every positive assertion vacuous)
set -uo pipefail

TESTS_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd -P)"
PLUGIN_ROOT="$(cd "$TESTS_DIR/.." && pwd -P)"
WORKFLOW="$PLUGIN_ROOT/scripts/imps-run.workflow.js"

command -v node >/dev/null 2>&1 || { echo "state-schema: node is required" >&2; exit 2; }
[ -f "$WORKFLOW" ] || { echo "state-schema: missing $WORKFLOW" >&2; exit 2; }

node - "$WORKFLOW" <<'NODE'
'use strict'
const fs = require('fs')
const src = fs.readFileSync(process.argv[2], 'utf8').split('\n')

let fails = 0
let asserts = 0
function assert(name, ok, detail) {
  asserts += 1
  if (ok) { console.log('ok   state-schema/' + name); return }
  fails += 1
  console.log('FAIL state-schema/' + name)
  if (detail) console.log('     ' + detail)
}

// --- Extract the object literal ------------------------------------------------------
// The file cannot be imported: it is a Workflow module whose top level executes the whole
// pipeline (`await runDispatch(state)`). Slice the literal out textually instead — the
// file's style is a top-level `const X = {` closing with a `}` at column 0. A slice that
// misses throws in the Function() below (loud), and the baseline assertions catch a slice
// that is merely wrong.
const start = src.findIndex((l) => /^const STATE_SCHEMA = \{/.test(l))
if (start < 0) { console.log('FAIL state-schema/extract'); console.log('     no top-level `const STATE_SCHEMA = {` line'); process.exit(1) }
let end = -1
for (let i = start + 1; i < src.length; i += 1) { if (/^\}/.test(src[i])) { end = i; break } }
if (end < 0) { console.log('FAIL state-schema/extract'); console.log('     no column-0 closing brace after line ' + (start + 1)); process.exit(1) }
const literal = src.slice(start, end + 1).join('\n').replace(/^const STATE_SCHEMA =\s*/, '')

let S
try {
  S = new Function('return (' + literal + ')')()
} catch (e) {
  console.log('FAIL state-schema/extract')
  console.log('     extracted text did not evaluate: ' + e.message)
  process.exit(1)
}
assert('extract', S && S.type === 'object' && !!S.properties, 'extracted value is not a schema object')

// --- Baseline: the slice really is the whole known-good schema -----------------------
// A mis-slice that happens to evaluate would otherwise let every check below pass
// against a fragment.
const P = S.properties || {}
for (const k of ['schema', 'task', 'repo', 'branch', 'tasks', 'phase', 'tasks_done', 'worktrees', 'failed_tasks']) {
  assert('baseline/top-level/' + k, Object.prototype.hasOwnProperty.call(P, k), 'missing top-level property ' + k)
}
assert(
  'baseline/required',
  JSON.stringify(S.required) === JSON.stringify(['schema', 'task', 'branch', 'tasks', 'phase']),
  'top-level required is ' + JSON.stringify(S.required)
)

const item = ((P.tasks || {}).items) || {}
const IP = item.properties || {}
for (const k of ['id', 'label', 'spec', 'model', 'type', 'deps']) {
  assert('baseline/task-item/' + k, Object.prototype.hasOwnProperty.call(IP, k), 'missing task-item property ' + k)
}

// --- The landmine ---------------------------------------------------------------------
assert(
  'task-item-additionalProperties-true',
  item.additionalProperties === true,
  'tasks.items.additionalProperties is ' + JSON.stringify(item.additionalProperties) +
    ' — an unknown per-task field can be dropped by a patchState() heartbeat (#87)'
)

// --- Schema 4: the review-discipline fields ------------------------------------------
// All six are TOP-LEVEL for the same reason escalated_tasks is: patchState() merges
// top-level keys only, so a field on the task item is writable at plan time and never
// again. All six are additive and OPTIONAL — a schema-3 state file must still load, which
// the legacy assertion below proves.
const SCHEMA4 = {
  parked_findings: (s) =>
    Array.isArray(s.type) && s.type.indexOf('array') !== -1 && s.type.indexOf('null') !== -1 &&
    !!s.items && s.items.type === 'object',
  wontfix_rulings: (s) =>
    Array.isArray(s.type) && s.type.indexOf('array') !== -1 && s.type.indexOf('null') !== -1 &&
    !!s.items && s.items.type === 'object',
  verdicts_pending: (s) =>
    Array.isArray(s.type) && s.type.indexOf('object') !== -1 && s.type.indexOf('null') !== -1,
  fix_rounds_done: (s) =>
    Array.isArray(s.type) && s.type.indexOf('number') !== -1 && s.type.indexOf('null') !== -1,
  fix_cycles: (s) =>
    Array.isArray(s.type) && s.type.indexOf('number') !== -1 && s.type.indexOf('null') !== -1,
  posting_mode: (s) =>
    Array.isArray(s.type) && s.type.indexOf('string') !== -1 && s.type.indexOf('null') !== -1,
  review_engine: (s) => Array.isArray(s.type) && s.type.indexOf('string') !== -1 && s.type.indexOf('null') !== -1,
  review_model: (s) => Array.isArray(s.type) && s.type.indexOf('string') !== -1 && s.type.indexOf('null') !== -1,
  code_review_rounds: (s) => Array.isArray(s.type) && s.type.indexOf('number') !== -1 && s.type.indexOf('null') !== -1,
  code_review_findings: (s) => Array.isArray(s.type) && s.type.indexOf('array') !== -1 && s.type.indexOf('null') !== -1,
  code_review_sessions: (s) => Array.isArray(s.type) && s.type.indexOf('array') !== -1 && s.type.indexOf('null') !== -1,
  code_review_override: (s) => Array.isArray(s.type) && s.type.indexOf('string') !== -1 && s.type.indexOf('null') !== -1,
}
const topRequired = S.required || []
for (const k of Object.keys(SCHEMA4)) {
  const present = Object.prototype.hasOwnProperty.call(P, k)
  assert('schema4/top-level/' + k, present, 'no top-level `' + k + '` — schema 4 is additive at the top level')
  assert(
    'schema4/shape/' + k,
    present && SCHEMA4[k](P[k]) && topRequired.indexOf(k) < 0,
    '`' + k + '` is ' + JSON.stringify(P[k]) + ' (and must stay OUT of top-level required)'
  )
}

// --- Minimal validator (type/enum/properties/required/items/additionalProperties) -----
function validate(schema, value, path, errs) {
  path = path || '$'
  errs = errs || []
  const types = Array.isArray(schema.type) ? schema.type : (schema.type ? [schema.type] : [])
  if (types.length) {
    const actual = value === null ? 'null' : Array.isArray(value) ? 'array' : typeof value
    const ok = types.some((t) => (t === 'number' ? actual === 'number' : t === 'integer' ? Number.isInteger(value) : t === actual))
    if (!ok) { errs.push(path + ': type ' + actual + ' not in ' + types.join('|')); return errs }
  }
  if (schema.enum && schema.enum.indexOf(value) < 0) errs.push(path + ': ' + JSON.stringify(value) + ' not in enum')
  if (Array.isArray(value) && schema.items) value.forEach((v, i) => validate(schema.items, v, path + '[' + i + ']', errs))
  if (value && typeof value === 'object' && !Array.isArray(value)) {
    for (const r of schema.required || []) {
      if (!Object.prototype.hasOwnProperty.call(value, r)) errs.push(path + ': missing required "' + r + '"')
    }
    for (const k of Object.keys(value)) {
      const sub = (schema.properties || {})[k]
      if (sub) { validate(sub, value[k], path + '.' + k, errs); continue }
      if (schema.additionalProperties === false) errs.push(path + ': unexpected property "' + k + '"')
      else if (schema.additionalProperties && typeof schema.additionalProperties === 'object') {
        validate(schema.additionalProperties, value[k], path + '.' + k, errs)
      }
    }
  }
  return errs
}

function sample() {
  return {
    schema: 4,
    task: 'refactor the state-schema fixture',
    repo: 'seankoji/claude-plugins',
    branch: 'imps/claude-plugins-20260728-000000',
    tasks: [
      { id: 1, label: 'ordinary imp', spec: 'do the thing', model: 'sonnet', type: 'code', deps: [] },
      { id: 2, label: 'second imp', spec: 'do the other thing', model: 'haiku', type: 'code', deps: [1] },
      { id: 3, label: 'legacy-shaped imp', spec: 'still valid', model: 'haiku', type: 'query', deps: [] },
    ],
    phase: 'dispatch_pending',
    segment: null,
    dispatched_at: null,
    poll_interval_seconds: 300,
    max_dispatch_hours: 6,
    last_heartbeat: null,
    tasks_done: [1],
    worktrees: { 1: 'imps/task-1' },
    artifacts: [],
    pr: null,
    verdicts: null,
    discussion_comment_url: null,
    source_discussion: null,
    gate_commands: null,
    learnings_saved: null,
    operator_decision: null,
    last_result: null,
    failed_tasks: [],
    parked_findings: [{ finding: 'the retry bound is unreachable', ruling: 'parked-deferred', rationale: 'no DoD criterion falsified; fix round 2 could not reproduce it' }],
    wontfix_rulings: [{ round: 1, finding: 'rename the helper', rationale: 'style only, no criterion depends on the name' }],
    verdicts_pending: { 'grumpy-engineer': { verdict: 'CHANGES_REQUESTED', posted: true, findings: ['still open'] } },
    fix_rounds_done: 3,
    fix_cycles: 1,
    posting_mode: 'live',
    review_engine: 'opencode', review_model: 'openai/gpt-5.4', code_review_rounds: 1,
    code_review_findings: [], code_review_sessions: ['ses_test'], code_review_override: null,
  }
}

let errs = validate(S, sample())
assert('sample-schema-4-validates', errs.length === 0, errs.join('; '))

// A hand-written SCHEMA-3 state file: none of the six schema-4 fields. `schema` is set
// explicitly — it derives from sample() above, which now says 4, so without this line
// this assertion would be checking a schema-4 object and could never fail in the way it
// exists to catch.
const legacy = sample()
legacy.schema = 3
for (const k of Object.keys(SCHEMA4)) delete legacy[k]
assert('legacy-schema-3-state-still-validates', validate(S, legacy).length === 0, validate(S, legacy).join('; '))

// --- Negative controls: prove the validator is not a no-op ----------------------------
const missingReq = sample()
delete missingReq.tasks[0].id
assert('negative/task-missing-id', validate(S, missingReq).length > 0, 'validator accepted a task item with no id')

const missingTop = sample()
delete missingTop.phase
assert('negative/missing-top-level-required', validate(S, missingTop).length > 0, 'validator accepted a state file with no phase')

// Proves the schema-4 shapes above are actually enforced, not just declared: without this,
// a `posting_mode: {}` or `posting_mode: 7` typed by a patchState() round-trip would slip
// through and the six positive assertions would be vacuous.
const badPostingMode = sample()
badPostingMode.posting_mode = 7
assert('negative/posting_mode-wrong-type', validate(S, badPostingMode).length > 0, 'validator accepted posting_mode: 7')

// The other three schema-4 fields carry the free text the whole review-discipline feature
// depends on (persona findings, ruling rationales) and, unlike posting_mode, had no
// wrong-type control of their own — a truncated patchState() round-trip that turned one of
// them into a string or a bare object would slip through unnoticed.
const badParkedFindings = sample()
badParkedFindings.parked_findings = 'not an array'
assert('negative/parked_findings-wrong-type', validate(S, badParkedFindings).length > 0, 'validator accepted parked_findings: "not an array"')

const badWontfixRulings = sample()
badWontfixRulings.wontfix_rulings = 'not an array'
assert('negative/wontfix_rulings-wrong-type', validate(S, badWontfixRulings).length > 0, 'validator accepted wontfix_rulings: "not an array"')

const badVerdictsPending = sample()
badVerdictsPending.verdicts_pending = 'not an object'
assert('negative/verdicts_pending-wrong-type', validate(S, badVerdictsPending).length > 0, 'validator accepted verdicts_pending: "not an object"')

// A truncated run must not pass silently.
const EXPECTED_ASSERTS = 50
if (asserts !== EXPECTED_ASSERTS) {
  console.log('FAIL state-schema/assertion-count')
  console.log('     ran ' + asserts + ' assertions, expected ' + EXPECTED_ASSERTS)
  fails += 1
}

process.exit(fails === 0 ? 0 : 1)
NODE
