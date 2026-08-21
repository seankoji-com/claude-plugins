'use strict'
const test = require('node:test')
const assert = require('node:assert/strict')
const fs = require('node:fs')
const path = require('node:path')

const SCRIPT_PATH = path.join(__dirname, '..', '..', 'plugins', 'ape', 'scripts', 'ape-forage.workflow.js')

// ape-forage.workflow.js is not a requirable module — like imps-run.workflow.js, it's
// evaluated by the Workflow tool's own runtime, which injects agent()/parallel()/phase()/
// args/log as ambient bindings and permits top-level await/return in the script body.
//
// Unlike imps-run.workflow.js, this script never factors its fan-out/dedupe/retry/
// threshold logic into named functions — that logic IS the top-level "Main" body (see
// the file's own header comment: "Real loops and real state here mean the sequencing
// ... is actual code, not prose"). So instead of slicing off a Main marker and pulling
// out named functions, wrap the ENTIRE body in an async Function constructed with those
// same ambient names as parameters (stubbed per test) and let it run end-to-end,
// returning whatever the script's own top-level `return` produces.
//
// The script also does `const fs = require('node:fs')` at module scope to check
// analyst report completeness before Synthesis. `require` is a binding local to this
// test module's CommonJS wrapper, not a global — the AsyncFunction constructor evals
// its body against the global scope, so the workflow's own `require('node:fs')` call
// would throw ReferenceError unless `require` is threaded in as a named parameter too,
// same as agent/parallel/phase/args/log. We inject a stub that intercepts 'fs' and
// 'node:fs' to hand back a fake filesystem (see fakeFs below) instead of touching the
// real one, and falls back to the real `require` for anything else.
const AsyncFunction = Object.getPrototypeOf(async function () {}).constructor

function baseArgs(overrides = {}) {
  return {
    pluginRoot: '/plugin-root',
    fingerprint: 'fingerprint text',
    focusArea: 'test coverage',
    workspaceDir: '/workspace',
    ...overrides,
  }
}

// A minimal fs stand-in keyed by absolute path -> byte size. A path with size 0 mimics
// a report file that was created but never written to; a path absent from the map
// mimics one that was never created at all (statSync throws ENOENT for both real
// reasons in production).
function fakeFs(sizesByPath = {}) {
  return {
    statSync(p) {
      if (!Object.prototype.hasOwnProperty.call(sizesByPath, p)) {
        const err = new Error(`ENOENT: no such file or directory, stat '${p}'`)
        err.code = 'ENOENT'
        throw err
      }
      return { size: sizesByPath[p] }
    },
  }
}

function runWorkflow({ agent, parallel, phase, args, log, fsStub }) {
  const source = fs.readFileSync(SCRIPT_PATH, 'utf8')
  const body = source.replace('export const meta', 'const meta')
  const factory = new AsyncFunction('agent', 'parallel', 'phase', 'args', 'log', 'require', body)
  const requireStub = (name) => (name === 'fs' || name === 'node:fs' ? fsStub || fakeFs() : require(name))
  return factory(agent, parallel, phase || (() => {}), args || baseArgs(), log || (() => {}), requireStub)
}

// Mirrors the real Workflow tool's parallel(): each thunk runs independently; one
// that throws resolves to null in the results array instead of rejecting the batch.
async function parallel(thunks) {
  const settled = await Promise.allSettled(thunks.map((fn) => fn()))
  return settled.map((s) => (s.status === 'fulfilled' ? s.value : null))
}

function candidate(fullName, overrides = {}) {
  return {
    fullName,
    url: `https://github.com/${fullName}`,
    stars: 100,
    pushedMonth: '2026-06',
    license: 'MIT',
    diskUsageMB: 10,
    rationale: 'r',
    hypothesis: 'h',
    ...overrides,
  }
}

// The ranking prompt embeds `merged` as a pretty-printed JSON block between a fixed
// marker and "\n\nRules:" — pull it back out so we can assert on the deduped set
// without guessing at internal variable names.
function extractMergedFromRankPrompt(promptText) {
  const marker = 'do not re-check that):\n'
  const start = promptText.indexOf(marker)
  const end = promptText.indexOf('\n\nRules:')
  assert.ok(start !== -1 && end !== -1, 'expected the ranking prompt template to still contain its candidates block markers')
  return JSON.parse(promptText.slice(start + marker.length, end))
}

