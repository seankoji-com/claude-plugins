"use strict";
//
// lib/installer.js — shared install/uninstall/doctor logic for the OpenCode npm
// channel. Used by both bin/cli.js (the `install|uninstall|doctor` subcommands) and
// postinstall.js (which just calls install()).
//
// The package this file ships inside of (its own directory tree, one level up from
// lib/) already carries the generated commands/*.md and share/<plugin>/** assets —
// build/generate.py's mirror_npm_source() copies this package's source verbatim into
// dist/opencode/, alongside the plugin output that lands in the same tree. So "the
// package root" and "the generated dist/opencode root" are the same directory once
// installed: node_modules/<pkg>/{package.json,bin/,lib/,commands/,share/}.
//
// __PLUGIN_ROOT__ resolution (contract: docs/plans/cross-platform-compat.md,
// "Machine paths — the invariant, reconciled"): every file under commands/ and
// share/<plugin>/ ships with the literal placeholder __PLUGIN_ROOT__. At install time
// we copy those files into the target prefix and replace the placeholder — for a
// command file, with the absolute path of *its own* plugin's installed share dir; for
// a file already under share/<plugin>/, with that same plugin's installed share dir
// (so a script can reference a sibling script). Because every run starts from the
// pristine templates shipped in the package (never from a previously-installed copy),
// re-running is idempotent: same prefix + same package contents => same output.
//

const fs = require("fs");
const os = require("os");
const path = require("path");

const MANIFEST_NAME = ".seankoji-plugins-manifest.json";
const PLACEHOLDER = "__PLUGIN_ROOT__";

function pkgRoot() {
  return path.resolve(__dirname, "..");
}

function pkgVersion() {
  const raw = fs.readFileSync(path.join(pkgRoot(), "package.json"), "utf8");
  return JSON.parse(raw).version;
}

function resolvePrefix(explicit) {
  return path.resolve(
    explicit || process.env.OPENCODE_CONFIG_DIR || path.join(os.homedir(), ".config", "opencode")
  );
}

function manifestPath(prefix) {
  return path.join(prefix, MANIFEST_NAME);
}

// The plugin set cannot be derived from share/<plugin> dirs alone: a plugin that ships
// no assets (e.g. ape — build/overrides/ape/port.json sets asset_dirs: []) never gets a
// share/ape/ directory, even though it does ship commands/ape-*.md. generate.py writes
// share/.plugins.json with the full generated-for-opencode plugin set for exactly this
// reason; fall back to the directory scan only if an older/hand-built package lacks it.
function listPlugins(root) {
  const manifestFile = path.join(root, "share", ".plugins.json");
  if (fs.existsSync(manifestFile)) {
    const names = JSON.parse(fs.readFileSync(manifestFile, "utf8"));
    if (Array.isArray(names)) return [...names].sort();
  }
  const shareDir = path.join(root, "share");
  if (!fs.existsSync(shareDir)) return [];
  return fs
    .readdirSync(shareDir, { withFileTypes: true })
    .filter((entry) => entry.isDirectory())
    .map((entry) => entry.name)
    .sort();
}

// Longest-name-first so "imps" doesn't shadow a hypothetical "imps-extra" plugin.
function pluginForCommandFile(filename, plugins) {
  const base = filename.replace(/\.md$/, "");
  const candidates = [...plugins].sort((a, b) => b.length - a.length);
  for (const plugin of candidates) {
    if (base === plugin || base.startsWith(plugin + "-")) return plugin;
  }
  return null;
}

function substitute(content, pluginShareAbsPath) {
  // Literal split/join, not a regex — the placeholder carries no regex metacharacters
  // that matter here, and split/join sidesteps any accidental $-escape surprises in the
  // absolute path used as the replacement.
  return content.split(PLACEHOLDER).join(pluginShareAbsPath);
}

