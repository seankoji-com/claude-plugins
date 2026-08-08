"use strict";
//
// postinstall.js — runs automatically on `npm install` (unless the install used
// --ignore-scripts, in which case this never fires and `claude-plugins-opencode doctor`
// is how a user is meant to discover that and self-heal with `install`).
//
// Deliberately calls the exact same installer.install() the `install` CLI subcommand
// calls — one implementation, two entry points.
//

const installer = require("./lib/installer.js");

try {
  const manifest = installer.install({});
  console.log(
    `claude-plugins-opencode: installed ${manifest.files.length} file(s) for ${manifest.plugins.length} plugin(s) into ${manifest.prefix}`
  );
} catch (err) {
  console.error(`claude-plugins-opencode postinstall failed: ${err.message}`);
  process.exitCode = 1;
}