test('discovery dedupes candidates by fullName across axes before ranking', async () => {
  const logs = []
  let rankPrompt = null

  async function agent(prompt, opts) {
    if (opts.label === 'discover:A') return { candidates: [candidate('acme/foo'), candidate('acme/bar')], tooFew: false }
    if (opts.label === 'discover:B') return { candidates: [candidate('acme/foo'), candidate('acme/baz')], tooFew: false }
    if (opts.label === 'discover:C') return { candidates: [candidate('acme/bar')], tooFew: true }
    if (opts.label === 'rank') {
      rankPrompt = prompt
      // Short-circuit right here — this test is about dedupe, not the full pipeline.
      return { selected: [], rejected: [] }
    }
    throw new Error(`unexpected agent call: ${opts.label}`)
  }

  const outcome = await runWorkflow({ agent, parallel, log: (m) => logs.push(m) })

  assert.equal(outcome.status, 'blocked', 'ranking with <2 selected should still block, confirming the pipeline reached rank')
  assert.ok(
    logs.includes('Discovery: 5 raw candidates across 3 axes -> 3 after dedupe'),
    `expected the dedupe count in the log line, got: ${JSON.stringify(logs)}`
  )
  const merged = extractMergedFromRankPrompt(rankPrompt)
  assert.deepEqual(
    merged.map((c) => c.fullName).sort(),
    ['acme/bar', 'acme/baz', 'acme/foo'],
    'acme/foo (axes A+B) and acme/bar (axes A+C) must each appear once, not twice'
  )
})

test('a failed clone batch is retried once and results are merged correctly', async () => {
  const logs = []
  const analyzeLabels = []
  let cloneCallCount = 0

  async function agent(prompt, opts) {
    if (opts.label === 'discover:A') return { candidates: [candidate('org/alpha'), candidate('org/beta')], tooFew: false }
    if (opts.label === 'discover:B') return { candidates: [candidate('org/gamma')], tooFew: false }
    if (opts.label === 'discover:C') return { candidates: [], tooFew: true }
    if (opts.label === 'rank') {
      return { selected: [candidate('org/alpha'), candidate('org/beta'), candidate('org/gamma')], rejected: [] }
    }
    if (opts.label === 'clone') {
      cloneCallCount += 1
      if (cloneCallCount === 1) return { cloned: ['org/alpha'], failed: ['org/beta', 'org/gamma'] }
      // Retry attempt: only the two that failed the first time are retried, and only
      // one of them succeeds this time.
      return { cloned: ['org/beta'], failed: ['org/gamma'] }
    }
    if (opts.label.startsWith('analyze:')) {
      analyzeLabels.push(opts.label)
      return {}
    }
    if (opts.label === 'synthesize') {
      return { recommendations: 'do the thing', nearMisses: '', stats: { reposAnalyzed: 2, techniquesSurfaced: 1 } }
    }
    throw new Error(`unexpected agent call: ${opts.label}`)
  }

  const fsStub = fakeFs({
    '/workspace/reports/org__alpha.md': 120,
    '/workspace/reports/org__beta.md': 84,
  })
  const outcome = await runWorkflow({ agent, parallel, log: (m) => logs.push(m), fsStub })

  assert.equal(cloneCallCount, 2, 'expected exactly one retry attempt (first + retry), not more')
  assert.equal(outcome.status, 'final')
  assert.ok(
    logs.includes('Clone: 2 failed on first attempt, retrying once'),
    `expected the first-attempt failure count to be logged before retrying, got: ${JSON.stringify(logs)}`
  )
  assert.ok(
    logs.includes('Clone: 2 verified, 1 failed'),
    `expected merged clone counts (first-attempt success + retry success), not just the retry attempt's own counts, got: ${JSON.stringify(logs)}`
  )
  assert.deepEqual(
    analyzeLabels.sort(),
    ['analyze:org__alpha', 'analyze:org__beta'],
    'only the merged cloned set (org/alpha from attempt 1, org/beta from the retry) should reach Analysis — org/gamma failed both attempts'
  )
})

test('blocks with reason "missing_reports" and never reaches synthesis when a report file was never written', async () => {
  const logs = []
  let synthesisCalled = false

  async function agent(prompt, opts) {
    if (opts.label === 'discover:A') return { candidates: [candidate('org/alpha'), candidate('org/beta')], tooFew: false }
    if (opts.label === 'discover:B') return { candidates: [], tooFew: true }
    if (opts.label === 'discover:C') return { candidates: [], tooFew: true }
    if (opts.label === 'rank') return { selected: [candidate('org/alpha'), candidate('org/beta')], rejected: [] }
    if (opts.label === 'clone') return { cloned: ['org/alpha', 'org/beta'], failed: [] }
    if (opts.label.startsWith('analyze:')) return {}
    if (opts.label === 'synthesize') {
      synthesisCalled = true
      return { recommendations: 'x', nearMisses: '', stats: { reposAnalyzed: 2, techniquesSurfaced: 1 } }
    }
    throw new Error(`unexpected agent call: ${opts.label}`)
  }

  // org/alpha's report exists; org/beta's was never created (absent from the map ->
  // fakeFs throws ENOENT, mirroring an analyst that returned without ever writing it).
  const fsStub = fakeFs({ '/workspace/reports/org__alpha.md': 120 })
  const outcome = await runWorkflow({ agent, parallel, log: (m) => logs.push(m), fsStub })

  assert.equal(synthesisCalled, false, 'synthesis must not run when a report is missing')
  assert.deepEqual(outcome, {
    status: 'blocked',
    reason: 'missing_reports',
    missing: ['org/beta'],
    notes: '1 of 2 analyst report(s) are missing or empty: org/beta. Synthesis requires a complete report set.',
  })
})

