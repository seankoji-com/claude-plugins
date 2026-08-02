'use strict'
const test = require('node:test')
const assert = require('node:assert/strict')
const fs = require('node:fs')
const path = require('node:path')

const SCRIPT_PATH = path.join(__dirname, '..', '..', 'plugins', 'imps', 'scripts', 'imps-run.workflow.js')

// imps-run.workflow.js is not a requirable module — it's evaluated by the Workflow
// tool's own runtime, which injects agent()/parallel()/phase()/args as ambient
// bindings and permits top-level await/return in the script body (see the file's
// own header comment). To unit-test its plain-JS logic (stageTasks/runDispatch),
// load everything up to the "Main" section — schemas + function declarations only
// — into a Function constructed with those same ambient names as parameters,
// stubbed per test. The Main section (which actually drives a run end to end) is
// never evaluated here.
function loadWorkflowFunctions({ agent, parallel, phase, args, log }) {
  const source = fs.readFileSync(SCRIPT_PATH, 'utf8')
  const mainMarker = source.indexOf("\nphase('Preflight')")
  assert.ok(mainMarker !== -1, 'expected to find the Main section marker — has imps-run.workflow.js been restructured?')
  const body = source.slice(0, mainMarker).replace('export const meta', 'const meta')
  const factory = new Function(
    'agent',
    'parallel',
    'phase',
    'args',
    'log',
    `${body}\nreturn { runDispatch, stageTasks, dispatchImp, parseTaskDecision, parseGateDecision, validateStateRead }`
  )
  return factory(agent, parallel, phase || (() => {}), args || {}, log || (() => {}))
}

// Mirrors the real Workflow tool's parallel(): each thunk runs independently; one
// that throws resolves to null in the results array instead of rejecting the batch.
async function parallel(thunks) {
  const settled = await Promise.allSettled(thunks.map((fn) => fn()))
  return settled.map((s) => (s.status === 'fulfilled' ? s.value : null))
}

function task(id, overrides = {}) {
  return { id, label: `task #${id}`, model: 'sonnet', type: 'code', deps: [], ...overrides }
}

function baseState(tasks) {
  return { tasks, tasks_done: [], failed_tasks: [], worktrees: {}, artifacts: [] }
}

test('runDispatch records a parallel()-dropped dispatch as failed instead of losing it', async () => {
  async function agent(prompt, opts) {
    if (opts.label === 'imp-1') return { status: 'done', branch: 'br-1', artifacts: [] }
    if (opts.label === 'imp-2') throw new Error('simulated worktree-creation contention')
    if (opts.label === 'imp-3') return { status: 'done', branch: 'br-3', artifacts: [] }
    return {} // patchState's heartbeat call
  }
  const { runDispatch } = loadWorkflowFunctions({ agent, parallel })

  const outcome = await runDispatch(baseState([task(1), task(2), task(3)]))

  assert.equal(outcome.blocked, false)
  assert.deepEqual([...outcome.doneIds].sort(), [1, 3])
  const failedIds = outcome.failed.map((f) => f.id).sort()
  assert.deepEqual(failedIds, [2], 'the errored task must show up in failed_tasks, not vanish')
  const task2 = outcome.failed.find((f) => f.id === 2)
  assert.equal(task2.notes, 'agent call errored (dropped by parallel())')
  assert.deepEqual(outcome.worktrees, { 1: 'br-1', 3: 'br-3' })
})

test('a dependent task is never dispatched once its dependency is dropped by parallel()', async () => {
  const calls = []
  async function agent(prompt, opts) {
    calls.push(opts.label)
    if (opts.label === 'imp-1') return { status: 'done', branch: 'br-1', artifacts: [] }
    if (opts.label === 'imp-2') throw new Error('simulated worktree-creation contention')
    if (opts.label === 'imp-4') return { status: 'done', branch: 'br-4', artifacts: [] }
    return {}
  }
  const { runDispatch } = loadWorkflowFunctions({ agent, parallel })

  const outcome = await runDispatch(baseState([task(1), task(2), task(4, { deps: [2] })]))

  assert.ok(!calls.includes('imp-4'), 'task 4 depends on task 2, which errored — it must never be dispatched')
  const task4 = outcome.failed.find((f) => f.id === 4)
  assert.ok(task4, 'task 4 must be recorded as failed via dependency cascade')
  assert.equal(task4.notes, 'dependency failed')
})