// Read a file's mode and contents through a SINGLE file descriptor, so the two
// operations cannot resolve to different inodes. statSync-then-readFileSync on a
// path is a genuine TOCTOU window (CodeQL js/file-system-race): between the two
// calls the path can be replaced — e.g. swapped for a symlink to something
// outside the package — and we would then copy the wrong bytes while carrying
// the mode we sampled from the original. Opening once and using fstat/read on
// the fd closes that window: both refer to the object we actually opened.
//
// Returns raw bytes, NOT a utf8 string: a decode-then-write round trip replaces any
// byte sequence that isn't valid UTF-8 with U+FFFD, silently corrupting a binary asset
// (an image, a compiled helper, an archive) that a plugin ships under its share/ dir.
// Callers decide whether to decode — see isBinary below.
function readFileAndMode(srcFile) {
  const fd = fs.openSync(srcFile, "r");
  try {
    return { mode: fs.fstatSync(fd).mode, bytes: fs.readFileSync(fd) };
  } finally {
    fs.closeSync(fd);
  }
}

// A NUL byte never appears in valid UTF-8 text, and a lossy decode/encode round trip
// that doesn't reproduce the input means the bytes weren't valid UTF-8 either. Both
// checks together cover the asset kinds a plugin realistically ships without needing a
// content-type table. Binary files are copied through byte-for-byte with no
// __PLUGIN_ROOT__ substitution — the placeholder is a text-file convention.
function isBinary(bytes) {
  if (bytes.includes(0)) return true;
  return !Buffer.from(bytes.toString("utf8"), "utf8").equals(bytes);
}

function walkFiles(dir) {
  const out = [];
  for (const entry of fs.readdirSync(dir, { withFileTypes: true }).sort((a, b) => (a.name < b.name ? -1 : 1))) {
    const full = path.join(dir, entry.name);
    if (entry.isDirectory()) {
      out.push(...walkFiles(full));
    } else if (entry.isFile()) {
      out.push(full);
    }
  }
  return out;
}

// `content` is either a string (text asset, post-substitution) or a Buffer (binary
// asset, copied verbatim). Passing an explicit encoding alongside a Buffer would be
// ignored by fs, but branching keeps the intent legible and keeps the text path's
// encoding pinned rather than left to the platform default.
function writeFileWithMode(destPath, content, mode) {
  fs.mkdirSync(path.dirname(destPath), { recursive: true });
  if (Buffer.isBuffer(content)) {
    fs.writeFileSync(destPath, content);
  } else {
    fs.writeFileSync(destPath, content, { encoding: "utf8" });
  }
  fs.chmodSync(destPath, mode);
}

// `prefixResolved` is `path.resolve(prefix) + path.sep`, computed once by the caller.
function withinPrefix(file, prefixResolved) {
  const resolved = path.resolve(file);
  return (resolved + path.sep).startsWith(prefixResolved);
}

// Best-effort cleanup of now-empty directories left behind by removing `files`,
// deepest first, never climbing past `prefix`. Shared by uninstall() (removing
// everything) and install() (removing only this run's orphans) so the bounded-climb
// guard exists in exactly one place.
function removeEmptyDirsUpward(files, prefixResolved, prefix) {
  const dirs = [...new Set(files.map((f) => path.dirname(path.resolve(f))))].sort(
    (a, b) => b.length - a.length
  );
  for (const dir of dirs) {
    let cur = dir;
    while ((cur + path.sep).startsWith(prefixResolved) && cur !== prefix) {
      try {
        fs.rmdirSync(cur);
      } catch {
        break; // not empty (or already gone) — stop climbing this branch
      }
      cur = path.dirname(cur);
    }
  }
}