test('blocks with reason "missing_reports" when a report file exists but is empty', async () => {
  let synthesisCalled = false

  async function agent(prompt, opts) {
    if (opts.label === 'discover:A') return { candidates: [candidate('org/alpha'), candidate('org/beta')], tooFew: false }
    if (opts.label === 'discover:B') return { candidates: [], tooFew: true }
    if (opts.label === 'discover:C') return { candidates: [], tooFew: true }
    if (opts.label === 'rank') return { selected: [candidate('org/alpha'), candidate('org/beta')], rejected: [] }
    if (opts.label === 'clone') return { cloned: ['org/alpha', 'org/beta'], failed: [] }
    if (opts.label.startsWith('analyze:')) return {}
    if (opts.label === 'synthesize') {
      synthesisCalled = true
      return { recommendations: 'x', nearMisses: '', stats: { reposAnalyzed: 2, techniquesSurfaced: 1 } }
    }
    throw new Error(`unexpected agent call: ${opts.label}`)
  }

  const fsStub = fakeFs({
    '/workspace/reports/org__alpha.md': 120,
    '/workspace/reports/org__beta.md': 0,
  })
  const outcome = await runWorkflow({ agent, parallel, fsStub })

  assert.equal(synthesisCalled, false, 'synthesis must not run when a report is empty')
  assert.equal(outcome.status, 'blocked')
  assert.equal(outcome.reason, 'missing_reports')
  assert.deepEqual(outcome.missing, ['org/beta'])
})

test('blocks with reason "no_candidates" when discovery+dedupe yields fewer than 2 candidates', async () => {
  async function agent(prompt, opts) {
    if (opts.label === 'discover:A') return { candidates: [candidate('solo/repo')], tooFew: true }
    if (opts.label === 'discover:B') return { candidates: [], tooFew: true }
    if (opts.label === 'discover:C') return { candidates: [], tooFew: true }
    throw new Error(`unexpected agent call: ${opts.label}`)
  }

  const outcome = await runWorkflow({ agent, parallel })

  assert.deepEqual(outcome, {
    status: 'blocked',
    reason: 'no_candidates',
    notes: 'Only 1 candidate(s) survived discovery+triage across all axes.',
  })
})

test('blocks with reason "no_candidates" when ranking selects fewer than 2 candidates', async () => {
  async function agent(prompt, opts) {
    if (opts.label === 'discover:A') return { candidates: [candidate('org/a'), candidate('org/b')], tooFew: false }
    if (opts.label === 'discover:B') return { candidates: [], tooFew: true }
    if (opts.label === 'discover:C') return { candidates: [], tooFew: true }
    if (opts.label === 'rank') {
      return { selected: [candidate('org/a')], rejected: [{ fullName: 'org/b', reason: 'weaker fit' }] }
    }
    throw new Error(`unexpected agent call: ${opts.label}`)
  }

  const outcome = await runWorkflow({ agent, parallel })

  assert.deepEqual(outcome, {
    status: 'blocked',
    reason: 'no_candidates',
    notes: 'Only 1 candidate(s) survived ranking.',
  })
})

test('blocks with reason "clone_failed" when fewer than 2 repos clone successfully after one retry', async () => {
  let cloneCallCount = 0
  async function agent(prompt, opts) {
    if (opts.label === 'discover:A') return { candidates: [candidate('org/x'), candidate('org/y')], tooFew: false }
    if (opts.label === 'discover:B') return { candidates: [], tooFew: true }
    if (opts.label === 'discover:C') return { candidates: [], tooFew: true }
    if (opts.label === 'rank') {
      return { selected: [candidate('org/x'), candidate('org/y')], rejected: [] }
    }
    if (opts.label === 'clone') {
      cloneCallCount += 1
      return { cloned: [], failed: ['org/x', 'org/y'] }
    }
    throw new Error(`unexpected agent call: ${opts.label}`)
  }

  const outcome = await runWorkflow({ agent, parallel })

  assert.equal(cloneCallCount, 2, 'expected exactly one retry attempt (first + retry), not more')
  assert.deepEqual(outcome, {
    status: 'blocked',
    reason: 'clone_failed',
    failed: ['org/x', 'org/y'],
    notes: 'Fewer than 2 repos cloned successfully after one retry — check auth/rate-limit/disk space and re-run.',
  })
})
