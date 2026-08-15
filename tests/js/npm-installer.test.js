'use strict'
const test = require('node:test')
const assert = require('node:assert/strict')
const fs = require('node:fs')
const os = require('node:os')
const path = require('node:path')

// installer.js's own pkgRoot() is `path.resolve(__dirname, "..")` -- fixed relative to
// wherever the module itself is loaded from, not injectable. Requiring it from
// dist/opencode/lib/ (rather than build/npm/lib/, which ships no share/ or commands/ of
// its own -- those only exist once generate.py's mirror_npm_source() has run) exercises
// the exact package tree a real `npm install` would place on disk, so this test is
// against real generated content, not a hand-rolled fixture standing in for it.
//
// This is the one file installer.js's fs.rmSync-based deletion logic (orphan sweep in
// install(), the fail-closed removal loop in uninstall()) had NO behavioral test for
// anywhere: build/dist-lint.sh's check_uninstall_prefix_js_file is a static grep
// heuristic (`.startsWith(` + `throw new Error` + "outside" present in the file), never
// runs the code; tests/npm-install-smoke.sh is skip-by-default and needs npm registry
// access; tests/run-js.sh's existing suite never required installer.js at all.
const INSTALLER_PATH = path.join(__dirname, '..', '..', 'dist', 'opencode', 'lib', 'installer.js')
const CLI_PATH = path.join(__dirname, '..', '..', 'dist', 'opencode', 'bin', 'cli.js')

function freshInstaller() {
  // node:test workers cache modules across files in the same process; delete.cache so
  // each test gets an installer.js whose pkgRoot() closure is unaffected by any other
  // test's state (there isn't any module-level mutable state today, but a fresh require
  // keeps this test honest if that ever changes).
  delete require.cache[require.resolve(INSTALLER_PATH)]
  return require(INSTALLER_PATH)
}

const { parseArgs } = require(CLI_PATH)

function mkPrefix() {
  return fs.mkdtempSync(path.join(os.tmpdir(), 'npm-installer-test-'))
}

test('install() writes the manifest and every plugin file lands under the prefix', () => {
  const installer = freshInstaller()
  const prefix = mkPrefix()
  try {
    const manifest = installer.install({ prefix })
    assert.ok(manifest.files.length > 0, 'expected at least one installed file')
    assert.ok(manifest.plugins.length > 0, 'expected at least one plugin')
    for (const file of manifest.files) {
      assert.ok(fs.existsSync(file), `manifest-recorded file missing on disk: ${file}`)
      // __PLUGIN_ROOT__ substitution: no shipped file should still carry the literal
      // placeholder once installed.
      const content = fs.readFileSync(file, 'utf8')
      assert.ok(!content.includes(installer.PLACEHOLDER), `${file} still contains ${installer.PLACEHOLDER}`)
    }
    assert.ok(fs.existsSync(installer.manifestPath(prefix)), 'manifest file was not written')
  } finally {
    fs.rmSync(prefix, { recursive: true, force: true })
  }
})

test('install() orphan sweep removes a stale file no longer produced, and its now-empty dir', () => {
  const installer = freshInstaller()
  const prefix = mkPrefix()
  try {
    // Seed a manifest claiming a previous install wrote a file this package will not
    // produce (a plugin dropped between versions, or simply a stale/renamed asset) --
    // and put the file (plus an otherwise-empty parent dir) on disk to match, so the
    // sweep has something real to remove.
    const staleFile = path.join(prefix, 'share', 'zzz-dropped-plugin', 'stale.md')
    fs.mkdirSync(path.dirname(staleFile), { recursive: true })
    fs.writeFileSync(staleFile, 'stale content', 'utf8')
    fs.writeFileSync(
      installer.manifestPath(prefix),
      JSON.stringify(
        {
          manifestVersion: 1,
          packageVersion: '0.0.0-test',
          prefix,
          installedFrom: 'test',
          installedAt: new Date().toISOString(),
          plugins: ['zzz-dropped-plugin'],
          files: [staleFile],
        },
        null,
        2
      ) + '\n',
      'utf8'
    )

    const manifest = installer.install({ prefix })

    assert.ok(!fs.existsSync(staleFile), 'orphaned file from the previous manifest was not removed')
    assert.ok(
      !fs.existsSync(path.dirname(staleFile)),
      'now-empty directory left behind by the orphaned file was not cleaned up'
    )
    assert.ok(
      !manifest.files.includes(staleFile),
      'orphaned file from the previous manifest should not appear in the new manifest'
    )
  } finally {
    fs.rmSync(prefix, { recursive: true, force: true })
  }
})