// Wraps JSON.parse with a diagnostic error naming the file and the remedy, instead of a
// raw SyntaxError with a line/column an end user can't act on. writeManifestFile below is
// atomic, but a manifest written before that guarantee existed (or corrupted by something
// outside this tool) still needs a legible failure here rather than a crash.
function readJsonManifest(mPath) {
  const raw = fs.readFileSync(mPath, "utf8");
  try {
    return JSON.parse(raw);
  } catch (err) {
    const corrupt = new Error(
      `manifest at ${mPath} is corrupt or truncated (${err.message}). This can happen if a ` +
        `prior install crashed mid-write (e.g. disk full). Remove it and re-run install to ` +
        `recover: rm ${JSON.stringify(mPath)} && claude-plugins-opencode install`
    );
    corrupt.code = "EMANIFESTCORRUPT";
    corrupt.manifestPath = mPath;
    throw corrupt;
  }
}

function readManifestIfPresent(mPath) {
  if (!fs.existsSync(mPath)) return null;
  try {
    return readJsonManifest(mPath);
  } catch (err) {
    if (err.code !== "EMANIFESTCORRUPT") throw err;
    // install() must not get stuck in the same SyntaxError doctor()'s "run install again"
    // advice would otherwise loop on forever: treat a corrupt manifest the same way as no
    // manifest at all (a fresh install), after telling the operator why.
    process.stderr.write(`warning: ${err.message}\n`);
    return null;
  }
}

function writeManifestFile(mPath, fields) {
  // Atomic on POSIX: write to a sibling temp file, then rename into place. rename(2)
  // within the same directory/filesystem cannot leave a partially-written manifest on
  // disk even if the process is killed or the disk fills up between the two calls —
  // unlike the plain writeFileSync this replaces, which can be interrupted mid-write and
  // leave truncated (unparseable) JSON for the next install/doctor/uninstall to trip on.
  const tmp = `${mPath}.${process.pid}.${Date.now()}.tmp`;
  fs.writeFileSync(tmp, JSON.stringify(fields, null, 2) + "\n", "utf8");
  fs.renameSync(tmp, mPath);
}

