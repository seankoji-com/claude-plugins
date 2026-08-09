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

function listPlugins(root) {
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

function writeFileWithMode(destPath, content, mode) {
  fs.mkdirSync(path.dirname(destPath), { recursive: true });
  fs.writeFileSync(destPath, content, { encoding: "utf8" });
  fs.chmodSync(destPath, mode);
}

function install(opts) {
  opts = opts || {};
  const root = pkgRoot();
  const prefix = resolvePrefix(opts.prefix);
  const plugins = listPlugins(root);
  const written = [];

  for (const plugin of plugins) {
    const srcShare = path.join(root, "share", plugin);
    const destShare = path.join(prefix, "share", plugin);
    for (const srcFile of walkFiles(srcShare)) {
      const rel = path.relative(srcShare, srcFile);
      const destFile = path.join(destShare, rel);
      const mode = fs.statSync(srcFile).mode;
      const content = substitute(fs.readFileSync(srcFile, "utf8"), destShare);
      writeFileWithMode(destFile, content, mode);
      written.push(destFile);
    }
  }

  const srcCommands = path.join(root, "commands");
  if (fs.existsSync(srcCommands)) {
    for (const srcFile of walkFiles(srcCommands).filter((f) => f.endsWith(".md"))) {
      const filename = path.basename(srcFile);
      const plugin = pluginForCommandFile(filename, plugins);
      if (!plugin) {
        throw new Error(
          `install: ${filename} does not match any known plugin under share/ — ` +
            "the generated package is inconsistent (regenerate dist/opencode)"
        );
      }
      const destShare = path.join(prefix, "share", plugin);
      const destFile = path.join(prefix, "commands", filename);
      const mode = fs.statSync(srcFile).mode;
      const content = substitute(fs.readFileSync(srcFile, "utf8"), destShare);
      writeFileWithMode(destFile, content, mode);
      written.push(destFile);
    }
  }

  written.sort();
  const manifest = {
    manifestVersion: 1,
    packageVersion: pkgVersion(),
    prefix,
    installedFrom: root,
    installedAt: new Date().toISOString(),
    plugins,
    files: written,
  };
  fs.mkdirSync(prefix, { recursive: true });
  fs.writeFileSync(manifestPath(prefix), JSON.stringify(manifest, null, 2) + "\n", "utf8");

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
  const manifest = JSON.parse(fs.readFileSync(mPath, "utf8"));
  const files = Array.isArray(manifest.files) ? manifest.files : [];

  const prefixResolved = path.resolve(prefix) + path.sep;
  for (const file of files) {
    const resolved = path.resolve(file);
    if (!(resolved + path.sep).startsWith(prefixResolved)) {
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

  // Best-effort cleanup of now-empty directories, deepest first, never past prefix.
  //
  // The climb resolves each dirname and reuses the same trailing-separator boundary test
  // as the file guard above, rather than a bare string startsWith on the raw manifest
  // value. Without that, a manifest entry like "<prefix>/../opencode/commands/x.md"
  // passes the file guard (it *resolves* inside the prefix) while its unresolved dirname
  // climbs to "<prefix>/.." — the prefix's parent. That escape is not currently
  // reachable, but only by accident: the manifest file itself still sits in the prefix
  // during this loop, so rmdir hits ENOTEMPTY and breaks. Moving the `fs.rmSync(mPath)`
  // below up above this loop — an innocuous-looking reorder — would make it live. The
  // guard is here so the fail-closed property does not depend on that ordering.
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
  const manifest = JSON.parse(fs.readFileSync(mPath, "utf8"));
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
  substitute,
  install,
  uninstall,
  doctor,
};