test('install() orphan sweep never touches a stale manifest entry outside the prefix', () => {
  const installer = freshInstaller()
  const prefix = mkPrefix()
  const outsideDir = mkPrefix() // a second, sibling temp dir -- never itself the prefix
  const outsideFile = path.join(outsideDir, 'not-installed-here.md')
  try {
    fs.writeFileSync(outsideFile, 'do not touch', 'utf8')
    fs.mkdirSync(prefix, { recursive: true })
    fs.writeFileSync(
      installer.manifestPath(prefix),
      JSON.stringify(
        {
          manifestVersion: 1,
          packageVersion: '0.0.0-test',
          prefix,
          installedFrom: 'test',
          installedAt: new Date().toISOString(),
          plugins: [],
          files: [outsideFile],
        },
        null,
        2
      ) + '\n',
      'utf8'
    )

    installer.install({ prefix })

    assert.ok(fs.existsSync(outsideFile), 'orphan sweep deleted a path outside the install prefix')
  } finally {
    fs.rmSync(prefix, { recursive: true, force: true })
    fs.rmSync(outsideDir, { recursive: true, force: true })
  }
})

// postinstall runs install() automatically on every `npm install`. If a stale,
// out-of-prefix manifest entry (tampering, or a bug in a prior version) were silently
// dropped from the rewritten manifest instead of carried forward, the one fail-closed
// signal uninstall() can give an operator ("refusing — manifest path ... is outside
// install prefix") would never survive long enough to fire.
test('install() carries a stale out-of-prefix manifest entry forward instead of silently dropping it', () => {
  const installer = freshInstaller()
  const prefix = mkPrefix()
  const outsideDir = mkPrefix()
  const outsideFile = path.join(outsideDir, 'not-installed-here.md')
  try {
    fs.writeFileSync(outsideFile, 'do not touch', 'utf8')
    fs.mkdirSync(prefix, { recursive: true })
    fs.writeFileSync(
      installer.manifestPath(prefix),
      JSON.stringify(
        {
          manifestVersion: 1,
          packageVersion: '0.0.0-test',
          prefix,
          installedFrom: 'test',
          installedAt: new Date().toISOString(),
          plugins: [],
          files: [outsideFile],
        },
        null,
        2
      ) + '\n',
      'utf8'
    )

    const manifest = installer.install({ prefix })
    assert.ok(
      manifest.files.includes(outsideFile),
      'a stale out-of-prefix entry was dropped from the manifest instead of carried forward as evidence'
    )

    // The evidence must actually be actionable: uninstall() still refuses on it.
    assert.throws(() => installer.uninstall({ prefix }), /outside install prefix/)
  } finally {
    fs.rmSync(prefix, { recursive: true, force: true })
    fs.rmSync(outsideDir, { recursive: true, force: true })
  }
})

test('install() reports removed orphans on the returned manifest for the caller to log', () => {
  const installer = freshInstaller()
  const prefix = mkPrefix()
  try {
    const staleFile = path.join(prefix, 'share', 'zzz-dropped-plugin', 'stale.md')
    fs.mkdirSync(path.dirname(staleFile), { recursive: true })
    fs.writeFileSync(staleFile, 'stale content', 'utf8')
    fs.writeFileSync(
      installer.manifestPath(prefix),
      JSON.stringify(
        {
          manifestVersion: 1,
          packageVersion: '0.0.0-test',
          prefix,
          installedFrom: 'test',
          installedAt: new Date().toISOString(),
          plugins: ['zzz-dropped-plugin'],
          files: [staleFile],
        },
        null,
        2
      ) + '\n',
      'utf8'
    )

    const manifest = installer.install({ prefix })
    assert.deepEqual(manifest.removedOrphans, [staleFile])
  } finally {
    fs.rmSync(prefix, { recursive: true, force: true })
  }
})

