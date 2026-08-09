#!/usr/bin/env node
"use strict";
//
// bin/cli.js — `claude-plugins-opencode install|uninstall|doctor`
//
// Kept deliberately thin: all real logic lives in lib/installer.js so postinstall.js
// (which runs unattended, with no argv to parse) can call the exact same install()
// function this CLI's `install` subcommand calls.
//
// `install` is what performs the __PLUGIN_ROOT__ substitution described in
// lib/installer.js's substitute() (a literal find/replace — the JS equivalent of a
// `sed` pass, done with String#split/#join instead of a shell to avoid quoting a
// path that may contain spaces): every file this package ships under commands/ and
// share/<plugin>/ carries the literal __PLUGIN_ROOT__ placeholder, and install()
// replaces it with the resolved absolute path of that plugin's installed share/
// directory. Re-running `install` re-substitutes from this package's pristine,
// unmodified templates, so it is idempotent.
//

const installer = require("../lib/installer.js");

function parseArgs(argv) {
  const args = { command: null, prefix: null, error: null };
  const rest = [];
  for (let i = 0; i < argv.length; i++) {
    const arg = argv[i];
    if (arg === "--prefix") {
      // A trailing `--prefix` with no following value must not silently resolve to
      // the default prefix — that turns a typo'd invocation like
      // `claude-plugins-opencode uninstall --prefix` into an uninstall against the
      // operator's real ~/.config/opencode instead of erroring out.
      if (i + 1 >= argv.length) {
        args.error = "--prefix requires a value";
        break;
      }
      args.prefix = argv[++i];
    } else if (arg.startsWith("--prefix=")) {
      const value = arg.slice("--prefix=".length);
      // Empty-value case: `--prefix=` with nothing after the `=`. Falsy, so
      // `resolvePrefix`'s `explicit || ...` fallback would silently resolve to the
      // real OPENCODE_CONFIG_DIR / ~/.config/opencode — exactly the guard the
      // space-separated form above already closes for a trailing bare `--prefix`.
      if (value === "") {
        args.error = "--prefix requires a value";
        break;
      }
      args.prefix = value;
    } else if (arg.startsWith("-") && arg !== "-") {
      // Any other dash-prefixed token is a mistyped or unknown flag, not a
      // positional command — falling through to `rest` would let e.g.
      // `uninstall -prefix /tmp/x` (missing a dash) or `--prefixx` be swallowed as
      // extra positionals while `--prefix` stays unset, so resolvePrefix() falls
      // back to the *real* OPENCODE_CONFIG_DIR / ~/.config/opencode — turning a
      // typo into an uninstall against the operator's live install.
      args.error = `unknown flag: ${arg}`;
      break;
    } else {
      rest.push(arg);
    }
  }
  if (!args.error) {
    if (rest.length > 1) {
      // Extra positional args past the command are almost always a mistyped flag
      // that slipped through as plain text (e.g. a stray value with no leading
      // dash) — reject rather than silently ignoring everything after rest[0].
      args.error = `unexpected argument(s): ${rest.slice(1).join(" ")}`;
    } else {
      args.command = rest[0] || null;
    }
  }
  return args;
}

function usage() {
  return [
    "usage: claude-plugins-opencode <install|uninstall|doctor> [--prefix <dir>]",
    "",
    "  install    copy commands/scripts into the OpenCode config dir, substituting __PLUGIN_ROOT__",
    "  uninstall  remove exactly what a prior install wrote, per its manifest (fails closed on out-of-prefix paths)",
    "  doctor     report install health — detects a --ignore-scripts install that skipped postinstall",
    "",
    "  --prefix <dir>   override the OpenCode config dir (default: $OPENCODE_CONFIG_DIR or ~/.config/opencode)",
  ].join("\n");
}

function main(argv) {
  const { command, prefix, error } = parseArgs(argv);

  if (error) {
    console.error(`error: ${error}`);
    console.error(usage());
    return 1;
  }

  switch (command) {
    case "install": {
      const manifest = installer.install({ prefix });
      console.log(`installed ${manifest.files.length} file(s) for ${manifest.plugins.length} plugin(s) into ${manifest.prefix}`);
      if (manifest.removedOrphans && manifest.removedOrphans.length > 0) {
        console.log(`removed ${manifest.removedOrphans.length} stale file(s) no longer produced by this package`);
      }
      return 0;
    }
    case "uninstall": {
      const result = installer.uninstall({ prefix });
      console.log(result.note);
      return 0;
    }
    case "doctor": {
      const report = installer.doctor({ prefix });
      console.log(`claude-plugins-opencode ${report.packageVersion}`);
      console.log(`prefix:    ${report.prefix}`);
      console.log(`installed: ${report.installed}`);
      console.log(`plugins:   ${report.plugins.join(", ") || "(none)"}`);
      if (report.problems.length === 0) {
        console.log("ok: install looks healthy");
      } else {
        for (const problem of report.problems) console.log(`problem: ${problem}`);
      }
      return report.ok ? 0 : 1;
    }
    default: {
      console.error(usage());
      return 1;
    }
  }
}

if (require.main === module) {
  let code = 1;
  try {
    code = main(process.argv.slice(2));
  } catch (err) {
    console.error(`error: ${err.message}`);
    code = 1;
  }
  process.exitCode = code;
}

module.exports = { main, parseArgs, usage };