test('an explicit status:"failed" result is still recorded the same way as before the fix', async () => {
  async function agent(prompt, opts) {
    if (opts.label === 'imp-1') return { status: 'failed', notes: 'lint errors', branch: null, artifacts: [] }
    return {}
  }
  const { runDispatch } = loadWorkflowFunctions({ agent, parallel })

  const outcome = await runDispatch(baseState([task(1)]))

  assert.deepEqual(outcome.failed.map((f) => f.id), [1])
  assert.equal(outcome.failed[0].notes, 'lint errors')
})

test('validateStateRead passes when readState() agrees with the raw file (#87)', async () => {
  const { validateStateRead } = loadWorkflowFunctions({ agent: async () => ({}), parallel })
  const state = { tasks: [task(1), task(2)], phase: 'dispatch_pending' }
  const rawCheck = { raw_task_count: 2, raw_phase: 'dispatch_pending', raw_error: null }

  assert.deepEqual(validateStateRead(state, rawCheck), { ok: true, error: null })
})

test('validateStateRead blocks when readState() mismaps tasks to [] (#87 reproduction)', async () => {
  const { validateStateRead } = loadWorkflowFunctions({ agent: async () => ({}), parallel })
  // Mirrors the observed failure: haiku nested real content under last_result and
  // defaulted top-level tasks to [] / phase to "complete" while the raw file still has
  // 8 tasks and phase "dispatch_pending".
  const state = { tasks: [], phase: 'complete', task: 'Read JSON from state file' }
  const rawCheck = { raw_task_count: 8, raw_phase: 'dispatch_pending', raw_error: null }

  const result = validateStateRead(state, rawCheck)
  assert.equal(result.ok, false)
  assert.match(result.error, /returned 0 task\(s\) but the raw file has 8/)
  assert.match(result.error, /#87/)
})

test('validateStateRead blocks on a phase mismatch even when task counts agree', async () => {
  const { validateStateRead } = loadWorkflowFunctions({ agent: async () => ({}), parallel })
  const state = { tasks: [task(1)], phase: 'complete' }
  const rawCheck = { raw_task_count: 1, raw_phase: 'dispatch_pending', raw_error: null }

  const result = validateStateRead(state, rawCheck)
  assert.equal(result.ok, false)
  assert.match(result.error, /phase/)
})

test('validateStateRead surfaces a fatal readState() error field instead of proceeding', async () => {
  const { validateStateRead } = loadWorkflowFunctions({ agent: async () => ({}), parallel })
  const state = { tasks: [], phase: null, error: 'file is not valid JSON' }
  const rawCheck = { raw_task_count: -1, raw_phase: '', raw_error: 'jq: parse error' }

  const result = validateStateRead(state, rawCheck)
  assert.equal(result.ok, false)
  assert.match(result.error, /fatal error/)
})

// parseTaskDecision/parseGateDecision are pure string parsers — no agent() calls inside
// them, so the stub agent below is never invoked; it only satisfies loadWorkflowFunctions'
// factory signature.
const noopAgent = async () => ({})

test('parseTaskDecision parses valid retry and skip decisions', () => {
  const { parseTaskDecision } = loadWorkflowFunctions({ agent: noopAgent, parallel })

  assert.deepEqual(parseTaskDecision('retry tasks #1,#2: fix the flaky test'), {
    kind: 'retry',
    ids: [1, 2],
    guidance: 'fix the flaky test',
  })
  assert.deepEqual(parseTaskDecision('skip tasks #4,#5'), { kind: 'skip', ids: [4, 5] })
})

test('parseTaskDecision is case-insensitive on the retry/skip keyword', () => {
  const { parseTaskDecision } = loadWorkflowFunctions({ agent: noopAgent, parallel })

  assert.deepEqual(parseTaskDecision('RETRY TASKS #1: bump the timeout'), {
    kind: 'retry',
    ids: [1],
    guidance: 'bump the timeout',
  })
  assert.deepEqual(parseTaskDecision('SKIP TASKS #3'), { kind: 'skip', ids: [3] })
})

test('parseTaskDecision tolerates whitespace around ids and guidance', () => {
  const { parseTaskDecision } = loadWorkflowFunctions({ agent: noopAgent, parallel })

  assert.deepEqual(parseTaskDecision('retry tasks #1, #2 :   extra spaces guidance  '), {
    kind: 'retry',
    ids: [1, 2],
    guidance: 'extra spaces guidance',
  })
})

test('parseTaskDecision returns null (not NaN, not a throw) for malformed input', () => {
  const { parseTaskDecision } = loadWorkflowFunctions({ agent: noopAgent, parallel })

  assert.equal(parseTaskDecision('retry tasks #abc: fix it'), null, 'non-numeric ids never match the id character class')
  assert.equal(parseTaskDecision('skip tasks #xyz'), null)
  assert.equal(parseTaskDecision('gibberish decision'), null)
  assert.equal(parseTaskDecision(''), null)
  assert.equal(parseTaskDecision(null), null)
  assert.equal(parseTaskDecision(undefined), null)
})

test('parseGateDecision parses valid retry and skip decisions', () => {
  const { parseGateDecision } = loadWorkflowFunctions({ agent: noopAgent, parallel })

  assert.deepEqual(parseGateDecision('retry lint: fix the eslint config'), {
    kind: 'retry',
    gate: 'lint',
    guidance: 'fix the eslint config',
  })
  assert.deepEqual(parseGateDecision('skip lint'), { kind: 'skip', gate: 'lint' })
})

test('parseGateDecision is case-insensitive on the retry/skip keyword', () => {
  const { parseGateDecision } = loadWorkflowFunctions({ agent: noopAgent, parallel })

  assert.deepEqual(parseGateDecision('RETRY TEST: bump the timeout'), {
    kind: 'retry',
    gate: 'TEST',
    guidance: 'bump the timeout',
  })
  assert.deepEqual(parseGateDecision('SKIP BUILD'), { kind: 'skip', gate: 'BUILD' })
})

test('parseGateDecision tolerates whitespace around the guidance text', () => {
  const { parseGateDecision } = loadWorkflowFunctions({ agent: noopAgent, parallel })

  assert.deepEqual(parseGateDecision('retry lint:    extra spaces guidance   '), {
    kind: 'retry',
    gate: 'lint',
    guidance: 'extra spaces guidance',
  })
})

// Gate names come from the discovered gate list, not a fixed vocabulary, so real projects
// routinely name them `type-check`, `test-e2e`, `lint:fix`-minus-the-colon and so on. #120
// widened the gate capture from `\w+` to `[^:]+` (retry) and `.+` (skip) and added .trim()
// to match; this test still asserted the old `\w+` behavior and had been failing on master
// since that merge. Non-word characters in a gate name are valid input, not malformed.
test('parseGateDecision accepts gate names that are not bare \\w+', () => {
  const { parseGateDecision } = loadWorkflowFunctions({ agent: noopAgent, parallel })

  assert.deepEqual(parseGateDecision('retry test-fail: guidance'), {
    kind: 'retry',
    gate: 'test-fail',
    guidance: 'guidance',
  })
  assert.deepEqual(parseGateDecision('skip type-check'), { kind: 'skip', gate: 'type-check' })
  // The gate name itself is trimmed, not just the guidance.
  assert.deepEqual(parseGateDecision('retry   spaced gate  : do the thing'), {
    kind: 'retry',
    gate: 'spaced gate',
    guidance: 'do the thing',
  })
})

test('parseGateDecision returns null (not NaN, not a throw) for malformed input', () => {
  const { parseGateDecision } = loadWorkflowFunctions({ agent: noopAgent, parallel })

  assert.equal(parseGateDecision('retry lint'), null, 'missing colon must not match')
  assert.equal(parseGateDecision('gibberish decision'), null)
  assert.equal(parseGateDecision(''), null)
  assert.equal(parseGateDecision(null), null)
  assert.equal(parseGateDecision(undefined), null)
})