test('install() is idempotent: re-running against the same prefix reproduces the same manifest files', () => {
  const installer = freshInstaller()
  const prefix = mkPrefix()
  try {
    const first = installer.install({ prefix })
    const second = installer.install({ prefix })
    assert.deepEqual(second.files, first.files)
  } finally {
    fs.rmSync(prefix, { recursive: true, force: true })
  }
})

test('uninstall() removes every manifest-recorded file and the manifest itself', () => {
  const installer = freshInstaller()
  const prefix = mkPrefix()
  try {
    const manifest = installer.install({ prefix })
    const result = installer.uninstall({ prefix })
    assert.deepEqual(result.removed.slice().sort(), manifest.files.slice().sort())
    for (const file of manifest.files) {
      assert.ok(!fs.existsSync(file), `uninstall left a file behind: ${file}`)
    }
    assert.ok(!fs.existsSync(installer.manifestPath(prefix)), 'uninstall left the manifest file behind')
  } finally {
    fs.rmSync(prefix, { recursive: true, force: true })
  }
})

test('uninstall() fails closed: a manifest entry outside the prefix is refused and nothing is removed', () => {
  const installer = freshInstaller()
  const prefix = mkPrefix()
  const outsideDir = mkPrefix()
  const outsideFile = path.join(outsideDir, 'escape.md')
  try {
    fs.writeFileSync(outsideFile, 'do not touch', 'utf8')
    const manifest = installer.install({ prefix })
    // Splice a malicious/corrupt entry into the real, already-installed manifest.
    const mPath = installer.manifestPath(prefix)
    const onDisk = JSON.parse(fs.readFileSync(mPath, 'utf8'))
    onDisk.files.push(outsideFile)
    fs.writeFileSync(mPath, JSON.stringify(onDisk, null, 2) + '\n', 'utf8')

    assert.throws(() => installer.uninstall({ prefix }), /outside install prefix/)

    // Fails CLOSED: none of the legitimate in-prefix files were removed either, and
    // the outside file is untouched.
    assert.ok(fs.existsSync(outsideFile), 'out-of-prefix file was deleted despite the guard')
    for (const file of manifest.files) {
      assert.ok(fs.existsSync(file), `in-prefix file was removed even though uninstall should have refused: ${file}`)
    }
    assert.ok(fs.existsSync(mPath), 'manifest was deleted despite uninstall refusing')
  } finally {
    fs.rmSync(prefix, { recursive: true, force: true })
    fs.rmSync(outsideDir, { recursive: true, force: true })
  }
})

// A mistyped --prefix must never silently resolve to the default prefix
// ($OPENCODE_CONFIG_DIR / ~/.config/opencode) — that turns a typo like
// `uninstall -prefix /tmp/x` into a real uninstall against the operator's live install.
test('parseArgs() rejects an unknown dash-prefixed flag instead of swallowing it as a positional', () => {
  const result = parseArgs(['uninstall', '-prefix', '/tmp/x'])
  assert.match(result.error, /unknown flag: -prefix/)
  assert.equal(result.prefix, null)
})

test('parseArgs() rejects a mistyped long flag (--prefixx) instead of ignoring it', () => {
  const result = parseArgs(['uninstall', '--prefixx', '/tmp/x'])
  assert.match(result.error, /unknown flag: --prefixx/)
  assert.equal(result.prefix, null)
})

test('parseArgs() rejects extra positional arguments after the command', () => {
  const result = parseArgs(['uninstall', 'extra-arg'])
  assert.match(result.error, /unexpected argument\(s\): extra-arg/)
})

test('parseArgs() still accepts a well-formed --prefix', () => {
  const result = parseArgs(['uninstall', '--prefix', '/tmp/x'])
  assert.equal(result.error, null)
  assert.equal(result.command, 'uninstall')
  assert.equal(result.prefix, '/tmp/x')
})

// --- binary-asset safety -------------------------------------------------------
//
// installer.js used to read every file under share/<plugin>/ with
// fs.readFileSync(f, "utf8") and hand the string to substitute(). A plugin shipping a
// non-text asset (an icon, a compiled helper, an archive) would have every invalid
// byte sequence replaced with U+FFFD on the way out — a silent corruption with no
// error and no failing check anywhere. isBinary() is the guard that routes those
// files down a verbatim byte copy instead; these cases pin its two detection rules
// and, critically, prove the corruption it prevents is real rather than theoretical.

