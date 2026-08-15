'use strict'
const test = require('node:test')
const assert = require('node:assert/strict')
const fs = require('node:fs')
const os = require('node:os')
const path = require('node:path')
const { execFileSync } = require('node:child_process')

// init-workspace.sh (issue #117) — unlike ape-forage.workflow.js and
// imps-run.workflow.js, this is a real standalone script, not a Workflow-tool body, so
// it needs no AsyncFunction eval: it's exercised the same way a user's shell would run
// it, via a real subprocess against a real (throwaway) git repo. HOME is pinned to a
// disposable temp dir on every invocation so this test never touches the real
// ~/tmp/repo-research.
const SCRIPT_PATH = path.join(__dirname, '..', '..', 'plugins', 'ape', 'scripts', 'init-workspace.sh')

function mkTmp(prefix) {
  return fs.mkdtempSync(path.join(os.tmpdir(), prefix))
}

function makeRepo(basename, remoteUrl) {
  const root = mkTmp('ape-slug-repo-')
  const repoDir = path.join(root, basename)
  fs.mkdirSync(repoDir, { recursive: true })
  execFileSync('git', ['init', '-q'], { cwd: repoDir })
  if (remoteUrl) execFileSync('git', ['remote', 'add', 'origin', remoteUrl], { cwd: repoDir })
  return repoDir
}

function runInitWorkspace(repoDir, home) {
  return execFileSync('bash', [SCRIPT_PATH], { cwd: repoDir, env: { ...process.env, HOME: home } }).toString()
}

function slugOf(stdout) {
  const m = stdout.match(/^slug=(.*)$/m)
  assert.ok(m, `expected a "slug=" line in output:\n${stdout}`)
  return m[1]
}

test('init-workspace.sh disambiguates two repos that share a basename but have different remotes', () => {
  const repoA = makeRepo('widgets', 'https://github.com/acme/widgets.git')
  const repoB = makeRepo('widgets', 'git@github.com:other-org/widgets.git')
  const homeA = mkTmp('ape-slug-home-')
  const homeB = mkTmp('ape-slug-home-')
  try {
    const slugA = slugOf(runInitWorkspace(repoA, homeA))
    const slugB = slugOf(runInitWorkspace(repoB, homeB))
    assert.notEqual(slugA, slugB, 'two identically-named repos with different remotes must not collide on slug')
    assert.equal(slugA, 'acme_widgets__widgets')
    assert.equal(slugB, 'other-org_widgets__widgets')
  } finally {
    fs.rmSync(path.dirname(repoA), { recursive: true, force: true })
    fs.rmSync(path.dirname(repoB), { recursive: true, force: true })
    fs.rmSync(homeA, { recursive: true, force: true })
    fs.rmSync(homeB, { recursive: true, force: true })
  }
})

test('init-workspace.sh falls back to the bare basename when there is no remote origin', () => {
  const repoDir = makeRepo('no-remote-repo', null)
  const home = mkTmp('ape-slug-home-')
  try {
    assert.equal(slugOf(runInitWorkspace(repoDir, home)), 'no-remote-repo')
  } finally {
    fs.rmSync(path.dirname(repoDir), { recursive: true, force: true })
    fs.rmSync(home, { recursive: true, force: true })
  }
})

test('init-workspace.sh migrates an old basename-only workspace to the disambiguated slug on first run', () => {
  const basename = 'legacy-repo'
  const repoDir = makeRepo(basename, 'https://github.com/acme/legacy-repo.git')
  const home = mkTmp('ape-slug-home-')
  try {
    // Seed a workspace as a pre-disambiguation run would have left it, keyed by the
    // bare basename alone.
    const oldWorkspace = path.join(home, 'tmp', 'repo-research', basename)
    fs.mkdirSync(oldWorkspace, { recursive: true })
    fs.writeFileSync(path.join(oldWorkspace, 'fingerprint.md'), '# old fingerprint', 'utf8')

    const slug = slugOf(runInitWorkspace(repoDir, home))
    assert.equal(slug, 'acme_legacy-repo__legacy-repo')
    const newWorkspace = path.join(home, 'tmp', 'repo-research', slug)
    assert.ok(
      fs.existsSync(path.join(newWorkspace, 'fingerprint.md')),
      'expected the old workspace contents to be migrated to the new slug path',
    )
    assert.ok(!fs.existsSync(oldWorkspace), 'expected the old basename-only workspace to be moved, not duplicated')
  } finally {
    fs.rmSync(path.dirname(repoDir), { recursive: true, force: true })
    fs.rmSync(home, { recursive: true, force: true })
  }
})