function install(opts) {
  opts = opts || {};
  const root = pkgRoot();
  const prefix = resolvePrefix(opts.prefix);
  const plugins = listPlugins(root);
  const written = [];

  const mPath = manifestPath(prefix);
  const prevManifest = readManifestIfPresent(mPath);
  const prevFiles = Array.isArray(prevManifest && prevManifest.files) ? prevManifest.files : [];

  fs.mkdirSync(prefix, { recursive: true });
  const mid = {
    manifestVersion: 1,
    packageVersion: pkgVersion(),
    prefix,
    installedFrom: root,
    installedAt: new Date().toISOString(),
    state: "installing",
    plugins,
    files: prevFiles,
  };
  // Marked mid-install BEFORE any file is copied. If install() throws partway through
  // (disk full, a permission error, a malformed source file), this state survives on
  // disk and doctor() can report "install crashed mid-run" instead of its only other
  // hypothesis for a stale/absent manifest — "--ignore-scripts skipped postinstall" —
  // which looks identical otherwise. Carries the previous file list forward so a
  // crash here doesn't itself look like an uninstall to doctor().
  writeManifestFile(mPath, mid);

  // Flushed after every plugin's files (and again after commands/) with
  // files: union(prevFiles, written-so-far) — not just `written`, and not only at the
  // very end. A crash between two flushes still leaves every file actually on disk (old
  // ones not yet superseded, plus everything copied so far this run) recorded
  // somewhere: without this, a crash after copying new files but before the final
  // fs.writeFileSync below left those new files on disk with NO manifest entry at all —
  // untracked by any future uninstall or orphan sweep. install-agy.sh's equivalent loop
  // records each plugin's path the same way, as soon as it lands on disk.
  const flushProgress = () => {
    mid.files = Array.from(new Set([...prevFiles, ...written])).sort();
    mid.installedAt = new Date().toISOString();
    writeManifestFile(mPath, mid);
  };

  for (const plugin of plugins) {
    const srcShare = path.join(root, "share", plugin);
    if (!fs.existsSync(srcShare)) continue; // plugin ships no assets (e.g. ape) — nothing to copy
    const destShare = path.join(prefix, "share", plugin);
    for (const srcFile of walkFiles(srcShare)) {
      const rel = path.relative(srcShare, srcFile);
      const destFile = path.join(destShare, rel);
      const { mode, bytes } = readFileAndMode(srcFile);
      // Binary assets copy through verbatim; only text carries __PLUGIN_ROOT__.
      const content = isBinary(bytes) ? bytes : substitute(bytes.toString("utf8"), destShare);
      writeFileWithMode(destFile, content, mode);
      written.push(destFile);
    }
    flushProgress();
  }

  const srcCommands = path.join(root, "commands");
  if (fs.existsSync(srcCommands)) {
    for (const srcFile of walkFiles(srcCommands).filter((f) => f.endsWith(".md"))) {
      const filename = path.basename(srcFile);
      const plugin = pluginForCommandFile(filename, plugins);
      if (!plugin) {
        throw new Error(
          `install: ${filename} does not match any known plugin — ` +
            "the generated package is inconsistent (regenerate dist/opencode)"
        );
      }
      const destShare = path.join(prefix, "share", plugin);
      const destFile = path.join(prefix, "commands", filename);
      // Command files are .md by the filter above, so always text — decoded
      // unconditionally rather than probed, since a binary .md is a packaging bug.
      const { mode, bytes } = readFileAndMode(srcFile);
      const content = substitute(bytes.toString("utf8"), destShare);
      writeFileWithMode(destFile, content, mode);
      written.push(destFile);
    }
    flushProgress();
  }

  written.sort();

  // Orphan cleanup: an update must leave exactly what the current package produces,
  // not the union of this install and every install before it. Anything the previous
  // manifest recorded that this run did not rewrite — a renamed/dropped command, or a
  // plugin that lost its last asset — is removed now, bounded to the prefix by the
  // same guard uninstall() uses, so a future uninstall never has to know about it.
  const prefixResolved = path.resolve(prefix) + path.sep;
  const writtenSet = new Set(written);
  const stale = prevFiles.filter((f) => !writtenSet.has(f));
  const orphaned = stale.filter((f) => withinPrefix(f, prefixResolved));
  // A stale entry that does NOT resolve inside the prefix is exactly what uninstall()
  // treats as fatal tampering ("refusing — manifest path ... is outside install
  // prefix"). Dropping it here (by simply not carrying it into `files` below) would
  // erase that evidence on every `npm install` — postinstall runs install()
  // automatically, so the fail-closed signal would never survive long enough for an
  // operator to see it via uninstall(). Keep it in the manifest instead of deleting it
  // or silently forgetting it; the file itself is left untouched either way.
  const outOfPrefixStale = stale.filter((f) => !withinPrefix(f, prefixResolved));
  for (const file of orphaned) {
    fs.rmSync(file, { force: true });
  }
  if (orphaned.length > 0) {
    removeEmptyDirsUpward(orphaned, prefixResolved, prefix);
  }

  const manifest = {
    manifestVersion: 1,
    packageVersion: pkgVersion(),
    prefix,
    installedFrom: root,
    installedAt: new Date().toISOString(),
    plugins,
    files: [...written, ...outOfPrefixStale].sort(),
  };
  writeManifestFile(mPath, manifest);
  // Not persisted in the manifest file itself (it's install()'s own run summary, not
  // install state) — cli.js/postinstall.js use this to print what changed, instead of
  // an update silently deleting files with no log line anywhere.
  manifest.removedOrphans = orphaned;

  return manifest;
}