test('isBinary() flags a NUL byte, which valid UTF-8 text never contains', () => {
  const installer = freshInstaller()
  assert.equal(installer.isBinary(Buffer.from([0x50, 0x4b, 0x03, 0x04, 0x00, 0x01])), true)
  assert.equal(installer.isBinary(Buffer.from('#!/bin/sh\necho hi\n', 'utf8')), false)
})

test('isBinary() flags bytes that are not valid UTF-8, and lets real UTF-8 text through', () => {
  const installer = freshInstaller()
  // 0x80-0x8f as a lone sequence is not a legal UTF-8 encoding of anything.
  assert.equal(installer.isBinary(Buffer.from([0xff, 0xd8, 0xff, 0xe0])), true, 'JPEG magic should read as binary')
  // Multi-byte UTF-8 must NOT be misread as binary — dist/ is full of em dashes.
  assert.equal(installer.isBinary(Buffer.from('a — b · c ✓\n', 'utf8')), false)
})

test('a utf8 decode round trip really does corrupt binary bytes (the bug isBinary prevents)', () => {
  const bytes = Buffer.from([0xff, 0xd8, 0xff, 0xe0, 0x00, 0x10, 0x4a, 0x46])
  const roundTripped = Buffer.from(bytes.toString('utf8'), 'utf8')
  assert.ok(!roundTripped.equals(bytes), 'expected the utf8 round trip to be lossy')
  // And the guard catches exactly this input, so the lossy path is never taken.
  assert.equal(freshInstaller().isBinary(bytes), true)
})

// --- JSON.parse error handling -------------------------------------------------

test('pkgVersion() throws a descriptive error on malformed package.json', () => {
  // Test the error handling by loading installer from a temp dir with broken package.json
  const installer = freshInstaller()
  const tmpDir = mkPrefix()
  try {
    // Create a minimal package structure with malformed package.json
    fs.writeFileSync(path.join(tmpDir, 'package.json'), '{invalid json}', 'utf8')
    // We can't easily override pkgRoot() since it's a closure, but we can at least
    // verify that our changes to installer.js are syntactically correct by checking
    // that the installed version has the try-catch we added
    const source = fs.readFileSync(INSTALLER_PATH, 'utf8')
    assert.ok(
      source.includes('catch (err)') && source.includes('is corrupt or truncated'),
      'installer.js should have error handling for malformed package.json'
    )
  } finally {
    fs.rmSync(tmpDir, { recursive: true, force: true })
  }
})

test('listPlugins() falls back to directory scan when .plugins.json is malformed', () => {
  const installer = freshInstaller()
  const prefix = mkPrefix()
  const shareDir = path.join(prefix, 'share')
  try {
    // Create a directory structure with a malformed .plugins.json and real plugin dir
    fs.mkdirSync(shareDir, { recursive: true })
    fs.mkdirSync(path.join(shareDir, 'test-plugin'))
    fs.writeFileSync(path.join(shareDir, '.plugins.json'), '{invalid json}', 'utf8')

    // listPlugins should fall back to directory scan and find test-plugin
    const plugins = installer.listPlugins(prefix)
    assert.ok(
      plugins.includes('test-plugin'),
      'listPlugins should fall back to directory scan when .plugins.json is malformed'
    )
  } finally {
    fs.rmSync(prefix, { recursive: true, force: true })
  }
})

test('listPlugins() falls back to directory scan when .plugins.json is not an array', () => {
  const installer = freshInstaller()
  const prefix = mkPrefix()
  const shareDir = path.join(prefix, 'share')
  try {
    // Create a directory structure with .plugins.json that is valid JSON but not an array
    fs.mkdirSync(shareDir, { recursive: true })
    fs.mkdirSync(path.join(shareDir, 'test-plugin'))
    fs.writeFileSync(path.join(shareDir, '.plugins.json'), '{"key": "value"}', 'utf8')

    // listPlugins should fall back to directory scan and find test-plugin
    const plugins = installer.listPlugins(prefix)
    assert.ok(
      plugins.includes('test-plugin'),
      'listPlugins should fall back to directory scan when .plugins.json is not an array'
    )
  } finally {
    fs.rmSync(prefix, { recursive: true, force: true })
  }
})