// Fails closed: every path in the manifest is checked against the resolved prefix
// BEFORE anything is deleted. If any path escapes the prefix, nothing is removed and
// the function throws.
function uninstall(opts) {
  opts = opts || {};
  const prefix = resolvePrefix(opts.prefix);
  const mPath = manifestPath(prefix);
  if (!fs.existsSync(mPath)) {
    return { removed: [], note: `nothing to uninstall — no manifest at ${mPath}` };
  }
  const manifest = readJsonManifest(mPath);
  const files = Array.isArray(manifest.files) ? manifest.files : [];

  // The climb below resolves each dirname and reuses the same trailing-separator
  // boundary test as this guard, rather than a bare string startsWith on the raw
  // manifest value. Without that, a manifest entry like
  // "<prefix>/../opencode/commands/x.md" passes this guard (it *resolves* inside the
  // prefix) while its unresolved dirname climbs to "<prefix>/.." — the prefix's
  // parent. That escape is not currently reachable, but only by accident: the
  // manifest file itself still sits in the prefix during the climb, so rmdir hits
  // ENOTEMPTY and breaks. Moving the `fs.rmSync(mPath)` below up above the climb — an
  // innocuous-looking reorder — would make it live. removeEmptyDirsUpward's own guard
  // is what keeps the fail-closed property from depending on that ordering.
  const prefixResolved = path.resolve(prefix) + path.sep;
  for (const file of files) {
    if (!withinPrefix(file, prefixResolved)) {
      throw new Error(
        `uninstall: refusing — manifest path ${JSON.stringify(file)} is outside install prefix ${prefix}`
      );
    }
  }

  const removed = [];
  for (const file of files) {
    fs.rmSync(file, { force: true });
    removed.push(file);
  }

  removeEmptyDirsUpward(files, prefixResolved, prefix);

  fs.rmSync(mPath, { force: true });
  return { removed, note: `removed ${removed.length} file(s) from ${prefix}` };
}

function doctor(opts) {
  opts = opts || {};
  const root = pkgRoot();
  const prefix = resolvePrefix(opts.prefix);
  const mPath = manifestPath(prefix);
  const report = {
    packageVersion: pkgVersion(),
    packageRoot: root,
    prefix,
    manifestPath: mPath,
    installed: false,
    ok: false,
    plugins: listPlugins(root),
    missingFiles: [],
    problems: [],
  };

  if (report.plugins.length === 0) {
    report.problems.push("this package ships no share/<plugin> directories — build/generate.py did not run before packing");
  }

  if (!fs.existsSync(mPath)) {
    report.problems.push(
      `not installed: no manifest at ${mPath} — postinstall likely did not run (e.g. --ignore-scripts). Run \`claude-plugins-opencode install\`.`
    );
    return report;
  }

  report.installed = true;
  let manifest;
  try {
    manifest = readJsonManifest(mPath);
  } catch (err) {
    // doctor()'s entire purpose is diagnosis without throwing — report the corrupt
    // manifest as a problem (with the same recovery instructions) rather than crashing.
    report.problems.push(err.message);
    return report;
  }
  if (manifest.state === "installing") {
    report.problems.push(
      `install appears to have crashed mid-run (manifest state is still "installing") — ` +
        "run `claude-plugins-opencode install` again to finish it"
    );
  }
  const files = Array.isArray(manifest.files) ? manifest.files : [];
  for (const file of files) {
    if (!fs.existsSync(file)) report.missingFiles.push(file);
  }
  if (report.missingFiles.length > 0) {
    report.problems.push(`${report.missingFiles.length} manifest-tracked file(s) missing on disk`);
  }
  if (manifest.packageVersion !== report.packageVersion) {
    report.problems.push(
      `manifest was written by package version ${manifest.packageVersion}, running package is ${report.packageVersion} — run install to refresh`
    );
  }
  report.ok = report.problems.length === 0;
  return report;
}

module.exports = {
  MANIFEST_NAME,
  PLACEHOLDER,
  pkgRoot,
  pkgVersion,
  resolvePrefix,
  manifestPath,
  listPlugins,
  pluginForCommandFile,
  isBinary,
  substitute,
  install,
  uninstall,
  doctor,
};
